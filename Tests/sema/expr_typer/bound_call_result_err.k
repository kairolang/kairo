// RUN: { %kairo %s --type-check-only --diag-show-ids 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// A bound call's result is checked where it lands, at the bound's arguments
// (bound_call_result.k has the accepted forms). These were all accepted
// before: the requirement's interface parameter was never bound, so the
// result was unknown and nothing compared it with anything.

pub struct Q { pub var q: i32 }
pub struct <W> Wrap { pub var w: W }

pub interface <T> Fancy {
    fn shine(const self) -> T
    fn wrap(const self) -> Wrap<T>
    fn take(const self, v: T) -> i32
    fn <U> map(const self, u: U) -> U
}

pub fn <C impl Fancy<i32>> mismatch(c: C) -> i32 {
    var z: Q = c.shine()
// DIAG: bound_call_result_err.k:[[@LINE-1]]:16: error [SC028E]: cannot convert 'i32' to 'Q'
    var y: bool = c.wrap().w
// DIAG: bound_call_result_err.k:[[@LINE-1]]:19: error [SC028E]: cannot convert 'i32' to 'bool'
    var k: Q = c.map(1)
// DIAG: bound_call_result_err.k:[[@LINE-1]]:16: error [SC028E]: cannot convert 'i32' to 'Q'
    return c.wrap().nope
// DIAG: bound_call_result_err.k:[[@LINE-1]]:21: error [R025E]: no member named 'nope' in 'Wrap'
}

// A parameter the bound decides takes what the bound says: `v: T` is an i32.
pub fn <C impl Fancy<i32>> argument(c: C) -> i32 {
    return c.take(Q { q: 1 })
// DIAG: bound_call_result_err.k:[[@LINE-1]]:12: error [SC063E]: no matching overload for call to 'take'
// DIAG: note [I900N]: candidate not viable: cannot convert argument of type 'Q' to parameter 'v' of type 'i32'
}

// Over the body's own parameter: E is not Q.
pub fn <E, C impl Fancy<E>> dependent(c: C) -> i32 {
    var q: Q = c.shine()
// DIAG: bound_call_result_err.k:[[@LINE-1]]:16: error [SC028E]: cannot convert 'E' to 'Q'
    return 0
}

fn main() -> i32 { return 0 }
