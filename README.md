# zstd.mojo

[![mojoshelf](https://mojoshelf.org/badge/zstd-mojo.svg)](https://mojoshelf.org/tins/zstd-mojo) [![mojo nightly](https://mojoshelf.org/badge/zstd-mojo/nightly.svg)](https://mojoshelf.org/tins/zstd-mojo)

[![CI](https://github.com/magmalake/zstd.mojo/actions/workflows/ci.yml/badge.svg)](https://github.com/magmalake/zstd.mojo/actions/workflows/ci.yml) [![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

> Part of [**magmalake**](https://magmalake.org) — data lake building blocks in Mojo.

**Zstandard** (RFC 8878) in pure Mojo — one-shot and streaming
compress/decompress, and frame introspection. No C library, no shim, no
foreign calls: a binary that uses it needs nothing at run time.

zstd is Apache Iceberg's default Parquet codec, a Puffin blob codec, and an
Avro codec — that's the headline use this tin targets.

The codec is vendored from [amarbaro/mojo-libs](https://github.com/amarbaro/mojo-libs)
(`libs/zstd`, Apache-2.0), a Mojo port of libzstd's algorithms: the
`src/zstd/_*.mojo` modules, each naming its origin and what was changed. The
public API in `src/zstd/__init__.mojo` is this tin's own.

## Install

```sh
pixi shelf add zstd-mojo
```

Working with a coding agent? `npx skills add mojoshelf/mojoshelf --skill mojoshelf-consume --yes` teaches it to find and install tins itself — it installs the `shelf` CLI too.

That resolves the tin from [mojoshelf](https://mojoshelf.org) and adds it — along with the tins it depends on — as **pixi git source dependencies**. magmalake tins are not published to a conda channel, so `pixi add zstd-mojo` will not find them.

## Prerequisites

- [pixi](https://pixi.sh)
- Nothing else.

## Use

```mojo
from zstd import compress, decompress

var z   = compress(raw)          # Span[UInt8] -> List[UInt8], level 1..22 (default 3)
var raw2 = decompress(z)         # -> List[UInt8], byte-for-byte back

var n = decompress_into(z, dst)  # write straight into a caller-owned buffer
                                  # (e.g. a Parquet page's declared size) —
                                  # no growth, no extra allocation, no copy

is_zstd_frame(z)                 # Bool — magic-number sniff, no allocation
frame_content_size(z)            # Optional[Int] — decompressed size from
                                  # the frame header, if it carries one
```

Build a consumer with this package on the import path:

```sh
mojo build your.mojo -I ../zstd.mojo/src -o your-bin
```

`compress` writes one frame with the content size and an XXH64 checksum.
Levels are libzstd's (1..22, 0 for the default 3, negative for faster);
out-of-range levels are clamped. `decompress` and `decompress_into` decode
every frame of their input, concatenated, and skip skippable frames.

### Streaming

For data that doesn't fit in memory at once:

```mojo
from zstd import Compressor, Decompressor

var c = Compressor(level=9)
var out = List[UInt8]()
for chunk in chunks:
    out.extend(c.update(chunk))   # each 128 KiB block as soon as it's full
out.extend(c.finish())            # the last block + the checksum

var d = Decompressor()
var back = List[UInt8]()
for chunk in compressed_chunks:   # cut anywhere
    back.extend(d.update(chunk))
back.extend(d.finish())           # no bytes; raises if the input stopped mid-frame
```

`Compressor` keeps the level's window of input (2.25 MiB at level 3) and
`Decompressor` the frame's window plus at most about one block of input held
over between calls, so memory stays flat whatever the total size. A
`Compressor` frame records a checksum but no content size; after `finish()`,
the next call starts a new frame.

### Errors

Every error is an `Error` whose text starts with `zstd: `, e.g.
`zstd: corrupt input`, `zstd: truncated input`, `zstd: checksum mismatch`,
`zstd: unknown frame prefix` (trailing bytes that aren't a frame) or
`zstd: destination buffer too small` (`decompress_into`).

## Test

```sh
pixi run test
```

`test/zstd_test.mojo`: round trips at several sizes (0 B, 1 B, 1 KiB, 1 MiB
compressible, 1 MiB random) and levels, a frame produced by Python
`zstandard` baked in as bytes, streaming matching one-shot, concatenated
frames, and errors raised.

`test/cli_test.sh` checks against the `zstd` command-line tool (conda-forge's,
a test-only dependency of the workspace, not of the package), both ways: our
frames at levels -5 to 22 decode with the tool, and the tool's frames
(`--fast` to `--ultra -22`, without checksum or content size,
multi-threaded, concatenated, a `--long=27` frame with a 128 MiB window)
decode with ours, through every API. It also decodes the golden frames in
`test/vectors` (from the zstd repository; see NOTICE) as the tool does, and
checks that truncated frames raise and bit-flipped ones raise or decode but
never crash. The whole task takes about 20 s.

## Perf

```sh
pixi run -e bench bench                 # the table below
pixi run -e bench bench -- --json       # every repetition, for tracking
pixi run -e bench bench -- --only bench_compress_random_9
```

One M4 macOS core, 64 MiB per shape, through
[bench.mojo](https://github.com/magmalake/bench.mojo) — mean of three timed
repetitions:

| data         | level | compress  | decompress | libzstd compress | libzstd decompress | ratio  |
|--------------|-------|----------:|-----------:|-----------------:|-------------------:|-------:|
| compressible |     1 | 6.19 GB/s | 2.51 GB/s  | 20.1 GB/s        | 10.8 GB/s          | 10817x |
| compressible |     3 | 3.49 GB/s | 2.75 GB/s  | 12.5 GB/s        | 11.1 GB/s          | 10817x |
| compressible |     9 | 579 MB/s  | 2.53 GB/s  | 2.02 GB/s        | 10.7 GB/s          |   747x |
| compressible |    19 | 332 MB/s  | 3.06 GB/s  | 2.15 GB/s        | 19.7 GB/s          | 11784x |
| random       |     1 | 1.57 GB/s | 10.4 GB/s  | 9.22 GB/s        | 33.2 GB/s          |  ~1.0x |
| random       |     3 | 1.43 GB/s | 7.62 GB/s  | 9.38 GB/s        | 32.0 GB/s          |  ~1.0x |
| random       |     9 | 424 MB/s  | 14.3 GB/s  | 5.66 GB/s        | 32.8 GB/s          |  ~1.0x |

The libzstd columns are the same bench on zstd-mojo 0.2.0 (the libzstd
binding this tin used to be), run the same day. Both runs were taken on a
machine that wasn't idle (the harness flagged them as not steady), so read
the columns against each other, not as absolute figures.

Every push to `main` re-runs these on a GitHub runner and appends to a history
published at
[magmalake.github.io/zstd.mojo/benchmarks](https://magmalake.github.io/zstd.mojo/benchmarks/).
Those numbers are slower and noisier than the table above — each history is
keyed by machine, so the two stay separate series and are never averaged
together.

Rates are against the **uncompressed** size in both directions, so every
level shares a scale. Both shapes are extremes: the compressible one is a
45-byte sentence repeated (it compresses thousands of times over), the random
one doesn't compress at all, which libzstd detects and skips faster than this
codec does. Neither predicts real data.

On real data (a few MiB each of text, a Mach-O binary and YAML, same
machine) this codec takes about 1.4-2.5x libzstd's time to compress at level 3
and 1.4-2.8x to decompress, and its frames are within
0.5% of libzstd's size at the same level.

## Status / scope

- Targets `osx-arm64`, `linux-64`, `linux-aarch64`.
- One-shot and streaming compress/decompress, frame introspection
  (`is_zstd_frame`, `frame_content_size`).
- Not supported: dictionaries (a frame that names one raises),
  multi-threaded compression, long-distance matching when compressing.
  Frames with a window over 128 MiB (`--long=28` and up) are refused, as
  libzstd refuses them by default.
- Frames are valid zstd, decoded by any zstd, but not byte-identical to
  libzstd's.
- Builds on one pinned Mojo nightly, `mojo-compiler ==1.3.0.dev2026111805`;
  a workspace that consumes the package needs that same pin.

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). The vendored codec
is Apache-2.0 (amarbaro/mojo-libs) and ports BSD-licensed Zstandard and
xxHash code; their notices are in NOTICE.
