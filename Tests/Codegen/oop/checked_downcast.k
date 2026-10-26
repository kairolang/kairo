// G18 (Compiler/Sema/NULLABLE.md; casting.md, Downcasting): the checked
// downcast `p as (*D)?` is C++'s dynamic_cast on a pointer, its null
// pointer the NULL nullable (storage is tagged: a `Nullable<D*>` holding
// nullptr would be present). Null when the dynamic type is not D or a
// class below it; the right pointer -- adjusted, from a second base --
// when it is. Spelled `as (*Dog)?` (`*Dog?` means the same since G1).
// Covered: a hit, a miss, a class below the target, a second base, a
// `*const` source, `if d?` narrowing the result, and the cast in generic
// bodies (target pointee `T`, source pointee `T`), where C++ checks it per
// instance.

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
    var *d? = a as (*Dog)?
    return (d ?? none)->bones
}

fn checked(a: *Animal) -> i32 {
    var *d? = a as *Dog?
    if d? { return d->bones }
    return -1
}

fn read_only(a: *const Animal) -> i32 {
    var *d? = a as (*const Dog)?
    if d? { return d->bones }
    return -1
}

fn <T> pick(a: *Animal, like: *T) -> (*T)? { return a as (*T)? }
fn <T> as_dog(a: *T) -> (*Dog)? { return a as (*Dog)? }

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
    var *hit? = t as (*Corgi)?                  // from the SECOND base: pointer adjusts
    if (hit ?? &fallback)->bones == 7 { r += 8 }
    var fox = Fox()
    var ft: *Tail = &fox
    var *miss? = ft as (*Corgi)?                // a Tail that is not a Corgi
    if (miss ?? &fallback)->bones == 0 { r += 16 }
    if (checked(&dog) == 7) && (checked(&cat) == -1) { r += 32 }
    if (read_only(&dog) == 7) && (read_only(&cat) == -1) { r += 64 }
    var ad: *Animal = &dog
    var ac: *Animal = &cat
    var *g1? = pick(ad, &none)
    var *g2? = pick(ac, &none)
    var *g3? = as_dog(ad)
    var *g4? = as_dog(ac)
    if g1? && (!g2?) && g3? && (!g4?) { r += 128 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      Nullable< ::checked_downcast::Dog *> d =[]( ::checked_downcast::Dog * __kairo_dc)-> ::builtin::Nullable< ::checked_downcast::Dog *> {
// CXX-NEXT:     return __kairo_dc ? ::builtin::Nullable< ::checked_downcast::Dog *>(__kairo_dc): ::builtin::Nullable< ::checked_downcast::Dog *>();
// CXX-NEXT: }
// CXX-NEXT: (dynamic_cast< ::checked_downcast::Dog *>(a));
// CXX:      (dynamic_cast<const::checked_downcast::Dog *>(a));
// CXX:      (dynamic_cast<T *>(a));

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 255
