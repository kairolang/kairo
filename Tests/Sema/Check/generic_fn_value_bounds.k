// A bounded generic function's instance read as a value (`pick<i32>`)
// is an instantiation site like a call: its `impl` bounds are checked there
// (SC162E at the use, the bound and the requirement as notes). It was typed
// by substitution only, so an argument that does not conform reached clang
// as "address of overloaded function 'pick' cannot be static_cast".

interface Big { fn big(const self) -> i32 }

class W impl Big {
    pub var n: i32
    fn W(self, n: i32) { self.n = n }
    fn big(const self) -> i32 = self.n
}

fn <T impl Big> pick(x: T) -> i32 { return x.big() }

// Inside a generic body the instance is the enclosing one's to check.
fn <U impl Big> forward(u: U) -> i32 {
    var f = pick<U>
    return f(u)
}

fn main() -> i32 {
    var ok = pick<W>
    var bad = pick<i32>
    var bad_f = pick<f64>
    return ok(W(1)) + forward(W(3))
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      generic_fn_value_bounds.k:25:15: error [SC162E]: 'i32' does not conform to 'Big': no member 'big' with the requirement's signature
// CHECK-NEXT: generic_fn_value_bounds.k:15:5: note [I900N]: required by this bound
// CHECK-NEXT: generic_fn_value_bounds.k:7:17: note [I900N]: 'big' is required here
// CHECK-NEXT: generic_fn_value_bounds.k:26:17: error [SC162E]: 'f64' does not conform to 'Big'
// CHECK-NOT:  error
