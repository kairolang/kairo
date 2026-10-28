// The asserting downcast `p as *D` (PANIC.md §5, casting.md "Downcasting"):
// a dynamic_cast checked on the spot. A hit is the right pointer --
// adjusted when D's base is not the first -- a class below D is a D, and a
// null pointer stays null. A miss CRASHES: the crash family, not a panic,
// so `bones` needs no `panic` specifier and no `try` can catch it. The
// message is built at compile time (the cast as written, the target and
// static types, the site) and written by rt/crash.c, which then aborts:
// SIGABRT, status 134, nothing after it runs. Every asserting downcast
// warns (SC001W placeholder) with a fix-it appending the `?` that makes it
// the checked form.

import std::io::println

class Animal { virtual fn kind(self) -> i32 { return 0 } }
class Dog derives Animal {
    pub var bones: i32
    fn Dog(self) { self.bones = 7 }
}
class Cat derives Animal { }
class Puppy derives Dog { }

class Tail { virtual fn wag(self) -> i32 { return 1 } }
class Corgi derives Dog, Tail { }

fn bones(a: *Animal) -> i32 {
    var *d = a as *Dog
    return d->bones
}

fn from_tail(t: *Tail) -> i32 {
    var *c = t as *Corgi
    return c->bones
}

fn read_only(a: *const Animal) -> i32 {
    var *d = a as *const Dog
    return d->bones
}

fn main() -> i32 {
    var r = 0
    var dog = Dog()
    var pup = Puppy()
    var cor = Corgi()
    var cat = Cat()
    if bones(&dog) == 7 { r += 1 }
    if bones(&pup) == 7 { r += 2 }          // a class below Dog is a Dog
    if from_tail(&cor) == 7 { r += 4 }      // from the SECOND base: pointer adjusts
    if read_only(&dog) == 7 { r += 8 }
    if r == 15 { println("hits ok") }
    bones(&cat)
    println("after")
    return r
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: asserting_downcast.k:26:14: warning [SC001W]: 'a as *Dog' crashes the program when the object is not a 'Dog'; use 'a as *Dog?' and test the result for cleaner handling
// DIAG: fix-it:"{{.*}}asserting_downcast.k":{26:23-26:23}:"?"
// DIAG: asserting_downcast.k:15:1: note [I900N]: 'Dog' is declared here
// DIAG: asserting_downcast.k:31:14: warning [SC001W]: 't as *Corgi' crashes the program when the object is not a 'Corgi'
// DIAG: asserting_downcast.k:36:14: warning [SC001W]: 'a as *const Dog' crashes the program when the object is not a 'Dog'
// DIAG-NOT: error [
//
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:     dynamic_cast< ::asserting_downcast::Dog *>(
// CXX:     ::builtin::errors::crash::unwrap_failed(
// CXX-NOT: static_cast< ::asserting_downcast::Dog *>(
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %FileCheck %s --check-prefix=ERR --match-full-lines < %t.err
// OUT:      hits ok
// OUT-NOT:  after
// ERR:      a as *Dog: the object is not a 'Dog' (static type '*Animal') at {{.*}}asserting_downcast.k:26:14
