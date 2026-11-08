// Only `@likely` / `@unlikely` may stand before `else`; any other attribute
// there is an error, not silently dropped.

fn f(x: i32) -> i32 {
    if x > 1 {
        return 1
    } @rarely else {
        return 2
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: else_hint_errors.k:7:7: error [S081E]: only @likely / @unlikely may precede 'else'
