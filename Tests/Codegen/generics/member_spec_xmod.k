// Member specializations written in another module than their class: a TU
// that calls `g.m<i32>()` without importing that module runs them, and so
// does a C++ host that includes it.

// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/member_spec_xmod && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: cd %S/Inputs/member_spec_xmod && %kairo main.k -o %t.d/main --cache-dir %t.d/c
// RUN: %t.d/main
// REQUIRES: kcc
// RUN: cd %S/Inputs/member_spec_xmod && %kcc host.cpp -o %t.d/host
// RUN: %t.d/host
