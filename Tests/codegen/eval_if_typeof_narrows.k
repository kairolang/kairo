// XFAIL: *
// Waiting on: typing an `eval if typeof T == U` branch with T narrowed to U.
// The branch is typed once for the generic T, so `value + 1` on an
// unbounded T has no `+`; that error is dropped with the branch's other
// diagnostics, and the poisoned node reaches code generation (an internal
// error). Once the branch is typed as U, this compiles and prints 4 then 0.

import std::io

fn <T> to_s(value: T) -> i32 {
    eval if typeof T == i32 { return value + 1 }
    return 0
}

fn main() -> i32 {
    io::println(f"{to_s(3)}")
    io::println(f"{to_s(3.0)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s
// CHECK: 4
// CHECK-NEXT: 0
