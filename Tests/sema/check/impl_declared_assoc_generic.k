// A declared `impl` checked at the declaration: an associated type the
// conformer does not declare (and the interface gives no default for) is an
// error at the clause, as at a use. A generic conformer is checked at its
// declaration only for what no argument can change: a method requirement
// with no member of its name, an associated type it never declares. A
// member whose signature reads the type parameter is checked per instance,
// where a bound meets it, so `Loose` is accepted here and refused at the
// call that needs it.

interface Container {
    type Item
    fn get(const self) -> Self::Item
}

interface Shape {
    fn area(const self) -> i32
}

class Bag impl Container {
    pub fn get(const self) -> i32 { return 0 }
}

class <T> Box impl Shape {
    pub var v: T
}

class <T> Crate impl Container {
    pub var v: T
    pub fn get(const self) -> T { return self.v }
}

class <T> Loose impl Shape {
    pub var v: T
    pub fn area(const self) -> T { return self.v }
}

fn <S impl Shape> measure(s: S) -> i32 {
    return s.area()
}

fn main() -> i32 {
    var l = Loose<i64>{v: 2}
    return measure(l)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: impl_declared_assoc_generic.k:19:16: error [SC161E]: 'Bag' does not conform to 'Container': it declares no associated type 'Item'
// CHECK-NEXT: impl_declared_assoc_generic.k:11:5: note [I900N]: 'Item' is required here
// CHECK: impl_declared_assoc_generic.k:23:20: error [SC162E]: 'Box<T>' declares 'impl Shape' but does not conform to it: it has no 'area' with the requirement's signature
// CHECK-NEXT: fix-it:"{{.*}}impl_declared_assoc_generic.k":{25:1-25:1}:"    pub fn area(const self) -> i32 { }\n"
// CHECK-NEXT: impl_declared_assoc_generic.k:16:5: note [I900N]: 'area' is required here
// CHECK: impl_declared_assoc_generic.k:27:22: error [SC161E]: 'Crate<T>' declares 'impl Container' but does not conform to it: it has no 'Item'
// CHECK-NEXT: impl_declared_assoc_generic.k:11:5: note [I900N]: 'Item' is required here
// CHECK: impl_declared_assoc_generic.k:43:12: error [SC162E]: 'Loose<i64>' does not conform to 'Shape'
