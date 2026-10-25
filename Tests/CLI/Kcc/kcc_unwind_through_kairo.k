// A C++ exception unwinding through a Kairo frame to a C++ catch
// (Inputs/unwind: thrower.hh, passthrough.k, passthrough_main.cpp).
// pass_through calls a throwing C++ inline function with no try of its
// own; c-cpp-exceptions.md says the exception passes through the Kairo
// frame and the C++ caller catches it.
//
// Expected to fail for now: a Kairo TU's C++ is compiled with exceptions
// off (Config::Language::exceptions defaults to -1, and a bare cc1 line
// adds no -fcxx-exceptions), so thrower.hh's `throw` is CL001E "cannot use
// 'throw' with exceptions disabled", and the cascade leaves checked_double
// undeclared (R020E). When a Kairo TU that calls C++ gets exceptions (and
// unwind tables for the frames on that path), this XPASSes: drop the
// XFAIL line.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// XFAIL: *
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/unwind/passthrough_main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      pass_through(5) = 11
// CHECK-NEXT: C++ caught through Kairo frame: negative
// CHECK-EMPTY:
