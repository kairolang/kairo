// A move-only left operand of a derived `op +` at its last use moves into
// the result: no copy is made (none can be), and the chain `a + b + c`
// moves `a` once and then reuses the temporary.

var moves: i32 = 0

class S {
    pub var v: i32 = 0
    fn S(self, x: i32) { self.v = x }
    @move fn S(self, other: Self) {
        self.v = other.v
        moves += 1
    }
    fn op += (self, const o: S) { self.v += o.v }
}

fn param(a: S) -> S {
    return a + S(10)
}

fn main() -> i32 {
    var a = S(1)
    moves = 0
    var b = a + S(2)
    // One move of `a` into the sum and one out of it into `b`, at most.
    if b.v != 3 || moves > 2 { return 1 }
    var c = S(4)
    var d = c + S(5) + S(6)
    if d.v != 15 { return 2 }
    var e = param(S(7))
    if e.v != 17 { return 3 }
    var s = S(0)
    for var i = 0; i < 3; ++i {
        s = s + S(1)
    }

    return if (s.v == 3) => (0) else => 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT:   error [
// CXX-LABEL: int main() noexcept {
// CXX:       sum{{[0-9]*}} = static_cast<{{.*}}S &&>(a);
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
