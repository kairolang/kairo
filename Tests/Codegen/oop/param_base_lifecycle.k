// The lifecycle of a class that derives its type parameter is each
// instance's own (classes-lifecycle.mdx, classes-inheritance.mdx): the
// argument is its base, so `Hooked<Counts>` runs Counts's destructor once
// per object, after its own field's, and copies through Counts's copy
// constructor.

import std::io

var log: i32 = 0      // one digit per event, oldest first

class Base {
    pub fn Base(self) { }
    pub virtual fn id(self) -> i32 { return 1 }
    pub virtual fn op finally(self) { log = log * 10 + 1 }
}

class Counts derives Base {
    pub var copies: i32 = 0
    pub fn Counts(self) { }
    @copy
    pub fn Counts(self, const other: Self) { self.copies = other.copies + 1 }
    pub override fn op finally(self) { log = log * 10 + 2 }
}

class Field {
    pub fn Field(self) { }
    @copy
    pub fn Field(self, const other: Self) { }
    pub fn op finally(self) { log = log * 10 + 3 }
}

class <A derives Base> Hooked derives A {
    pub var f: Field
    pub override fn id(self) -> i32 { return A::id(self) + 10 }
}

fn main() -> i32 {
    {
        var h = Hooked<Counts>()
        var c = h
        io::println(f"copy {c.copies} {c.id()}")
    }

    io::println(f"scope {log}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      copy 1 11
// CHECK-NEXT: scope 321321
