# zstd.mojo

[![CI](https://github.com/magmalake/zstd.mojo/actions/workflows/ci.yml/badge.svg)](https://github.com/magmalake/zstd.mojo/actions/workflows/ci.yml) [![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

> Part of **magmalake** — data lake building blocks in Mojo.

A Mojo binding to **libzstd** — one-shot and streaming compress/decompress —
via FFI, built the same way [zlib.mojo](https://github.com/magmalake/zlib.mojo)
wraps zlib: a small C shim (`shim/zstd_wrapper.c`) compiled to
**`libzstdmojo.so`** and loaded through an `OwnedDLHandle`. No link flags for
consumers; the shim is `dlopen`ed at runtime.

zstd is Apache Iceberg's default Parquet codec, a Puffin blob codec, and an
Avro codec — that's the headline use this binding targets. It wraps the real
libzstd (conda-forge's `zstd` package); a pure-Mojo zstd is out of scope.

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

| data         | level | compress   | decompress | ratio  |
|--------------|-------|-----------:|-----------:|-------:|
| compressible |     1 | ~1.4 GB/s  | ~1.5 GB/s  | 10824x |
| compressible |     3 | ~3.3 GB/s  | ~7.6 GB/s  | 10824x |
| compressible |     9 | ~0.7 GB/s  | ~2.7 GB/s  |   747x |
| compressible |    19 | ~0.5 GB/s  | ~10.4 GB/s |  11792x |
| random       |     1 | ~2.5 GB/s  | ~14.1 GB/s |   ~1.0x |
| random       |     3 | ~1.6 GB/s  | ~9.9 GB/s  |   ~1.0x |
| random       |     9 | ~1.3 GB/s  | ~11.9 GB/s |   ~1.0x |

Numbers vary run to run (the one-shot `compress()`/`decompress()` API
`dlopen`s the shim on every call — fine for Parquet-page-sized buffers, but
don't use it in a hot per-call loop; use `Compressor`/`Decompressor` to
amortize that cost instead). Re-run `pixi run bench` for your own hardware.

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
