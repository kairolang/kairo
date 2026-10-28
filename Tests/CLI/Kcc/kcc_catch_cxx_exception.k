// A Kairo try/catch catching a C++ exception thrown one Kairo frame down
// (Inputs/unwind: thrower.hh, guarded.k, guarded_main.cpp), as
// c-cpp-exceptions.md specifies: `catch e: cxx::std::exception`.
//
// `relay` is `@unwind`: the exception has to cross its frame to reach the
// try in `guarded` (a noexcept frame would terminate). `guarded` itself is
// noexcept: the C++ `try` PanicLowering keeps around the body (PANIC.md
// §3.5, §4.5a H) catches it inside the frame.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/unwind/guarded_main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      guarded(5)  = 11
// CHECK-NEXT:   [Kairo] caught C++ exception
// CHECK-NEXT: guarded(-5) = -1
// CHECK-EMPTY:
