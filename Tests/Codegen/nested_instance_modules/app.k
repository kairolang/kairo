// nested_instance_modules/app.k -- exit 31
// A type nested in a generic class, named through an instance from ANOTHER
// module (GH#91): `lib::Table<i64>::Row` is the instance's Row, its fields
// read through i64, and the instance it lives in is homed in this TU,
// which is the only one that names it.
import lib

fn total(r: lib::Table<i64>::Row) -> i64 { return r.key + (r.n as i64) }

fn main() -> i32 {
    var t = lib::Table<i64>(4)
    var a: lib::Table<i64>::Row = t.row(10, 2)
    t.put(lib::Table<i64>::Row { key: 5, n: 3 })
    var k: lib::Table<i64>::Key = t.last.key           // 5
    var m = lib::Table<i64>::Mode::Slow
    var r = (total(a) + k) as i32                      // 12 + 5
    if m == lib::Table<i64>::Mode::Slow { r += 14 }
    return r                                           // 31
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 31
