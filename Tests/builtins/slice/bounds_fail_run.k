// A failed bounds check ends the program through index_fail or range_fail,
// which name the index or the range and the length, in every build mode.
// CASE picks the failing access; the last case is in bounds and exits 0.

import std::io
ffi "c" import "stdlib.h"

fn main() -> i32 {
    var v: [i32]  = [1, 2, 3]
    var s: [i32;] = v
    var k: i32 = 0
    unsafe {
        var unsafe *c = getenv("CASE")
        if c != &null {
            k = atoi(c)
        }
    }

    if k == 1 {
        io::println(f"{s[3]}")
    } else if k == 2 {
        s[7] = 1
    } else if k == 3 {
        s[2..5].reverse()
    } else if k == 4 {
        var lo: usize = 3
        var hi: usize = 2
        s[lo..hi].reverse()
    } else if k == 5 {
        s[4..].reverse()
    } else if k == 6 {
        s[..=3].reverse()
    } else if k == 7 {
        s.swap(0, 3)
    } else if k == 8 {
        var (a, b) = s.split_at(4)
    } else if k == 9 {
        for w in s.windows(0) { }
    } else {
        s[0..3].reverse()
        s[3..].reverse()
        s[..=2].reverse()
        io::println(f"ok {s[0]} {s[2]}")
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
// RUN: env CASE=2 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C2
// RUN: env CASE=3 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C3
// RUN: env CASE=4 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C4
// RUN: env CASE=5 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C5
// RUN: env CASE=6 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C6
// RUN: env CASE=7 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C7
// RUN: env CASE=8 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C8
// RUN: env CASE=9 not --crash %t.o2.exe 2>&1 | %FileCheck %s --check-prefix=C9
// RUN: env CASE=0 %t.exe | %FileCheck %s --check-prefix=OK
// RUN: env CASE=0 %t.o2.exe | %FileCheck %s --check-prefix=OK
// C1: index 3 is out of bounds for length 3
// C2: index 7 is out of bounds for length 3
// C3: range 2..5 is out of bounds for length 3
// C4: range 3..2 is out of bounds for length 3
// C5: range 4..3 is out of bounds for length 3
// C6: range 0..4 is out of bounds for length 3
// C7: index 3 is out of bounds for length 3
// C8: range 0..4 is out of bounds for length 3
// C9: index 0 is out of bounds for length 0
// OK: ok 1 3
