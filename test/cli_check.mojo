"""Driver for test/cli_test.sh, which checks zstd.mojo against the `zstd`
command-line tool (the reference implementation) in both directions.

    cli-check gen DIR          inputs in DIR/raw, our frames of them in
                               DIR/ours, and DIR/ours.txt listing
                               "frame raw" pairs
    cli-check check LIST       every "frame raw" pair of LIST decodes to raw
                               through decompress, decompress_into and
                               Decompressor; raw "-" means every path must
                               raise
    cli-check corrupt FRAME... every cut of each frame raises, and bit flips
                               raise or decode, never crash

It exits non-zero on the first mismatch, naming it.
"""

from std.os import makedirs
from std.sys import argv
from zstd import (
    Compressor,
    Decompressor,
    compress,
    decompress,
    decompress_into,
    frame_content_size,
)

comptime MIB = 1024 * 1024


def _load(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def _save(path: String, data: Span[UInt8, _]) raises:
    with open(path, "w") as f:
        f.write_bytes(data)


struct _Lcg(Movable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> Int:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Int(self.s >> 33)


def _text(n: Int, seed: UInt64) -> List[UInt8]:
    """Words from a small table with spaces, punctuation and line breaks:
    compresses like prose, never periodic."""
    var words: List[String] = [
        "the", "of", "and", "zstd", "frame", "block", "window", "a", "to",
        "literal", "sequence", "match", "offset", "Huffman", "entropy", "in",
        "is", "parquet", "page", "column", "row", "group", "1024", "lake",
    ]
    var r = _Lcg(seed)
    var out = List[UInt8](capacity=n + 16)
    while len(out) < n:
        var w = words[r.next() % len(words)].as_bytes()
        out.extend(w)
        var k = r.next() % 16
        out.append(UInt8(ord("\n")) if k == 0 else (UInt8(ord(",")) if k == 1 else UInt8(ord(" "))))
    out.resize(n, 0)
    return out^


def _random(n: Int, seed: UInt64) -> List[UInt8]:
    var r = _Lcg(seed)
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(UInt8(r.next() & 255))
    return out^


def _mixed(n: Int, seed: UInt64) -> List[UInt8]:
    """Text with runs of random bytes and of one byte value: blocks that come
    out compressed, raw and RLE."""
    var r = _Lcg(seed)
    var out = List[UInt8](capacity=n)
    var t = _text(n, seed + 1)
    var i = 0
    while i < n:
        var k = min(n - i, 1000 + r.next() % 60000)
        var kind = r.next() % 4
        if kind == 0:
            out.extend(_random(k, seed + UInt64(i)))
        elif kind == 1:
            for _ in range(k):
                out.append(UInt8(r.next() % 3))
        else:
            out.extend(Span(t)[i : i + k])
        i += k
    return out^


def _stream(data: Span[UInt8, _], level: Int, chunk: Int) raises -> List[UInt8]:
    var c = Compressor(level)
    var out = List[UInt8]()
    var i = 0
    while i < len(data):
        var n = min(chunk, len(data) - i)
        out.extend(c.update(data[i : i + n]))
        i += n
    out.extend(c.finish())
    return out^


def _gen(dir: String) raises:
    makedirs(dir + "/raw", exist_ok=True)
    makedirs(dir + "/ours", exist_ok=True)
    var names = List[String]()
    var inputs = List[List[UInt8]]()
    names.append("empty")
    inputs.append(List[UInt8]())
    names.append("one")
    inputs.append([UInt8(42)])
    names.append("text100")
    inputs.append(_text(100, 1))
    names.append("text4k")
    inputs.append(_text(4096, 2))
    names.append("text128k1")
    inputs.append(_text(128 * 1024 + 1, 3))
    names.append("text1m")
    inputs.append(_text(MIB, 4))
    names.append("random1m")
    inputs.append(_random(MIB, 5))
    names.append("mixed3m")
    inputs.append(_mixed(3 * MIB, 6))
    var listing = String()
    for i in range(len(names)):
        var raw = dir + "/raw/" + names[i] + ".raw"
        _save(raw, inputs[i])
        var levels: List[Int] = [-5, 1, 3, 9, 19]
        if len(inputs[i]) <= 4096:
            levels.append(22)
        for level in levels:
            var z = dir + "/ours/" + names[i] + "." + String(level) + ".zst"
            _save(z, compress(inputs[i], level))
            listing += z + " " + raw + "\n"
        var z = dir + "/ours/" + names[i] + ".stream.zst"
        _save(z, _stream(inputs[i], 3, 70001))
        listing += z + " " + raw + "\n"
    # Repeats 4 MiB further back than level 3's 2 MiB window reaches: made by
    # the tool with --long=27 (cli_test.sh), it needs a 128 MiB window.
    var long = _random(4 * MIB, 7)
    long.extend(Span(long.copy()))
    _save(dir + "/raw/long8m.raw", long)
    # Two of our frames back to back, and the same with a skippable frame
    # between them.
    var a = inputs[3].copy()
    var b = inputs[5].copy()
    var ab = a.copy()
    ab.extend(Span(b))
    _save(dir + "/raw/concat.raw", ab)
    var two = compress(a, 3)
    var skip: List[UInt8] = [0x50, 0x2A, 0x4D, 0x18, 3, 0, 0, 0, 1, 2, 3]
    var with_skip = two.copy()
    with_skip.extend(Span(skip))
    two.extend(compress(b, 19))
    with_skip.extend(_stream(b, 1, 4096))
    _save(dir + "/ours/concat.zst", two)
    _save(dir + "/ours/concat-skip.zst", with_skip)
    listing += dir + "/ours/concat.zst " + dir + "/raw/concat.raw\n"
    listing += dir + "/ours/concat-skip.zst " + dir + "/raw/concat.raw\n"
    _save(dir + "/ours.txt", listing.as_bytes())
    print("cli-check gen:", len(names), "inputs, frames in", dir + "/ours")


def _same(got: Span[UInt8, _], want: Span[UInt8, _], what: String) raises:
    if len(got) != len(want):
        raise Error(what, ": ", len(got), " bytes, want ", len(want))
    for i in range(len(want)):
        if got[i] != want[i]:
            raise Error(what, ": differs at byte ", i)


def _streamed(frame: Span[UInt8, _], chunk: Int) raises -> List[UInt8]:
    var d = Decompressor()
    var out = List[UInt8]()
    var i = 0
    while i < len(frame):
        var n = min(chunk, len(frame) - i)
        out.extend(d.update(frame[i : i + n]))
        i += n
    out.extend(d.finish())
    return out^


def _chunks(n: Int) -> List[Int]:
    """Decompressor chunk sizes for an n-byte frame: byte by byte for small
    frames, odd sizes around the block size for all."""
    var out: List[Int] = [4093, 131075, n + 1]
    if n <= 20000:
        out.append(1)
    return out^


def _check_good(frame: Span[UInt8, _], want: Span[UInt8, _], name: String) raises:
    _same(decompress(frame), want, name + " decompress")
    # The first frame's size: all of it, unless more frames follow.
    var size = frame_content_size(frame)
    if size and size.value() > len(want):
        raise Error(name, ": frame_content_size ", size.value(), ", want ", len(want), " at most")
    var dst = List[UInt8](length=len(want) + 7, fill=0xEE)
    var n = decompress_into(frame, Span(dst)[: len(want)])
    _same(Span(dst)[:n], want, name + " decompress_into")
    for k in range(7):
        if dst[len(want) + k] != 0xEE:
            raise Error(name, ": decompress_into wrote past the end of dst")
    if len(want) > 0:
        var raised = False
        try:
            _ = decompress_into(frame, Span(dst)[: len(want) - 1])
        except e:
            raised = String(e).startswith("zstd: ")
        if not raised:
            raise Error(name, ": decompress_into into a short buffer did not raise")
    for c in _chunks(len(frame)):
        _same(_streamed(frame, c), want, name + " Decompressor/" + String(c))


def _raises_everywhere(frame: Span[UInt8, _], name: String) raises:
    var ok = 0
    try:
        _ = decompress(frame)
    except e:
        ok += 1 if String(e).startswith("zstd: ") else 0
    var dst = List[UInt8](length=1 << 20, fill=0)
    try:
        _ = decompress_into(frame, dst)
    except e:
        ok += 1 if String(e).startswith("zstd: ") else 0
    try:
        _ = _streamed(frame, 4093)
    except e:
        ok += 1 if String(e).startswith("zstd: ") else 0
    if ok != 3:
        raise Error(name, ": decoded on ", 3 - ok, " of 3 paths, the tool refuses it")


def _check(list_path: String) raises:
    var lines = String(unsafe_from_utf8=_load(list_path))
    var good = 0
    var bad = 0
    for line in lines.split("\n"):
        if line.byte_length() == 0:
            continue
        var parts = line.split(" ")
        var name = String(parts[0])
        var frame = _load(name)
        if parts[1] == "-":
            _raises_everywhere(frame, name)
            bad += 1
        else:
            _check_good(frame, _load(String(parts[1])), name)
            good += 1
    print("cli-check check:", list_path, good, "frames decoded to the tool's bytes,", bad, "refused as the tool refuses them")


def _corrupt(path: String) raises:
    var frame = _load(path)
    var n = len(frame)
    # Every proper prefix is truncated input: it must raise on every path.
    var step = 1 if n <= 4000 else n // 2000 + 1
    var cuts = 0
    var k = 0
    while k < n:
        var cut = Span(frame)[:k]
        if k > 0:
            _raises_everywhere(cut, path + " cut at " + String(k))
            cuts += 1
        k += step
    # Flipped bits: raise or decode, but no crash and no write past dst.
    var r = _Lcg(UInt64(n))
    var raised = 0
    var decoded = 0
    for _ in range(400):
        var f = frame.copy()
        var at = r.next() % n
        f[at] ^= UInt8(1 << (r.next() % 8))
        try:
            _ = decompress(f)
            decoded += 1
        except:
            raised += 1
        var dst = List[UInt8](length=(1 << 21) + 7, fill=0xEE)
        try:
            _ = decompress_into(f, Span(dst)[: 1 << 21])
        except:
            pass
        for j in range(7):
            if dst[(1 << 21) + j] != 0xEE:
                raise Error(path, ": a flipped frame wrote past dst")
        try:
            _ = _streamed(f, 4093)
        except:
            pass
    print("cli-check corrupt:", path, cuts, "cuts raised; 400 bit flips:", raised, "raised,", decoded, "decoded")


def main() raises:
    var args = argv()
    if len(args) < 3:
        raise Error("usage: cli-check gen DIR | check LIST | corrupt FRAME...")
    var cmd = String(args[1])
    if cmd == "gen":
        _gen(String(args[2]))
    elif cmd == "check":
        _check(String(args[2]))
    elif cmd == "corrupt":
        for i in range(2, len(args)):
            _corrupt(String(args[i]))
    else:
        raise Error("cli-check: unknown command ", cmd)
