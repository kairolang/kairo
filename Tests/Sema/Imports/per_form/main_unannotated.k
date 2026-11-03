// A top-level declaration with no visibility written is `pub` (modules.md,
// Visibility on Top-Level Declarations), so a plain `import m::*` makes it
// usable. I used to record the IMPORT's own visibility (private unless
// `pub import`) for such a decl, and every use of one in an expression was
// R047E "imported but is declared private"; a type position never checked,
// so `-> Pair` passed while `Pair(1, 2)` failed. Only `priv fn hidden` may
// draw it.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: R047E{{.*}}'twice'
// CHECK-NOT: R047E{{.*}}'Pair'
// CHECK-NOT: R047E{{.*}}'base'
// CHECK: main_unannotated.k:[[@LINE+10]]:{{[0-9]+}}: error [R047E]: 'hidden' is imported but is declared private in its module
// CHECK-NOT: error

import unannotated::*

fn make() -> Pair {
    return Pair(twice(base), 3)
}

fn use_private() -> i32 {
    return hidden()
}
