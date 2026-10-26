// A Kairo try/catch catching a C++ exception thrown one Kairo frame down
// (Inputs/unwind: thrower.hh, guarded.k, guarded_main.cpp), as
// c-cpp-exceptions.md specifies: `catch e: cxx::std::exception`.
//
// `relay` is `@unwind`: the exception has to cross its frame to reach the
// try in `guarded` (a noexcept frame would terminate).
//
// Expected to fail for now: codegen ICEs on the try: "EmitIR: try/catch;
// PanicLowering owns it". PanicLowering does not yet lower a try around a
// C++ call to a C++ try/catch. (Exceptions themselves are on now.) When
// it lands this XPASSes: drop the XFAIL line.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// XFAIL: *
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/unwind/guarded_main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      guarded(5)  = 11
// CHECK-NEXT:   [Kairo] caught C++ exception
// CHECK-NEXT: guarded(-5) = -1
// CHECK-EMPTY:
