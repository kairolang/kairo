// --cmax-macro-expansions=N caps total macro expansions per run; going over
// is R008E and the note reports the budget in force.

macro one!() { x }
fn main() -> i32 {
    var x = 1
    return one!() + one!() + one!() + one!() + one!()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-macro-expansions=3 2>&1 || true; } | %FileCheck %s
// CHECK: error [R008E]: macro expansion budget exhausted
// CHECK: current budget is 3
