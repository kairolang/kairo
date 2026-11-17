// Element access and observers of a slice on an empty, a one-element and a
// many-element slice: size, is_empty, indexing for reading and writing,
// get / get_mut / first / last / at (null on a miss), data / begin / end,
// and writes seen through every alias of the same elements. Elements are
// i32, string and a move-only instrumented class whose live count returns
// to zero.
//
// Cases from libc++ test/std/containers/views/views.span/span.elem/
// Cases from libc++ test/std/containers/views/views.span/span.obs/
// Cases from Rust library/coretests/tests/slice.rs (get, first, last, get_mut)

import self::Inputs::inst::*
import std::io

fn observers_int() {
    var none: [i32]
    var one: [i32]  = [7]
    var many: [i32] = [4, 8, 15, 16, 23, 42]
    var e: [i32;] = none
    var o: [i32;] = one
    var m: [i32;] = many

    check(e.size() == 0 && e.is_empty(), "empty slice size / is_empty", 1)
    check(o.size() == 1 && !o.is_empty(), "one-element slice size / is_empty", 2)
    check(m.size() == 6 && !m.is_empty(), "many-element slice size / is_empty", 3)

    var d: [i32;] = Slice<i32>()
    check(d.size() == 0 && d.is_empty(), "default slice is empty", 4)
    check(d.first() == null && d.last() == null && d.get(0) == null, "default slice has no elements", 5)
    check(d.data() == null && d.begin() == null && d.end() == null, "default slice has no storage", 6)
}

fn nullable_reads_int() {
    var none: [i32]
    var one: [i32]  = [7]
    var many: [i32] = [4, 8, 15, 16, 23, 42]
    var e: [i32;] = none
    var o: [i32;] = one
    var m: [i32;] = many

    check(e.first() == null, "first on empty is null", 10)
    check(e.last() == null, "last on empty is null", 11)
    check(e.get(0) == null, "get(0) on empty is null", 12)
    check(e.at(0) == null && e.at(-1) == null, "at on empty is null", 13)

    var *f1? = o.first()
    var *l1? = o.last()
    check(f1? && l1? && *f1 == 7 && *l1 == 7, "first and last of one element", 14)
    check(o.get(1) == null && o.at(1) == null && o.at(-2) == null, "one past a single element is null", 15)
    var *a1? = o.at(-1)
    check(a1? && *a1 == 7, "at(-1) of one element", 16)

    var *f? = m.first()
    var *l? = m.last()
    check(f? && l? && *f == 4 && *l == 42, "first and last of many", 17)
    var *g0? = m.get(0)
    var *g5? = m.get(5)
    check(g0? && g5? && *g0 == 4 && *g5 == 42, "get at both ends", 18)
    check(m.get(6) == null && m.get(usize::MAX) == null, "get past the end is null", 19)

    var *n1? = m.at(-1)
    var *n6? = m.at(-6)
    var *p5? = m.at(5)
    check(n1? && n6? && p5? && *n1 == 42 && *n6 == 4 && *p5 == 42, "at from both ends", 20)
    check(m.at(6) == null && m.at(-7) == null, "at past either end is null", 21)
    check(m.at(isize::MIN) == null && m.at(isize::MAX) == null, "at at the isize extremes is null", 22)
}

fn writes_int() {
    var many: [i32] = [1, 2, 3, 4, 5]
    var m: [i32;] = many
    var alias: [i32;] = m

    m[0] = 10
    m[4] = 50
    alias[2] = 30
    check(many[0] == 10 && many[2] == 30 && many[4] == 50, "writes reach the owner", 30)
    check(m[2] == 30 && alias[0] == 10, "writes are seen through every alias", 31)

    var *p? = m.get_mut(1)
    if !p? {
        fail("get_mut in range", 32)
    }

    *p = 20
    check(many[1] == 20, "write through get_mut", 33)
    check(m.get_mut(5) == null && m.get_mut(usize::MAX) == null, "get_mut past the end is null", 34)
    var nov: [i32]
    var none: [i32;] = nov
    check(none.get_mut(0) == null, "get_mut on empty is null", 35)

    var q: [i32;] = m[1..4]
    q[0] += 1
    q[2] *= 2
    check(many[1] == 21 && many[3] == 8, "compound writes through a sub-slice", 36)
}

fn pointers_int() {
    var many: [i32] = [1, 2, 3, 4]
    var m: [i32;] = many
    var *b? = m.begin()
    var *d? = m.data()
    var *e? = m.end()
    if !b? || !d? || !e? {
        fail("begin, data and end are non-null on many", 40)
    }

    unsafe {
        var bp = b as unsafe *const i32 as usize
        var dp = d as unsafe *const i32 as usize
        var ep = e as unsafe *const i32 as usize
        check(bp == dp, "begin and data agree", 41)
        check(ep - bp == 4 * sizeof i32, "end is one past the last element", 42)
        check(*(b as unsafe *const i32) == 1, "begin points at the first element", 43)
    }

    const tail: [const i32;] = m[4..]
    check(tail.is_empty() && tail.begin() != null, "empty tail of a slice keeps its position", 44)
    var *mut? = m.data_mut()
    if !mut? {
        fail("data_mut is non-null on many", 45)
    }

    *mut = 99
    check(many[0] == 99, "write through data_mut", 46)
    var empty: [i32;] = Slice<i32>()
    check(empty.data_mut() == null, "data_mut of the default slice is null", 47)
}

fn strings() {
    var v: [string] = ["alpha", "beta", "gamma"]
    var s: [string;] = v
    check(s.size() == 3, "string slice size", 50)
    check(s[0] == "alpha" && s[2] == "gamma", "string indexing", 51)
    var *f? = s.first()
    var *l? = s.last()
    check(f? && l? && *f == "alpha" && *l == "gamma", "string first and last", 52)
    var *a? = s.at(-2)
    check(a? && *a == "beta", "string at(-2)", 53)
    check(s.get(3) == null, "string get past the end", 54)
    s[1] = "BETA"
    check(v[1] == "BETA", "string write through the slice", 55)
    var *g? = s.get_mut(2)
    if !g? {
        fail("string get_mut", 56)
    }

    *g += "!"
    check(v[2] == "gamma!", "string append through get_mut", 57)
    const none: [const string;] = s[1..1]
    check(none.first() == null && none.last() == null, "string empty first and last", 58)
}

fn instrumented() {
    {
        var v = insts(5, 100, 10)
        var s: [Inst;] = v
        var moves0 = MOVES
        check(s.size() == 5 && !s.is_empty(), "inst size", 60)
        check(s[0].key() == 100 && s[4].key() == 140, "inst indexing", 61)
        var *f? = s.first()
        var *l? = s.last()
        check(f? && l? && f->key() == 100 && l->key() == 140, "inst first and last", 62)
        var *g? = s.get_mut(2)
        if !g? {
        fail("inst get_mut", 63)
    }

        g->k = 7
        check(s[2].key() == 7 && v[2].key() == 7, "inst write through get_mut", 64)
        s[3].k = 9
        var *a? = s.at(-2)
        check(a? && a->key() == 9, "inst at(-2) sees the write", 65)
        check(s.get(5) == null && s.at(-6) == null, "inst misses are null", 66)
        const e: [const Inst;] = s[2..2]
        check(e.first() == null && e.last() == null && e.get(0) == null, "inst empty slice has no elements", 67)
        check(LIVE == 5 && MOVES == moves0, "reading a slice neither moves nor copies", 68)
    }

    check_clean("access: instrumented", 69)
}

fn main() -> i32 {
    observers_int()
    nullable_reads_int()
    writes_int()
    pointers_int()
    strings()
    instrumented()
    io::println("access ok")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: access ok
