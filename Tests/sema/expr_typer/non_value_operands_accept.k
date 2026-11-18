// The value counterparts of the non-value operands type-check cleanly: a
// cast of a value, arithmetic on a value, a function called rather than
// named, and a generic function called with its argument deduced.

class C { var v: i64 = 0 }

fn h(x: i32) -> i32 = x

fn <T> g(x: T) -> T = x

fn cast_value() -> i32 {
    var c: C
    return c.v as i32
}
fn add_value() -> i32 { return 1 + h(2) }
fn arg_value() -> i32 = h(h(3))
fn generic_call() -> i32 = g(4)

class K {
    fn p(self) -> i32 = 5
    fn r(self) -> i32 = self.p()
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error [' --implicit-check-not='warning [' --implicit-check-not='I003E'
