"""`zstd` — Mojo bindings to libzstd (one-shot and streaming) via a thin C
shim (libzstdmojo.so).

Mirrors zlib.mojo's FFI pattern: a single-call C wrapper (shim/zstd_wrapper.c,
built to $CONDA_PREFIX/lib/libzstdmojo.so by the zstd-shim pixi package) is
loaded through an `OwnedDLHandle`. The handle is opened **once per process**
and never closed (`_LIB` below) — a `dlopen`/`dlclose` cycle costs hundreds of
microseconds, so opening one per call made the binding's fixed cost dwarf the
compression it wrapped. Every FFI-calling worker takes the handle as a
BORROWED `imm` parameter — Mojo destroys a value at its last syntactic use,
and if a function both owned the handle *and* called `get_function` on it,
that call would be the last use, `dlclose`-ing the library before the obtained
function pointer is actually invoked a few lines later. Splitting "hold the
handle" (`_lib()`) from "use the handle" (a `_do_*` worker that takes it by
`imm` borrow) keeps it alive for the whole worker call, function-pointer
invocation included.

zstd is Apache Iceberg's default Parquet codec, a Puffin blob codec, and an
Avro codec — this binding targets that headline use as a magmalake leaf tin.
"""

from std.os import abort, getenv
from std.ffi import _Global, OwnedDLHandle, c_int, c_long_long, c_size_t


comptime _CONTINUE = 0
comptime _FLUSH = 1
comptime _END = 2


def _find_lib() -> String:
    """Path to libzstdmojo.so: `$CONDA_PREFIX/lib` (installed by the
    zstd-shim pixi package), else `build/` for a bare checkout."""
    var prefix = getenv("CONDA_PREFIX", "")
    if prefix == "":
        return String("build/libzstdmojo.so")
    var out = String("")
    out += prefix
    out += "/lib/libzstdmojo.so"
    return out^


def _open_lib() -> OwnedDLHandle:
    """`dlopen` the shim, once, for the life of the process."""
    try:
        return OwnedDLHandle(_find_lib())
    except e:
        abort(String("zstd.mojo: ", e))


comptime _LIB = _Global["zstd_mojo_shim", _open_lib]
"""The shim handle, opened on first use and never closed.

`dlopen`/`dlclose` is not free — on macOS a full open/close cycle of an
already-resident library measures around 450 microseconds, which is three
orders of magnitude more than decompressing a Parquet page. Opening the
handle per call therefore made the *fixed* cost of a `decompress` dominate
every real workload: a 24 MiB ZSTD Parquet read spends ~150 ms in `dlopen`
and ~10 ms decompressing. One process-wide handle removes all of it, and
`dlsym` on the cached handle costs ~400 ns.

`_Global` initialises exactly once even under concurrent first use, so the
handle is safe to reach from worker threads.
"""


def _lib() raises -> ref[MutUntrackedOrigin] OwnedDLHandle:
    """The cached handle, borrowed. Never destroy the referent."""
    return _LIB.get_or_create_ptr()[]


def _error_name(imm lib: OwnedDLHandle, code: UInt) raises -> String:
    """Reconstructs the `const char*` from `zstdm_error_name` as a `String`.

    The string is one of libzstd's static error-name literals, so its
    lifetime outlives this call regardless of `lib`."""
    var name_fn = lib.get_function[Int]("zstdm_error_name")
    var addr = name_fn(code)
    if addr == 0:
        return String("<unknown zstd error>")
    var p = Pointer[UInt8, ImmUntrackedOrigin](
        unsafe_from_address=addr
    )
    return String(unsafe_from_utf8_ptr=p)


def _check(imm lib: OwnedDLHandle, code: UInt, what: String) raises:
    """Raises with libzstd's own error name (`ZSTD_getErrorName`) if `code`
    (a raw libzstd `size_t` return value) encodes an error."""
    var is_err_fn = lib.get_function[c_int]("zstdm_is_error")
    if Int(is_err_fn(code)) != 0:
        raise Error(what + ": " + _error_name(lib, code))


# ---------------------------------------------------------------------------
# One-shot
# ---------------------------------------------------------------------------


def _do_compress(
    imm lib: OwnedDLHandle, data: Span[UInt8, _], level: c_int
) raises -> List[UInt8]:
    var bound_fn = lib.get_function[c_size_t]("zstdm_compress_bound")
    var cap = Int(bound_fn(c_size_t(len(data))))
    var out = List[UInt8](capacity=cap)
    out.resize(cap, 0)

    var compress_fn = lib.get_function[c_size_t]("zstdm_compress")
    var rc = compress_fn(
        Int(data.unsafe_ptr()),
        c_size_t(len(data)),
        Int(out.unsafe_ptr()),
        c_size_t(cap),
        level,
    )
    _check(lib, rc, "zstd.compress")
    out.resize(Int(rc), 0)
    return out^


def compress(data: Span[UInt8, _], level: Int = 3) raises -> List[UInt8]:
    """Compresses `data` into a single zstd frame at `level` (1..22).

    Zero-length `data` is a real (if degenerate) case for zstd — it still
    produces a valid, tiny frame that decompresses back to zero bytes."""
    ref lib = _lib()
    return _do_compress(lib, data, c_int(level))


def _do_frame_content_size(
    imm lib: OwnedDLHandle, data: Span[UInt8, _]
) raises -> Int:
    var size_fn = lib.get_function[c_long_long]("zstdm_frame_content_size")
    return Int(size_fn(Int(data.unsafe_ptr()), c_size_t(len(data))))


def _do_decompress_known(
    imm lib: OwnedDLHandle, data: Span[UInt8, _], size: Int
) raises -> List[UInt8]:
    var out = List[UInt8](capacity=size)
    out.resize(size, 0)
    if size > 0:
        var decompress_fn = lib.get_function[c_size_t]("zstdm_decompress")
        var rc = decompress_fn(
            Int(data.unsafe_ptr()),
            c_size_t(len(data)),
            Int(out.unsafe_ptr()),
            c_size_t(size),
        )
        _check(lib, rc, "zstd.decompress")
        if Int(rc) != size:
            out.resize(Int(rc), 0)
    return out^


def decompress(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Decompresses a single zstd frame.

    Uses `ZSTD_getFrameContentSize` to size the output in one shot when the
    frame carries it (true for anything `compress()` produced). Falls back
    to the streaming API — growing the output buffer as it goes — when the
    size is unknown (e.g. a frame streamed with an unset pledged size). A
    genuinely corrupt frame raises either way, with libzstd's error name.
    """
    if len(data) == 0:
        return List[UInt8]()
    ref lib = _lib()
    var size = _do_frame_content_size(lib, data)
    if size >= 0:
        return _do_decompress_known(lib, data, size)
    var dec = Decompressor()
    var out = dec.update(data)
    out.extend(dec.finish())
    return out^


def _do_decompress_into(
    imm lib: OwnedDLHandle, data: Span[UInt8, _], dst: Span[mut=True, UInt8, _]
) raises -> Int:
    var decompress_fn = lib.get_function[c_size_t]("zstdm_decompress")
    var rc = decompress_fn(
        Int(data.unsafe_ptr()),
        c_size_t(len(data)),
        Int(dst.unsafe_ptr()),
        c_size_t(len(dst)),
    )
    _check(lib, rc, "zstd.decompress_into")
    return Int(rc)


def decompress_into(
    data: Span[UInt8, _], dst: Span[mut=True, UInt8, _]
) raises -> Int:
    """Decompresses `data` straight into caller-owned `dst` — no growth, no
    extra allocation. For callers that already know the decompressed size
    (e.g. a Parquet page's declared uncompressed length). Returns the number
    of bytes written; raises (`zstd.decompress_into: Dst_Too_Small`, ...) if
    `dst` is too small or `data` is not a valid frame."""
    if len(data) == 0:
        return 0
    ref lib = _lib()
    return _do_decompress_into(lib, data, dst)


# ---------------------------------------------------------------------------
# Frame introspection
# ---------------------------------------------------------------------------


def is_zstd_frame(data: Span[UInt8, _]) -> Bool:
    """Whether `data` starts with the zstd frame magic number (0xFD2FB528,
    little-endian) — a quick, allocation-free format sniff."""
    if len(data) < 4:
        return False
    var magic = (
        UInt32(data[0])
        | (UInt32(data[1]) << 8)
        | (UInt32(data[2]) << 16)
        | (UInt32(data[3]) << 24)
    )
    return magic == 0xFD2FB528


def frame_content_size(data: Span[UInt8, _]) raises -> Optional[Int]:
    """The decompressed size recorded in a zstd frame header, or `None` if
    `data` isn't a zstd frame or the frame doesn't carry a content size
    (e.g. streamed with an unset pledged size)."""
    if not is_zstd_frame(data):
        return None
    ref lib = _lib()
    var size = _do_frame_content_size(lib, data)
    if size < 0:
        return None
    return size


# ---------------------------------------------------------------------------
# Streaming
# ---------------------------------------------------------------------------


struct Compressor(Movable):
    """A streaming zstd compressor over `ZSTD_CCtx` (the modern API's
    `ZSTD_CStream`). Feed chunks to `update()`; call `finish()` once at the
    end to flush the trailing block and frame epilogue."""

    var _cctx: Int

    def __init__(out self, level: Int = 3) raises:
        var create_fn = _lib().get_function[Int]("zstdm_create_cctx")
        self._cctx = create_fn()
        if self._cctx == 0:
            raise Error("zstd.Compressor: ZSTD_createCCtx failed")
        var level_fn = _lib().get_function[c_size_t](
            "zstdm_cctx_set_level"
        )
        var rc = level_fn(self._cctx, c_int(level))
        _check(_lib(), rc, "zstd.Compressor(level)")

    def __deinit__(deinit self):
        try:
            var free_fn = _lib().get_function[c_size_t](
                "zstdm_free_cctx"
            )
            _ = free_fn(self._cctx)
        except:
            pass

    def _drive(mut self, chunk: Span[UInt8, _], end_op: Int) raises -> List[
        UInt8
    ]:
        var stream_fn = _lib().get_function[c_size_t](
            "zstdm_compress_stream2"
        )

        var cap = len(chunk) + 64
        if cap < 4096:
            cap = 4096
        var out = List[UInt8](capacity=cap)
        out.resize(cap, 0)

        var src_pos = List[UInt](capacity=1)
        src_pos.resize(1, 0)
        var dst_pos = List[UInt](capacity=1)
        dst_pos.resize(1, 0)

        var written = 0
        while True:
            var rc = stream_fn(
                self._cctx,
                Int(chunk.unsafe_ptr()),
                c_size_t(len(chunk)),
                Int(src_pos.unsafe_ptr()),
                Int(out.unsafe_ptr()) + written,
                c_size_t(cap - written),
                Int(dst_pos.unsafe_ptr()),
                c_int(end_op),
            )
            _check(_lib(), rc, "zstd.Compressor")
            written += Int(dst_pos[0])
            dst_pos[0] = 0

            var src_done = Int(src_pos[0]) >= len(chunk)
            if end_op == _CONTINUE:
                if src_done:
                    break
            elif src_done and Int(rc) == 0:
                break
            if written >= cap:
                cap *= 2
                out.resize(cap, 0)
        out.resize(written, 0)
        return out^

    def update(mut self, chunk: Span[UInt8, _]) raises -> List[UInt8]:
        """Compresses `chunk`, returning whatever compressed bytes libzstd
        was ready to emit (may be less than a full block; may be empty)."""
        return self._drive(chunk, _CONTINUE)

    def finish(mut self) raises -> List[UInt8]:
        """Flushes the trailing block and frame epilogue (checksum, content
        size if pledged). Call exactly once, after the last `update()`."""
        var empty = List[UInt8]()
        return self._drive(Span(empty), _END)


struct Decompressor(Movable):
    """A streaming zstd decompressor over `ZSTD_DCtx` (the modern API's
    `ZSTD_DStream`). Feed chunks to `update()` as they arrive; there's no
    separate flush step, so `finish()` is a no-op kept for API symmetry with
    `Compressor`."""

    var _dctx: Int

    def __init__(out self) raises:
        var create_fn = _lib().get_function[Int]("zstdm_create_dctx")
        self._dctx = create_fn()
        if self._dctx == 0:
            raise Error("zstd.Decompressor: ZSTD_createDCtx failed")

    def __deinit__(deinit self):
        try:
            var free_fn = _lib().get_function[c_size_t](
                "zstdm_free_dctx"
            )
            _ = free_fn(self._dctx)
        except:
            pass

    def update(mut self, chunk: Span[UInt8, _]) raises -> List[UInt8]:
        """Decompresses as much of `chunk` as libzstd will take in one pass,
        growing the output buffer until all of `chunk` is consumed."""
        var stream_fn = _lib().get_function[c_size_t](
            "zstdm_decompress_stream"
        )

        var cap = len(chunk) * 3
        if cap < 4096:
            cap = 4096
        var out = List[UInt8](capacity=cap)
        out.resize(cap, 0)

        var src_pos = List[UInt](capacity=1)
        src_pos.resize(1, 0)
        var dst_pos = List[UInt](capacity=1)
        dst_pos.resize(1, 0)

        var written = 0
        while True:
            var rc = stream_fn(
                self._dctx,
                Int(chunk.unsafe_ptr()),
                c_size_t(len(chunk)),
                Int(src_pos.unsafe_ptr()),
                Int(out.unsafe_ptr()) + written,
                c_size_t(cap - written),
                Int(dst_pos.unsafe_ptr()),
            )
            _check(_lib(), rc, "zstd.Decompressor")
            written += Int(dst_pos[0])
            dst_pos[0] = 0

            if Int(src_pos[0]) >= len(chunk):
                break
            if written >= cap:
                cap *= 2
                out.resize(cap, 0)
        out.resize(written, 0)
        return out^

    def finish(mut self) raises -> List[UInt8]:
        """No-op — decompression has no trailing flush step. Kept so
        `Compressor`/`Decompressor` share the same update/finish shape."""
        return List[UInt8]()
