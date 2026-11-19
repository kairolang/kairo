// `@destroy` of a `*Base` skips the derived destructor when Base has no
// virtual destructor and a class with a destructor derives from it, even
// when Base has no virtual method at all. A virtual destructor, or a pointer
// of the most derived type, is accepted.

class Plain {
    var a: i32
}

class Owner derives Plain {
    @copy fn Owner(self, const other: Self) = delete
    var b: i32

    fn op finally(self) { }
}

class Virt {
    @copy fn Virt(self, const other: Self) = delete
    var a: i32

    virtual fn op finally(self) { }
}

class VOwner derives Virt {
    @copy fn VOwner(self, const other: Self) = delete
    var b: i32

    override fn op finally(self) { }
}

class Leaf {
    @copy fn Leaf(self, const other: Self) = delete
    var a: i32

    fn op finally(self) { }
}

fn bad(p: *Plain) {
    @destroy p
}

fn bad_generic_form(p: *Plain) {
    @destroy<Plain>(p)
}

fn ok_virtual(p: *Virt) {
    @destroy p
}

fn ok_most_derived(p: *Owner) {
    @destroy p
}

fn ok_leaf(p: *Leaf) {
    @destroy p
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s
// CHECK: destroy_through_plain_base.k:39:{{[0-9]+}}: error [SC056E]: 'Plain' has no virtual destructor and a class with a destructor derives from it
// CHECK: destroy_through_plain_base.k:43:{{[0-9]+}}: error [SC056E]: 'Plain' has no virtual destructor
// CHECK-NOT: error [SC056E]
