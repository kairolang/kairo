// witness/header_declared/main.k -- exit 6
// A DECLARED conformance (`extend X impl I`, `class X impl I`) is a row
// wherever its declaration is emitted, with no Kairo instance to reach it:
// lib's header carries the specializations, so a C++ host instantiating
// `twice` with lib's own types compiles, links and runs. Kairo's own
// `twice(Metric)` reaches the same row, and the header still writes it once.
import lib
fn main() -> i32 {
    var m = lib::Metric { base: 3 }
    return lib::twice(m)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.h
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/m --emit-headers=%t.h
// RUN: %t.exe; test $? -eq 6
// RUN: cat %t.h/lib.hh | %FileCheck %s --check-prefix=HDR
// HDR: #ifndef __KAIRO_W_{{.*}}Scalable_witness___lib__Metric_
// HDR: template<> struct Scalable_witness<{{ ?}}::lib::Metric> {
// HDR-NEXT: static signed int scale(const{{ ?}}::lib::Metric{{ ?}}* self, signed int factor) {
// HDR-NEXT: return{{ ?}}::lib::__kairo_ext_Metric::scale(self,
// HDR: template<> struct Scalable_witness<{{ ?}}::lib::Gauge> {
// HDR-NOT: struct Scalable_witness<{{ ?}}::lib::Metric>
// HDR-NOT: struct Scalable_witness<{{ ?}}::lib::Own>
// HDR: signed int twice(T a);

// The host, against lib's own header and objects.
// RUN: %kairo %S/lib.k -c --cache-dir %t.d/k --emit-headers=%t.hl
// RUN: %clangxx -std=c++23 -I%t.hl %S/host.cc %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.host.exe
// RUN: %t.host.exe; test $? -eq 18
// A host type whose own member is not the requirement's exact signature
// fails at the concept, never compiling a different witness.
// RUN: not %clangxx -std=c++23 -fsyntax-only -I%t.hl -DWRONG %S/host.cc 2>&1 | %FileCheck %s --check-prefix=WRONG
// WRONG: constraints not satisfied
