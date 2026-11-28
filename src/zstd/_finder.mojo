# Vendored from https://github.com/amarbaro/mojo-libs, libs/zstd/src/zstd/finder.mojo at
# tag zstd-v0.4.1 (commit 72d4eaf). Copyright 2026 AMARBARO, licensed under the Apache License 2.0
# (see LICENSE); a port to Mojo of Zstandard (BSD, Meta Platforms, Inc. and affiliates), whose notice is in NOTICE.
# Modified for zstd.mojo: imports renamed and an unused one dropped; row_insert takes its table pointers again after row_fill, for Mojo 1.3's origin check.
"""Match finders and parsers of zstd's fast, double-fast, greedy and lazy strategies (algorithms of
libzstd's zstd_fast.c, zstd_double_fast.c, zstd_lazy.c; BSD-3-Clause, Meta Platforms and Yann Collet). Positions are offsets
into the buffer p; table entries are pos + e.boff, 0 meaning empty."""
from std.bit import count_trailing_zeros
from std.memory import pack_bits
from std.sys import PrefetchOptions, prefetch
from ._enc import Enc


@always_inline
def r32(p: ImmPointer[UInt8, _], i: Int) -> UInt32:
    return p.unsafe_offset(i).unsafe_bitcast[UInt32]().unsafe_load[alignment=1]()


@always_inline
def r64(p: ImmPointer[UInt8, _], i: Int) -> UInt64:
    return p.unsafe_offset(i).unsafe_bitcast[UInt64]().unsafe_load[alignment=1]()


@always_inline
def count(p: ImmPointer[UInt8, _], a: Int, b: Int, limit: Int) -> Int:
    """Common run of p[a:limit] and p[b:] (b < a)."""
    var i = a
    var m = b
    while i + 8 <= limit:
        var x = r64(p, i) ^ r64(p, m)
        if x != 0:
            return i + Int(count_trailing_zeros(x) >> 3) - a
        i += 8
        m += 8
    while i < limit and p[unsafe_offset=i] == p[unsafe_offset=m]:
        i += 1
        m += 1
    return i - a


@always_inline
def hashm(p: ImmPointer[UInt8, _], i: Int, bits: Int, mls: Int) -> Int:
    if mls <= 4:
        return Int((r32(p, i) * 2654435761) >> UInt32(32 - bits))
    if mls == 5:
        return Int(((r64(p, i) << 24) * 889523592379) >> UInt64(64 - bits))
    if mls == 6:
        return Int(((r64(p, i) << 16) * 227718039650203) >> UInt64(64 - bits))
    if mls == 7:
        return Int(((r64(p, i) << 8) * 58295818150454627) >> UInt64(64 - bits))
    return Int((r64(p, i) * 0xCF1BBCDCB7A56463) >> UInt64(64 - bits))


def fast(mut e: Enc, p: ImmPointer[UInt8, _], start: Int, end: Int) -> Int:
    """ZSTD_compressBlock_fast_noDict_generic over p[start:end]: positions are searched in a software pipeline
    of four, the step grows every 128 bytes without a match. Returns where the unmatched tail begins."""
    var ht = e.ht.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
    var hl = e.hlog
    var mls = min(max(e.mml, 4), 7)
    var step_size = e.tlen + (1 if e.tlen == 0 else 0) + 1
    var maxd = 1 << e.wlog
    var boff = e.boff
    var ilimit = end - 8
    var ip0 = start
    var anchor = start
    if start + boff == 0:
        ip0 += 1
    while True:
        var low = max(0, ip0 - maxd)
        var r1 = e.r0 if e.r0 <= ip0 - low else 0
        var step = step_size
        var next_step = ip0 + 128
        var ip1 = ip0 + 1
        var ip2 = ip0 + step
        var ip3 = ip2 + 1
        if ip3 >= ilimit:
            break
        var h0 = hashm(p, ip0, hl, mls)
        var h1 = hashm(p, ip1, hl, mls)
        var midx = Int(ht[unsafe_offset=h0]) - boff
        var cur0: Int
        var mpos = 0
        var ml = 0
        var found = 0  # 1: repeat offset, 2: table match, 0: none
        while True:
            cur0 = ip0
            ht[unsafe_offset=h0] = UInt32(cur0 + boff)
            if r1 > 0 and r32(p, ip2) == r32(p, ip2 - r1):
                ip0 = ip2
                mpos = ip0 - r1
                var back = 1 if p[unsafe_offset=ip0 - 1] == p[unsafe_offset=mpos - 1] else 0
                ip0 -= back
                mpos -= back
                ml = 4 + back
                ht[unsafe_offset=h1] = UInt32(ip1 + boff)
                found = 1
                break
            if midx >= low and r32(p, ip0) == r32(p, midx):
                ht[unsafe_offset=h1] = UInt32(ip1 + boff)
                mpos = midx
                found = 2
                break
            midx = Int(ht[unsafe_offset=h1]) - boff
            h0 = h1
            h1 = hashm(p, ip2, hl, mls)
            ip0 = ip1
            ip1 = ip2
            ip2 = ip3
            cur0 = ip0
            ht[unsafe_offset=h0] = UInt32(cur0 + boff)
            if midx >= low and r32(p, ip0) == r32(p, midx):
                if step <= 4:
                    ht[unsafe_offset=h1] = UInt32(ip1 + boff)
                mpos = midx
                found = 2
                break
            midx = Int(ht[unsafe_offset=h1]) - boff
            h0 = h1
            h1 = hashm(p, ip2, hl, mls)
            ip0 = ip1
            ip1 = ip2
            ip2 = ip0 + step
            ip3 = ip1 + step
            if ip2 >= next_step:
                step += 1
                next_step += 128
            if ip3 >= ilimit:
                break
        if found == 0:
            break
        if found == 2:
            ml = 4
            while ip0 > anchor and mpos > low and p[unsafe_offset=ip0 - 1] == p[unsafe_offset=mpos - 1]:
                ip0 -= 1
                mpos -= 1
                ml += 1
        ml += count(p, ip0 + ml, mpos + ml, end)
        e.store(p, anchor, ip0 - anchor, ip0 - mpos, ml)
        ip0 += ml
        anchor = ip0
        if ip0 <= ilimit:
            ht[unsafe_offset=hashm(p, cur0 + 2, hl, mls)] = UInt32(cur0 + 2 + boff)
            ht[unsafe_offset=hashm(p, ip0 - 2, hl, mls)] = UInt32(ip0 - 2 + boff)
            while ip0 <= ilimit and e.r1 > 0 and ip0 - e.r1 >= max(0, ip0 - maxd) and r32(p, ip0) == r32(p, ip0 - e.r1):
                var r2 = e.r1
                var ml2 = count(p, ip0 + 4, ip0 + 4 - r2, end) + 4
                ht[unsafe_offset=hashm(p, ip0, hl, mls)] = UInt32(ip0 + boff)
                e.store(p, ip0, 0, r2, ml2)
                ip0 += ml2
                anchor = ip0
    return anchor


def dfast(mut e: Enc, p: ImmPointer[UInt8, _], start: Int, end: Int) -> Int:
    """ZSTD_compressBlock_doubleFast: a long (8-byte) and a short (mml-byte) hash table."""
    var hl = e.ht.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
    var hs = e.ct.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
    var lbits = e.hlog
    var sbits = e.clog
    var mls = min(max(e.mml, 4), 7)
    var maxd = 1 << e.wlog
    var boff = e.boff
    var ilimit = end - 8
    var ip = start
    var anchor = start
    if start + boff == 0:
        ip += 1
    while ip < ilimit:
        var h2 = hashm(p, ip, lbits, 8)
        var h = hashm(p, ip, sbits, mls)
        var mlong = Int(hl[unsafe_offset=h2]) - boff
        var mshort = Int(hs[unsafe_offset=h]) - boff
        var curr = ip
        hl[unsafe_offset=h2] = UInt32(curr + boff)
        hs[unsafe_offset=h] = UInt32(curr + boff)
        var low = max(0, curr - maxd)
        var ml: Int
        var r1 = e.r0
        if ip + 1 - r1 >= low and r32(p, ip + 1) == r32(p, ip + 1 - r1):
            ml = count(p, ip + 5, ip + 5 - r1, end) + 4
            ip += 1
            e.store(p, anchor, ip - anchor, r1, ml)
        else:
            var m: Int
            if mlong >= low and r64(p, mlong) == r64(p, ip):
                ml = count(p, ip + 8, mlong + 8, end) + 8
                m = mlong
            elif mshort >= low and r32(p, mshort) == r32(p, ip):
                var h3 = hashm(p, ip + 1, lbits, 8)
                var m3 = Int(hl[unsafe_offset=h3]) - boff
                hl[unsafe_offset=h3] = UInt32(curr + 1 + boff)
                if m3 >= low and r64(p, m3) == r64(p, ip + 1):
                    ml = count(p, ip + 9, m3 + 8, end) + 8
                    ip += 1
                    m = m3
                else:
                    ml = count(p, ip + 4, mshort + 4, end) + 4
                    m = mshort
            else:
                ip += ((ip - anchor) >> 8) + 1
                continue
            while ip > anchor and m > low and p[unsafe_offset=ip - 1] == p[unsafe_offset=m - 1]:
                ip -= 1
                m -= 1
                ml += 1
            e.store(p, anchor, ip - anchor, ip - m, ml)
        ip += ml
        anchor = ip
        if ip <= ilimit:
            hl[unsafe_offset=hashm(p, curr + 2, lbits, 8)] = UInt32(curr + 2 + boff)
            hs[unsafe_offset=hashm(p, curr + 2, sbits, mls)] = UInt32(curr + 2 + boff)
            hl[unsafe_offset=hashm(p, ip - 2, lbits, 8)] = UInt32(ip - 2 + boff)
            hs[unsafe_offset=hashm(p, ip - 2, sbits, mls)] = UInt32(ip - 2 + boff)
            while ip <= ilimit and ip - e.r1 >= max(0, ip - maxd) and r32(p, ip) == r32(p, ip - e.r1):
                var r2 = e.r1
                var ml2 = count(p, ip + 4, ip + 4 - r2, end) + 4
                hl[unsafe_offset=hashm(p, ip, lbits, 8)] = UInt32(ip + boff)
                hs[unsafe_offset=hashm(p, ip, sbits, mls)] = UInt32(ip + boff)
                e.store(p, ip, 0, r2, ml2)
                ip += ml2
                anchor = ip
    return anchor


def hc_insert(mut e: Enc, p: ImmPointer[UInt8, _], upto: Int):
    """Fills the hash and chain tables for the positions below upto not yet in them."""
    var ht = e.ht.unsafe_ptr()
    var ct = e.ct.unsafe_ptr()
    var cmask = (1 << e.clog) - 1
    var mls = min(max(e.mml, 4), 6)
    var boff = e.boff
    var i = e.upd
    while i < upto:
        var h = hashm(p, i, e.hlog, mls)
        ct[unsafe_offset=(i + boff) & cmask] = ht[unsafe_offset=h]
        ht[unsafe_offset=h] = UInt32(i + boff)
        i += 1
        if e.skip:
            break
    e.upd = max(e.upd, upto)


def hc_find(mut e: Enc, p: ImmPointer[UInt8, _], ip: Int, end: Int, mut off: Int) -> Int:
    """ZSTD_HcFindBestMatch: the longest match at ip among the chain of earlier positions with the same
    hash, up to 1 << slog candidates; its distance in off. 0 when there is none of 4 bytes or more."""
    hc_insert(e, p, ip)
    var ht = e.ht.unsafe_ptr()
    var ct = e.ct.unsafe_ptr()
    var cmask = (1 << e.clog) - 1
    var mls = min(max(e.mml, 4), 6)
    var boff = e.boff
    var idx = Int(ht[unsafe_offset=hashm(p, ip, e.hlog, mls)])
    var low = max(0, ip - (1 << e.wlog))
    var minchain = max(0, ip - (1 << e.clog))
    var best = 0
    var attempts = 1 << e.slog
    while idx - boff >= low and idx > 0 and attempts > 0:
        attempts -= 1
        var m = idx - boff
        if m < ip and (best == 0 or (ip + best < end and p[unsafe_offset=m + best] == p[unsafe_offset=ip + best])):
            var cur = count(p, ip, m, end)
            if cur > best:
                best = cur
                off = ip - m
                if ip + cur >= end:
                    break
        if m <= minchain:
            break
        idx = Int(ct[unsafe_offset=idx & cmask])
    return best if best >= 4 else 0


@always_inline
def row_put(ht: MutPointer[UInt32, _], tt: MutPointer[UInt8, _], rel: Int, rmask: Int, h: Int, v: Int):
    """ZSTD_row_nextIndex and the store: the head byte tt[rel] steps down through rmask..1 (slot 0 never holds an
    entry), so the newest entry of a row sits at its head and older ones follow it upward."""
    var nxt = (Int(tt[unsafe_offset=rel]) - 1) & rmask
    if nxt == 0:
        nxt = rmask
    tt[unsafe_offset=rel] = UInt8(nxt)
    tt[unsafe_offset=rel + nxt] = UInt8(h & 255)
    ht[unsafe_offset=rel + nxt] = UInt32(v)


@always_inline
def row_hash[rl: Int](ht: MutPointer[UInt32, _], tt: MutPointer[UInt8, _], p: ImmPointer[UInt8, _], i: Int, bits: Int, mls: Int) -> Int:
    """The row hash of position i (row number above 8 tag bits); its row is prefetched (ZSTD_row_prefetch)."""
    var h = hashm(p, i, bits, mls)
    var rel = (h >> 8) << rl
    prefetch[PrefetchOptions().for_read().high_locality().to_data_cache()](ht.unsafe_offset(rel))
    comptime if rl >= 5:
        prefetch[PrefetchOptions().for_read().high_locality().to_data_cache()](ht.unsafe_offset(rel + 16))
    prefetch[PrefetchOptions().for_read().high_locality().to_data_cache()](tt.unsafe_offset(rel))
    comptime if rl == 6:
        prefetch[PrefetchOptions().for_read().high_locality().to_data_cache()](tt.unsafe_offset(rel + 32))
    return h


def row_fill[rl: Int](mut e: Enc, p: ImmPointer[UInt8, _], lim: Int):
    """ZSTD_row_fillHashCache: the hashes of the next 8 positions to enter the rows (none past lim) go to the
    cache, their rows prefetched. row_insert and row_find then keep the cache 8 positions ahead, so a row is
    in the cache by the time it is written or searched."""
    var ht = e.ht.unsafe_ptr().unsafe_offset(e.ha)
    var tt = e.tt.unsafe_ptr().unsafe_offset(e.ta)
    var hc = e.hcache.unsafe_ptr()
    var bits = e.hlog - rl + 8
    var mls = min(max(e.mml, 4), 6)
    for i in range(e.upd, e.upd + min(8, lim - e.upd + 1)):
        hc[unsafe_offset=i & 7] = UInt32(row_hash[rl](ht, tt, p, i, bits, mls))


def row_insert[rl: Int](mut e: Enc, p: ImmPointer[UInt8, _], upto: Int):
    """ZSTD_row_update_internal: enters the positions below upto not yet in the rows; of a stretch over 384
    positions (a long match) only the first 96 and the last 32. Reads up to 16 bytes past upto."""
    var ht = e.ht.unsafe_ptr().unsafe_offset(e.ha)
    var tt = e.tt.unsafe_ptr().unsafe_offset(e.ta)
    var hc = e.hcache.unsafe_ptr()
    var bits = e.hlog - rl + 8
    var mls = min(max(e.mml, 4), 6)
    var boff = e.boff
    var i = e.upd
    var stop = i + 96 if upto - i > 384 else upto
    while True:
        while i < stop:
            var nh = row_hash[rl](ht, tt, p, i + 8, bits, mls)
            var h = Int(hc[unsafe_offset=i & 7])
            hc[unsafe_offset=i & 7] = UInt32(nh)
            row_put(ht, tt, (h >> 8) << rl, (1 << rl) - 1, h, i + boff)
            i += 1
        if stop >= upto:
            break
        i = upto - 32
        stop = upto
        e.upd = i
        row_fill[rl](e, p, upto + 1)
        # zstd.mojo: row_fill borrows e mutably, which ends the pointers taken from it above (Mojo 1.3 rejects their reuse)
        ht = e.ht.unsafe_ptr().unsafe_offset(e.ha)
        tt = e.tt.unsafe_ptr().unsafe_offset(e.ta)
        hc = e.hcache.unsafe_ptr()
    e.upd = max(e.upd, upto)


def row_find[rl: Int](mut e: Enc, p: ImmPointer[UInt8, _], ip: Int, end: Int, mut off: Int) -> Int:
    """ZSTD_RowFindBestMatch: ht is rows of 1 << rl entries. One SIMD compare of a row's tag bytes (8 more hash
    bits per entry) picks the entries worth reading, newest first, at most 1 << min(slog, rl) of them. The longest
    match at ip, its distance in off; 0 when there is none of 4 bytes or more. Needs ip + 16 <= end."""
    comptime W = 1 << rl
    var bits = e.hlog - rl + 8
    var mls = min(max(e.mml, 4), 6)
    var h: Int
    if e.skip:
        e.upd = ip
        h = hashm(p, ip, bits, mls)
    else:
        row_insert[rl](e, p, ip)
        var hc = e.hcache.unsafe_ptr()
        h = Int(hc[unsafe_offset=ip & 7])
        hc[unsafe_offset=ip & 7] = UInt32(row_hash[rl](e.ht.unsafe_ptr().unsafe_offset(e.ha), e.tt.unsafe_ptr().unsafe_offset(e.ta), p, ip + 8, bits, mls))
    var ht = e.ht.unsafe_ptr().unsafe_offset(e.ha)
    var tt = e.tt.unsafe_ptr().unsafe_offset(e.ta)
    var boff = e.boff
    var rel = (h >> 8) << rl
    var head = Int(tt[unsafe_offset=rel]) & (W - 1)
    var m = UInt64(pack_bits(tt.unsafe_offset(rel).unsafe_load[width=W]().eq(SIMD[DType.uint8, W](UInt8(h & 255)))))
    # bit k after the rotation is slot (head + k) mod W: the scan runs from the newest entry to the oldest
    m = ((m >> UInt64(head)) | (m << UInt64((W - head) & 63))) & (UInt64(0xFFFFFFFFFFFFFFFF) >> UInt64(64 - W))
    var low = max(0, ip - (1 << e.wlog))
    var store = Array[Int, W](uninitialized=True)
    var cand = store.unsafe_ptr()  # at most W - 1 entries: slot 0 is never one
    var n = 0
    var attempts = 1 << min(e.slog, rl)
    while m != 0 and attempts > 0:
        var slot = (head + Int(count_trailing_zeros(m))) & (W - 1)
        m &= m - 1
        if slot == 0:
            continue
        var idx = Int(ht[unsafe_offset=rel + slot])
        if idx == 0 or idx - boff < low or idx - boff >= ip:
            break
        prefetch[PrefetchOptions().for_read().high_locality().to_data_cache()](p.unsafe_offset(idx - boff))
        cand[unsafe_offset=n] = idx - boff
        n += 1
        attempts -= 1
    row_put(ht, tt, rel, W - 1, h, ip + boff)
    e.upd = ip + 1
    var best = 3
    for k in range(n):
        var c = cand[unsafe_offset=k]
        if r32(p, c + best - 3) == r32(p, ip + best - 3):
            var cur = count(p, ip, c, end)
            if cur > best:
                best = cur
                off = ip - c
                if ip + cur >= end:
                    break
    return best if best >= 4 else 0
