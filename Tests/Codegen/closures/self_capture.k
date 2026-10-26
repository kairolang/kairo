// `self` in a closure: the enclosing method's receiver, which is a pointer
// already, so every capture form takes the pointer (`this` in a method,
// the receiver parameter in an extension member) and writes through it
// reach the object. `|*|` leaves `self` as it is (a pointer to the object,
// not a pointer to the pointer). A named list cannot spell `self` and
// still captures it. A generic class's method too.

import std::io::println

class Counter {
    pub var n: i32 = 0
    fn add_twice(self, k: i32) -> i32 {
        var f = fn (d: i32) -> i32 { self.n += d; return self.n }
        f(k)
        return f(k)
    }
    fn add_all(self, k: i32) -> i32 {
        var g = fn ()|*| { self.n += *k }
        g()
        return self.n
    }
    fn add_named(self, k: i32) -> i32 {
        var h = fn ()|k| { self.n += k }
        h()
        return self.n
    }
}

struct P { pub var x: i32 = 0 }
extend P {
    fn scaled(self, k: i32) -> i32 {
        var f = fn () -> i32 { return self.x * k }
        return f()
    }
}

class <T> Box {
    pub var v: T
    fn Box(self, v: T) { self.v = v }
    fn apply(self, f: fn(T) -> T) -> T {
        var g = fn () -> T { return f(self.v) }
        return g()
    }
}

fn main() -> i32 {
    var c = Counter()
    println(f"method: {c.add_twice(3)} {c.n}")
    println(f"all: {c.add_all(4)}")
    println(f"named: {c.add_named(5)}")
    var p = P { x: 3 }
    println(f"extension: {p.scaled(4)}")
    var b = Box<i32>(20)
    println(f"generic: {b.apply(fn (v: i32) -> i32 = v + 1)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      method: 6 6
// OUT-NEXT: all: 10
// OUT-NEXT: named: 15
// OUT-NEXT: extension: 12
// OUT-NEXT: generic: 21

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: own(new auto([this](signed int d) mutable->signed int {
// CXX: own(new auto([this, k = & k]() mutable->void {
// CXX: own(new auto([self, k]() mutable->signed int {
