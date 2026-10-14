// -O selects the cc1 optimisation level; -Os/-Oz are size goals, -Og maps to
// -O1, and every level above 0 turns the vectorizers on. Unknown levels are
// rejected by the flag parser.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args -O2 | %FileCheck %s --check-prefix=O2
// O2:      -O2
// O2-SAME: -vectorize-loops -vectorize-slp
// RUN: %kairo %s --print-clang-args -Oz | %FileCheck %s --check-prefix=OZ
// OZ: -Oz
// RUN: %kairo %s --print-clang-args -Og | %FileCheck %s --check-prefix=OG
// OG: -O1
// RUN: { %kairo %s --print-clang-args -O9 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: invalid value '9' for flag '-O'
