// `x[i]` on a class with no `op []` is an error under --type-check-only.
class Plain {
    var n: i32 = 0
}

fn read(p: Plain) -> i32 {
    return p[0]
}

fn main() -> i32 {
    var p = Plain()
    return read(p)
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s
// CHECK: subscript_missing_op.k:7:12: error [SC103E]: 'Plain' has no subscript operator
