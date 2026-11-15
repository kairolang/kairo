// A user macro cannot take the name of a builtin macro (compile_note!,
// embed!), of defined!, or of a parser intrinsic (unwrap!): an unqualified
// call would never reach it.

macro compile_note!() { 1 }
macro embed!() { 1 }
macro defined!(x) { 1 }
macro unwrap!(x) { x }
macro mine!() { 1 }

fn main() -> i32 { return mine!() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: builtin_names_reserved.k:5:7: error [R014E]: macro 'compile_note!' redefines a compiler builtin; builtin names are reserved
// CHECK: builtin_names_reserved.k:6:7: error [R014E]: macro 'embed!' redefines a compiler builtin; builtin names are reserved
// CHECK: builtin_names_reserved.k:7:7: error [R014E]: macro 'defined!' redefines a compiler builtin; builtin names are reserved
// CHECK: builtin_names_reserved.k:8:7: error [R014E]: macro 'unwrap!' redefines a compiler builtin; builtin names are reserved
// CHECK-NOT: 'mine!'
