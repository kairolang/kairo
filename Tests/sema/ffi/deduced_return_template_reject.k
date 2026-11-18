// The deduced result of an imported placeholder-return template is a typed
// pointer: a member it lacks is R025E, naming the deduced type.

ffi "c++" import "deduced_return_template.h"

fn f(b: unsafe *Base) -> i32 {
    var t = my_cast<Leaf>(b)
    return t->nope()
}

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: deduced_return_template_reject.k:8:15: error [R025E]: no member named 'nope' in 'Leaf'
