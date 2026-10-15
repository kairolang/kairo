// Only the arities a TU reaches are emitted, each a template struct of
// fields `_i: Ti`: one here, no Tuple3, and no builtin file behind it
// (TupleRecords mints the record on first use). A header's copy is under
// `#ifndef __KAIRO_TUPLE_2`; a preamble includes nothing and has none.

fn f(p: (i32, i64)) -> i64 = p.1 + (p.0 as i64)
fn main() -> i32 { return f((1, 2)) as i32 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-cxx 2>/dev/null || true; } | %FileCheck %s
// CHECK: template<class T0, class T1> struct Tuple2;
// CHECK: template<class T0, class T1> struct Tuple2 {
// CHECK-NEXT: T0 _0;
// CHECK-NEXT: T1 _1;
// CHECK-NEXT: };
// CHECK: f(::builtin::Tuple2<signed int, signed long> p);
// CHECK-NOT: Tuple3
