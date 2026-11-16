// A class that derives its type parameter may declare its own constructor
// and destructor and narrow the base (classes-inheritance.mdx, Deriving a
// type parameter). `Built<Arg>(4)` builds the argument by its default
// constructor before the mixin's own constructor runs, so the body reads
// what Arg's constructor set; the destructors run mixin, argument, bound.
// `Shut` derives its parameter `priv`: its own file reads the base through
// it, and the conversion to the argument and the bound stays.

import std::io

var log: i32 = 0      // one digit per destructor, oldest first

class Base {
    pub var n: i32 = 3
    pub fn Base(self) { }
    pub fn f(self) -> i32 { return 10 }
    pub virtual fn id(self) -> i32 { return 1 }
    pub virtual fn op finally(self) { log = log * 10 + 1 }
}

class Arg derives Base {
    pub fn Arg(self) { self.n = 5 }
    pub fn extra(self) -> i32 { return 20 }
    pub override fn op finally(self) { log = log * 10 + 2 }
}

class <A derives Base> Built derives A {
    pub var k: i32
    pub var t: i32 = 0
    pub fn Built(self, k: i32) {
        self.k = k
        self.t = self.n + k
    }
    pub override fn op finally(self) { log = log * 10 + 3 }
}

class <A derives Base> Shut derives priv A {
    pub fn inside(self) -> i32 { return self.n + self.f() }
}

fn main() -> i32 {
    {
        var b = Built<Arg>(4)
        io::println(f"built {b.k} {b.t} {b.n} {b.id()} {b.extra()}")
    }

    io::println(f"destroyed {log}")
    var s = Shut<Arg>()
    var a: *Arg = &s
    var p: *Base = &s
    io::println(f"narrowed {s.inside()} {s.n} {a->extra()} {p->f()}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2> %t.err
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      built 4 9 5 1 20
// CHECK-NEXT: destroyed 321
// CHECK-NEXT: narrowed 15 5 20 10
// The hidden layout virtual says `override` through the parameter base.
// RUN: %FileCheck %s --check-prefix=QUIET --allow-empty < %t.err
// QUIET-NOT: C505W
