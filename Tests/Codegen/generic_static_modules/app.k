// generic_static_modules/app.k -- exit 47
// A static field of a generic class from ANOTHER module, named through an
// instance (MONO G4): `lib::Pool<i64>::live` is that instance's static, as
// is a nested type's (`lib::Pool<i64>::Slot::used`); the instance is homed
// in this TU, the only one that names it.
import lib

fn main() -> i32 {
    var a = lib::Pool<i64>(5)
    var b = lib::Pool<i64>(6)
    var r = lib::Pool<i64>::live * 10                   // 30
    r += lib::Pool<u8>::live                            // its own static, 1: 31
    lib::Pool<i64>::cap = 4
    r += lib::Pool<i64>::cap + lib::Pool<u8>::cap       // 4 + 0: 35
    lib::Pool<i64>::Slot::used *= 4
    r += lib::Pool<i64>::Slot::used                     // 12: 47
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 47
