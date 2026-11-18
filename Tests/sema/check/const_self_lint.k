// -Wconst-self (opt-in): SC273W on a method whose body never mutates
// `self`, SC274W on an `@inout` parameter never mutated, each with a
// fix-it. Off by default. No warning where `self` is written through a
// field, passed to a non-const method, has its address taken, or where the
// signature is not the method's own (virtual / override, interface).

class Counter {
    var n: i32 = 0
    var items: [i32]

    // Only reads a field: warned.
    fn get(self) -> i32 { return self.n }

    // Calls get(), itself const-able: warned too (the fixpoint).
    fn twice(self) -> i32 { return self.get() * 2 }

    // Already const: nothing to say.
    fn peek(const self) -> i32 { return self.n }

    // Writes through a field: not warned.
    fn bump(self) { self.n += 1 }

    // Calls a non-const method on a field: not warned.
    fn add(self, x: i32) { self.items.push(x) }

    // Calls bump(), which mutates: not warned (the fixpoint rules it out).
    fn bump_twice(self) {
        self.bump()
        self.bump()
    }

    // Takes &self: not warned.
    fn addr(self) -> unsafe *Counter { return unsafe &self }

    // A constructor builds self: never warned.
    fn Counter(self) { }
}

class Base {
    var v: i32 = 3
    virtual fn value(self) -> i32 { return self.v }
}

class Derived derives Base {
    override fn value(self) -> i32 { return 4 }
}

interface Named {
    fn name(self) -> i32
}

class Tag impl Named {
    var id: i32 = 7
    // Implements a requirement: its signature is the interface's.
    fn name(self) -> i32 { return self.id }
}

fn read_only(@inout x: i32) -> i32 { return x + 1 }

fn writes(@inout x: i32) { x = 2 }

fn passes_on(@inout x: i32) { writes(&x) }

fn main() -> i32 {
    var c = Counter()
    c.bump()
    var y = 1
    writes(&y)
    passes_on(&y)
    var d = Derived()
    var t = Tag()
    return c.twice() + read_only(&y) + d.value() + t.name() - 21
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -Wconst-self 2>&1 || true; } | %FileCheck %s --check-prefix=ON --implicit-check-not=SC273W --implicit-check-not=SC274W
// ON-DAG: const_self_lint.k:12:12: warning [SC273W]: method 'get' never mutates 'self'; declare it 'const self'
// ON-DAG: fix-it:"{{.*}}const_self_lint.k":{12:12-12:12}:"const "
// ON-DAG: const_self_lint.k:15:14: warning [SC273W]: method 'twice' never mutates 'self'; declare it 'const self'
// ON-DAG: const_self_lint.k:58:21: warning [SC274W]: '@inout' parameter 'x' is never mutated; declare it 'const'
// ON-DAG: fix-it:"{{.*}}const_self_lint.k":{58:14-58:20}:"const"
// ON-NOT: error

// Silent by default.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=OFF --allow-empty
// OFF-NOT: SC273W
// OFF-NOT: SC274W
// OFF-NOT: error
