// Every documented trap of a slice, one program with CASE selecting the
// failing call: windows(0) and chunks(0) on empty and non-empty slices of
// every element type, indices and ranges past the end or reversed
// (including usize::MAX bounds that must not wrap), split_at and
// split_at_mut past the length, and swap out of range. Each case dies with
// the message that names the offending index or range and the length; the
// last case is in bounds and exits 0.
//
// Cases from libc++ test/std/containers/views/views.span/span.sub/
// Cases from Rust library/coretests/tests/slice.rs (should_panic cases)
// Cases from Rust library/alloctests/tests/slice.rs (should_panic cases)

import std::io
import self::Inputs::inst::*
ffi "c" import "stdlib.h"

fn main() -> i32 {
    var v: [i32] = [1, 2, 3]
    var none: [i32]
    var s: [i32;] = v
    var e: [i32;] = none
    var sv: [string] = ["a", "b"]
    var ss: [const string;] = sv
    var iv = insts(2, 0, 1)
    var is: [const Inst;] = iv
    var k: i32 = 0
    unsafe {
        var unsafe *c = getenv("CASE")
        if c != &null {
            k = atoi(c)
        }
    }

    if k == 1 {
        for w in s.windows(0) { }
    } else if k == 2 {
        for w in e.windows(0) { }
    } else if k == 3 {
        for c in s.chunks(0) { }
    } else if k == 4 {
        for c in e.chunks(0) { }
    } else if k == 5 {
        s[..=usize::MAX].reverse()
    } else if k == 6 {
        s[usize::MAX..].reverse()
    } else if k == 7 {
        var m = usize::MAX
        s[m..m].reverse()
    } else if k == 8 {
        var (a, b) = s.split_at(usize::MAX)
    } else if k == 9 {
        var (a, b) = s.split_at_mut(4)
    } else if k == 10 {
        s.swap(3, 0)
    } else if k == 11 {
        s.swap(0, 3)
    } else if k == 12 {
        e[0] = 1
    } else if k == 13 {
        var lo: usize = 2
        var hi: usize = 1
        s[lo..hi].reverse()
    } else if k == 14 {
        s[..=3].reverse()
    } else if k == 15 {
        s[3..4].reverse()
    } else if k == 16 {
        var i = usize::MAX
        io::println(f"{s[i]}")
    } else if k == 17 {
        const c: [const i32;] = s
        io::println(f"{c[3]}")
    } else if k == 18 {
        e.swap(0, 0)
    } else if k == 19 {
        for w in ss.windows(0) { }
    } else if k == 20 {
        for c in is.chunks(0) { }
    } else if k == 21 {
        s[4..].reverse()
    } else {
        s[0..3].reverse()
        s[3..].reverse()
        s[..=2].reverse()
        s.swap(0, 2)
        var (a, b) = s.split_at_mut(3)
        for w in s.windows(usize::MAX) { }
        io::println(f"ok {s[0]} {s[2]} {a.size()} {b.size()}")
    }

    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
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
// RUN: env CASE=12 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C12
// RUN: env CASE=12 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C12
// RUN: env CASE=13 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C13
// RUN: env CASE=13 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C13
// RUN: env CASE=14 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C14
// RUN: env CASE=14 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C14
// RUN: env CASE=15 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C15
// RUN: env CASE=15 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C15
// RUN: env CASE=16 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C16
// RUN: env CASE=16 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C16
// RUN: env CASE=17 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C17
// RUN: env CASE=17 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C17
// RUN: env CASE=18 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C18
// RUN: env CASE=18 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C18
// RUN: env CASE=19 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C19
// RUN: env CASE=19 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C19
// RUN: env CASE=20 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C20
// RUN: env CASE=20 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C20
// RUN: env CASE=21 not --crash %t.exe 2>&1 | %FileCheck %s --check-prefix=C21
// RUN: env CASE=21 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C21
// RUN: env CASE=0 %t.exe | %FileCheck %s --check-prefix=OK
// RUN: env CASE=0 %t.o2.exe | %FileCheck %s --check-prefix=OK
// C1: index 0 is out of bounds for length 0
// C2: index 0 is out of bounds for length 0
// C3: index 0 is out of bounds for length 0
// C4: index 0 is out of bounds for length 0
// C5: out of bounds for length 3
// C6: out of bounds for length 3
// C7: out of bounds for length 3
// C8: out of bounds for length 3
// C9: out of bounds for length 3
// C10: index 3 is out of bounds for length 3
// C11: index 3 is out of bounds for length 3
// C12: index 0 is out of bounds for length 0
// C13: range 2..1 is out of bounds for length 3
// C14: out of bounds for length 3
// C15: range 3..4 is out of bounds for length 3
// C16: index 18446744073709551615 is out of bounds for length 3
// C17: index 3 is out of bounds for length 3
// C18: index 0 is out of bounds for length 0
// C19: index 0 is out of bounds for length 0
// C20: index 0 is out of bounds for length 0
// C21: range 4..3 is out of bounds for length 3
// OK: ok 3 1 3 0
