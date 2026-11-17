// Searching and comparing: contains / in, index_of, last_index_of,
// starts_with, ends_with, ==, is_sorted, binary_search (found flag, hit
// position and insertion point, on every gap and at both ends, with runs of
// equal elements) and partition_point (which also gives a lower and an upper
// bound). Each on empty / one / many elements. Elements are i32, u8, string
// and a move-only instrumented class whose live count returns to zero.
//
// Cases from libc++ test/std/algorithms/alg.sorting/alg.binary.search/
// Cases from libc++ test/std/algorithms/alg.sorting/is.sorted/
// Cases from libc++ test/std/algorithms/alg.nonmodifying/alg.equal/
// Cases from Rust library/coretests/tests/slice.rs (binary_search, contains, starts_with, ends_with, partition_point)

import self::Inputs::inst::*
import std::io

fn below_10(p: *const i32) -> bool {
    return *p < 10
}

fn all_true(p: *const i32) -> bool {
    return true
}

fn all_false(p: *const i32) -> bool {
    return false
}

fn is_even(p: *const i32) -> bool {
    return *p % 2 == 0
}

fn inst_below_3(p: *const Inst) -> bool {
    return p->key() < 3
}

fn string_below_m(p: *const string) -> bool {
    return *p < "m"
}

fn linear() {
    var v: [i32] = [3, 1, 4, 1, 5, 9, 2, 6]
    const s: [const i32;] = v
    check(s.contains(3) && s.contains(6) && s.contains(1), "contains at both ends and inside", 1)
    check(!s.contains(7) && !s.contains(0) && !s.contains(-1), "contains misses", 2)
    check(1 in s && !(8 in s), "the in operator", 3)
    var i1? = s.index_of(1)
    var l1? = s.last_index_of(1)
    check((i1 ?? 99) == 1 && (l1 ?? 99) == 3, "index_of and last_index_of with a repeated element", 4)
    var i3? = s.index_of(3)
    var l6? = s.last_index_of(6)
    var l3? = s.last_index_of(3)
    check((i3 ?? 99) == 0 && (l6 ?? 99) == 7 && (l3 ?? 99) == 0, "hits at the first and the last position", 5)
    check(s.index_of(8) == null && s.last_index_of(8) == null, "index_of misses are null", 6)

    var none: [i32]
    const e: [const i32;] = none
    check(!e.contains(1) && !(1 in e) && e.index_of(1) == null && e.last_index_of(1) == null, "searching an empty slice", 7)
    var one: [i32] = [5]
    const o: [const i32;] = one
    var oi? = o.index_of(5)
    var ol? = o.last_index_of(5)
    check(o.contains(5) && !o.contains(6) && (oi ?? 99) == 0 && (ol ?? 99) == 0, "searching one element", 8)
}

fn linear_long() {
    var v: [u8]
    for var i: usize = 0; i < 100; ++i {
        v.push((i % 50) as u8)
    }

    const s: [const u8;] = v
    var a? = s.index_of(49)
    var b? = s.last_index_of(49)
    var c? = s.index_of(0)
    var d? = s.last_index_of(0)
    check((a ?? 0) == 49 && (b ?? 0) == 99, "u8 hits across a long slice", 10)
    check((c ?? 99) == 0 && (d ?? 99) == 50, "u8 first element and its repeat", 11)
    check(s.index_of(50) == null && !s.contains(200), "u8 misses across a long slice", 12)
    for var k: usize = 0; k < 100; ++k {
        var h? = s.index_of(v[k])
        if (h ?? 999) != k % 50 {
            fail("u8 index_of finds the first occurrence at every position", 13)
        }
    }
}

fn prefix_suffix_equal() {
    var v: [i32] = [1, 2, 3, 4, 5]
    var w: [i32] = [1, 2, 3, 4, 5]
    var x: [i32] = [1, 2, 3, 4, 6]
    var y: [i32] = [1, 2, 3, 4]
    var none: [i32]
    const s: [const i32;] = v
    const same: [const i32;] = w
    const diff: [const i32;] = x
    const shorter: [const i32;] = y
    const e: [const i32;] = none

    check(s == same && s == s, "equal contents", 20)
    check(!(s == diff) && !(s == shorter) && !(shorter == s), "unequal contents and lengths", 21)
    check(e == e && !(e == s) && !(s == e), "empty equals only empty", 22)
    check(s.starts_with(shorter) && s.starts_with(s) && s.starts_with(e), "starts_with a prefix, itself and empty", 23)
    check(!s.starts_with(diff) && !shorter.starts_with(s), "starts_with a longer or different slice", 24)
    check(s.ends_with(s[3..]) && s.ends_with(s) && s.ends_with(e), "ends_with a suffix, itself and empty", 25)
    check(!s.ends_with(s[..4]) && !s.ends_with(diff) && !e.ends_with(s), "ends_with a non-suffix", 26)
    check(e.starts_with(e) && e.ends_with(e), "empty starts and ends with empty", 27)
    check(s[1..3] == s[1..3] && s[1..3] == same[1..3] && !(s[1..3] == s[2..4]), "equality of sub-slices", 28)

    var a: [string] = ["x", "y", "z"]
    var b: [string] = ["x", "y", "z"]
    var c: [string] = ["x", "y"]
    const sa: [const string;] = a
    const sb: [const string;] = b
    const sc: [const string;] = c
    check(sa == sb && !(sa == sc) && sa.starts_with(sc) && sa.ends_with(sa[1..]), "string slices compare by content", 29)

    var f: [i64] = [1, 2]
    var g: [i64] = [1, 2]
    const sf: [const i64;] = f
    const sg: [const i64;] = g
    check(sf == sg && !(sf == sf[..1]), "i64 slices", 30)
    var p: [u8] = [1, 2, 3, 4]
    var q: [u8] = [1, 2, 3, 4]
    var r: [u8] = [1, 2, 3, 5]
    const sp: [const u8;] = p
    const sq: [const u8;] = q
    const sr: [const u8;] = r
    check(sp == sq && !(sp == sr) && sp.starts_with(sr[..3]) && !sp.ends_with(sr[1..]), "u8 slices compare bytewise", 31)
}

fn sortedness() {
    var none: [i32]
    var one: [i32]  = [1]
    var up: [i32]   = [1, 2, 2, 3, 9]
    var same: [i32] = [4, 4, 4, 4]
    var down: [i32] = [3, 2, 1]
    var late: [i32] = [1, 2, 3, 4, 0]
    var early: [i32] = [2, 1, 3, 4, 5]
    const e: [const i32;] = none
    const o: [const i32;] = one
    const a: [const i32;] = up
    const s: [const i32;] = same
    const d: [const i32;] = down
    const l: [const i32;] = late
    const r: [const i32;] = early
    check(e.is_sorted() && o.is_sorted(), "empty and one element are sorted", 40)
    check(a.is_sorted() && s.is_sorted(), "non-decreasing with repeats is sorted", 41)
    check(!d.is_sorted() && !l.is_sorted() && !r.is_sorted(), "a descent anywhere is not sorted", 42)
    check(a[1..4].is_sorted() && d[1..].is_sorted() == false && l[..4].is_sorted(), "is_sorted of sub-slices", 43)
    var w: [string] = ["a", "b", "b", "c"]
    var u: [string] = ["b", "a"]
    const sw: [const string;] = w
    const su: [const string;] = u
    check(sw.is_sorted() && !su.is_sorted(), "string is_sorted", 44)
}

/// Checks `binary_search` of every value from `lo` to `hi` against a linear
/// scan: a hit names an equal element, a miss names the insertion point.
fn binary_all(const tag: string, const s: [const i32;], lo: i32, hi: i32, code: i32) {
    for var x: i32 = lo; x <= hi; ++x {
        var (found, at) = s.binary_search(x)
        var want: usize = 0
        var present = false
        for var i: usize = 0; i < s.size(); ++i {
            if s[i] < x {
                want = i + 1
            }

            if s[i] == x {
                present = true
            }
        }

        if found != present {
            fail(f"binary_search found flag: {tag} value {x}", code)
        }

        if found {
            if at >= s.size() || s[at] != x {
                fail(f"binary_search hit position: {tag} value {x}", code + 1)
            }
        } else if at != want {
            fail(f"binary_search insertion point: {tag} value {x}", code + 2)
        }
    }
}

fn binary_search_int() {
    var none: [i32]
    const e: [const i32;] = none
    var (f0, a0) = e.binary_search(1)
    check(!f0 && a0 == 0, "binary_search on empty", 50)

    var one: [i32] = [1]
    const o: [const i32;] = one
    var (f1, a1) = o.binary_search(0)
    var (f2, a2) = o.binary_search(1)
    var (f3, a3) = o.binary_search(2)
    check(!f1 && a1 == 0 && f2 && a2 == 0 && !f3 && a3 == 1, "binary_search on one element", 51)

    var distinct: [i32] = [1, 2, 4, 6, 8, 9]
    const d: [const i32;] = distinct
    binary_all("distinct", d, -1, 11, 52)
    var dup: [i32] = [1, 3, 3, 3]
    const dd: [const i32;] = dup
    binary_all("with a run", dd, 0, 4, 55)
    var runs: [i32] = [1, 1, 1, 2, 2, 5, 5, 5, 5, 7]
    const r: [const i32;] = runs
    binary_all("with runs", r, 0, 8, 58)
    var same: [i32] = [3, 3, 3, 3, 3, 3, 3]
    const sm: [const i32;] = same
    binary_all("all equal", sm, 2, 4, 61)
    var ext: [i32] = [i32::MIN, -1, 0, i32::MAX]
    const x: [const i32;] = ext
    var (fm, am) = x.binary_search(i32::MIN)
    var (fM, aM) = x.binary_search(i32::MAX)
    check(fm && am == 0 && fM && aM == 3, "binary_search at the extremes of i32", 64)

    for var n: usize = 0; n <= 70; ++n {
        var big: [i32]
        for var i: usize = 0; i < n; ++i {
            big.push((i * 2) as i32)
        }

        const b: [const i32;] = big
        binary_all("even numbers", b, -1, (n * 2) as i32, 65)
    }
}

fn binary_search_other() {
    var w: [string] = ["ant", "bee", "cat", "dog", "emu"]
    const sw: [const string;] = w
    var (f, a) = sw.binary_search("cat")
    check(f && a == 2, "string binary_search hit", 70)
    var (g, b) = sw.binary_search("cow")
    check(!g && b == 3, "string binary_search miss", 71)
    var (h, c) = sw.binary_search("aardvark")
    var (k, d) = sw.binary_search("zebra")
    check(!h && c == 0 && !k && d == 5, "string binary_search before and after", 72)
    var (m, n) = sw.binary_search("")
    check(!m && n == 0, "string binary_search of the empty string", 73)

    var bytes: [u8] = [1, 3, 5, 200, 255]
    const sb: [const u8;] = bytes
    var (p, q) = sb.binary_search(200)
    var (r, t) = sb.binary_search(4)
    check(p && q == 3 && !r && t == 2, "u8 binary_search", 74)
}

fn partition_point_cases() {
    var none: [i32]
    const e: [const i32;] = none
    check(e.partition_point(below_10) == 0, "partition_point on empty", 80)
    var v: [i32] = [1, 3, 5, 10, 12, 20]
    const s: [const i32;] = v
    check(s.partition_point(below_10) == 3, "partition_point in the middle", 81)
    check(s.partition_point(all_true) == 6, "partition_point when every element satisfies", 82)
    check(s.partition_point(all_false) == 0, "partition_point when none does", 83)
    check(s[3..].partition_point(below_10) == 0, "partition_point of a tail that starts false", 84)
    check(s[..3].partition_point(below_10) == 3, "partition_point of a head that is all true", 85)
    var one: [i32] = [4]
    const o: [const i32;] = one
    check(o.partition_point(below_10) == 1 && o.partition_point(all_false) == 0, "partition_point on one element", 86)

    var m: [i32] = [2, 4, 6, 7, 9]
    const sm: [const i32;] = m
    check(sm.partition_point(is_even) == 3, "partition_point on a grouped predicate", 87)

    var w: [string] = ["ant", "cat", "emu", "pig", "yak"]
    const sw: [const string;] = w
    check(sw.partition_point(string_below_m) == 3, "string partition_point", 88)
}

fn instrumented() {
    {
        var v = insts(6, 0, 2)
        const s: [const Inst;] = v
        var w = insts(6, 0, 2)
        const t: [const Inst;] = w
        var moves0 = MOVES
        check(s.is_sorted(), "inst is_sorted", 93)
        var (f, a) = s.binary_search(Inst(6, 99))
        var (g, b) = s.binary_search(Inst(7, 99))
        check(f && a == 3 && !g && b == 4, "inst binary_search", 94)
        check(s.partition_point(inst_below_3) == 2, "inst partition_point", 95)
        var li? = s.last_index_of(Inst(4, 99))
        check((li ?? 99) == 2 && s.last_index_of(Inst(5, 99)) == null, "inst last_index_of", 99)
        check(s == t && s.starts_with(t[..3]) && s.ends_with(t[3..]), "inst equality, starts_with, ends_with", 96)
        check(LIVE == 12 && MOVES == moves0, "searching moves nothing", 97)
    }

    check_clean("search: instrumented", 98)
}

fn main() -> i32 {
    linear()
    linear_long()
    prefix_suffix_equal()
    sortedness()
    binary_search_int()
    binary_search_other()
    partition_point_cases()
    instrumented()
    io::println("search ok")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: search ok
