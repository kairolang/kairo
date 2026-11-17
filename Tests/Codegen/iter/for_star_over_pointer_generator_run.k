// A generator that yields pointers (`-> yield *T`, `-> yield *const T`)
// hands out places it owns. Over a call of one, `for *p` binds the yielded
// pointer itself, as it does over an `op in -> yield *T`: a write through
// `p` lands in the place, and `p->n` reads it. A plain `for p` binds the
// pointer value. Neither copies the pointee. A generic `-> yield T` yields
// values even where `T` is a pointer.

var made:  i32 = 0
var moves: i32 = 0

class Str {
    pub var n: i32 = 0

    pub fn Str(self, n: i32) {
        self.n = n
        made   += 1
    }

    @move
    pub fn Str(self, other: Self) {
        self.n  = other.n
        moves   += 1
    }
}

class Pair {
    pub var a: Str
    pub var b: Str
    pub fn Pair(self) { self.a = Str(1); self.b = Str(2) }

    pub fn each(self) -> yield *Str {
        yield &self.a
        yield &self.b
    }

    pub fn each_const(const self) -> yield *const Str {
        yield &self.a
        yield &self.b
    }
}

fn main() -> i32 {
    var p = Pair()
    made  = 0
    moves = 0
    for *s in p.each() {
        s->n += 10
    }

    if p.a.n != 11 || p.b.n != 12 { return 1 }

    var sum = 0
    for const *s in p.each_const() {
        sum += s->n
    }

    if sum != 23 { return 2 }

    sum = 0
    for s in p.each_const() {
        sum += s->n
    }

    if sum != 23 || made != 0 || moves != 0 { return 3 }

    if through_value(5) != 5 { return 4 }

    return 0
}

// `-> yield T` yields values, read off the declaration as an `op in`'s
// rule is: at `T = *i32`, `*p` is the address of the yielded pointer.
fn <T> one(v: T) -> yield T {
    yield v
}

fn through_value(n: i32) -> i32 {
    var x = n
    var r = 0
    for *p in one(&x) {
        r += **p
    }

    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-sema 2>&1 || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA-NOT:  error [
// SEMA:      NamedIdentExpr          @ 47:9     : *Str
// SEMA:      NamedIdentExpr          @ 54:16    : const *const Str

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe
