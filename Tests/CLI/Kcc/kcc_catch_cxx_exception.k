// A Kairo try/catch catching a C++ exception thrown one Kairo frame down
// (Inputs/unwind: thrower.hh, guarded.k, guarded_main.cpp), as
// c-cpp-exceptions.md specifies: `catch e: cxx::std::exception`.
//
// Expected to fail for now, for two reasons, in this order:
//  - a Kairo TU is compiled with exceptions off, so thrower.hh's `throw`
//    is CL001E (kcc_unwind_through_kairo.k has the details);
//  - with -fexceptions, codegen ICEs on the try: "EmitIR: try/catch;
//    PanicLowering owns it". PanicLowering does not yet lower a try
//    around a C++ call to a C++ try/catch.
// When both land this XPASSes: drop the XFAIL line.
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
