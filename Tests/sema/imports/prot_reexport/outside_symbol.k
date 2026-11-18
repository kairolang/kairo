import lib::a::fx
fn main() -> i32 { return fx() }

// --- lit wiring -----------------------------------------------------------
// The symbol path `lib::a::fx` walks lib/a.k's surface
// (ImportResolution::_reexported_cell), where a `prot import` counts only
// for files of lib's module.
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: outside_symbol.k:1:16: error [R015E]: 'fx' is not declared in module 'a'
