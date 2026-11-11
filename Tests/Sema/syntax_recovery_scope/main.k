// --check-past-syntax-errors, the scope rule (Driver/CompilerRecovery.k):
// broken.k has a syntax error that is not kept inside its body (the `(`
// it leaves open means the body's `}` is not the one the text pairs with
// its `{`, so the file cannot be checked without that body), so it and
// main.k (which imports it) are not checked; sibling.k and leaf.k import nothing broken and are. sibling.k's
// own type error is reported only then: with the mode off the parse error
// stops the action before Sema. main.k's type error is never reported: an
// importer of a broken file is not checked. Both runs fail.
//
// RUN: { %kairo %s -I %S --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=OFF --implicit-check-not=error
// RUN: { %kairo %s -I %S --type-check-only --check-past-syntax-errors 2>&1 || true; } | %FileCheck %s --check-prefix=ON --implicit-check-not=error
// RUN: not %kairo %s -I %S --type-check-only --check-past-syntax-errors
// RUN: not %kairo %s -I %S --type-check-only --check-past-syntax-errors --threads=1
//
// OFF: broken.k:8:14: error [S054E]: expected ')' or ',' after expression
// OFF: broken.k:8:18: error [S052E]: expected expression, found ';'
// ON-DAG: broken.k:8:14: error [S054E]: expected ')' or ',' after expression
// ON-DAG: broken.k:8:18: error [S052E]: expected expression, found ';'
// ON-DAG: sibling.k:4:18: error [SC028E]: cannot convert 'string' to 'i32'

import broken::above
import sibling::sibling

fn main() -> i32 {
    var z: i32 = "never checked"
    return above() + sibling()
}
