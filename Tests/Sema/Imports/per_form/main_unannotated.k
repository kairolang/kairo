// A top-level declaration with no visibility written is `pub` under the old
// rule (-fdefault-visibility=pub, still the compiler tree's), so a plain
// `import m::*` makes it usable. The IMPORT's own visibility (private unless
// `pub import`) is not recorded for such a decl, or every use of one in an expression would be
// R047E "imported but is declared private" while a type position never checked,
// so `-> Pair` passed and `Pair(1, 2)` failed. Only `priv fn hidden` may
// draw it.
// RUN: { %kairo %s --type-check-only -fdefault-visibility=pub 2>&1 || true; } | %FileCheck %s
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
