// A Kairo `@inout` value passed to a C++ function TEMPLATE that takes it by
// non-const lvalue reference (`template <IndexableBuffer B, typename T>
// T cxx_scale_and_sum(B& buf, T factor)`, Inputs/cxx_template_ref/
// cxx_math.hh). Kairo's rule: a mutating reference argument is marked with
// `&`, so ring.k writes `cxx_scale_and_sum(&buf, 3)`.
//
// The `&` is taken as the reference marker before clang deduces the
// template parameter, so B
// deduces from buf's own type and `B&` binds buf itself. A bare `buf` is
// SC097E, as for any @inout argument.
//
// The program also crosses the boundary every other way: a Kairo generic
// class built and indexed from C++ through its const-overloaded `op []`, a
// C++20 concept over it, overloads on `const int&` / `int&&`, and a Kairo
// assignment through a C++ `int&` return.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cp %S/Inputs/cxx_template_ref/* %t.d/
// RUN: cd %t.d && %kairo main.cpp ring.k -o %t.d/app --cache-dir %t.d/o
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      === Starting C++ <-> Kairo Ping-Pong ===
// CHECK-NEXT: [C++] After 2x scale in C++, sum = 38 (kb[0] = 20)
// CHECK-NEXT: [Kairo] Calling C++20 concept-constrained cxx_scale_and_sum on RingBuf<i32>...
// CHECK-NEXT:   [C++] feed(const int& lvalue) = 7
// CHECK-NEXT:   [C++] feed(int&& rvalue)      = 10
// CHECK-NEXT: [C++] Final combined score from Kairo = 731
// CHECK-NEXT:   [Kairo] RingBuf::~RingBuf() destroyed!
// CHECK-NEXT: === Done ===
