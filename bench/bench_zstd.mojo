"""Compress and decompress 64 MiB at several levels, through the shared
harness (magmalake/bench.mojo).

    pixi run -e bench bench
    pixi run -e bench bench -- --json
    pixi run -e bench bench -- --only bench_compress_compressible_1

Levels are separate benchmarks rather than a loop, because each is a distinct
number worth tracking, and `--only` / `--skip` can then address one.

Level 19 is cheaper here than intuition suggests -- 31 ms, barely different
from level 9 -- because the synthetic input compresses about 11,800x and the
expensive search finds a match almost immediately. That is a property of this
input, not of level 19; do not read it as a general claim.
"""

from std.random import random_ui64, seed

from bench import Benchmark, BenchSuite, Metric, keep

from zstd import compress, decompress

comptime MIB = 1024 * 1024
comptime SIZE = 64 * MIB


def _compressible(n: Int) -> List[UInt8]:
    var pattern = String("The quick brown fox jumps over the lazy dog. ")
    var pbytes = pattern.as_bytes()
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(pbytes[i % len(pbytes)])
    return out^


def _random(n: Int) -> List[UInt8]:
    seed(7)
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(UInt8(random_ui64(0, 255)))
    return out^

def bench_compress_compressible_1(mut b: Benchmark) raises:
    var data = _compressible(SIZE)
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(compress(Span(data), 1))

    b.iter[call]()
    keep(data)


def bench_decompress_compressible_1(mut b: Benchmark) raises:
    var data = _compressible(SIZE)
    var comp = compress(Span(data), 1)
    # Against the uncompressed size, so every level shares a scale.
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(decompress(comp))

    b.iter[call]()
    keep(data)
    keep(comp)


def bench_compress_compressible_3(mut b: Benchmark) raises:
    var data = _compressible(SIZE)
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(compress(Span(data), 3))

    b.iter[call]()
    keep(data)


def bench_decompress_compressible_3(mut b: Benchmark) raises:
    var data = _compressible(SIZE)
    var comp = compress(Span(data), 3)
    # Against the uncompressed size, so every level shares a scale.
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(decompress(comp))

    b.iter[call]()
    keep(data)
    keep(comp)


def bench_compress_compressible_9(mut b: Benchmark) raises:
    var data = _compressible(SIZE)
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(compress(Span(data), 9))

    b.iter[call]()
    keep(data)


def bench_decompress_compressible_9(mut b: Benchmark) raises:
    var data = _compressible(SIZE)
    var comp = compress(Span(data), 9)
    # Against the uncompressed size, so every level shares a scale.
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(decompress(comp))

    b.iter[call]()
    keep(data)
    keep(comp)


def bench_compress_compressible_19(mut b: Benchmark) raises:
    var data = _compressible(SIZE)
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(compress(Span(data), 19))

    b.iter[call]()
    keep(data)


def bench_decompress_compressible_19(mut b: Benchmark) raises:
    var data = _compressible(SIZE)
    var comp = compress(Span(data), 19)
    # Against the uncompressed size, so every level shares a scale.
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(decompress(comp))

    b.iter[call]()
    keep(data)
    keep(comp)


def bench_compress_random_1(mut b: Benchmark) raises:
    var data = _random(SIZE)
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(compress(Span(data), 1))

    b.iter[call]()
    keep(data)


def bench_decompress_random_1(mut b: Benchmark) raises:
    var data = _random(SIZE)
    var comp = compress(Span(data), 1)
    # Against the uncompressed size, so every level shares a scale.
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(decompress(comp))

    b.iter[call]()
    keep(data)
    keep(comp)


def bench_compress_random_3(mut b: Benchmark) raises:
    var data = _random(SIZE)
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(compress(Span(data), 3))

    b.iter[call]()
    keep(data)


def bench_decompress_random_3(mut b: Benchmark) raises:
    var data = _random(SIZE)
    var comp = compress(Span(data), 3)
    # Against the uncompressed size, so every level shares a scale.
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(decompress(comp))

    b.iter[call]()
    keep(data)
    keep(comp)


def bench_compress_random_9(mut b: Benchmark) raises:
    var data = _random(SIZE)
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(compress(Span(data), 9))

    b.iter[call]()
    keep(data)


def bench_decompress_random_9(mut b: Benchmark) raises:
    var data = _random(SIZE)
    var comp = compress(Span(data), 9)
    # Against the uncompressed size, so every level shares a scale.
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        keep(decompress(comp))

    b.iter[call]()
    keep(data)
    keep(comp)


def _print_ratios() raises:
    """Ratios and round-trip checks, once. The old bench asserted round-trip
    size inside the region it was timing.

    It also warmed the loader here, because one-shot compress/decompress used
    to `dlopen` the shim on every call; that is a process-wide handle now, so
    the warmup is only about page cache.
    """
    var warm = _compressible(4096)
    _ = decompress(compress(Span(warm), 1))

    var c = _compressible(SIZE)
    var r = _random(SIZE)
    print("input", SIZE // MIB, "MiB per shape")
    for level in [1, 3, 9, 19]:
        var cc = compress(Span(c), level)
        if len(decompress(cc)) != SIZE:
            raise Error("compressible round-trip size mismatch")
        var line = String("  compressible level ", level, ": ",
                          len(cc) // 1024, " KiB (",
                          Float64(SIZE) / Float64(len(cc)), "x )")
        if level != 19:
            var rc = compress(Span(r), level)
            if len(decompress(rc)) != SIZE:
                raise Error("random round-trip size mismatch")
            line += String(" | random: ", len(rc) // 1024, " KiB (",
                           Float64(SIZE) / Float64(len(rc)), "x )")
        print(line)


def main() raises:
    _print_ratios()
    # One warmup and three repetitions: level 19 over 64 MiB is seconds per
    # iteration, and every body rebuilds its input once per phase.
    BenchSuite.run[__functions_in_module()](
        num_warmup_iters=1, num_repetitions=3
    )
