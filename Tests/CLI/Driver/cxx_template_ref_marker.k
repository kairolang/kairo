// A Kairo `@inout` value passed to a C++ function TEMPLATE that takes it by
// non-const lvalue reference (`template <IndexableBuffer B, typename T>
// T cxx_scale_and_sum(B& buf, T factor)`, Inputs/cxx_template_ref/
// cxx_math.hh). Kairo's rule: a mutating reference argument is marked with
// `&`, so ring.k writes `cxx_scale_and_sum(&buf, 3)`.
//
// Expected to fail, deliberately, for now: the marker is not taken for a C++
// template. CallTyping commits `&x` as the reference marker
// (`_commit_marker`, is_mode_marker) only once the selected parameter is
// known to be a mutable reference; for a C++ template clang deduces that
// parameter, and it deduces from `&buf` typed as a POINTER: B =
// RingBuf<int>*, so `B&` cannot bind the pointer prvalue and clang reports
// "no matching function for call to 'cxx_scale_and_sum' ... expects an
// lvalue for 1st argument". Writing `buf` without the `&` compiles and runs
// (cxx_template_ref_control.k). The user left it this way on purpose, to
// keep self-hosting simpler (the marker is still optional: SC097W only
// warns that it will be required). When the marker becomes required, a `&x`
// argument to a deduced non-const lvalue-reference template parameter must
// be taken as the marker before deduction, so B deduces from x's own type;
// then this test passes (lit reports XPASS), the XFAIL line goes, and the
// control can be deleted.
//
// The program also crosses the boundary every other way: a Kairo generic
// class built and indexed from C++ through its const-overloaded `op []`, a
// C++20 concept over it, overloads on `const int&` / `int&&`, and a Kairo
// assignment through a C++ `int&` return.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// XFAIL: *
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
