import Lb::Pk

fn main() -> i32 {
    var f = Pk::pick<Pk::W>
    return f(Pk::W(5))                      // 15
}

// --- lit wiring -----------------------------------------------------------
// An imported bounded generic's instance named through a path and
// read as a value runs: the instance the value use names is planned and
// emitted like a call's. The non-conforming value and call forms are each
// one SC162E at the use.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %S/bad.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD:      bad.k:4:15: error [SC162E]: 'i32' does not conform to 'Big'
// BAD:      bad.k:5:12: error [SC162E]: 'f64' does not conform to 'Big'
// BAD-NOT:  error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
