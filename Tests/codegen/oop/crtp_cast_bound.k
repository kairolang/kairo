// The CRTP downcast through a `derives` bound: inside `class <X derives
// Mixin<X> ...> Mixin`, `&self as *X` needs no `unsafe` -- the bound proves
// every X is a Mixin<X>, so it is C++'s static_cast (no vtable, no check).
//
// What this pins, beyond crtp_self_cast.k's one line:
//  - a `const self` (`*const X`) and a mutating one (`*X`), through the
//    `dyn()` helper every Compiler/ mixin defines;
//  - the base calling INTO X through an `impl` bound on the same parameter;
//  - a mixin that is NOT the first base, so it sits at a nonzero offset:
//    a reinterpret would read the wrong object there, the static_cast
//    adjusts the pointer (the a2 shape that miscompiled through `as unsafe
//    *X`);
//  - a mixin chain: `Stmts<T> derives Rav<T>`, each casting itself down
//    to the leaf through its own bound, Rav's through Stmts';
//  - `as static *X`, which asks for exactly this kind of cast.

interface Weighted {
    fn weight(const self) -> i32
}

class Base {
    pub var b: i32 = 100
}

class <X derives Counter<X> impl Weighted> Counter {
    pub var hits: i32 = 0
    fn dyn(self) -> *X { return &self as *X }
    fn cdyn(const self) -> *const X { return &self as *const X }
    fn bump(self) -> i32 {
        self.hits += 1
        return self.dyn()->weight() + self.hits
    }
    fn twice(const self) -> i32 { return self.cdyn()->weight() * 2 }
}

class Node derives Base, Counter<Node> impl Weighted {
    pub var w: i32 = 5
    fn weight(const self) -> i32 { return self.w }
}

// The chain: Rav is the root mixin, Stmts the intermediate one; the leaf
// derives only Stmts<Leaf> and reaches Rav<Leaf> through it.
interface Visits {
    fn visit(self, n: i32) -> i32
}

class <D derives Rav<D> impl Visits> Rav {
    pub var depth: i32 = 0
    fn rdyn(self) -> *D { return &self as *D }
    fn walk(self, n: i32) -> i32 {
        self.depth += 1
        return self.rdyn()->visit(n)
    }
}

class <T derives Stmts<T> impl Visits> Stmts derives Rav<T> {
    fn sdyn(self) -> *T { return &self as *T }
    fn stmt(self, n: i32) -> i32 { return self.sdyn()->walk(n) + 1 }
    // Rav's pointer, cast down from inside Stmts: Stmts<T> derives Rav<T>.
    fn from_rav(self) -> i32 {
        var r: *Rav<T> = &self
        var t = r as *T
        return t->depth
    }
}

class Leaf derives Base, Stmts<Leaf> impl Visits {
    pub var k: i32 = 3
    fn visit(self, n: i32) -> i32 { return n * self.k }
}

class <X derives Plain<X>> Plain {
    fn me(const self) -> *const X { return &self as static *const X }
}

class Seven derives Plain<Seven> {
    pub var v: i32 = 7
}

fn main() -> i32 {
    var r = 0
    var n = Node()
    if n.twice() == 10 { r += 1 }
    if n.bump() == 6 { r += 2 }
    if (n.hits == 1) && (n.b == 100) { r += 4 }

    var l = Leaf()
    if l.stmt(4) == 13 { r += 8 }
    if l.from_rav() == 1 { r += 16 }

    var s = Seven()
    if s.me()->v == 7 { r += 32 }
    return r                                    // 63
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The cast is a static_cast, never a reinterpret.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: static_cast<X *>(
// CXX: static_cast<const X *>(
// CXX-NOT: reinterpret_cast<{{(const )?}}X *>

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 63
