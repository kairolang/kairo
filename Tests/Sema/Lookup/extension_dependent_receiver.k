// A generic extension's parameters are bound from the receiver in a
// generic body as they are from a concrete one: `View<U>` gives
// `extend <T> View<T>` T := U, so the member's types read through U. The
// body is checked once, so an extension whose target the receiver's shape
// does not meet (`View<*T>` against `View<U>`) is no candidate there.

struct <T> View {
    var p: *T
    var n: usize
}

extend <T> View<T> {
    fn first(const self) -> *const T { return self.p }
    fn pair(const self, const v: T) -> T { return v }
}

extend <T> View<*T> {
    fn pointee(const self) -> *T { return *self.p }
}

fn <U> elem(v: View<U>, const x: U) -> U {
    var f: *const U = v.first()
    var bad: *i32 = v.first()
    var q = v.pointee()
    return v.pair(x)
}

fn <U> inner(v: View<*U>) -> *U { return v.pointee() }

fn <U> const_elem(v: View<const U>) -> *const U { return v.first() }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: extension_dependent_receiver.k:23:{{[0-9]+}}: error [{{[A-Z]+[0-9]+E}}]: {{.*}}'*const U'
// CHECK: extension_dependent_receiver.k:24:{{[0-9]+}}: error [SC063E]: no matching overload for call to 'pointee'
// CHECK-NEXT: note [I900N]: candidate not viable: the receiver is not an instance this extension applies to
