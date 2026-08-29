"""Test gate for zstd.mojo.

  - round trips at several sizes/levels (0 B, 1 B, 1 KiB, 1 MiB compressible,
    1 MiB random)
  - a known frame produced by Python `zstandard` decodes to the exact bytes
    it was made from
  - streaming (Compressor/Decompressor) matches one-shot (compress/decompress)
  - is_zstd_frame / frame_content_size agree with what compress() produced
  - corrupt input raises
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
    # true and decompress() takes the real libzstd path) but is truncated /
    # garbage after that — not a valid frame.
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


def main() raises:
    _test_edge_sizes()
    _test_known_frame()
    _test_corrupt_input()
    print("zstd.mojo: all tests passed")
