// across shapes: a pack of mixed types forwarded through a static
// method and an instance method into a function, an empty pack, and a
// move-only element beside copyable ones. (Into a constructor is
// ctor_from_pack.k, XFAIL.) Every temporary crosses every
// layer without a copy, and the move-only one is moved once.

var moves: i32 = 0
var copies: i32 = 0

class Tok {
    pub var v: i32
    pub fn Tok(self, v: i32) { self.v = v }
    @move fn Tok(self, other: Self) { self.v = other.v; other.v = -1; moves += 1 }
    fn op finally(self) { }
}

class Counted {
    pub var v: i32
    pub fn Counted(self, v: i32) { self.v = v }
    @copy fn Counted(self, const other: Self) { self.v = other.v; copies += 1 }
}

fn sink(t: Tok, const c: Counted, n: i32) -> i32 { return t.v + c.v + n }

class Factory {
    static fn <...A> make(...args: A) -> i32 { return sink(args...) }
    fn <...A> make_via(self, ...args: A) -> i32 { return Factory::make(args...) }
}

fn <...A> how_many(...args: A) -> i32 {
    var n = 0
    for a in args { n += 1 }
    return n
}
fn <...A> relay(...args: A) -> i32 { return how_many(args...) }

fn main() -> i32 {
    var s = Factory::make(Tok(1), Counted(2), 3)
    if s != 6 { return 1 }
    if (moves != 1) || (copies != 0) { return 2 }
    var f = Factory()
    var s2 = f.make_via(Tok(10), Counted(20), 30)
    if s2 != 60 { return 3 }
    if (moves != 2) || (copies != 0) { return 4 }
    if relay() != 0 { return 5 }
    if relay(1, 2.5, true) != 3 { return 6 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
