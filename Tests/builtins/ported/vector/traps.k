// A vector's bounds checks and capacity checks end the program: an index past
// the end, an insert past the end, remove and swap_remove past the end or on
// an empty vector, drain and sub-range bounds that are inverted or past the
// end (including `usize::MAX` bounds), and a capacity that does not fit in a
// `usize` all trap in every build mode. CASE picks the failing operation; the
// last case stays in bounds and exits 0.
//
// Cases from libc++ test/std/containers/sequences/vector/access.pass.cpp,
//   vector.modifiers/, vector.capacity/reserve.pass.cpp (length_error)
// Cases from Rust library/alloctests/tests/vec.rs
//   (test_index_out_of_bounds, test_slice_out_of_bounds_1..5,
//   test_swap_remove_empty, test_drain_out_of_bounds, max_insert, max_remove,
//   max_swap_remove, test_drain_end_overflow)
//
// The message names the index or range and the length (containers/slice.k,
// index_fail and range_fail). Where a case has no message in the library it
// checks only that the program dies.

import std::io
ffi "c" import "stdlib.h"

fn main() -> i32 {
    var v: [i32]    = [1, 2, 3]
    var e: [i32]
    var s: [string] = ["a", "b"]
    var k: i32 = 0
    unsafe {
        var unsafe *c = getenv("CASE")
        if c != &null {
            k = atoi(c)
        }
    }

    var top = usize::MAX
    if k == 1 {
        io::println(f"{v[3]}")
    } else if k == 2 {
        v[7] = 1
    } else if k == 3 {
        io::println(f"{e[0]}")
    } else if k == 4 {
        v.insert(4, 9)
    } else if k == 5 {
        e.insert(1, 9)
    } else if k == 6 {
        var x = v.remove(3)
    } else if k == 7 {
        var x = e.remove(0)
    } else if k == 8 {
        var x = v.swap_remove(3)
    } else if k == 9 {
        var x = e.swap_remove(0)
    } else if k == 10 {
        var d = v.drain(2..5)
    } else if k == 11 {
        var lo: usize = 3
        var hi: usize = 2
        var d = v.drain(lo..hi)
    } else if k == 12 {
        var d = v.drain(0..=3)
    } else if k == 13 {
        var lo: usize = 2
        var hi: usize = 5
        v[lo..hi].reverse()
    } else if k == 14 {
        var lo: usize = 4
        v[lo..].reverse()
    } else if k == 15 {
        var hi: usize = 3
        v[..=hi].reverse()
    } else if k == 16 {
        v.reserve(top)
    } else if k == 17 {
        var w = Vector<i32>::with_capacity(top)
    } else if k == 18 {
        v.insert(top, 9)
    } else if k == 19 {
        var x = v.remove(top)
    } else if k == 20 {
        var x = v.swap_remove(top)
    } else if k == 21 {
        var d = v.drain(0..top)
    } else if k == 22 {
        var d = v.drain(top..=top)
    } else if k == 23 {
        var d = v.drain(0..=top)
    } else if k == 24 {
        v.resize(top, 0)
    } else if k == 25 {
        var w = Vector<string>::with_capacity(top / 8)
    } else if k == 26 {
        s.insert(3, "x")
    } else if k == 27 {
        var x = s.remove(2)
    } else if k == 28 {
        io::println(f"{s[2]}")
    } else {
        v.insert(3, 4)
        var a = v.remove(3)
        var b = v.swap_remove(0)
        {
            var d = v.drain(0..2)
        }

        e.insert(0, 1)
        var c = e.remove(0)
        s.insert(2, "c")
        var r = s.remove(0)
        v.reserve(0)
        io::println(f"ok {a} {b} {c} {r} {v.size()} {s.size()}")
    }

    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: env CASE=1 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C1
// RUN: env CASE=1 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C1
// RUN: env CASE=2 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C2
// RUN: env CASE=2 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C2
// RUN: env CASE=3 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C3
// RUN: env CASE=3 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C3
// RUN: env CASE=4 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C4
// RUN: env CASE=4 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C4
// RUN: env CASE=5 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C5
// RUN: env CASE=5 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C5
// RUN: env CASE=6 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C6
// RUN: env CASE=6 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C6
// RUN: env CASE=7 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C7
// RUN: env CASE=7 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C7
// RUN: env CASE=8 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C8
// RUN: env CASE=8 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C8
// RUN: env CASE=9 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C9
// RUN: env CASE=9 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C9
// RUN: env CASE=10 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C10
// RUN: env CASE=10 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C10
// RUN: env CASE=11 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C11
// RUN: env CASE=11 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C11
// RUN: env CASE=12 not --crash %t.exe
// RUN: env CASE=12 not --crash %t.o2.exe
// RUN: env CASE=13 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C13
// RUN: env CASE=13 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C13
// RUN: env CASE=14 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C14
// RUN: env CASE=14 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C14
// RUN: env CASE=15 not --crash %t.exe
// RUN: env CASE=15 not --crash %t.o2.exe
// RUN: env CASE=16 not --crash %t.exe
// RUN: env CASE=16 not --crash %t.o2.exe
// RUN: env CASE=17 not --crash %t.exe
// RUN: env CASE=17 not --crash %t.o2.exe
// RUN: env CASE=18 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C18
// RUN: env CASE=18 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C18
// RUN: env CASE=19 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C19
// RUN: env CASE=19 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C19
// RUN: env CASE=20 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C20
// RUN: env CASE=20 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C20
// RUN: env CASE=21 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C21
// RUN: env CASE=21 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C21
// RUN: env CASE=22 not --crash %t.exe
// RUN: env CASE=22 not --crash %t.o2.exe
// RUN: env CASE=23 not --crash %t.exe
// RUN: env CASE=23 not --crash %t.o2.exe
// RUN: env CASE=24 not --crash %t.exe
// RUN: env CASE=24 not --crash %t.o2.exe
// RUN: env CASE=25 not --crash %t.exe
// RUN: env CASE=25 not --crash %t.o2.exe
// RUN: env CASE=26 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C26
// RUN: env CASE=26 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C26
// RUN: env CASE=27 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C27
// RUN: env CASE=27 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C27
// RUN: env CASE=28 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C28
// RUN: env CASE=28 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C28
// RUN: env CASE=0 %t.exe | %FileCheck %s --check-prefix=OK
// RUN: env CASE=0 %t.o2.exe | %FileCheck %s --check-prefix=OK
// C1: index 3 is out of bounds for length 3
// C2: index 7 is out of bounds for length 3
// C3: index 0 is out of bounds for length 0
// C4: index 4 is out of bounds for length 3
// C5: index 1 is out of bounds for length 0
// C6: index 3 is out of bounds for length 3
// C7: index 0 is out of bounds for length 0
// C8: index 3 is out of bounds for length 3
// C9: index 0 is out of bounds for length 0
// C10: range 2..5 is out of bounds for length 3
// C11: range 3..2 is out of bounds for length 3
// C13: range 2..5 is out of bounds for length 3
// C14: range 4..3 is out of bounds for length 3
// C18: index 18446744073709551615 is out of bounds for length 3
// C19: index 18446744073709551615 is out of bounds for length 3
// C20: index 18446744073709551615 is out of bounds for length 3
// C21: range 0..18446744073709551615 is out of bounds for length 3
// C26: index 3 is out of bounds for length 2
// C27: index 2 is out of bounds for length 2
// C28: index 2 is out of bounds for length 2
// OK: ok 4 1 1 a 0 2
