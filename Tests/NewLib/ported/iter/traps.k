// `step_by(0)` ends the program in every build mode: the step is never
// zero (Lib/std2/iter.k, `step_by`: "Traps when `n` is zero"). The trap is at
// the call that builds the adapter, so it happens even when the chain is never
// pulled and when the source is empty. CASE picks the call; case 0 uses the
// legal steps and exits 0.
//
// Cases from Rust library/coretests/tests/iter/adapters/step_by.rs
//   (test_iterator_step_by_zero)

import std::iter::*
import std::io
import self::Inputs::probe::*
ffi "c" import "stdlib.h"

fn main() -> i32 {
    var v: [i64] = [1, 2, 3]
    var s: [string] = ["a", "b"]
    var k: i32 = 0
    unsafe {
        var unsafe *c = getenv("CASE")
        if c != &null {
            k = atoi(c)
        }
    }

    var zero: usize = 0
    if k == 1 {
        var c = iter(Both<i64>(5)).step_by(zero)
    } else if k == 2 {
        iter(v.iter()).step_by(zero).count()
    } else if k == 3 {
        var c = iter(Both<i64>(0)).step_by(zero)
    } else if k == 4 {
        var c = iter(s.iter()).skip(1).take(1).step_by(zero)
    } else if k == 5 {
        var c = iter(Fwd<Counted>(3)).step_by(zero)
    } else {
        var a = iter(v.iter()).step_by(1).count()
        var b = iter(v.iter()).step_by(2).count()
        var e = iter(s.iter()).step_by(usize::MAX).count()
        io::println(f"ok {a} {b} {e}")
    }

    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: env CASE=1 not --crash %t.exe
// RUN: env CASE=1 not --crash %t.o2.exe
// RUN: env CASE=2 not --crash %t.exe
// RUN: env CASE=2 not --crash %t.o2.exe
// RUN: env CASE=3 not --crash %t.exe
// RUN: env CASE=3 not --crash %t.o2.exe
// RUN: env CASE=4 not --crash %t.exe
// RUN: env CASE=4 not --crash %t.o2.exe
// RUN: env CASE=5 not --crash %t.exe
// RUN: env CASE=5 not --crash %t.o2.exe
// RUN: env CASE=0 %t.exe | %FileCheck %s --check-prefix=OK
// RUN: env CASE=0 %t.o2.exe | %FileCheck %s --check-prefix=OK
// OK: ok 3 2 1
