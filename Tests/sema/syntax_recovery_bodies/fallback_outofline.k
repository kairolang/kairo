// --check-past-syntax-errors falls back (see fallback.k) for a broken body
// that is an out-of-line member definition: the class's declaration ring
// expects it to be one, so it cannot stand as a signature alone. The
// importer is not checked: its own type error is not reported.
//
// RUN: { %kairo %s -I %S --type-check-only --check-past-syntax-errors 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
//
// CHECK: outofline_lib.k:8:21: error [S052E]: expected expression, found ';'

import outofline_lib::fine

fn main() -> i32 {
    var z: i32 = "not checked"
    return fine(1)
}
