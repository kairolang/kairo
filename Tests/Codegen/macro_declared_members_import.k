// Members declared by an IMPORTED `pub macro`: a method, a field, an
// operator, a `pub` and a `priv` method with nested blocks, a method from a
// macro another macro invokes, a whole class and an `ffi "c"` function.
// Every token of a macro body reads at the invocation, the body's braces,
// visibility keywords and `ffi "lang"` head included, so a member's range
// stays in app.k; a range running from app.k into lib.k made the codegen
// token sink read past the end of app.k's buffer (I003E).
// Inputs/macro_members_import: lib.k declares, app.k uses.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/macro_members_import && %kairo app.k -o %t.d/app.exe --cache-dir %t.d/c
// RUN: %t.d/app.exe; test $? -eq 42
// RUN: cd %S/Inputs/macro_members_import && %kairo app.k --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s < %t.d/h/app.hh
// CHECK-DAG: get() const
// CHECK-DAG: extra
// CHECK-DAG: operator+(
// CHECK-DAG: clamp(
// CHECK-DAG: class Holder {
// CHECK-DAG: twice() const
// CHECK-DAG: got() const
