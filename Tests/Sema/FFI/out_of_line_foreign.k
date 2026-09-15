ffi "c++" import "out_of_line_foreign.h";
fn helper() -> i32 { return 1; }
fn other() -> i32 { return 2; }
fn third() -> i32 { return 3; }
class K { var n: i32; }
fn S::g(self, const x: i32) { var r = helper(); var q = other(); var t = third(); }
fn S::f(self, @inout x: i32) { var k: *K = &null; }
fn S::h(self, @move x: i32) { }
fn S::p(self, x: *i32) { }
fn U::U(self, x: i32) { }

// --- lit wiring -----------------------------------------------------------
// Out-of-line definitions of IMPORTED members. S and U live in the header's
// TU, whose tables are keyed by that TU's imms; everything below used to
// probe them with THIS file's imm and take whatever shared the index:
//
//   - the out-of-line match itself (N(a) / R(b)): `S::g` compared against
//     `f`, so every definition's verdict depended on declaration order;
//     `S::p(*i32)` never found `p(int*)`.
//   - names in the BODY: the walk from `fn S::g` went S -> the header's TU
//     and never reached this file, so `helper()` bound to class S and
//     `other()` / `third()` to S's members, with bogus qualifier errors.
//   - a type named in the body (T's walk, same shape): `K` on line 7.
//   - the ctor key: `fn U::U` compared name imms across the two TUs.
//
// The dump pins each body name to THIS file's function, not an S member.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// DIAG-NOT: {{error|warning}} [
//
// SEMA:      -- out-of-line definitions --
// SEMA-NEXT: g @ 6:1 -> attached to S
// SEMA-NEXT: f @ 7:1 -> attached to S
// SEMA-NEXT: h @ 8:1 -> attached to S
// SEMA-NEXT: p @ 9:1 -> attached to S
// SEMA-NEXT: U @ 10:1 -> attached to U
// SEMA:      use helper @ 6:{{[0-9]+}} -> fn helper @ 2:1
// SEMA:      use other @ 6:{{[0-9]+}} -> fn other @ 3:1
// SEMA:      use third @ 6:{{[0-9]+}} -> fn third @ 4:1
// SEMA-NOT:  (shadows
