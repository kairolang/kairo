import lib::*
import lib::a::*
fn main() -> i32 { return fx() }

// --- lit wiring -----------------------------------------------------------
// Neither lib/module.k's nor lib/a.k's `prot import self::x::*` is a
// re-export to this file, which is outside lib's module.
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: outside_wildcard.k:3:27: error [R020E]: use of undeclared identifier 'fx'
