// A builtin meets an operator requirement only through an operator it has
// built in with the requirement's shape. `bool` has no `+`, a pointer no
// `+` taking a pointer, `f64` no `%` and no usable `<=>`, and `i32 + i32`
// gives `i32`, not `bool`. A class meets it only by declaring the operator.
// An interface that also declares a method is met by a builtin only when an
// extension supplies the method.

interface Add { fn op + (const self, const o: Self) -> Self }
interface Ord { fn op <=> (const self, const o: Self) -> Ordering }
interface Rem { fn op % (const self, const o: Self) -> Self }
interface AddBool { fn op + (const self, const o: Self) -> bool }
interface Scaled {
    fn op + (const self, const o: Self) -> Self
    fn scale(const self) -> i32
}

fn <T impl Add> twice(const a: T) -> T { return a + a }
fn <T impl Ord> top(const a: T, const b: T) -> T {
    if a < b { return b }
    return a
}
fn <T impl Rem> rem(const a: T, const b: T) -> T { return a % b }
fn <T impl AddBool> ab(const a: T) -> bool { return a + a }
fn <T impl Scaled> sc(const a: T) -> i32 { return (a + a).scale() }

class Plain { pub var v: i32 = 0 }

extend i64 {
    fn scale(const self) -> i32 { return 2 }
}

fn main() -> i32 {
    var x = 1
    twice(true)
    twice(Plain())
    twice(&x)
    top(1.0, 2.0)
    rem(1.0, 2.0)
    ab(1)
    sc(3)
    return sc(3 as i64)
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: builtin_operator_bounds_unmet.k:34:5: error [SC162E]: 'bool' does not conform to 'Add': no member 'op +' with the requirement's signature
// CHECK: builtin_operator_bounds_unmet.k:35:5: error [SC162E]: 'Plain' does not conform to 'Add': no member 'op +' with the requirement's signature
// CHECK: builtin_operator_bounds_unmet.k:36:5: error [SC162E]: '*i32' does not conform to 'Add': no member 'op +' with the requirement's signature
// CHECK: builtin_operator_bounds_unmet.k:37:5: error [SC162E]: 'f64' does not conform to 'Ord': no member 'op <=>' with the requirement's signature
// CHECK: builtin_operator_bounds_unmet.k:38:5: error [SC162E]: 'f64' does not conform to 'Rem': no member 'op %' with the requirement's signature
// CHECK: builtin_operator_bounds_unmet.k:39:5: error [SC162E]: 'i32' does not conform to 'AddBool': no member 'op +' with the requirement's signature
// CHECK: builtin_operator_bounds_unmet.k:40:5: error [SC162E]: 'i32' does not conform to 'Scaled': no member 'scale' with the requirement's signature
// CHECK-NOT: error
