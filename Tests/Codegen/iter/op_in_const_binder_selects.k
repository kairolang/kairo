// A loop with no mutable pointer binder takes `op in (const self)` on a
// mutable object, for a value yield and a pointer yield alike; a `*x`
// binder takes `op in (self)`. Each form yields a different value, so the exit code
// shows which one ran.

class Bag {
    var a: i32 = 1

    fn op in (self) -> yield i32 {
        yield 1
    }

    fn op in (const self) -> yield i32 {
        yield 10
    }
}

class Cell {
    var m: i32 = 100
    var c: i32 = 1000

    fn op in (self) -> yield *i32 {
        yield &self.m
    }

    fn op in (const self) -> yield *const i32 {
        yield &self.c
    }
}

fn main() -> i32 {
    var b = Bag()
    var s = 0
    for x in b { // 10
        s += x
    }

    for const x in b { // 10
        s += x
    }

    var c = Cell()
    for const x in c { // 1000
        s += x
    }

    for const *x in c { // 1000
        s += *x
    }

    for x in c { // 1000
        s += x
    }

    for *x in c {
        *x = 7
    }

    return (s - 3009) + c.m // 11 + 7
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty --implicit-check-not=error
// BUILD-NOT: C307W
// RUN: %t.exe; test $? -eq 18
