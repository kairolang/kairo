// The braces of a file-scope `eval { }` block group declarations of the
// enclosing scope, so a macro defined inside one is visible after the
// block's closing brace. Checked only: a file-scope `eval` block is not
// emitted yet.

eval {
    macro from_eval!() { 3 }
}

fn main() -> i32 {
    return from_eval!() - 3
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error [
