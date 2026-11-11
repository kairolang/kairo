// A Kairo generic bounded by an imported C++ concept, included by a
// C++ host. The bound's requires clause named the stand-in concept under the
// header's module namespace (`::my_code::Addable_c`), which the include does
// not carry: CL001E "no member named 'my_code' in the global namespace". It
// now names the C++ concept itself. 3 + 7.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/concept_bound/host.cc -I %S/Inputs/concept_bound -o %t.d/main
// RUN: %t.d/main; test $? -eq 10
// RUN: %kcc -E %S/Inputs/concept_bound/host.cc -I %S/Inputs/concept_bound -o %t.d/host.ii
// RUN: %FileCheck %s --input-file=%t.d/host.ii
// CHECK: requires ( :: Addable < T > )
