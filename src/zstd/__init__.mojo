# The decoding loops below follow libs/zstd/src/zstd/codec.mojo of
# https://github.com/amarbaro/mojo-libs at tag zstd-v0.4.1 (commit 72d4eaf;
# Apache License 2.0, Copyright 2026 AMARBARO; see NOTICE), modified: this
# file is zstd.mojo's own API over the vendored encoder and decoder.
"""`zstd` — Zstandard (RFC 8878) compression in pure Mojo: one-shot and
streaming compress/decompress and frame introspection, with no C library and
no foreign calls.

The codec is vendored from amarbaro/mojo-libs (the `_*.mojo` modules here, a
port of libzstd's algorithms; see NOTICE). This file is the public API:
`compress`, `decompress`, `decompress_into`, `is_zstd_frame`,
`frame_content_size`, `Compressor` and `Decompressor`.

Every error is an `Error` whose text starts with `zstd: `, e.g.
`zstd: corrupt input`, `zstd: truncated input`, `zstd: checksum mismatch` or
`zstd: destination buffer too small`.

Not supported: dictionaries (a frame that names one raises), multi-threaded
compression and long-distance matching. Frames whose window is over 128 MiB
(`--long=28` and up) are refused, as libzstd refuses them by default.
"""

from std.memory import unsafe_memmove
from ._compress import BLOCK, Zenc, compress_all
from ._decode import Zdec


def _truncated() -> Error:
    return Error("zstd: truncated input")


# ---------------------------------------------------------------------------
# One-shot
# ---------------------------------------------------------------------------


def _compress_stream(data: Span[UInt8, _], level: Int) -> List[UInt8]:
    """The whole of `data` through the streaming encoder: one frame with no
    content size, for inputs the one-shot encoder doesn't take (2 GiB and
    over)."""
    var z = Zenc(level)
    var i = 0
    while i < len(data):
        var n = min(len(data) - i, 1 << 24)
        z.write(data[i : i + n])
        i += n
    z.finish()
    var out = List[UInt8]()
    swap(out, z.out)
    return out^


def compress(data: Span[UInt8, _], level: Int = 3) raises -> List[UInt8]:
    """Compresses `data` into a single zstd frame at `level`.

    Levels are libzstd's: 1..22, 0 meaning the default (3), negative levels
    faster still; out-of-range levels are clamped. The frame records the
    content size and an XXH64 checksum. Zero-length `data` still produces a
    valid, tiny frame that decompresses back to zero bytes. Inputs of 2 GiB
    and more go through the streaming encoder, into a frame without a
    content size.
    """
    if len(data) >= 1 << 31:
        return _compress_stream(data, level)
    var out = compress_all(data, level)
    # The encoder reserves room for input that doesn't compress. A caller that
    # keeps many frames (a Parquet writer's pages) shouldn't keep that too.
    if out.capacity() > len(out) + len(out) // 4 + 4096:
        var tight = List[UInt8](capacity=len(out))
        tight.extend(Span(out))
        return tight^
    return out^


def decompress(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Decompresses every frame of `data`, concatenated (skippable frames are
    skipped). Empty `data` gives an empty result.

    When the first frame records its content size (true for anything
    `compress()` produced) the output is allocated at that size up front;
    otherwise it grows as the frames decode.

    Raises:
        Error: On corrupt or truncated data, a checksum mismatch, or trailing
            bytes that aren't a zstd frame.
    """
    if len(data) == 0:
        return List[UInt8]()
    var d = Zdec(False)
    var size = _header_content_size(data)
    if size > 0:
        # Room for the frame plus the decoder's block slack, so that one frame
        # never regrows the buffer. The header is untrusted: no more than the
        # data could hold (a 4-byte RLE block decodes to at most 128 KiB).
        var hint = min(size, len(data) << 15)
        d.out.resize(unsafe_uninit_length=hint + BLOCK + 64)
    var ip = d.parse(data.unsafe_ptr().unsafe_mut_cast[False](), len(data))
    if ip < len(data) or not d.idle():
        raise _truncated()
    d.out.resize(unsafe_uninit_length=d.op)
    var res = List[UInt8]()
    swap(res, d.out)
    return res^


def decompress_into(
    data: Span[UInt8, _], dst: Span[mut=True, UInt8, _]
) raises -> Int:
    """Decompresses every frame of `data` straight into caller-owned `dst` —
    no growth, no extra allocation, no copy. For callers that already know the
    decompressed size (e.g. a Parquet page's declared uncompressed length).
    Returns the number of bytes written; empty `data` writes nothing.

    `dst` may be larger than the output: the bytes of `dst` past the
    returned count are then scratch, and up to 31 of them may be
    overwritten (the decoder copies in 16- and 32-byte steps). Nothing past
    the end of `dst` is ever written.

    Raises:
        Error: `zstd: destination buffer too small` if the frames hold more
            than `dst` does (bytes up to that point may have been written),
            and as `decompress` does on invalid data.
    """
    if len(data) == 0:
        return 0
    var d = Zdec(dst=dst)
    var ip = d.parse(data.unsafe_ptr().unsafe_mut_cast[False](), len(data))
    if ip < len(data) or not d.idle():
        raise _truncated()
    return d.op


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


def _header_content_size(data: Span[UInt8, _]) -> Int:
    """The content size in the frame header at the start of `data`: -1 when
    the header doesn't record one, -2 when `data` doesn't start with a whole
    zstd frame header."""
    if not is_zstd_frame(data) or len(data) < 5:
        return -2
    var fd = Int(data[4])
    if fd & 8 != 0:  # reserved bit
        return -2
    var single = (fd >> 5) & 1
    var fcs = fd >> 6
    var dsz = 0 if fd & 3 == 0 else (1 if fd & 3 == 1 else (2 if fd & 3 == 2 else 4))
    var csz = single if fcs == 0 else (2 if fcs == 1 else (4 if fcs == 2 else 8))
    var q = 5 + (1 - single) + dsz
    if len(data) < q + csz:
        return -2
    if csz == 0:
        return -1
    var v = 0
    for k in range(csz):
        v |= Int(data[q + k]) << (8 * k)
    if csz == 2:
        v += 256
    if v < 0:  # 2^63 and up: more than any buffer
        return -2
    return v


def frame_content_size(data: Span[UInt8, _]) raises -> Optional[Int]:
    """The decompressed size recorded in a zstd frame header, or `None` if
    `data` doesn't start with a zstd frame header or the frame doesn't carry a
    content size (e.g. one written by `Compressor`). Only the first frame's
    header is read."""
    var size = _header_content_size(data)
    if size < 0:
        return None
    return size


# ---------------------------------------------------------------------------
# Streaming
# ---------------------------------------------------------------------------


struct Compressor(Movable):
    """A streaming zstd compressor. Feed chunks to `update()`; call `finish()`
    once at the end to write the last block and the checksum.

    Input is kept in a window buffer (the level's window plus 256 KiB:
    2.25 MiB at level 3) and compressed a 128 KiB block at a time, so
    `update()` returns each block as soon as it's full and memory stays flat
    whatever the total size. The frame records a checksum but no content
    size. After `finish()`, the next `update()` or `finish()` starts a new
    frame.
    """

    var _z: Zenc
    var _level: Int
    var _done: Bool

    def __init__(out self, level: Int = 3) raises:
        """A compressor at `level`, as `compress()` takes it."""
        self._z = Zenc(level)
        self._level = level
        self._done = False

    def _take(mut self) -> List[UInt8]:
        var out = List[UInt8]()
        swap(out, self._z.out)
        return out^

    def _restart(mut self):
        if self._done:
            self._z = Zenc(self._level)
            self._done = False

    def update(mut self, chunk: Span[UInt8, _]) raises -> List[UInt8]:
        """Compresses `chunk`, returning the compressed bytes that are ready
        (the frame header and every finished block; may be empty)."""
        self._restart()
        self._z.write(chunk)
        return self._take()

    def finish(mut self) raises -> List[UInt8]:
        """Compresses what is left and writes the frame epilogue (last block,
        checksum). Call once, after the last `update()`."""
        self._restart()
        self._z.finish()
        self._done = True
        return self._take()


def _drain(
    mut d: Zdec, p: ImmPointer[UInt8, _], n: Int, mut out: List[UInt8]
) raises -> Int:
    """Decodes what is complete in p[0:n] through the sliding decoder `d`,
    appending the output to `out`; returns the bytes consumed."""
    var ip = 0
    var progress = True
    while progress:
        var c = d.parse(p.unsafe_offset(ip), n - ip)
        ip += c
        var got = d.op - d.rd
        if got > 0:
            out.extend(Span(d.out)[d.rd : d.op])
            d.rd = d.op
        progress = c > 0 or got > 0
    return ip


struct Decompressor(Movable):
    """A streaming zstd decompressor. Feed compressed chunks to `update()` as
    they arrive, cut anywhere; each call returns what they decode to. Frames
    may follow one another. `finish()` returns nothing and raises if the input
    stopped inside a frame.

    Memory is the frame's window (8 MiB at most for what libzstd writes at
    levels up to 19 without `--long`) plus at most about one block of input
    held over between calls.
    """

    var _d: Zdec
    var _pend: List[UInt8]

    def __init__(out self) raises:
        self._d = Zdec(True)
        self._pend = List[UInt8]()

    def update(mut self, chunk: Span[UInt8, _]) raises -> List[UInt8]:
        """Decompresses as much as `chunk` (with what earlier calls held over)
        completes, and holds over the rest.

        Raises:
            Error: On corrupt data, a checksum mismatch, or bytes between
                frames that aren't a zstd frame.
        """
        var out = List[UInt8]()
        if len(self._pend) == 0:
            var p = chunk.unsafe_ptr().unsafe_mut_cast[False]()
            var used = _drain(self._d, p, len(chunk), out)
            self._pend.extend(chunk[used:])
            return out^
        self._pend.extend(chunk)
        var p = self._pend.unsafe_ptr().unsafe_mut_cast[False]()
        var used = _drain(self._d, p, len(self._pend), out)
        var left = len(self._pend) - used
        if used > 0 and left > 0:
            var b = self._pend.unsafe_ptr()
            unsafe_memmove(
                dest=b,
                src=b.unsafe_offset(used).unsafe_origin_cast[
                    MutUntrackedOrigin
                ](),
                count=left,
            )
        self._pend.resize(unsafe_uninit_length=left)
        return out^

    def finish(mut self) raises -> List[UInt8]:
        """Checks that the input ended between frames. Returns no bytes:
        `update()` already returned everything. Kept so `Compressor` and
        `Decompressor` share the same update/finish shape.

        Raises:
            Error: `zstd: truncated input` if the input so far stops inside a
                frame.
        """
        if len(self._pend) > 0 or self._d.inframe or self._d.skip > 0:
            raise _truncated()
        return List[UInt8]()
