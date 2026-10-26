// A C++ exception unwinding through a Kairo frame to a C++ catch
// (Inputs/unwind: thrower.hh, passthrough.k, passthrough_main.cpp).
// pass_through calls a throwing C++ inline function with no try of its
// own, and is marked `@unwind`, so its frame is not noexcept: the
// exception passes through it and the C++ caller catches it. Without
// `@unwind` the frame would be noexcept and the throw would terminate
// (Tests/Codegen/exceptions/noexcept_terminates.k).
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/unwind/passthrough_main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      pass_through(5) = 11
// CHECK-NEXT: C++ caught through Kairo frame: negative
// CHECK-EMPTY:
