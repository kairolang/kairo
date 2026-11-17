// Making a slice: the default (empty) slice, a slice over a vector, over a
// fixed-size array, over a raw pointer and length, over another slice, the
// conversion from `[T;]` to `[const T;]`, copies of a slice (two words that
// alias the same elements), passing and returning slices by value, and a
// slice that outlives nothing it should not (the owner is read after writes
// through the slice). Elements are i32, string and a move-only instrumented
// class whose live count returns to zero.
//
// Differs from the sources: a sub-range expression selects its form from how it is
// used, not from the type it is converted to (operator-overloading.mdx, "Places and
// values"), so a mutable view is bound by `var t = s[1..]` before it is returned or
// assigned.
//
// Cases from libc++ test/std/containers/views/views.span/span.cons/
// Cases from Rust library/coretests/tests/slice.rs (from_raw_parts, as_slice, copies)

import self::Inputs::inst::*
import std::io

fn sum_of(const s: [const i32;]) -> i32 {
    var t = 0
    for x in s {
        t += x
    }

    return t
}

fn bump_all(s: [i32;]) {
    for var i: usize = 0; i < s.size(); ++i {
        s[i] += 1
    }
}

fn tail_of(s: [i32;]) -> [i32;] {
    var t = s[1..]
    return t
}

fn first_n(const s: [const string;], n: usize) -> [const string;] {
    return s[..n]
}

fn defaults() {
    var d: [i32;] = Slice<i32>()
    check(d.size() == 0 && d.is_empty(), "default slice is empty", 1)
    check(d.first() == null && d.last() == null && d.get(0) == null, "default slice has no elements", 2)
    check(d.begin() == null && d.end() == null && d.data() == null, "default slice has no storage", 3)
    var n = 0
    for x in d {
        n += 1
    }

    check(n == 0, "a for over a default slice runs no body", 4)
    d.reverse()
    d.rotate(3)
    d.sort()
    d.fill(1)
    check(d.size() == 0, "mutators on the default slice do nothing", 5)
    var dc: [const i32;] = d
    check(dc.size() == 0 && sum_of(dc) == 0, "default slice converts to const", 6)
    check(d.to_owned().size() == 0, "to_owned of the default slice", 7)

    var e: [string;] = Slice<string>()
    check(e.size() == 0 && e.first() == null, "default string slice", 8)
    var ec: [const Inst;] = Slice<const Inst>()
    check(ec.size() == 0 && ec.last() == null, "default const slice of a move-only element", 9)
}

fn from_owners() {
    var v: [i32] = [1, 2, 3, 4]
    var s: [i32;] = v
    check(s.size() == 4 && s[3] == 4, "slice over a vector", 10)
    s[0] = 10
    check(v[0] == 10, "the slice aliases its vector", 11)
    var arr: [i32; 5] = [5, 6, 7, 8, 9]
    var a: [i32;] = arr
    check(a.size() == 5 && a[0] == 5 && a[4] == 9, "slice over a fixed-size array", 12)
    a[2] = 70
    check(arr[2] == 70, "the slice aliases its array", 13)
    var ca: [const i32;] = arr
    check(ca.size() == 5 && sum_of(ca) == 5 + 6 + 70 + 8 + 9, "const slice over a fixed-size array", 14)

    var none: [i32]
    var e: [i32;] = none
    check(e.size() == 0 && e.is_empty(), "slice over an empty vector", 15)
    var many: [i32] = [1, 2]
    for var i: i32 = 0; i < 100; ++i {
        many.push(i)
    }

    var m: [i32;] = many
    check(m.size() == 102 && m[101] == 99, "slice over a grown vector", 16)

    var sv: [string] = ["a", "b"]
    var ss: [string;] = sv
    check(ss.size() == 2 && ss[1] == "b", "slice over a string vector", 17)
}

fn from_raw() {
    var v: [i32] = [1, 2, 3, 4, 5]
    var s: [i32;] = v
    var *b? = s.data_mut()
    if !b? {
        fail("data_mut of a non-empty slice", 20)
    }

    unsafe {
        var unsafe *raw = b as unsafe *i32
        var whole = Slice<i32>(raw, 5)
        check(whole.size() == 5 && whole[4] == 5, "Slice(data, len) over the whole vector", 21)
        var mid = Slice<i32>(raw + 1, 3)
        check(mid.size() == 3 && mid[0] == 2 && mid[2] == 4, "Slice(data, len) over the middle", 22)
        mid[1] = 30
        check(v[2] == 30, "a raw slice aliases the owner", 23)
        var empty = Slice<i32>(raw, 0)
        check(empty.size() == 0 && empty.is_empty() && empty.first() == null, "Slice(data, 0) is empty", 24)
        var at_end = Slice<i32>(raw + 5, 0)
        check(at_end.size() == 0 && at_end.begin() != null, "an empty slice at the end keeps its address", 25)
        var cs = Slice<const i32>(raw as unsafe *const i32, 2)
        check(cs.size() == 2 && cs[1] == 2, "Slice<const T>(data, len)", 26)
    }
}

fn conversions_and_copies() {
    var v: [i32] = [1, 2, 3]
    var s: [i32;] = v
    var c: [const i32;] = s
    check(c.size() == 3 && c[1] == 2, "[T;] converts to [const T;]", 30)
    var vc: [const i32;] = v
    check(vc.size() == 3 && vc[2] == 3, "[T] converts to [const T;]", 31)
    s[1] = 20
    check(c[1] == 20 && vc[1] == 20, "a const view sees later writes", 32)

    var a = s
    var b = s
    a[0] = 100
    b[2] = 300
    check(v[0] == 100 && v[2] == 300 && s[0] == 100, "copies of a slice alias the same elements", 33)
    var rest = s[1..]
    a = rest
    check(a.size() == 2 && a[0] == 20 && s.size() == 3, "assigning to a copy leaves the original", 34)
    const nested: [const i32;] = s[1..][1..]
    check(nested.size() == 1 && nested[0] == 300, "a slice of a slice", 35)

    var total = sum_of(s)
    check(total == 100 + 20 + 300, "a mutable slice passes as const", 36)
    bump_all(s)
    check(v[0] == 101 && v[1] == 21 && v[2] == 301, "a slice passed by value writes through", 37)
    var t = tail_of(s)
    t[0] = 0
    check(t.size() == 2 && v[1] == 0, "a returned slice aliases the owner", 38)

    var sv: [string] = ["p", "q", "r"]
    const ss: [const string;] = sv
    var f = first_n(ss, 2)
    check(f.size() == 2 && f[0] == "p" && f[1] == "q", "a returned const string slice", 39)
    check(sizeof [i32;] == 2 * sizeof usize && sizeof [const string;] == 2 * sizeof usize, "a slice is two words", 40)
}

fn instrumented() {
    {
        var v = insts(4, 10, 1)
        var s: [Inst;] = v
        var moves0 = MOVES
        var c: [const Inst;] = s
        var a = s
        var b = c
        a[0].k = 99
        check(b[0].key() == 99 && v[0].key() == 99, "copies of a slice of move-only elements alias", 50)
        check(c.size() == 4 && s.size() == 4, "conversion keeps the length", 51)
        check(MOVES == moves0 && LIVE == 4, "making and copying slices moves nothing", 52)
        const nested: [const Inst;] = s[1..3]
        check(nested.size() == 2 && nested[0].key() == 11, "a slice of move-only elements, sliced", 53)
    }

    check_clean("construct: instrumented", 54)
}

fn main() -> i32 {
    defaults()
    from_owners()
    from_raw()
    conversions_and_copies()
    instrumented()
    io::println("construct ok")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: construct ok
