// witness/header/main.k -- exit 6
// `--emit-headers`: iface's header carries the witness primary and its
// concept under their guard, and the bounded template's declaration and
// body carry the concept. host.cc then instantiates it from C++.
import iface
import metric::Metric
fn main() -> i32 {
    var m = Metric { base: 3 }
    return iface::twice(m)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.h
// RUN: %kairo %s -o %t.exe --cache-dir %t.d --emit-headers=%t.h
// RUN: %t.exe; test $? -eq 6
// RUN: cat %t.h/iface.hh | %FileCheck %s --check-prefix=HDR
// The concept is tier 0 (ahead of every head that names it) and the
// primary tier 1, each a definition under its own guard.
// HDR: template<class __kairo_Self> struct Scalable_witness;
// HDR: #ifndef __KAIRO_WC_{{.*}}Scalable_witness
// HDR-NEXT: #define __KAIRO_WC_{{.*}}Scalable_witness
// HDR: concept Scalable_c =
// HDR: #endif
// HDR: #ifndef __KAIRO_W_{{.*}}Scalable_witness
// HDR-NEXT: #define __KAIRO_W_{{.*}}Scalable_witness
// HDR: struct Scalable_witness {
// HDR: #endif
// HDR: requires{{ ?}}({{ ?}}::{{.*}}::Scalable_c<T>) signed int twice(T a);
// RUN: %clangxx -std=c++23 -fsyntax-only -I%t.h %S/host.cc
// RUN: not %clangxx -std=c++23 -fsyntax-only -I%t.h -DWRONG %S/host.cc 2>&1 | %FileCheck %s --check-prefix=WRONG
// WRONG: constraints not satisfied
