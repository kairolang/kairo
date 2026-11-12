import lib::a
fn main() -> i32 { return a::fx() }

// --- lit wiring -----------------------------------------------------------
// `a::fx` asks lib/a.k's surface (MemberLookup::reexport_lookup),
// where a `prot import` counts only for files of lib's module.
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: outside_plain.k:2:30: error [R025E]: no member named 'fx' in module 'a'
