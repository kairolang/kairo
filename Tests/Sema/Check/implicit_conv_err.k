class A {
    var v: i32
    @implicit fn op as (const self) -> i32 { return self.v }
    @implicit fn value(const self) -> i32 { return self.v }      // expect: error implicit-not-op-as
}
struct B {
    var a: A
    @implicit fn op as (const self) -> A { return self.a }
}
struct C {
    var v: i32
    fn op as (const self) -> bool { return self.v != 0 }
}
fn want_i32(x: i32) -> i32 { return x }
fn want_i64(x: i64) -> i64 { return x }
fn want_bool(x: bool) -> bool { return x }
fn want_vec(const xs: [i32]) { }
fn t(a: A, b: B, k: C, c: bool, s: [i32;]) {
    var ok1 = want_i32(a)                                        // the implicit operator
    var ok2: A = b
    var ok3 = want_bool(k as bool)                               // the explicit one, written
    var e1 = want_bool(k)                                        // expect: error not marked implicit
    var e2 = want_i32(b)                                         // expect: error no chain B -> A -> i32
    var e3 = want_i64(a)                                         // expect: error result is not exactly i64
    var e4 = if c { a } else { 1 }                               // expect: error an arm is not converted
    want_vec(s)                                                  // expect: error slice to vector allocates
}
// expect: no other diagnostics

// --- lit wiring -----------------------------------------------------------
// One user conversion, exact result, never under a join; the unmarked
// `op as` still needs its `as`.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:     implicit_conv_err.k:4:{{[0-9]+}}: error [SC115E]: '@implicit' applies only to a conversion operator
// DIAG:     implicit_conv_err.k:22:{{[0-9]+}}: error [
// DIAG:     implicit_conv_err.k:23:{{[0-9]+}}: error [
// DIAG:     implicit_conv_err.k:24:{{[0-9]+}}: error [
// DIAG:     implicit_conv_err.k:25:{{[0-9]+}}: error [
// DIAG:     implicit_conv_err.k:26:{{[0-9]+}}: error [
// DIAG-NOT: implicit_conv_err.k:{{19|20|21}}:
