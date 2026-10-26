// A C++ exception and Kairo frames, run for real. Every Kairo function is
// `noexcept` unless marked `@unwind` (or built with -funwind):
//  - `contained` throws and catches inside C++, called from Kairo: works,
//    no exception ever reaches the Kairo frame.
//  - `relay` is `@unwind`: `checked` throws through it, and the C++
//    `guard` above it catches (-1).
// noexcept_terminates.k is the same callback without `@unwind`.
ffi "c++" import "guard.hh"

@unwind fn relay(x: i32) -> i32 {
    return checked(x) + 1
}

fn main() -> i32 {
    var a = contained(-3)        // -7: caught in C++
    var b = guard(relay, 4)      // 9: no throw
    var c = guard(relay, -4)     // -1: thrown through relay, caught by guard
    if (a == -7) && (b == 9) && (c == -1) { return 42 }
    return 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: signed int relay(signed int x) {
// IR: int main() noexcept {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
