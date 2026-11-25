#!/usr/bin/env bash
# zstd.mojo against the `zstd` command-line tool (the reference
# implementation, conda-forge's zstd in the pixi environment), both ways:
#
#   1. our frames (test/cli_check.mojo gen: sizes 0 B to 3 MiB, levels -5 to
#      22, streamed, concatenated, with a skippable frame) decode with the
#      tool to the bytes they were made from;
#   2. the tool's frames of the same inputs (levels --fast=5 to --ultra -22,
#      without checksum, without content size, multi-threaded, concatenated,
#      a --long=27 frame with a 128 MiB window) decode with ours to the bytes
#      the tool decodes them to, through decompress, decompress_into and
#      Decompressor;
#   3. the golden frames of test/vectors (from the zstd repository's
#      tests/golden-decompression and tests/golden-decompression-errors and
#      its decodecorpus tool, collected by amarbaro/mojo-libs; see NOTICE)
#      decode with ours as with the tool, or raise where it refuses them;
#   4. truncated frames raise, and frames with flipped bits raise or decode
#      but never crash.
set -euo pipefail
cd "$(dirname "$0")/.."

w=build/cli-test
rm -rf "$w"
mkdir -p "$w/cli" "$w/vec"
mojo build test/cli_check.mojo -I src -o build/cli-check
# The codec must be the Mojo one in src/, not a libzstd binding left installed.
if grep -a -q libzstdmojo build/cli-check; then
    echo "FAIL: build/cli-check still refers to libzstdmojo" >&2
    exit 1
fi

./build/cli-check gen "$w"

# 1. Ours through the tool.
n=0
while read -r z raw; do
    zstd -q -t "$z"
    if ! zstd -q -d -c "$z" | cmp -s - "$raw"; then
        echo "FAIL: zstd -d $z differs from $raw" >&2
        exit 1
    fi
    n=$((n + 1))
done < "$w/ours.txt"
echo "cli-test: $n of our frames decoded by $(zstd -V | sed 's/^\*\*\* //; s/, by.*//')"

# 2. The tool's through ours.
list="$w/cli.txt"
: > "$list"
add() { echo "$w/cli/$1 $2" >> "$list"; }
for raw in "$w"/raw/*.raw; do
    name=$(basename "$raw" .raw)
    if [ "$name" = long8m ]; then
        continue
    fi
    for lv in 1 3 9 19; do
        zstd -q -"$lv" -c "$raw" > "$w/cli/$name.$lv.zst"
        add "$name.$lv.zst" "$raw"
    done
    zstd -q --fast=5 -c "$raw" > "$w/cli/$name.fast5.zst"
    add "$name.fast5.zst" "$raw"
    zstd -q -3 --no-check -c "$raw" > "$w/cli/$name.nocheck.zst"
    add "$name.nocheck.zst" "$raw"
    zstd -q -3 -c < "$raw" > "$w/cli/$name.pipe.zst"
    add "$name.pipe.zst" "$raw"
    zstd -q -3 -T4 -c < "$raw" > "$w/cli/$name.mt.zst"
    add "$name.mt.zst" "$raw"
    if [ "$(wc -c < "$raw")" -le 4096 ]; then
        zstd -q --ultra -22 -c "$raw" > "$w/cli/$name.22.zst"
        add "$name.22.zst" "$raw"
    fi
done
cat "$w/cli/text4k.3.zst" "$w/cli/text1m.19.zst" > "$w/cli/concat.zst"
add concat.zst "$w/raw/concat.raw"
zstd -q --long=27 -3 -c < "$w/raw/long8m.raw" > "$w/cli/long8m.long27.zst"
add long8m.long27.zst "$w/raw/long8m.raw"
window=$(zstd -lv "$w/cli/long8m.long27.zst" 2>&1 | sed -n 's/^Window Size: *//p')
echo "cli-test: --long=27 frame window: $window"
./build/cli-check check "$list"

# 3. Golden frames.
for v in test/vectors/*.zst; do
    out="$w/vec/$(basename "$v").raw"
    if zstd -q -d -c "$v" > "$out" 2> /dev/null; then
        echo "$v $out"
    else
        echo "$v -"
    fi
done > "$w/vec.txt"
./build/cli-check check "$w/vec.txt"

# 4. Corrupt and truncated input.
./build/cli-check corrupt "$w/cli/text4k.3.zst" "$w/cli/text128k1.19.zst" \
    "$w/cli/text1m.pipe.zst" "$w/ours/text128k1.3.zst" "$w/ours/mixed3m.-5.zst"
echo "cli-test: all passed"
