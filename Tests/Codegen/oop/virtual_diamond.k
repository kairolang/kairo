// `derives virtual` (classes-inheritance.md, Diamond and virtual
// inheritance): B and C share ONE A subobject inside D. A's constructor
// runs once, before B's and C's, which both see and update the same
// field; reached through B or C the field has one address; and a virtual
// C overrides is dispatched to C's body from an `*A` to the D.
//
// The spec's version passes arguments through `A::A(self, v)`; base
// constructor calls do not resolve yet (base_ctor_call.k), so A here
// default-constructs. Addresses are compared as `unsafe *void` because
// `ptr as usize` does not compile yet (ptr_to_usize.k).

class A {
    pub var value: i32
    fn A(self) { self.value = 5 }
    virtual fn who(self) -> i32 { return 1 }
}

class B derives virtual A {
    fn B(self) { self.value = self.value + 100 }
}

class C derives virtual A {
    fn C(self) { self.value = self.value + 200 }
    override fn who(self) -> i32 { return 3 }
}

class D derives B, C { }

fn main() -> i32 {
    var r = 0
    var d = D()
    var a: *A = &d
    var b: *B = &d
    var c: *C = &d
    if a->value == 305 { r += 1 }               // one A: 5, then +100, then +200
    unsafe {
        if ((&b->value) as unsafe *void) == ((&c->value) as unsafe *void) { r += 2 }
    }
    if a->who() == 3 { r += 4 }
    if b->who() == 3 { r += 8 }                 // through the side that did not override
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
