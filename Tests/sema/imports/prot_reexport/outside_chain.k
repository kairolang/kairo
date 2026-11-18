import lib::c::*
import hub::*
fn main() -> i32 { return fx() }

// --- lit wiring -----------------------------------------------------------
// A chain does not launder a `prot import`. lib/c.k's `prot import` of
// lib/a.k stops at lib's module, and hub.k's `pub import lib::a::*` hands
// on only what reached hub.k, which is outside lib's module: neither brings
// fx here.
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: outside_chain.k:3:27: error [R020E]: use of undeclared identifier 'fx'
