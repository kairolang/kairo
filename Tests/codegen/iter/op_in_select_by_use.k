// Which `op in` a loop calls is decided by what the loop does, as a split
// subscript's form is. Only a mutable pointer binder (`*x`, `unsafe *x`,
// alone or in a binder list) takes `op in (self)`; every other loop takes
// `op in (const self)` when the type declares one, over a mutable object
// too. A type with no const form iterates through `op in (self)`. Each
// form yields a different value, so the exit code shows which one ran.

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

class Pair {
    var m: i32 = 3
    var c: i32 = 30

    fn op in (self) -> yield (*i32, i32) {
        yield (&self.m, 1)
    }

    fn op in (const self) -> yield (*const i32, i32) {
        yield (&self.c, 2)
    }
}

class Raw {
    var m: i32 = 5
    var c: i32 = 50

    fn op in (self) -> yield unsafe *i32 {
        unsafe {
            yield &self.m as unsafe *i32
        }
    }

    fn op in (const self) -> yield unsafe *i32 {
        unsafe {
            yield &self.c as unsafe *const i32 as unsafe *i32
        }
    }
}

class Only {
    var a: i32 = 7

    fn op in (self) -> yield i32 {
        yield self.a
    }
}

fn main() -> i32 {
    var s = 0
    var b = Bag()
    for x in b { // const: 10
        s += x
    }

    for const x in b { // const: 10
        s += x
    }

    var c = Cell()
    for x in c { // const: 1000
        s += x
    }

    for const *x in c { // const: 1000
        s += *x
    }

    for *x in c { // self: writes m
        *x += 1
    }

    var p = Pair()
    for (a, n) in p { // const: 30 + 2
        s += a + n
    }

    for (const *a, n) in p { // const: 30 + 2
        s += *a + n
    }

    for (*a, n) in p { // self: writes m, n = 1
        *a += n
    }

    var r = Raw()
    for unsafe *x in r { // self: writes m
        unsafe {
            *x += 1
        }
    }

    var o = Only()
    for x in o { // self, the only form: 7
        s += x
    }

    // 10 + 10 + 1000 + 1000 + 32 + 32 + 7 = 2091
    return (s - 2091) + (c.m - 100) * 10 + (p.m - 3) * 20 + (r.m - 5) * 40
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty --implicit-check-not=error
// BUILD-NOT: C307W
// RUN: %t.exe; test $? -eq 70
