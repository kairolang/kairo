// Sub-slices: every range form (a..b, a..=b, a.., ..b, ..=b) at both ends and
// on empty / one / many elements, the empty ranges at every position, nested
// ranges, split_at and split_at_mut at 0, in the middle and at the length,
// writes through a mutable sub-slice reaching the owner, disjoint writes
// through the two halves of split_at_mut, and the read members on the
// `[const T;]` a read-only range yields. Elements are i32, string and a
// move-only instrumented class whose live count returns to zero.
//
// Cases from libc++ test/std/containers/views/views.span/span.sub/
// Cases from libc++ test/std/containers/views/views.span/span.cons/
// Cases from Rust library/coretests/tests/slice.rs (split_at, ranges)

import self::inputs::inst::*
import std::io

fn ranges_int() {
    var v: [i32] = [10, 11, 12, 13, 14, 15]
    var s: [i32;] = v
    const c: [const i32;] = s

    check(c[0..6].size() == 6 && c[0..0].size() == 0 && c[6..6].size() == 0, "full and empty a..b", 1)
    check(c[2..4].size() == 2 && c[2..4][0] == 12 && c[2..4][1] == 13, "middle a..b", 2)
    check(c[0..1][0] == 10 && c[5..6][0] == 15, "single element at both ends", 3)
    check(c[2..=4].size() == 3 && c[2..=4][2] == 14, "a..=b", 4)
    check(c[5..=5].size() == 1 && c[5..=5][0] == 15, "last element by ..=", 5)
    check(c[0..=0].size() == 1 && c[0..=0][0] == 10, "first element by ..=", 6)
    check(c[4..].size() == 2 && c[4..][0] == 14, "a..", 7)
    check(c[0..].size() == 6 && c[6..].size() == 0, "from 0 and from len", 8)
    check(c[..2].size() == 2 && c[..2][1] == 11 && c[..0].size() == 0 && c[..6].size() == 6, "..b", 9)
    check(c[..=2].size() == 3 && c[..=2][2] == 12 && c[..=5].size() == 6, "..=b", 10)

    for var k: usize = 0; k <= 6; ++k {
        check(c[k..k].size() == 0, "empty range at every position", 11)
        check(c[k..].size() == 6 - k && c[..k].size() == k, "split by from / to at every position", 12)
    }

    for var a: usize = 0; a <= 6; ++a {
        for var b: usize = a; b <= 6; ++b {
            var sub = c[a..b]
            check(sub.size() == b - a, "a..b length for every pair", 13)
            for var i: usize = 0; i < sub.size(); ++i {
                check(sub[i] == 10 + ((a + i) as i32), "a..b element for every pair", 14)
            }
        }
    }

    check(c[1..5][1..3][0] == 12 && c[1..5][1..3].size() == 2, "nested ranges", 15)
    check(c[2..][1..][0] == 13 && c[..4][..2].size() == 2, "nested open ranges", 16)

    var none: [i32]
    const e: [const i32;] = none
    check(e[0..0].size() == 0 && e[..].size() == 0 && e[0..].size() == 0 && e[..0].size() == 0, "ranges on empty", 17)
    var one: [i32] = [5]
    const o: [const i32;] = one
    check(o[0..1][0] == 5 && o[1..].size() == 0 && o[..1][0] == 5 && o[..=0][0] == 5, "ranges on one", 18)
}

fn writes_through_ranges() {
    var v: [i32] = [0, 0, 0, 0, 0, 0]
    var s: [i32;] = v
    {
        var mid: [i32;] = s[1..4]
        mid[0] = 1
        mid[2] = 3
        mid.fill(7)
        mid[1] = 8
    }

    check(v[0] == 0 && v[1] == 7 && v[2] == 8 && v[3] == 7 && v[4] == 0, "writes through a..b reach the owner", 20)
    {
        var tail: [i32;] = s[4..]
        tail[0] = 4
        tail[1] = 5
        var head: [i32;] = s[..=0]
        head[0] = -1
    }

    check(v[0] == -1 && v[4] == 4 && v[5] == 5, "writes through a.. and ..=b", 21)
    s[1..3].reverse()
    check(v[1] == 8 && v[2] == 7, "a mutator called on a range expression", 22)
    s[..2][1] = 100
    check(v[1] == 100, "index through a range expression", 23)
}

fn split_int() {
    var v: [i32] = [1, 2, 3, 4, 5]
    var s: [i32;] = v
    const c: [const i32;] = s

    var (l0, r0) = c.split_at(0)
    check(l0.size() == 0 && r0.size() == 5 && r0[0] == 1, "split_at(0)", 30)
    var (l5, r5) = c.split_at(5)
    check(l5.size() == 5 && r5.size() == 0 && l5[4] == 5, "split_at(len)", 31)
    var (l2, r2) = c.split_at(2)
    check(l2.size() == 2 && r2.size() == 3 && l2[1] == 2 && r2[0] == 3, "split_at(middle)", 32)

    for var k: usize = 0; k <= 5; ++k {
        var (a, b) = c.split_at(k)
        check(a.size() == k && b.size() == 5 - k, "split_at lengths at every position", 33)
    }

    var none: [i32]
    const e: [const i32;] = none
    var (le, re) = e.split_at(0)
    check(le.size() == 0 && re.size() == 0, "split_at on empty", 34)

    var (ma, mb) = s.split_at_mut(2)
    ma[0] = 10
    mb[0] = 30
    ma[1] += mb[2]
    mb[2] = 0
    check(v[0] == 10 && v[1] == 7 && v[2] == 30 && v[4] == 0, "disjoint writes through split_at_mut", 35)
    var (za, zb) = s.split_at_mut(0)
    check(za.size() == 0 && zb.size() == 5, "split_at_mut(0)", 36)
    var (fa, fb) = s.split_at_mut(5)
    check(fa.size() == 5 && fb.size() == 0, "split_at_mut(len)", 37)
    fa[4] = 55
    check(v[4] == 55, "write through the first half at len", 38)
    var (sa, sb) = s.split_at_mut(3)
    sa.reverse()
    sb.reverse()
    check(v[0] == 30 && v[1] == 7 && v[2] == 10 && v[3] == 55 && v[4] == 4, "reverse of each half stays inside the half", 39)
}

fn strings() {
    var v: [string] = ["a", "b", "c", "d", "e"]
    var s: [string;] = v
    const c: [const string;] = s
    check(c[1..4].size() == 3 && c[1..4][0] == "b" && c[1..4][2] == "d", "string a..b", 50)
    check(c[3..][1] == "e" && c[..2][1] == "b" && c[..=2][2] == "c", "string open ranges", 51)
    var (l, r) = c.split_at(2)
    check(l.size() == 2 && l[1] == "b" && r.size() == 3 && r[0] == "c", "string split_at", 52)
    var (ma, mb) = s.split_at_mut(1)
    ma[0] = "A"
    mb[3] = "E"
    check(v[0] == "A" && v[4] == "E" && v[1] == "b", "string disjoint writes", 53)
    s[1..3].reverse()
    check(v[1] == "c" && v[2] == "b", "string range reverse", 54)
    check(c[2..2].size() == 0, "string empty range", 55)
}

fn instrumented() {
    {
        var v = insts(6, 0, 1)
        var s: [Inst;] = v
        var moves0 = MOVES
        const c: [const Inst;] = s
        check(c[1..4].size() == 3 && c[1..4][0].key() == 1 && c[1..4][2].key() == 3, "inst a..b", 60)
        check(c[4..][1].key() == 5 && c[..2][1].key() == 1 && c[..=2][2].key() == 2, "inst open ranges", 61)
        var (l, r) = c.split_at(3)
        check(l.size() == 3 && r.size() == 3 && r[0].key() == 3, "inst split_at", 62)
        var (ma, mb) = s.split_at_mut(2)
        ma[0].k = 100
        mb[1].k = 300
        check(v[0].key() == 100 && v[3].key() == 300, "inst writes through split_at_mut", 63)
        s[1..5].reverse()
        check(v[1].key() == 4 && v[4].key() == 1 && v[0].key() == 100, "inst reverse of a range", 64)
        check(LIVE == 6, "slicing creates no object", 65)
        var many = s.size()
        check(many == 6, "length unchanged", 66)
        check(MOVES > moves0, "reverse of a range moved elements", 67)
    }

    check_clean("subslice: instrumented", 68)
}

fn main() -> i32 {
    ranges_int()
    writes_through_ranges()
    split_int()
    strings()
    instrumented()
    io::println("subslice ok")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: subslice ok
