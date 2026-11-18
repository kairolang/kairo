// Two included modules that both use an f-string share the one deferred
// formatting helper in a C++ TU: the second include must not define it
// again. Each include also leaves its own functions callable.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %t.d && %kairo -I %S/inputs/include_k_fmt %S/inputs/include_k_fmt/use_fmt.cc %S/inputs/include_k_fmt/fa.k %S/inputs/include_k_fmt/fb.k -o %t.d/fmt --cache-dir %t.d/o1
// RUN: %t.d/fmt > %t.d/fmt.out; test $? -eq 5
// RUN: %FileCheck %s --input-file=%t.d/fmt.out
// CHECK:      a a 1
// CHECK-NEXT: b b 1
