// A member inherited from a generic base takes the parameters of the base
// instance the receiver reaches: on `Const<i32>`, `put` is `put(x: i32)`
// (the base is `Source<i32>`), so `put(NullT { })` is SC063E, not a
// deduction T := NullT that fails in C++. `put(1)` is clean.

struct NullT { }

class <T> Source {
    pub var last: T
    fn put(self, x: T) { self.last = x }
}

class <T> Const derives Source<T> { }

fn main() -> i32 {
    var c = Const<i32>()
    c.put(1)
    c.put(NullT { })
    return c.last - 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: inherited_member_params.k:18:{{[0-9]+}}: error [SC063E]: no matching overload for call to 'put'
// CHECK: inherited_member_params.k:10:{{[0-9]+}}: note [I900N]: candidate not viable: cannot convert argument of type 'NullT' to parameter 'x' of type 'i32'
