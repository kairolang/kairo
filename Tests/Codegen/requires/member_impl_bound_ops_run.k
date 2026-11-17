// Operators and associated types through a member's `requires`: `!=`
// derived from the bound's `op ==`, `<=` and `>` from `op <=>`, a
// `__builtin_is_same` conjunct beside the bound, `J::Item impl Eq` on a
// member and on a free function, and `x in self` / `for x in self` through
// the record's own `op in`. Pull<Gen>, whose Item has no `==`, is used
// without calling the member that needs it.

import std::io::println

interface Eq {
    fn op ==(const self, const o: Self) -> bool
}

interface Cmp {
    fn op <=>(const self, const o: Self) -> Ordering
}

interface Src {
    type Item
    fn next(self) -> Self::Item
}

class Num {
    pub var v: i32
    pub fn Num(self) { self.v = 0 }
    pub fn Num(self, v: i32) { self.v = v }
    pub fn op ==(const self, const o: Num) -> bool { return self.v == o.v }
}

class Ver {
    pub var v: i32
    pub fn Ver(self) { self.v = 0 }
    pub fn Ver(self, v: i32) { self.v = v }
    pub fn op <=>(const self, const o: Ver) -> Ordering {
        if self.v < o.v { return Ordering::Less }
        if self.v > o.v { return Ordering::Greater }
        return Ordering::Equal
    }
}

class Count {
    pub var n: i32 = 0
}

extend Count impl Src {
    type Item = Num
    fn next(self) -> Num {
        self.n += 1
        return Num(self.n)
    }
}

class <T> Pair {
    pub var a: T
    pub var b: T

    pub fn Pair(self, a: T, b: T) {
        self.a = a
        self.b = b
    }

    // `!=` derives from the bound's `op ==`, `<=` and `>` from `op <=>`.
    pub fn differ(const self) -> bool requires T impl Eq { return self.a != self.b }
    pub fn ordered(const self) -> bool requires T impl Cmp { return self.a <= self.b }
    pub fn desc(const self) -> bool requires T impl Cmp { return self.a > self.b }

    // A parameter equated with T by the clause, used through T's bound.
    pub fn <U> eq_to(const self, u: U) -> bool requires __builtin_is_same<U, T>() && T impl Eq {
        return self.a == u
    }
}

class <J> Pull {
    pub var j: J

    pub fn Pull(self, j: J) { self.j = j }

    // The associated type's bound comes from the member's clause.
    pub fn two_same(self) -> bool requires J impl Src && J::Item impl Eq {
        var x = self.j.next()
        var y = self.j.next()
        return x == y
    }
}

// The same on a free function.
fn <J impl Src> first_is(j: J, const v: J::Item) -> bool requires J::Item impl Eq {
    return j.next() == v
}

class <T> Bag {
    pub var a: T
    pub var b: T

    pub fn Bag(self, a: T, b: T) {
        self.a = a
        self.b = b
    }

    pub fn op in (const self, const v: T) -> bool requires T impl Eq { return self.a == v || self.b == v }

    pub fn op in (const self) -> yield T {
        yield self.a
        yield self.b
    }

    pub fn holds(const self, const v: T) -> bool requires T impl Eq { return v in self }

    pub fn sum(const self) -> i32 requires T impl Cmp {
        var k = 0
        for x in self {
            if x > self.a {
                k += 1
            }
        }

        return k
    }
}

class Opaque {
    pub var v: i32 = 0
}

class Gen {
    pub var n: i32 = 0
}

extend Gen impl Src {
    type Item = Opaque
    fn next(self) -> Opaque { return Opaque{} }
}

fn main() -> i32 {
    var p = Pair<Num>(Num(1), Num(2))
    var r = Pair<Ver>(Ver(1), Ver(2))
    println(f"{p.differ()} {r.ordered()} {r.desc()} {p.eq_to(Num(1))}")
    var q = Pull<Count>(Count{})
    println(f"{q.two_same()} {first_is<Count>(Count{}, Num(1))}")
    var g = Bag<Num>(Num(3), Num(5))
    var h = Bag<Ver>(Ver(3), Ver(5))
    println(f"{g.holds(Num(5))} {g.holds(Num(4))} {h.sum()}")
    var o = Pull<Gen>(Gen{})
    println(f"{o.j.n}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: true true false true
// CHECK-NEXT: false true
// CHECK-NEXT: true false 1
// CHECK-NEXT: 0
