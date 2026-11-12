import lib::a::{fx}
fn main() -> i32 { return fx() }

// --- lit wiring -----------------------------------------------------------
// A selective import names what it takes from lib/a.k's surface,
// where a `prot import` counts only for files of lib's module.
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: outside_selective.k:1:17: error [R015E]: 'fx' is not declared in module 'a'
