// XFAIL: *
//
// Library defect: the trap for an inclusive range past the end of a vector
// (`v.drain(0..=3)` and `v[..=3]` on three elements) prints "range 0..3 is
// out of bounds for length 3", a range that is in bounds. A slice prints the
// exclusive end of the range it was given, "range 0..4 is out of bounds for
// length 3" (containers/slice.k, range_inclusive_end); the vector's
// `range_end_` passes the inclusive end unchanged to the same message.
//
// Cases from Rust library/alloctests/tests/vec.rs
//   (test_drain_inclusive_out_of_bounds, test_slice_out_of_bounds_5)

import std::io
ffi "c" import "stdlib.h"

fn main() -> i32 {
    var v: [i32] = [1, 2, 3]
    var k: i32 = 0
    unsafe {
        var unsafe *c = getenv("CASE")
        if c != &null {
            k = atoi(c)
        }
    }

    if k == 1 {
        var d = v.drain(0..=3)
    } else {
        var hi: usize = 3
        v[..=hi].reverse()
    }

    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: env CASE=1 not --crash %t.exe 2>&1 | %FileCheck %s
// RUN: env CASE=2 not --crash %t.exe 2>&1 | %FileCheck %s
// RUN: env CASE=1 not --crash %t.o2.exe 2>&1 | %FileCheck %s
// RUN: env CASE=2 not --crash %t.o2.exe 2>&1 | %FileCheck %s
// CHECK: range 0..4 is out of bounds for length 3
