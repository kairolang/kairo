// A call whose arguments borrow one place and move another is accepted and
// runs with every value live: the borrow is of `a`, the move is of `b`. The
// same place borrowed by one call and moved by the next statement is
// accepted too, since the borrow has ended.

class Str {
    pub var n: i32 = 0
    pub fn Str(self, n: i32) { self.n = n }
    @move pub fn Str(self, other: Self) { self.n = other.n; other.n = -1 }
}

fn put(const s: Str, at: i32) -> i32 = s.n + at
fn take(s: Str) -> i32 = s.n

fn sequential(s: Str) -> i32 {
    var r = put(s, 1)
    var q = take(s)
    return r + q
}

fn main() -> i32 {
    var a = Str(4)
    var b = Str(5)
    var x = put(a, take(b))
    return sequential(Str(1)) + x - 12
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.e
// RUN: %t.o2.exe
