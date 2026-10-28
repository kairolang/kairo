// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
//
// An operator on a bounded `T` binds through the bound only when it is the
// left operand's own: `in` is the RIGHT operand's (`xs.op in(x)`), and `??`
// is no user operator at all. Those still defer on a dependent operand, as
// before bounds were consulted; `x in xs` was briefly an SC066E ("'in'
// needs an 'op in' on '[T]'"). What the bounds do NOT declare is no longer
// deferred (MONO.md D0, G11): an `==` none of them declares is R025E, and
// `===` on two pointers is SC034E whatever they point to, as it is on any
// pair that cannot be null.

pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
fn <T impl Scalable> has(x: T, xs: [T]) -> bool { return x in xs }
fn <T impl Scalable> pick(a: T?, b: T) -> T { return a ?? b }
fn <T impl Scalable> same(a: *T, b: *T) -> bool { return a === b }
fn <T impl Scalable> plain(a: T, b: T) -> bool { return a == b }
fn main() -> i32 { return 0 }
// CHECK: bounded_operand_defers.k:17:58: error [SC034E]: '===' needs a nullable operand; '*T' and '*T' are not nullable
// CHECK: bounded_operand_defers.k:18:57: error [R025E]: '==' on 'T' needs a bound that declares 'op =='; none of the bounds of 'T' does
