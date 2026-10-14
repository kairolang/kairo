// --cmax-expr-depth caps expression recursion in the parser (it used to read
// the scope cap instead, leaving this flag dead). Nine nested parentheses
// exceed a cap of 3 and report once; a cap of 100 accepts the same program.
// The scope cap stays at its default so only the expression counter can fire.

fn main() -> i32 {
    return (((((((((1)))))))))
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --type-check-only --cmax-expr-depth=3 %s 2>&1 || true; } | %FileCheck %s --check-prefix=LOW
// RUN: %kairo --type-check-only --cmax-expr-depth=100 %s
// LOW: error [S063E]: exceeded maximum expression nesting depth
