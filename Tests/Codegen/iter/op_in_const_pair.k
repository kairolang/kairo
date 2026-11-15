// A type may declare both iteration forms. The loop picks one by the
// iterable's own constness: a mutable object takes `op in (self)`, a
// const one (a const binding, a const parameter, a field through
// `const self`) takes `op in (const self)`. Containment `op in (self, x)`
// is a separate operator beside them.

class Bag {
    var v: i32 = 0

    fn op in (self) -> yield i32 {
        yield 1
    }

    fn op in (const self) -> yield i32 {
        yield 10
    }

    fn op in (self, x: i32) -> bool {
        return x == self.v
    }
}

class Holder {
    var b: Bag

    fn Holder(self) {
        self.b = Bag()
    }

    fn through_const(const self) -> i32 {
        var s = 0
        for x in self.b { // const self: the const form
            s += x
        }

        return s
    }
}

fn over_param(const b: Bag) -> i32 {
    var s = 0
    for x in b { // a const parameter: the const form
        s += x
    }

    return s
}

fn main() -> i32 {
    var   m = Bag()
    const c = Bag()
    var   s = 0
    for x in m { // 1
        s += x
    }

    for x in c { // 20
        s += x * 2
    }

    for const x in c { // 30
        s += x * 3
    }

    s += over_param(m)                // 10
    s += Holder().through_const() * 4 // 40
    if 0 in m {
        s += 100
    }

    return s // 201
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 201
