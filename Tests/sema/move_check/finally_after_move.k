// `x.finally()` on a local moved on a path that reaches it is a use after
// the move (SC052E), as a read is: a move is destructive, so no object is
// left there to destroy (classes-lifecycle.mdx, ownership.mdx).
//  - moved: moved on every path; maybe: on one path; part: a field moved.
//  - remade: assigned again after the move, so `finally()` ends the new
//    value; kept: never moved. Neither is an error.

class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) { }
}

class Pair {
    var a: Res
    var b: Res
    fn Pair(self) {
        self.a = Res(1)
        self.b = Res(2)
    }
}

fn take(r: Res) { }

fn moved() {
    var a = Res(1)
    var b = a
    a.finally()
}

fn maybe(c: bool) {
    var a = Res(2)
    if c {
        take(a)
    }
    a.finally()
}

fn part() {
    var p = Pair()
    var x = p.a
    p.finally()
}

fn remade() {
    var a = Res(3)
    take(a)
    a = Res(4)
    a.finally()
}

fn kept() {
    var a = Res(5)
    a.finally()
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: finally_after_move.k:32:5: error [SC052E]: 'a' is used after being moved
// DIAG: finally_after_move.k:40:5: error [SC052E]: 'a' is used after being moved
// DIAG: finally_after_move.k:46:5: error [SC052E]: 'p' is used after its part 'p.a' was moved
