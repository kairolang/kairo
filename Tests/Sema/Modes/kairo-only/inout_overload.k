fn f(x: i32) -> i32 { return 1; }
fn f(@inout x: i32) -> i32 { x = 0; return 2; }
fn main() {
    var a = 5;
    var r1 = f(a);                          // expect: clean; binds the by-value f (dump: callee resolved to f @ line 1)
    var r2 = f(&a);                         // expect: clean; binds the @inout f (line 2)
    var p: *i32 = &a;
    var r3 = f(p);                          // expect: error no matching overload (a *i32 is neither)
}

// --- lit wiring -----------------------------------------------------------
// KAIRO-ONLY: no C++ oracle -- `@inout` and the `&` marker have no C++
// spelling at the call site. `f(x: T)` / `f(@inout x: T)` are two entities
// and the marker chooses.
//
// The unmarked `f(a)` reaching `@inout` ranks as a conversion, so the
// by-value overload wins it; the marked `f(&a)` picks `@inout`. The second
// RUN pins WHICH decl each call bound to, off the name-bindings dump.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// DIAG-NOT: inout_overload.k:{{[1-7]}}:{{[0-9]+}}: error
// DIAG:     inout_overload.k:8:{{[0-9]+}}: error [SC001E]: no matching overload for call to 'f'
// DIAG-NOT: {{error|warning}} [
//
// SEMA:      -- name bindings --
// SEMA:      <tu>::main
// SEMA:      f @ 5:14 -> fn f @ 1:1
// SEMA:      f @ 6:14 -> fn f @ 2:1
