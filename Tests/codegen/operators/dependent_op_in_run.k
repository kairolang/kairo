// `x in y` in a generic body whose `y` is a record of dependent type (`self`
// in `class <T> Bag`, a `Bag<T>` parameter) is a call of y's `op in`, as it
// is on a concrete record: C++ has no `in` operator to leave it to. The
// membership form and `for x in y` over a user `op in -> yield` both run.

import std::io::println

class <T> Bag {
    pub var a: T
    pub var b: T

    pub fn Bag(self, a: T, b: T) {
        self.a = a
        self.b = b
    }

    // T is opaque here: the operator answers without reading v.
    pub fn op in (const self, const v: T) -> bool { return true }

    pub fn op in (const self) -> yield T {
        yield self.a
        yield self.b
    }

    pub fn has_self(const self, const v: T) -> bool { return v in self }

    pub fn count(const self) -> i32 {
        var k = 0
        for x in self {
            k += 1
        }

        return k
    }
}

class Eqs {
    pub var n: i32

    pub fn Eqs(self, n: i32) { self.n = n }

    pub fn op in (const self, const v: i32) -> bool { return v == self.n }
}

class <T> Probe {
    pub fn Probe(self) { }

    // The container is a parameter of dependent type.
    pub fn look(const self, const bag: Bag<T>, const v: T) -> bool { return v in bag }
}

fn main() -> i32 {
    var g = Bag<i32>(3, 5)
    var p = Probe<i32>()
    var e = Eqs(4)
    println(f"{g.has_self(3)} {p.look(g, 5)} {g.count()} {4 in e}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: true true 2 true
