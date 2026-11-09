// An ADT variant's C++ factory is named after the variant unless the name
// is already taken in the record (its own name, a template parameter, a
// member it is written with): then `_` is appended, repeated while taken,
// and variants whose names are free claim them first
// (Compiler/Spec/Interop.md#constructing-adt-variants-from-c;
// Inputs/adt_factory_clash). Checked in the header text and by a C++ host
// calling the renamed factories.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: cd %S/Inputs/adt_factory_clash && %kairo shape.k --type-check-only --emit-headers %t.d/h
// RUN: tr -d '[:space:]' < %t.d/h/shape.hh | %FileCheck %s --check-prefix=HDR
// HDR: staticShapeShape_(signedintw)noexcept
// HDR: staticShapeis_null()noexcept
// HDR: staticShapePt(signedintShape_)noexcept{returnShape(::__kairo_vt<2>{},Shape_);}
// HDR: staticNodeNode__(signedintv)noexcept
// HDR: staticNodeNode_(signedintv)noexcept
// RUN: cd %t.d && %kcc %S/Inputs/adt_factory_clash/main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      shape 7
// CHECK-NEXT: is_null -1
// CHECK-NEXT: pt 105
// CHECK-NEXT: node 3
// CHECK-NEXT: node_ 40
// CHECK-EMPTY:
