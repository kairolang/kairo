// A member that needs a mutable element is not a member of the const
// element form: the type declares it in the primary and leaves it out of
// the `View<const T>` specialization, so calling it on a `View<const X>` is
// R025E, with the two declarations that explain it. The read members an
// extension adds are on both forms, and a name neither form has keeps the
// plain error.

class <T> View {
    pub var n: usize
    pub fn View(self, n: usize) { self.n = n }
    pub fn swap(self, i: usize, j: usize) { }
    pub fn fill(self, const v: T) { }
}

class <T> View<const T> {
    pub var n: usize
    pub fn View(self, n: usize) { self.n = n }
}

extend <T> View<T> {
    pub fn size(const self) -> usize { return self.n }
}

fn <U> generic(c: View<const U>, m: View<U>) -> usize {
    c.swap(0, 1)
    m.swap(0, 1)
    return c.size() + m.size()
}

fn main() -> i32 {
    var a = View<i32>(1)
    var c = View<const i32>(1)
    a.swap(0, 0)
    a.fill(2)
    c.swap(0, 0)
    c.fill(2)
    c.missing()
    a.missing()
    return (a.size() + c.size() + generic(c, a)) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="note ["
// CHECK: const_element_mutator.k:25:7: error [R025E]: no member named 'swap' in 'View'
// CHECK-NEXT: const_element_mutator.k:11:9: note [I900N]: 'swap' is a member of the primary declaration, which 'View<const U>' is not an instance of
// CHECK-NEXT: const_element_mutator.k:15:1: note [I900N]: 'View<const U>' is an instance of this specialization, which does not declare 'swap'
// CHECK: const_element_mutator.k:35:7: error [R025E]: no member named 'swap' in 'View'
// CHECK-NEXT: const_element_mutator.k:11:9: note [I900N]: 'swap' is a member of the primary declaration, which 'View<const i32>' is not an instance of
// CHECK-NEXT: const_element_mutator.k:15:1: note [I900N]: 'View<const i32>' is an instance of this specialization, which does not declare 'swap'
// CHECK: const_element_mutator.k:36:7: error [R025E]: no member named 'fill' in 'View'
// CHECK-NEXT: const_element_mutator.k:12:9: note [I900N]: 'fill' is a member of the primary declaration, which 'View<const i32>' is not an instance of
// CHECK-NEXT: const_element_mutator.k:15:1: note [I900N]: 'View<const i32>' is an instance of this specialization, which does not declare 'fill'
// CHECK: const_element_mutator.k:37:7: error [R025E]: no member named 'missing' in 'View'
// CHECK: const_element_mutator.k:38:7: error [R025E]: no member named 'missing' in 'View'
