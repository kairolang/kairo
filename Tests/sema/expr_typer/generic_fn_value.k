// A generic function's instance named as a value (`pick<i32>`) is the
// function pointer a plain function is (functions.mdx, Function Pointers):
// typed, so an operator or a cast on it is checked like one on `twice`.
// It was untyped, and an operator or cast over it reached finish() in no
// terminal state, an internal error. A generic function without
// its arguments, or an overload set, is not a value: SC094E.

pub fn <T> pick(v: T) -> T { return v }
fn twice(v: i32) -> i32 { return v * 2 }
fn ov(v: i32) -> i32 { return v }
fn ov(v: f64) -> f64 { return v }

fn main() -> i32 {
    var a = pick<i32> + 1
    var b = twice + 1
    var c = pick<i32> as unsafe fn(i32) -> i32
    var d = pick + 1
    var e = ov + 1
    var g = (pick) + 1
    var f = pick<i32>
    var h: fn(i32) -> i32 = pick<i32>
    return f(0) + h(0)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: generic_fn_value.k:14:13: error [SC066E]: no operator '+' for operands 'unsafe fn (i32) -> i32' and 'i32'
// CHECK: generic_fn_value.k:15:13: error [SC066E]: no operator '+' for operands 'unsafe fn (i32) -> i32' and 'i32'
// CHECK: generic_fn_value.k:16:13: warning [SC031W]: redundant cast: 'unsafe fn (i32) -> i32' converts to 'unsafe fn (i32) -> i32' implicitly
// CHECK: generic_fn_value.k:17:13: error [SC094E]: 'pick' is a generic function; it is a value only as one instance, with every generic argument written
// CHECK: generic_fn_value.k:18:13: error [SC094E]: 'ov' names an overloaded function, not a value; call it
// CHECK: generic_fn_value.k:19:14: error [SC094E]: 'pick' is a generic function; it is a value only as one instance, with every generic argument written
