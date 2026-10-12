// A bare name in a pattern is never a binder, so an unknown one is the
// ordinary undeclared-identifier error. Its note says how to write the binder
// that was probably meant.

fn f(x: i32) {
    match x {
        case nn { }
// DIAG:      pattern_head_unresolved.k:[[@LINE-1]]:14: error [R020E]: use of undeclared identifier 'nn'
// DIAG-NEXT: pattern_head_unresolved.k:[[@LINE-2]]:14: note [{{[A-Z0-9]+}}]: to bind the matched value to a new name, write 'var nn'
        default { }
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
