// A member type of a base class is not in scope by its bare name inside the
// derived class: R021E says which base holds it and offers `B::Inner`.

class B {
    class Inner { var v: i32 = 1 }
}

class D derives B {
    fn f(self) -> i32 {
        var x: Inner = B::Inner()
        return x.v
    }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: base_member_type_bare_name.k:10:16: error [R021E]: 'Inner' is not a member of 'D'; 'B::Inner' is
// CHECK-NEXT: fix-it:"{{.*}}":{10:16-10:21}:"B::Inner"
