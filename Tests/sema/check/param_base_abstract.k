// Whether an instance of a class deriving its type parameter is abstract is
// the instance's own question (classes-inheritance.mdx, Deriving a type
// parameter): the argument is the base, so what stays pure virtual is read
// off it, not off the parameter's bound. Over the abstract bound `Shape`,
// `Logged<Square>` is concrete because Square defines `area`, and
// `Fills<Open>` because the mixin does; `Logged<Open>` leaves `area` pure
// and cannot be built (SC249E, with a note at the method). Inside a generic
// function the argument is not known yet, so `Logged<X>()` is accepted
// there and decided per instance.

class Shape {
    pub fn Shape(self) { }
    pub virtual fn area(self) -> i32
}

class Square derives Shape {
    pub fn Square(self) { }
    pub override fn area(self) -> i32 { return 4 }
}

class Open derives Shape {
    pub fn Open(self) { }
}

class <A derives Shape> Logged derives A {
    pub fn twice(self) -> i32 { return self.area() * 2 }
}

class <A derives Shape> Fills derives A {
    pub override fn area(self) -> i32 { return 9 }
}

fn concrete() -> i32 {
    var l = Logged<Square>()
    var f = Fills<Open>()
    var s = Logged<Fills<Open>>()
    return l.twice() + f.area() + s.twice()
}

fn <X derives Shape> later() -> i32 {
    var l = Logged<X>()
    return l.twice()
}

fn abstract_argument() -> i32 {
    var l = Logged<Open>()
    return l.twice()
}

fn main() -> i32 {
    return concrete()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: {{.*}}param_base_abstract.k:46:13: error [SC249E]: cannot create an object of abstract class 'Logged'
// CHECK-NEXT: {{.*}}param_base_abstract.k:13:9: note [SC249N]: 'Shape::area' is pure virtual and 'Logged' does not override it
