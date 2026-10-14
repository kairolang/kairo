// --cmax-scope-depth caps parser nesting. A cap too small for the program
// (here 4, and the builtin sources nest deeper still) used to hang the
// compiler: the depth check failed without consuming a token and the caller's
// loop re-entered the same construct forever. It must now terminate with the
// nesting error, and a generous cap must leave the same program clean.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --type-check-only --cmax-scope-depth=4 %s 2>&1 || true; } | %FileCheck %s --check-prefix=LOW
// RUN: %kairo --type-check-only --cmax-scope-depth=256 %s
// LOW: error [S063E]: exceeded maximum nesting depth
