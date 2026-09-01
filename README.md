# zstd.mojo

[![mojoshelf](https://mojoshelf.org/badge/zstd-mojo.svg)](https://mojoshelf.org/tins/zstd-mojo) [![mojo nightly](https://mojoshelf.org/badge/zstd-mojo/nightly.svg)](https://mojoshelf.org/tins/zstd-mojo)

[![CI](https://github.com/magmalake/zstd.mojo/actions/workflows/ci.yml/badge.svg)](https://github.com/magmalake/zstd.mojo/actions/workflows/ci.yml) [![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

> Part of [**magmalake**](https://magmalake.org) — data lake building blocks in Mojo.

A Mojo binding to **libzstd** — one-shot and streaming compress/decompress —
via FFI, built the same way [zlib.mojo](https://github.com/magmalake/zlib.mojo)
wraps zlib: a small C shim (`shim/zstd_wrapper.c`) compiled to
**`libzstdmojo.so`** and loaded through an `OwnedDLHandle`. No link flags for
consumers; the shim is `dlopen`ed at runtime.

zstd is Apache Iceberg's default Parquet codec, a Puffin blob codec, and an
Avro codec — that's the headline use this binding targets. It wraps the real
libzstd (conda-forge's `zstd` package); a pure-Mojo zstd is out of scope.

## Install

```sh
pixi shelf add zstd-mojo
```

That resolves the tin from [mojoshelf](https://mojoshelf.org) and adds it — along with the tins it depends on — as **pixi git source dependencies**. magmalake tins are not published to a conda channel, so `pixi add zstd-mojo` will not find them.

## Prerequisites

- [pixi](https://pixi.sh)
- Nothing else — `zstd` (the C library) and the shim are pulled in and built
  automatically as pixi dependencies.

## Use

```mojo
from zstd import compress, decompress

var z   = compress(raw)          # Span[UInt8] -> List[UInt8], level 1..22 (default 3)
var raw2 = decompress(z)         # -> List[UInt8], byte-for-byte back

var n = decompress_into(z, dst)  # write straight into a caller-owned buffer
                                  # (e.g. a Parquet page's declared size) —
                                  # no growth, no extra allocation

is_zstd_frame(z)                 # Bool — magic-number sniff, no allocation
frame_content_size(z)            # Optional[Int] — decompressed size from
                                  # the frame header, if it carries one
```

Build a consumer with this package on the import path:

```sh
mojo build your.mojo -I ../zstd.mojo/src -o your-bin
```

`_find_lib()` resolves the shim at `$CONDA_PREFIX/lib/libzstdmojo.so` (or
`build/` for a bare checkout). For distribution, bundle `libzstdmojo.so`
alongside the binary and relocate it with `@loader_path`.

### Streaming

For data that doesn't fit in memory at once, `Compressor`/`Decompressor` wrap
`ZSTD_CCtx`/`ZSTD_DCtx` (the modern API's `ZSTD_CStream`/`ZSTD_DStream`):

```mojo
from zstd import Compressor, Decompressor

var c = Compressor(level=9)
var out = List[UInt8]()
for chunk in chunks:
    out.extend(c.update(chunk))
out.extend(c.finish())            # flush the trailing block + frame epilogue

var d = Decompressor()
var back = List[UInt8]()
for chunk in compressed_chunks:
    back.extend(d.update(chunk))
back.extend(d.finish())           # no-op — kept for symmetry with Compressor
```

`decompress()` itself falls back to this same streaming path internally when
a frame's content size is unknown (e.g. streamed with an unset pledged size),
growing its output buffer as it goes.

### Errors

Errors raise with libzstd's own error name, straight from
`ZSTD_getErrorName` — e.g. `zstd.decompress: Corruption_detected` or
`zstd.decompress_into: Dst_Too_Small`.

## Test

```sh
pixi run test       # builds the shim, then round-trips + a known-frame decode
pixi run -e stable test    # same, pinned to Mojo 1.0.0 instead of nightly
```

Covers: round trips at several sizes (0 B, 1 B, 1 KiB, 1 MiB compressible,
1 MiB random) and levels; decoding a frame produced independently by Python
`zstandard`, baked in as byte constants; streaming matching one-shot output;
and a corrupt frame raising.

## Perf

```sh
pixi run bench       # 64 MiB compressible + random buffers, a few levels
```

Indicative numbers, one M-series macOS core, `pixi run -e stable bench`:

| data         | level | compress    | decompress  | ratio  |
|--------------|-------|------------:|------------:|-------:|
| compressible |     1 | ~10.2 GB/s  | ~7.4 GB/s   | 10824x |
| compressible |     3 | ~12.0 GB/s  | ~10.8 GB/s  | 10824x |
| compressible |     9 | ~2.1 GB/s   | ~11.6 GB/s  |   747x |
| compressible |    19 | ~2.1 GB/s   | ~19.8 GB/s  |  11792x |
| random       |     1 | ~7.7 GB/s   | ~31.9 GB/s  |  ~1.0x |
| random       |     3 | ~10.0 GB/s  | ~32.1 GB/s  |  ~1.0x |
| random       |     9 | ~5.4 GB/s   | ~31.3 GB/s  |  ~1.0x |

Numbers vary run to run; re-run `pixi run bench` for your own hardware.

The shim is `dlopen`ed **once per process** and never closed, so the one-shot
`compress()`/`decompress()` calls are safe in a hot loop. They did not used to
be: through 0.1.0 every call opened and closed the handle, which on macOS costs
around 450 µs whether the library is already resident or not. That fixed cost
swamped the actual work on anything page-sized — a 24 MiB ZSTD Parquet file
(332 pages) spent ~150 ms in `dlopen` and ~25 ms decompressing. Caching the
handle took the fixed cost of a call from ~415 µs to ~1.4 µs.

## How the shim is built

`shim/` is a [pixi-build-cmake](https://pixi.sh) package: `CMakeLists.txt`
finds conda-forge's `zstd` CMake package config (`find_package(zstd CONFIG)`
— zstd ships one, unlike zlib's bundled CMake `Find` module) and links
`zstd_wrapper.c` into `libzstdmojo.so`, installed to `$CONDA_PREFIX/lib`. It's
a pixi source dependency (`zstd-shim = { path = "shim" }`) of the top-level
workspace, so `pixi install`/`pixi run` builds it automatically — no manual
build step.

The shim itself stays thin: it's mostly ABI hygiene (building
`ZSTD_inBuffer`/`ZSTD_outBuffer` structs internally so Mojo never replicates
their layout) rather than reimplementing anything — one-shot compress/decompress,
error-code checks, and streaming all forward straight to the matching libzstd
call.

## Status / scope

- Targets `osx-arm64`, `linux-64`, `linux-aarch64`.
- One-shot and streaming compress/decompress, frame introspection
  (`is_zstd_frame`, `frame_content_size`). No dictionary support, no
  multi-threaded compression — out of scope for a leaf tin; open an issue if
  you need either.
- Compiles on Mojo stable (`==1.0.0`, the `stable` pixi environment) and on
  the Modular nightly channel (`default` environment) — see CI.

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
