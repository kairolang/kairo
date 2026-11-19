// A private declaration of the builtin library (string.k's `priv eval W`)
// is out of reach of user code, so it does not collide with a visible `W`:
// here the struct a header declares. The same private name used alone is
// still reported as private (R047E), not as unknown.

ffi "c++" import "prelude_private_w.h"

fn main() -> i32 {
    var w = W()
    return w.v
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: R016E
// OK-NOT: error
// RUN: { %kairo %S/inputs/prelude_private_alone.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=ALONE
// ALONE: error [R047E]: 'HDR' is imported but is declared private in its module
