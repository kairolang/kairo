// --type-check-only stops after Sema: a clean file exits 0 and prints no ld
// line, and an ill-typed one still reports its diagnostic. This is the
// working loop while CodeGen is unfinished.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --print-ld-args | %FileCheck %s --check-prefix=NOLD --allow-empty
// NOLD-NOT: ld.lld
// NOLD-NOT: ld
