// A const function may not read a parameter that is passed by reference
// (a const record parameter, an @inout or @move parameter): the
// call would read through memory the purity contract says it never touches.
// A by-value record parameter is fine, and so is a const fn that only
// forwards the record without reading it.

class Big { var a: i32 = 1  var s: i64 = 2 }

fn by_value(p: Big) const -> i32 { return p.a }
fn const_param(const p: Big) const -> i32 { return p.a }
fn inout_param(@inout p: Big) const -> i32 { return p.a }
fn move_param(@move p: Big) const -> i32 { return p.a }

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: const_fn_reads_ref_param.k:10:52: error [SC200E]: 'const_param' is const, so it cannot read 'p', which is passed by reference
// CHECK: const_fn_reads_ref_param.k:11:53: error [SC200E]: 'inout_param' is const, so it cannot read 'p', which is passed by reference
// CHECK: const_fn_reads_ref_param.k:12:51: error [SC200E]: 'move_param' is const, so it cannot read 'p', which is passed by reference
