// The asserting downcast, `p as *Derived` (casting.md, Downcasting): checks
// the dynamic type like the checked form, and panics instead of yielding
// null. Allowed only in a `panic` function or inside `try`.
//
// XFAIL: *
// Waiting on two things. (1) The cast has no runtime check: it lowers to a
// plain static_cast (no __dynamic_cast in the IR), so a Cat passed here is
// silently read as a Dog. (2) PanicLowering is a stub, so EmitIR ICEs on
// the `panic` function and the `try` ("PanicLowering owns it"). Also not
// diagnosed yet: the same cast OUTSIDE a panic function or `try`.
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

class Animal { virtual fn kind(self) -> i32 { return 0 } }
class Dog derives Animal {
    pub var bones: i32
    fn Dog(self) { self.bones = 7 }
}
class Cat derives Animal { }

fn bones(a: *Animal) panic -> i32 {
    var d = a as *Dog
    return d->bones
}

fn main() -> i32 {
    var r = 0
    var dog = Dog()
    var cat = Cat()
    try { if bones(&dog) == 7 { r += 1 } } catch { }
    try { bones(&cat) } catch { r += 2 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3
