fn a(x: fn(i32) -> void) { }
fn b(x: fn(@inout i32) -> void) { }
fn c(x: fn(@move i32) -> void) { }
fn d(x: fn(@inout i32) -> void) { }
// expect: no diagnostics; a.x, b.x, c.x are three distinct canonicals;
// expect: b.x and d.x are the same canonical (dump: identical canonical pointer / same rendered type)
fn e(x: fn(@inout i32) -> void) { d(x); }   // expect: clean -- the same canonical as d.x
fn g(x: fn(@inout i32) -> void) { a(x); }   // expect: error -- fn(@inout i32) is not fn(i32)
fn k(x: fn(@inout i32) -> void) { c(x); }   // expect: error -- nor is it fn(@move i32)

// --- lit wiring -----------------------------------------------------------
// Modes are in the fn-pointer canonical's key (CanonicalTypeStore::func).
//
// The dump does not render parameter types, so identity is asserted through
// the checker instead: a `fn(@inout i32)` value passes where the SAME
// canonical is expected (line 7) and is rejected where either of the other
// two is (lines 8, 9). Lines 1-4 declare nothing wrong.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// DIAG-NOT:  fnptr_modes.k:{{[1-7]}}:{{[0-9]+}}: {{error|warning}}
// DIAG:      fnptr_modes.k:8:{{[0-9]+}}: error [SC001E]: no matching overload for call to 'a'
// DIAG-NEXT: fnptr_modes.k:1:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: {{.*}}'fn (@inout i32)'{{.*}}'fn (i32)'
// DIAG:      fnptr_modes.k:9:{{[0-9]+}}: error [SC001E]: no matching overload for call to 'c'
// DIAG-NEXT: fnptr_modes.k:3:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: {{.*}}'fn (@inout i32)'{{.*}}'fn (@move i32)'
// DIAG-NOT:  {{error|warning}} [
