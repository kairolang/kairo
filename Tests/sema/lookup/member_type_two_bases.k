// A member type declared in two bases is ambiguous in the derived class, as
// in C++: `D::Inner` and `Self::Inner` inside D are errors naming both
// bases, as a type and in an expression. A member type or an alias declared
// in the derived class itself answers first, and a base qualifier picks one.

class B {
    pub class Inner {
        pub var x: i32 = 1
    }
}

class C {
    pub class Inner {
        pub var y: i32 = 2
    }
}

class D derives B, C {
    fn D(self) { }

    fn make(self) -> i32 {
        var i: Self::Inner = Self::Inner()
        return 0
    }
}

class E derives B, C {
    pub type Inner = C::Inner
}

class F derives B, C {
    pub class Inner {
        pub var z: i32 = 3
    }
}

fn main() -> i32 {
    var a: D::Inner = D::Inner()
    var e: E::Inner = E::Inner()
    var f: F::Inner = F::Inner()
    var b: B::Inner = B::Inner()
    return e.y + f.z + b.x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: member_type_two_bases.k:22:22: error [R028E]: 'Inner' is ambiguous in 'D': its bases 'B' and 'C' both declare a member 'Inner'
// CHECK-NEXT: member_type_two_bases.k:7:9: note [R028N]: declared in 'B' here
// CHECK-NEXT: member_type_two_bases.k:13:9: note [R028N]: declared in 'C' here
// CHECK-NEXT: note [I900N]: name it as 'B::Inner' or 'C::Inner', or declare 'Inner' in 'D'
// CHECK: member_type_two_bases.k:22:36: error [R028E]: 'Inner' is ambiguous
// CHECK: note [R028N]: candidate declared here, in 'B'
// CHECK: note [R028N]: candidate declared here, in 'C'
// CHECK: member_type_two_bases.k:38:15: error [R028E]: 'Inner' is ambiguous in 'D': its bases 'B' and 'C' both declare a member 'Inner'
// CHECK: member_type_two_bases.k:38:26: error [R028E]: 'Inner' is ambiguous
// CHECK-NOT: error
