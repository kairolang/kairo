// --check-past-syntax-errors goes on only when every error so far is one
// file's own parse error. An import that does not resolve is reported by
// the preprocessor for no file's parse, so the action stops after the parse
// exactly as it does with the mode off: sibling.k is not checked either.
//
// RUN: { %kairo %s -I %S --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// RUN: { %kairo %s -I %S --type-check-only --check-past-syntax-errors 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
//
// CHECK-DAG: broken.k:8:14: error [S054E]: expected ')' or ',' after expression
// CHECK-DAG: broken.k:8:18: error [S052E]: expected expression, found ';'
// CHECK-DAG: unattributed.k:{{[0-9]+}}:{{[0-9]+}}: error

import broken::above
import sibling::sibling
import no_such_module::nothing

fn main() -> i32 {
    return above() + sibling()
}
