// A policy code is category + number. SC005 (a Semantic warning) and S005 (a
// Syntax code) used to collapse to the key 5, so allowing one silenced the
// other. -A S005 must leave the SC005W warning alone; -A SC005 removes it.

fn f(__x: i32) -> i32 { return __x }
fn main() -> i32 { return f(0) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -A S005 2>&1 || true; } | %FileCheck %s --check-prefix=KEPT
// RUN: { %kairo %s --type-check-only -A SC005 2>&1 || true; } | %FileCheck %s --check-prefix=GONE --allow-empty
// KEPT: warning [SC005W]: parameter name is reserved
// GONE-NOT: SC005
