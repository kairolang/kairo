import lib::*

fn main() -> i32 {
    var c = Cfg()
    return c.n
}

// --- lit wiring -----------------------------------------------------------
// lib.k has a Sema error and a record with an array-field default
// FieldInitLowering never lowered. Two inputs import it: the first reports
// the error, the second finds lib analysed and silent. Its codegen must not
// walk lib's un-lowered decls into an emitter ICE guard (the abort hid every
// other diagnostic); the batch reports the error and exits 1.
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo -c %s %S/user.k --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// RUN: %kairo -c %s %S/user.k --cache-dir %t.d >/dev/null 2>&1; test $? -eq 1
// CHECK: error [SC076E]
// CHECK-NOT: Internal Compiler Error
// CHECK-NOT: internal compiler error
