# Changelog

## Unreleased

## 0.3.0 - 2026-11-25

### Changed

- zstd is now pure Mojo: the codec is vendored, with small changes, from
  [amarbaro/mojo-libs](https://github.com/amarbaro/mojo-libs) (`libs/zstd`
  at commit 9dc0066, Apache-2.0; a port of libzstd's algorithms, whose BSD
  notices for Zstandard and xxHash are now in NOTICE). The C shim
  (`shim/`, `libzstdmojo.so`), its `dlopen` search (`_dlopen.mojo`) and the
  run-time need for libzstd are gone: the `zstd-mojo` package no longer
  depends on `zstd-shim` or conda-forge's `zstd`, and a binary built with it
  needs nothing at run time. The workspace keeps conda-forge's `zstd`, for
  the tests only, which use its command-line tool as the reference.
- The API is unchanged: `compress`, `decompress`, `decompress_into`,
  `is_zstd_frame`, `frame_content_size`, `Compressor` and `Decompressor`,
  same signatures. What differs:
  - Compressed bytes are valid zstd that any zstd decodes, but not
    libzstd's bytes; sizes are within about 0.5% of libzstd's at the same
    level on the data measured (text, a binary, YAML), and should stay
    within 1-2% elsewhere.
  - Speed: compressing at level 3 takes about 1.4-2.5x libzstd's time, and
    decompressing about 1.4-2.8x, on a few MiB of real data (M4). On the
    bench's synthetic extremes the gap is wider: on random input, which
    libzstd detects and skips faster, 6-13x to compress and 2-4x to
    decompress; on the repeated-sentence input 3-6.5x either way (see the
    README's Perf table).
  - No dictionaries (a frame that names one raises), no multi-threaded
    compression, no long-distance matching when compressing. Decoding
    still takes `--long` frames with windows up to 128 MiB.
  - Error texts: every error starts with `zstd: ` (`zstd: corrupt input`,
    `zstd: truncated input`, `zstd: checksum mismatch`,
    `zstd: destination buffer too small`, ...) in place of libzstd's error
    names (`zstd.decompress: Corruption_detected`,
    `zstd.decompress_into: Dst_Too_Small`).
  - `decompress` and `decompress_into` decode every frame of their input,
    concatenated, and skip skippable frames; trailing bytes that aren't a
    frame raise. `decompress` used to size its output from the first
    frame and fail on a second.
  - `decompress_into` decodes straight into the caller's buffer, as before.
  - `Decompressor.finish()` raises `zstd: truncated input` when the input
    stopped inside a frame; it used to be a no-op. With complete input it
    still returns nothing.
  - `Compressor` hands out each 128 KiB block as it fills, and its frames
    record a checksum but, as before, no content size. After `finish()`
    the next call starts a new frame.
  - `compress` of 2 GiB or more goes through the streaming encoder, so
    that frame records no content size.

## 0.2.0 - 2026-11-20

### Changed

- Pins lint-mojo 0.2.0.

## 0.1.5 - 2026-11-03

- The shim is found without `CONDA_PREFIX`: after `$CONDA_PREFIX/lib`,
  zstd looks next to the executable, in its `../lib`, and on the binary's
  rpath (the environment `mojo build` ran in), so a binary built with
  `pixi run mojo build` runs from a plain shell. The search lives in
  `src/zstd/_dlopen.mojo`, shared with the other magmalake tins that load
  a library.
- A shim that can't be found is an Error raised by the zstd call, naming
  the library and every place searched and saying to set `CONDA_PREFIX`.
  It used to abort with a stack dump.
- The fallback to `build/libzstdmojo.so` relative to the working directory
  is gone: it named a file only zstd.mojo's own checkout had, and loading
  a library from the working directory isn't safe.
