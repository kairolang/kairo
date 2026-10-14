// Diagnostics name the flag the user typed: `'--long'` when there is no short
// alias, `'-s'` when there is no long, `'-s' / '--long'` when both. They used
// to print a bare `'-'` for every long-only flag.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --pic-level=7 2>&1 || true; } | %FileCheck %s --check-prefix=RANGE
// RANGE: error [U003E]: flag '--pic-level' value 7 is out of range [0, 2]
// RUN: { %kairo %s --type-check-only --pic-level=x 2>&1 || true; } | %FileCheck %s --check-prefix=INT
// INT: error [U003E]: flag '--pic-level' expects an integer, got 'x'
// RUN: { %kairo %s --type-check-only --sysroot 2>&1 || true; } | %FileCheck %s --check-prefix=VAL
// VAL: error [U004E]: flag '--sysroot' requires a value but none was provided
// RUN: { %kairo %s --type-check-only --cmax-errors=x 2>&1 || true; } | %FileCheck %s --check-prefix=CFG
// CFG: error [U003E]: flag '--cmax-errors' expects an integer, got 'x'
