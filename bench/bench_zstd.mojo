"""Throughput bench: compress/decompress 64 MiB of compressible and random
data at a few levels, reporting MB/s. `pixi run bench`."""

from std.random import seed, random_ui64
from std.time import perf_counter
from zstd import compress, decompress


comptime MIB = 1024 * 1024
comptime SIZE = 64 * MIB


def _make_compressible(n: Int) -> List[UInt8]:
    var pattern = "The quick brown fox jumps over the lazy dog. "
    var pbytes = pattern.as_bytes()
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(pbytes[i % len(pbytes)])
    return out^


def _make_random(n: Int) -> List[UInt8]:
    seed(7)
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(UInt8(random_ui64(0, 255)))
    return out^


def _bench_one(data: Span[UInt8, _], level: Int, label: String) raises:
    var mib = Float64(len(data)) / Float64(MIB)

    var t0 = perf_counter()
    var comp = compress(data, level)
    var t1 = perf_counter()
    var compress_mbps = mib / (t1 - t0)

    var t2 = perf_counter()
    var back = decompress(comp)
    var t3 = perf_counter()
    var decompress_mbps = mib / (t3 - t2)

    if len(back) != len(data):
        raise Error(label + ": round-trip size mismatch")

    var ratio = Float64(len(data)) / Float64(len(comp))
    print(
        label,
        " level=",
        level,
        ": compress ",
        compress_mbps,
        " MB/s, decompress ",
        decompress_mbps,
        " MB/s, ratio ",
        ratio,
        "x",
        sep="",
    )


def main() raises:
    print("zstd.mojo bench: ", SIZE // MIB, " MiB buffers", sep="")
    var compressible = _make_compressible(SIZE)
    var random_data = _make_random(SIZE)

    # One-shot compress()/decompress() dlopen the shim on every call; warm up
    # the loader (page cache, dlopen) before timing so the first data point
    # isn't skewed by one-time process startup cost.
    var warm = _make_compressible(4096)
    _ = decompress(compress(warm, 1))

    for level in [1, 3, 9, 19]:
        _bench_one(compressible, level, "compressible")
    for level in [1, 3, 9]:
        _bench_one(random_data, level, "random      ")
