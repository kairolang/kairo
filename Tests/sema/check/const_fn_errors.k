// A const function (`fn f(...) const`) reads only its inputs: no global or static, nothing through
// a pointer, and it calls only other const fns, eval fns and the compiler
// intrinsics. `@pure` may read memory but changes none: no write to a
// global or through a pointer, and it calls only const, @pure and eval fns.

var g: i32 = 1
eval LIMIT: i32 = 10

fn plain(x: i32) -> i32 { return x }
fn ok_const(x: i32) const -> i32 { return x + LIMIT }
eval fn twice(x: i32) -> i32 { return x * 2 }

fn reads_global() const -> i32 { return g }
fn derefs(p: unsafe *i32) const -> i32 { unsafe { return *p } }
fn calls_plain(x: i32) const -> i32 { return plain(x) }
fn fine(x: i32) const -> i32 { return ok_const(x) + twice(3) }

@pure
fn pure_reads(p: unsafe *i32) -> i32 { unsafe { return *p + g } }
@pure
fn pure_writes() -> i32 { g = 2; return g }
@pure
fn pure_calls(x: i32) -> i32 { return plain(x) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: const_fn_errors.k:13:{{[0-9]+}}: error [SC200E]:
// CHECK-DAG: const_fn_errors.k:14:{{[0-9]+}}: error [SC200E]:
// CHECK-DAG: const_fn_errors.k:15:{{[0-9]+}}: error [SC200E]:
// CHECK-DAG: const_fn_errors.k:21:{{[0-9]+}}: error [SC200E]:
// CHECK-DAG: const_fn_errors.k:23:{{[0-9]+}}: error [SC200E]:
// Clean: a const fn calling a const fn and an eval fn (16), and a @pure
// one reading a global and a pointer (19).
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=CLEAN
// CLEAN-NOT: const_fn_errors.k:16:{{[0-9]+}}: error
// CLEAN-NOT: const_fn_errors.k:19:{{[0-9]+}}: error
