// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error
//
// An operator on a bounded `T` binds through the bound only when it is the
// left operand's own: `in` is the RIGHT operand's (`xs.op in(x)`), and `??`
// and `===` are no user operator at all. Those still defer on a dependent
// operand, as before bounds were consulted; `x in xs` was briefly an
// SC066E ("'in' needs an 'op in' on '[T]'"). An `==` the bound does not
// declare defers too.

pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
fn <T impl Scalable> has(x: T, xs: [T]) -> bool { return x in xs }
fn <T impl Scalable> pick(a: T?, b: T) -> T { return a ?? b }
fn <T impl Scalable> same(a: *T, b: *T) -> bool { return a === b }
fn <T impl Scalable> plain(a: T, b: T) -> bool { return a == b }
fn main() -> i32 { return 0 }
