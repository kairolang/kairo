// `Base::m(self)` reaches a method of a base class only. A name the base
// lacks is R025E, and passing a derived object to an unrelated class's
// method does not convert `self` (SC063E). The valid call on the same
// derived class (`A::plain(self)`) stays accepted.

class A {
    fn plain(const self) -> i32 { return 10 }
}

class B derives A {
    fn ok(self) -> i32 { return A::plain(self) }
    fn missing_in_base(self) -> i32 { return A::missing(self) }
}

class U {
    fn plain(const self) -> i32 { return 1 }
}

class C derives A {
    fn via_unrelated(self) -> i32 { return U::plain(self) }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: qualified_base_shapes_reject.k:12:49: error [R025E]: no member named 'missing' in 'A'
// CHECK: qualified_base_shapes_reject.k:20:44: error [SC063E]: no matching overload for call to 'plain'
// CHECK: note [I900N]: candidate not viable: cannot convert argument of type 'C' to parameter 'self' of type 'const U'
