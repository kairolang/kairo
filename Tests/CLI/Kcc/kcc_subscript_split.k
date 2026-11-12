// A split subscript across the C++ boundary. Kairo calls each form by
// its own member name (`__kairo_op_get` / `__kairo_op_set`); what
// `#include "buf.k"` gives a C++ host is `operator[]` forwarders to them, the
// place form's on a mutable object and the read form's on a const one, so
// C++ writes and reads `t[i]` as it always did. Where the two forms would be
// one C++ overload (Keyed: one index type, both `self`), the place form takes
// `operator[]` and the read form is reached by name. The host returns
// 5 + 20 + 7 + 103: its write went to `w`, its const read came from `r`.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc -c %S/Inputs/subscript_split/host.cc -o %t.d/host.o
// RUN: %kcc -c %S/Inputs/subscript_split/buf.k -o %t.d/buf.o
// RUN: %kcc %t.d/host.o %t.d/buf.o -o %t.d/main
// RUN: %t.d/main; test $? -eq 135
// RUN: %kcc -E %S/Inputs/subscript_split/host.cc -o %t.d/host.ii
// RUN: %FileCheck %s --input-file=%t.d/host.ii
// CHECK: class Two {
// CHECK-SAME: const signed int & __kairo_op_get ( decltype ( sizeof ( 0 ) ) i ) const noexcept ;
// CHECK-SAME: signed int & __kairo_op_set ( decltype ( sizeof ( 0 ) ) i ) noexcept ;
// CHECK-SAME: const signed int & operator [ ] ( decltype ( sizeof ( 0 ) ) i ) const noexcept ;
// CHECK-SAME: signed int & operator [ ] ( decltype ( sizeof ( 0 ) ) i ) noexcept ;
// CHECK: class Keyed {
// CHECK-SAME: signed int __kairo_op_get ( signed long k ) noexcept ;
// CHECK-SAME: signed int & __kairo_op_set ( signed long k ) noexcept ;
// CHECK-SAME: signed int & operator [ ] ( signed long k ) noexcept ;
// CHECK-NOT: operator [ ] ( signed long k ) noexcept ; signed int & operator [ ]
