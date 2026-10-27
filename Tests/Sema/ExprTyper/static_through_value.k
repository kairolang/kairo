// A static requirement (an interface `fn` with no `self`) or a static
// extension member called through a VALUE is SC001E, with a note at the
// declaration and the fix-it that calls it through the receiver's type as
// the body spells it (`y.make(2)` -> `T::make(2)`). Before the check these
// passed X and ICEd in ExtensionLowering ("a static requirement called
// through a value; X should have rejected it"), even under
// --type-check-only.
// Not rejected: the `::` form, an instance requirement through a value,
// and a plain class's static through a value (C++'s rule: the value is
// discarded).

interface I {
    fn make(x: i32) -> i32
    fn get(self) -> i32
}

class C { var y: i32 }
extend C impl I {
    fn make(x: i32) -> i32 { return x }
    fn get(self) -> i32 { return self.y }
}

extend C {
    static fn twice(x: i32) -> i32 { return x * 2 }
}

class P {
    static fn one() -> i32 { return 1 }
}

fn <T impl I> bad(y: T, p: *T) -> i32 {
    return y.make(2) + p->make(3)
}

fn bad_ext(c: C) -> i32 {
    return c.make(4) + c.twice(5)
}

fn <T impl I> good(y: T) -> i32 {
    return T::make(1) + y.get()
}

fn good_plain(c: C, q: P) -> i32 {
    return C::twice(1) + C::make(2) + q.one() + c.get()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: {{warning|error}}
// CHECK: static_through_value.k:32:14: error [SC001E]: 'make' is a static requirement; it takes no 'self' and is called through the type, not a value
// CHECK-NEXT: fix-it:{{.*}}:{32:12-32:14}:"T::"
// CHECK-NEXT: static_through_value.k:13:5: note [SC001N]: 'make' is declared here, without 'self'
// CHECK-NOT: {{warning|error}}
// CHECK: static_through_value.k:32:27: error [SC001E]: 'make' is a static requirement; it takes no 'self' and is called through the type, not a value
// CHECK-NEXT: fix-it:{{.*}}:{32:24-32:27}:"T::"
// CHECK-NEXT: static_through_value.k:13:5: note [SC001N]: 'make' is declared here, without 'self'
// CHECK-NOT: {{warning|error}}
// CHECK: static_through_value.k:36:14: error [SC001E]: 'make' is a static extension member; it takes no 'self' and is called through the type, not a value
// CHECK-NEXT: fix-it:{{.*}}:{36:12-36:14}:"C::"
// CHECK-NEXT: static_through_value.k:19:5: note [SC001N]: 'make' is declared here, without 'self'
// CHECK-NOT: {{warning|error}}
// CHECK: static_through_value.k:36:26: error [SC001E]: 'twice' is a static extension member; it takes no 'self' and is called through the type, not a value
// CHECK-NEXT: fix-it:{{.*}}:{36:24-36:26}:"C::"
// CHECK-NEXT: static_through_value.k:24:5: note [SC001N]: 'twice' is declared here, without 'self'
// CHECK-NOT: {{warning|error}}
