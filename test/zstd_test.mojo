"""Test gate for zstd.mojo.

  - round trips at several sizes/levels (0 B, 1 B, 1 KiB, 1 MiB compressible,
    1 MiB random)
  - a known frame produced by Python `zstandard` decodes to the exact bytes
    it was made from
  - streaming (Compressor/Decompressor) matches one-shot (compress/decompress)
  - is_zstd_frame / frame_content_size agree with what compress() produced
  - corrupt and truncated input raises, a short decompress_into buffer
    raises, and Decompressor.finish() raises on a stream cut inside a frame
  - concatenated frames, out-of-range levels, Compressor output before
    finish() and a Compressor reused after finish()
  - Decompressor waits for a checksum that arrives in a later update() than
    the last block (a local fix over upstream), and decompress_into never
    writes past an exactly sized destination

test/cli_test.sh checks the same API against the `zstd` command-line tool.
"""

from std.random import seed, random_ui64
from zstd import (
    compress,
    decompress,
    decompress_into,
    is_zstd_frame,
    frame_content_size,
    Compressor,
    Decompressor,
)


def _assert_bytes_equal(got: Span[UInt8, _], want: Span[UInt8, _], msg: String) raises:
    if len(got) != len(want):
        raise Error(
            msg
            + ": length mismatch "
            + String(len(got))
            + " != "
            + String(len(want))
        )
    for i in range(len(want)):
        if got[i] != want[i]:
            raise Error(msg + ": byte mismatch at index " + String(i))


def _make_compressible(n: Int) -> List[UInt8]:
    var pattern = "The quick brown fox jumps over the lazy dog. "
    var pbytes = pattern.as_bytes()
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(pbytes[i % len(pbytes)])
    return out^


def _make_random(n: Int, seed_value: Int) -> List[UInt8]:
    seed(seed_value)
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(UInt8(random_ui64(0, 255)))
    return out^


def _round_trip(data: Span[UInt8, _], level: Int, label: String) raises:
    var comp = compress(data, level)
    if not is_zstd_frame(comp):
        raise Error(label + ": compress() output missing zstd magic")
    var maybe_size = frame_content_size(comp)
    if maybe_size:
        if maybe_size.value() != len(data):
            raise Error(
                label
                + ": frame_content_size "
                + String(maybe_size.value())
                + " != "
                + String(len(data))
            )
    var back = decompress(comp)
    _assert_bytes_equal(back, data, label + " (one-shot)")

    # decompress_into: caller already knows the size (the common Parquet-page
    # case), so it can allocate exactly and skip decompress()'s own sizing.
    if len(data) > 0:
        var dst = List[UInt8](capacity=len(data))
        dst.resize(len(data), 0)
        var n = decompress_into(comp, dst)
        if n != len(data):
            raise Error(
                label + ": decompress_into wrote " + String(n) + " bytes"
            )
        _assert_bytes_equal(dst, data, label + " (decompress_into)")

    # Streaming compress, fed in a few chunks, must match the one-shot frame's
    # decompressed content (frames need not be byte-identical - level/window
    # choices can differ - only the decompressed payload has to match).
    var comp2 = List[UInt8]()
    var chunk_size = len(data) // 3 + 1
    var compressor = Compressor(level)
    var offset = 0
    while offset < len(data):
        var end = offset + chunk_size
        if end > len(data):
            end = len(data)
        comp2.extend(compressor.update(data[offset:end]))
        offset = end
    comp2.extend(compressor.finish())

    var back2 = decompress(comp2)
    _assert_bytes_equal(back2, data, label + " (streaming compress)")

    # Streaming decompress of the one-shot frame, fed in a few chunks, must
    # match the plain decompress() result.
    var back3 = List[UInt8]()
    var decompressor = Decompressor()
    var dchunk = len(comp) // 3 + 1
    var doffset = 0
    while doffset < len(comp):
        var dend = doffset + dchunk
        if dend > len(comp):
            dend = len(comp)
        back3.extend(decompressor.update(comp[doffset:dend]))
        doffset = dend
    back3.extend(decompressor.finish())
    _assert_bytes_equal(back3, data, label + " (streaming decompress)")


def _test_known_frame() raises:
    # Produced by Python `zstandard`:
    #   zstandard.ZstdCompressor(level=9).compress(
    #       b"magmalake zstd.mojo known-frame test\n"
    #   )
    var frame: List[UInt8] = [
        40, 181, 47, 253, 32, 37, 41, 1, 0, 109, 97, 103, 109, 97, 108, 97,
        107, 101, 32, 122, 115, 116, 100, 46, 109, 111, 106, 111, 32, 107,
        110, 111, 119, 110, 45, 102, 114, 97, 109, 101, 32, 116, 101, 115,
        116, 10,
    ]
    var want = "magmalake zstd.mojo known-frame test\n".as_bytes()

    if not is_zstd_frame(frame):
        raise Error("known frame: is_zstd_frame() false")
    var maybe_size = frame_content_size(frame)
    if not maybe_size:
        raise Error("known frame: frame_content_size() unexpectedly unknown")
    if maybe_size.value() != len(want):
        raise Error(
            "known frame: content size "
            + String(maybe_size.value())
            + " != "
            + String(len(want))
        )

    var back = decompress(frame)
    _assert_bytes_equal(back, want, "known frame")
    print("known-frame decode OK:", len(frame), "bytes ->", len(want), "back")


def _test_corrupt_input() raises:
    # A short buffer that starts with the zstd magic (so is_zstd_frame is
    # true) but is garbage after that — not a valid frame.
    var junk: List[UInt8] = [40, 181, 47, 253, 1, 2, 3, 4, 5, 6, 7, 8]
    var raised = False
    var message = String("")
    try:
        _ = decompress(junk)
    except e:
        raised = True
        message = String(e)
    if not raised:
        raise Error("corrupt input: decompress() did not raise")
    print("corrupt input correctly raised:", message)


def _test_edge_sizes() raises:
    _round_trip(List[UInt8](), 3, "0 B")

    var one_byte: List[UInt8] = [42]
    _round_trip(one_byte, 3, "1 B")

    for level in [1, 3, 9]:
        _round_trip(_make_compressible(1024), level, "1 KiB compressible")

    for level in [1, 3, 19]:
        _round_trip(_make_compressible(1024 * 1024), level, "1 MiB compressible")

    _round_trip(_make_random(1024 * 1024, 1234), 3, "1 MiB random")


def _expect_raise(msg: String, what: String) raises:
    """Raises unless `msg` (an error caught by the caller, or "" for none) is
    a zstd error."""
    if not msg.startswith("zstd: "):
        raise Error(what + ": did not raise a zstd error (" + msg + ")")


def _test_errors() raises:
    var data = _make_compressible(100_000)
    var comp = compress(data, 3)

    # Every proper prefix is truncated: decompress and decompress_into raise.
    for k in range(0, len(comp), 7):
        if k == 0:
            continue
        var msg = String("")
        try:
            _ = decompress(Span(comp)[:k])
        except e:
            msg = String(e)
        _expect_raise(msg, "decompress of a " + String(k) + "-byte prefix")

    var dst = List[UInt8](length=len(data) - 1, fill=0)
    var msg = String("")
    try:
        _ = decompress_into(comp, dst)
    except e:
        msg = String(e)
    _expect_raise(msg, "decompress_into a short buffer")
    if msg != "zstd: destination buffer too small":
        raise Error("decompress_into a short buffer: " + msg)

    # A stream cut inside its frame: update() returns what it can, finish()
    # raises.
    var d = Decompressor()
    _ = d.update(Span(comp)[: len(comp) - 1])
    msg = String("")
    try:
        _ = d.finish()
    except e:
        msg = String(e)
    _expect_raise(msg, "Decompressor.finish() of a cut stream")
    var empty = Decompressor()
    if len(empty.finish()) != 0:
        raise Error("Decompressor.finish() with no input returned bytes")

    # Trailing bytes that aren't a frame.
    var trailing = comp.copy()
    trailing.extend(Span(comp)[:9])
    msg = String("")
    try:
        _ = decompress(trailing)
    except e:
        msg = String(e)
    _expect_raise(msg, "decompress with trailing bytes")

    var not_frame: List[UInt8] = [1, 2, 3]
    if frame_content_size(not_frame) or frame_content_size(Span(comp)[:5]):
        raise Error("frame_content_size of a non-frame / cut header")
    print("errors raised as expected")


def _test_frames_and_streams() raises:
    var a = _make_compressible(5000)
    var b = _make_random(300_000, 99)
    var ab = a.copy()
    ab.extend(Span(b))

    # Concatenated frames decode to the concatenation, through every path.
    var two = compress(a, 1)
    two.extend(compress(b, 9))
    _assert_bytes_equal(decompress(two), ab, "two frames")
    var dst = List[UInt8](length=len(ab), fill=0)
    var n = decompress_into(two, dst)
    _assert_bytes_equal(Span(dst)[:n], ab, "two frames (decompress_into)")
    var d = Decompressor()
    var back = d.update(two)
    back.extend(d.finish())
    _assert_bytes_equal(back, ab, "two frames (Decompressor)")

    # Levels out of range are clamped, as libzstd clamps them.
    for level in [0, -200_000, 100]:
        _assert_bytes_equal(
            decompress(compress(b, level)), b, "level " + String(level)
        )

    # Compressor hands out blocks before finish(), and starts a new frame
    # after it.
    var c = Compressor(3)
    var big = _make_random(1024 * 1024, 7)
    var early = c.update(big)
    if len(early) < 512 * 1024:
        raise Error(
            "Compressor.update(1 MiB) returned only "
            + String(len(early))
            + " bytes"
        )
    var frame1 = early^
    frame1.extend(c.finish())
    if frame_content_size(frame1):
        raise Error("a Compressor frame recorded a content size")
    var frame2 = c.update(a)
    frame2.extend(c.finish())
    _assert_bytes_equal(decompress(frame1), big, "Compressor frame 1")
    _assert_bytes_equal(decompress(frame2), a, "Compressor frame 2")
    print("frames and streams OK")


def _test_checksum_in_later_chunk() raises:
    """Regression (local fix over upstream): a frame whose 4-byte checksum
    arrives in a later update() than its last block decodes; upstream's push
    parser raised `zstd: truncated input` there."""
    var data = _make_compressible(200_000)
    var comp = compress(data, 3)
    for cut in [4, 3, 2, 1]:
        var d = Decompressor()
        var back = d.update(Span(comp)[: len(comp) - cut])
        back.extend(d.update(Span(comp)[len(comp) - cut :]))
        back.extend(d.finish())
        _assert_bytes_equal(
            back, data, "checksum cut " + String(cut) + " bytes from the end"
        )
    # Every split point of a small frame, in two update() calls.
    var small = compress(_make_compressible(3000), 3)
    var want = decompress(small)
    for k in range(len(small) + 1):
        var d = Decompressor()
        var back = d.update(Span(small)[:k])
        back.extend(d.update(Span(small)[k:]))
        back.extend(d.finish())
        _assert_bytes_equal(back, want, "split at " + String(k))
    print("checksum in a later chunk OK")


def _mixed(n: Int, seed_value: Int) -> List[UInt8]:
    """Short random runs and short repeats at small and large offsets: many
    sequences with short literals and overlapping matches, up to the end."""
    seed(seed_value)
    var out = List[UInt8](capacity=n + 64)
    while len(out) < n:
        var lit = Int(random_ui64(0, 12))
        for _ in range(lit):
            out.append(UInt8(random_ui64(97, 122)))
        if len(out) > 40:
            var off = Int(random_ui64(1, 40 if random_ui64(0, 1) == 0 else UInt64(len(out) - 1)))
            var ml = Int(random_ui64(3, 70))
            for _ in range(ml):
                out.append(out[len(out) - off])
    out.resize(n, 0)
    return out^


def _test_decompress_into_exact_buffer() raises:
    """decompress_into writes nothing past the caller's buffer, even though
    the decoder's 16- and 32-byte copies overshoot the output inside its own
    buffers: the bytes after an exactly sized destination stay untouched."""
    comptime GUARD = 64
    var inputs = List[List[UInt8]]()
    inputs.append(_make_compressible(100_000))
    inputs.append(_mixed(300_000, 5))
    inputs.append(_mixed(1000, 6))
    inputs.append(_make_random(50_000, 8))
    for i in range(len(inputs)):
        for level in [1, 3, 9, 19]:
            var data = Span(inputs[i])
            var comp = compress(data, level)
            var buf = List[UInt8](length=len(data) + GUARD, fill=0xA5)
            var n = decompress_into(comp, Span(buf)[: len(data)])
            var label = "exact buffer, input " + String(i) + " level " + String(level)
            if n != len(data):
                raise Error(label + ": wrote " + String(n))
            _assert_bytes_equal(Span(buf)[: len(data)], data, label)
            for j in range(len(data), len(buf)):
                if buf[j] != 0xA5:
                    raise Error(label + ": byte " + String(j - len(data)) + " past the buffer written")
    print("decompress_into stays inside its buffer")


def main() raises:
    _test_edge_sizes()
    _test_known_frame()
    _test_corrupt_input()
    _test_errors()
    _test_frames_and_streams()
    _test_checksum_in_later_chunk()
    _test_decompress_into_exact_buffer()
    print("zstd.mojo: all tests passed")
