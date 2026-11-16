// What forwarding a pack guarantees, observed through callees that take
// their argument by value and consume it: an expansion the pack is read
// again after hands each element on intact, and only the last one gives the
// element away. `eat` empties the S it is handed, so an expansion that gave
// its element away early would leave the next one a shorter string. A MOVE
// element can be passed on only by a move, so `moved` compiling and running
// one `@move` shows the last expansion forwards.

ffi "c++" import "string"

var moves: i32 = 0

class S {
    pub var v: cxx::std::string
    fn S(self, n: usize) { self.v.resize(n) }
}

class M {
    pub var n: i32 = 0
    fn M(self, n: i32) { self.n = n }
    @move fn M(self, other: Self) {
        self.n = other.n
        other.n = 0
        moves += 1
    }
}

// Each writes to its parameter, so it owns a value of its own.
fn eat(s: S) -> usize {
    var n = s.v.size()
    s.v.clear()
    return n
}

fn eat2(a: S, b: S) -> usize {
    var n = a.v.size() + b.v.size()
    a.v.clear()
    b.v.clear()
    return n
}

fn eat_m(m: M) -> i32 {
    m.n += 1
    return m.n
}

fn <...T> once(...xs: T) -> usize { return eat(xs...) }
fn <...T> twice(...xs: T) -> usize { return eat(xs...) + eat(xs...) }
fn <...T> thrice(...xs: T) -> usize {
    var a = eat(xs...)
    var b = eat(xs...)
    return a + b + eat(xs...)
}
fn <...T> looped(...xs: T) -> usize {
    var n: usize = 0
    for var i = 0; i < 3; ++i { n += eat(xs...) }
    return n
}
fn <...T> branched(pick: bool, ...xs: T) -> usize {
    var n = eat(xs...)
    if pick { n += eat(xs...) }
    return n
}
fn <...T> pair(...xs: T) -> usize { return eat2(xs...) + eat2(xs...) }
fn <...T> moved(...xs: T) -> i32 { return eat_m(xs...) }

fn main() -> i32 {
    if once(S(40)) != 40 { return 1 }
    if twice(S(40)) != 80 { return 2 }
    if thrice(S(40)) != 120 { return 3 }
    if looped(S(40)) != 120 { return 4 }
    if branched(true, S(40)) != 80 { return 5 }
    if branched(false, S(40)) != 40 { return 6 }
    if pair(S(40), S(2)) != 84 { return 7 }

    // An lvalue argument is the caller's: no expansion takes it.
    var s = S(40)
    if twice(s) != 80 { return 8 }
    if s.v.size() != 40 { return 9 }

    if moved(M(7)) != 8 { return 10 }
    if moves != 1 { return 11 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// The callees take values, or nothing here could observe a move.
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=CXX
// CXX: eat( ::{{[A-Za-z0-9_:]+}}::S s) noexcept;
// CXX: eat_m( ::{{[A-Za-z0-9_:]+}}::M m) noexcept;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
