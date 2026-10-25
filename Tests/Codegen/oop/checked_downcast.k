// The checked downcast (casting.md, Downcasting): C++'s dynamic_cast on a
// pointer. Null when the dynamic type is not the target or a class below
// it; the right pointer -- adjusted, from a second base -- when it is.
//
// Spelled `as (*Dog)?` (`*Dog?` means the same since NULLABLE.md G1). The
// result is read with `??` because `if d?` does not type-check yet
// (null_check.k).
//
// XFAIL: *
// Waiting on the checked downcast's lowering (NULLABLE.md G18) and `??`
// (G8). `(*Dog)?` itself lowers since G3, but the cast is emitted as a
// static_cast from `Animal*` to `Nullable<Dog*>`, which clang rejects;
// nothing emits dynamic_cast yet. Sema already types the cast as
// `(*Dog)?` (Tests/Sema/ExprTyper/casts.k).
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

class Animal { virtual fn kind(self) -> i32 { return 0 } }
class Dog derives Animal {
    pub var bones: i32
    fn Dog(self) { self.bones = 7 }
}
class Cat derives Animal { }
class Puppy derives Dog { }

class Tail { virtual fn wag(self) -> i32 { return 1 } }
class Corgi derives Dog, Tail { }
class Fox derives Tail { }

fn bones(a: *Animal, none: *Dog) -> i32 {
    var d = a as (*Dog)?
    return (d ?? none)->bones
}

fn main() -> i32 {
    var r = 0
    var none = Dog()
    none.bones = 0
    var dog = Dog()
    var cat = Cat()
    var pup = Puppy()
    if bones(&dog, &none) == 7 { r += 1 }
    if bones(&cat, &none) == 0 { r += 2 }
    if bones(&pup, &none) == 7 { r += 4 }       // a class below Dog is a Dog
    var cor = Corgi()
    var fallback = Corgi()
    fallback.bones = 0
    var t: *Tail = &cor
    var hit = t as (*Corgi)?                    // from the SECOND base: pointer adjusts
    if (hit ?? &fallback)->bones == 7 { r += 8 }
    var fox = Fox()
    var ft: *Tail = &fox
    var miss = ft as (*Corgi)?                  // a Tail that is not a Corgi
    if (miss ?? &fallback)->bones == 0 { r += 16 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 31
