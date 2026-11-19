// windows(n) and chunks(n) on empty / one / many elements with n = 1, n
// below, equal to and above the length, and n near usize::MAX: how many
// pieces come out, their lengths and contents in order, the short final
// chunk, and that a huge n neither overflows nor reads past the slice.
// Elements are i32, string and a move-only instrumented class whose live
// count returns to zero. n == 0 traps and is covered in traps.k.
//
// Cases from libc++ test/std/containers/views/views.span/span.sub/
// Cases from Rust library/coretests/tests/slice.rs (windows, chunks)
// Cases from Rust library/alloctests/tests/slice.rs (windows, chunks)

import self::inputs::inst::*
import std::io

/// Number of windows and the sum over every window of (length * 1000 +
/// first element), so lengths and positions are both checked.
fn window_sig(const s: [const i32;], n: usize) -> (usize, i64) {
    var count: usize = 0
    var sig: i64 = 0
    for w in s.windows(n) {
        sig += (w.size() as i64) * 1000 + (w[0] as i64)
        count += 1
    }

    return (count, sig)
}

fn chunk_sig(const s: [const i32;], n: usize) -> (usize, i64) {
    var count: usize = 0
    var sig: i64 = 0
    for c in s.chunks(n) {
        sig += (c.size() as i64) * 1000 + (c[0] as i64)
        count += 1
    }

    return (count, sig)
}

fn windows_int() {
    var v: [i32] = [1, 2, 3, 4, 5]
    const s: [const i32;] = v

    var (c1, s1) = window_sig(s, 1)
    check(c1 == 5 && s1 == 5 * 1000 + 15, "windows(1)", 1)
    var (c2, s2) = window_sig(s, 2)
    check(c2 == 4 && s2 == 4 * 2000 + 10, "windows(2)", 2)
    var (c3, s3) = window_sig(s, 3)
    check(c3 == 3 && s3 == 3 * 3000 + 6, "windows(3)", 3)
    var (c4, s4) = window_sig(s, 4)
    check(c4 == 2 && s4 == 2 * 4000 + 3, "windows(len - 1)", 4)
    var (c5, s5) = window_sig(s, 5)
    check(c5 == 1 && s5 == 5000 + 1, "windows(len)", 5)
    var (c6, s6) = window_sig(s, 6)
    check(c6 == 0 && s6 == 0, "windows(len + 1)", 6)
    var (cm, sm) = window_sig(s, usize::MAX)
    check(cm == 0 && sm == 0, "windows(usize::MAX)", 7)
    var (ch, sh) = window_sig(s, usize::MAX - 1)
    check(ch == 0 && sh == 0, "windows(usize::MAX - 1)", 8)
    var (cq, sq) = window_sig(s, (usize::MAX / 2) + 1)
    check(cq == 0 && sq == 0, "windows(2^63)", 9)

    var elems: i32 = 0
    for w in s.windows(2) {
        elems += w[1] - w[0]
    }

    check(elems == 4, "consecutive windows overlap by n - 1", 10)

    var none: [i32]
    const e: [const i32;] = none
    var (z1, _) = window_sig(e, 1)
    var (z2, _) = window_sig(e, usize::MAX)
    check(z1 == 0 && z2 == 0, "windows on empty", 11)
    var one: [i32] = [9]
    const o: [const i32;] = one
    var (o1, os) = window_sig(o, 1)
    var (o2, _) = window_sig(o, 2)
    check(o1 == 1 && os == 1009 && o2 == 0, "windows on one element", 12)
}

fn chunks_int() {
    var v: [i32] = [1, 2, 3, 4, 5]
    const s: [const i32;] = v

    var (c1, s1) = chunk_sig(s, 1)
    check(c1 == 5 && s1 == 5 * 1000 + 15, "chunks(1)", 20)
    var (c2, s2) = chunk_sig(s, 2)
    check(c2 == 3 && s2 == 2000 + 1 + 2000 + 3 + 1000 + 5, "chunks(2) keeps a short last chunk", 21)
    var (c3, s3) = chunk_sig(s, 3)
    check(c3 == 2 && s3 == 3000 + 1 + 2000 + 4, "chunks(3) keeps a short last chunk", 22)
    var (c4, s4) = chunk_sig(s, 4)
    check(c4 == 2 && s4 == 4000 + 1 + 1000 + 5, "chunks(len - 1)", 23)
    var (c5, s5) = chunk_sig(s, 5)
    check(c5 == 1 && s5 == 5000 + 1, "chunks(len)", 24)
    var (c6, s6) = chunk_sig(s, 6)
    check(c6 == 1 && s6 == 5000 + 1, "chunks(len + 1) is the whole slice", 25)
    var (cm, sm) = chunk_sig(s, usize::MAX)
    check(cm == 1 && sm == 5000 + 1, "chunks(usize::MAX) is the whole slice", 26)
    var (ch, sh) = chunk_sig(s, usize::MAX - 1)
    check(ch == 1 && sh == 5000 + 1, "chunks(usize::MAX - 1) is the whole slice", 27)
    var (cq, sq) = chunk_sig(s, (usize::MAX / 2) + 1)
    check(cq == 1 && sq == 5000 + 1, "chunks(2^63) is the whole slice", 28)

    var none: [i32]
    const e: [const i32;] = none
    var (z1, _) = chunk_sig(e, 1)
    var (z2, _) = chunk_sig(e, 7)
    var (z3, _) = chunk_sig(e, usize::MAX)
    check(z1 == 0 && z2 == 0 && z3 == 0, "chunks on empty yield nothing", 29)
    var one: [i32] = [9]
    const o: [const i32;] = one
    var (o1, os) = chunk_sig(o, 1)
    var (o2, _) = chunk_sig(o, 2)
    check(o1 == 1 && os == 1009 && o2 == 1, "chunks on one element", 30)

    var total: usize = 0
    for var n: usize = 1; n <= 8; ++n {
        var (cnt, _) = chunk_sig(s, n)
        check(cnt == (5 + n - 1) / n, "chunk count is ceil(len / n)", 31)
        for c in s.chunks(n) {
            total += c.size()
        }
    }

    check(total == 5 * 8, "chunks cover every element exactly once", 32)
}

fn windows_chunks_of_a_range() {
    var v: [i32] = [0, 1, 2, 3, 4, 5, 6, 7]
    var m: [i32;] = v
    var sum: i32 = 0
    for w in m[2..6].windows(2) {
        sum += w[0] * 10 + w[1]
    }

    check(sum == 23 + 34 + 45, "windows of a sub-range stay inside it", 40)
    var last: i32 = -1
    for c in m[5..].chunks(2) {
        last = c[c.size() - 1]
    }

    check(last == 7, "chunks of a tail end at the slice end", 41)
    for w in m[3..3].windows(1) {
        fail("an empty sub-range yields no window", 42)
    }

    for c in m[8..].chunks(3) {
        fail("an empty tail yields no chunk", 43)
    }
}

fn strings() {
    var v: [string] = ["a", "b", "c", "d", "e"]
    const s: [const string;] = v
    var joined = ""
    for w in s.windows(3) {
        joined += f"{w[0]}{w[1]}{w[2]}."
    }

    check(joined == "abc.bcd.cde.", "string windows(3)", 50)
    var parts = ""
    for c in s.chunks(2) {
        for var i: usize = 0; i < c.size(); ++i {
            parts += c[i]
        }

        parts += "|"
    }

    check(parts == "ab|cd|e|", "string chunks(2)", 51)
    var big: usize = 0
    for w in s.windows(usize::MAX) {
        big += 1
    }

    for c in s.chunks(usize::MAX) {
        big += c.size()
    }

    check(big == 5, "string windows and chunks at usize::MAX", 52)
}

fn instrumented() {
    {
        var v = insts(7, 0, 1)
        const s: [const Inst;] = v
        var moves0 = MOVES
        var wsum: i64 = 0
        var wn: i64 = 0
        for w in s.windows(3) {
            wsum += w[0].key() + w[1].key() + w[2].key()
            wn += 1
        }

        check(wn == 5 && wsum == 3 + 6 + 9 + 12 + 15, "inst windows(3)", 60)
        var cn: i64 = 0
        var lens: i64 = 0
        for c in s.chunks(3) {
            lens = lens * 10 + (c.size() as i64)
            cn += 1
        }

        check(cn == 3 && lens == 331, "inst chunks(3) lengths 3, 3, 1", 61)
        for w in s.windows(8) {
            fail("inst windows(len + 1) yields nothing", 62)
        }

        var whole: i64 = 0
        for c in s.chunks(usize::MAX) {
            whole += c.size() as i64
        }

        check(whole == 7, "inst chunks(usize::MAX)", 63)
        check(MOVES == moves0 && LIVE == 7, "windows and chunks neither move nor create elements", 64)
    }

    check_clean("windows_chunks: instrumented", 65)
}

fn main() -> i32 {
    windows_int()
    chunks_int()
    windows_chunks_of_a_range()
    strings()
    instrumented()
    io::println("windows_chunks ok")
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: windows_chunks ok
