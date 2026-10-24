// The control for cxx_template_ref_marker.k (XFAIL): the same program with
// the `&` marker dropped from `cxx_scale_and_sum(&buf, 3)`, which is what
// compiles today. It keeps every other crossing in that program covered
// while the marker bug stands. Delete this file when the marker test
// passes.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cp %S/Inputs/cxx_template_ref/* %t.d/
// RUN: sed -i 's/cxx_scale_and_sum(&buf, 3)/cxx_scale_and_sum(buf, 3)/' %t.d/ring.k
// RUN: grep -q 'cxx_scale_and_sum(buf, 3)' %t.d/ring.k
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
