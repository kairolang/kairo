// An operand that a later operand of the same call or operator could
// change is evaluated first into a local. A value of a type that cannot be
// copied (Str has no copy constructor) is read in place instead: a `const`
// parameter, a receiver and an operator's operand borrow it, so the local
// is a reference and nothing is copied or moved. A store whose value is a
// call (`p->s = make(v)`) moves the result into the place.

var made:  i32 = 0
var moves: i32 = 0
var drops: i32 = 0

class Str {
    pub var n: i32 = 0

    pub fn Str(self, n: i32) {
        self.n = n
        made   += 1
    }

    @move
    pub fn Str(self, other: Self) {
        self.n  = other.n
        other.n = -1
        moves   += 1
    }

    fn op finally(self) {
        drops += 1
    }

    pub fn size(const self) -> i32 = self.n

    pub fn op == (const self, const o: Str) -> bool = self.n == o.n
}

class Box {
    pub var s: Str
    pub fn Box(self) { self.s = Str(0) }
}

fn put(const s: Str, at: i32) -> i32 = s.n + at

fn three(const a: Str, b: i32, c: i32) -> i32 = a.n + b + c

fn make(n: i32) -> Str = Str(n)

fn grow(s: *Str) -> i32 {
    s->n += 1
    return s->n
}

fn main() -> i32 {
    var s = Str(4)
    made  = 0
    moves = 0
    if put(s, 10 - s.size()) != 10 { return 1 }

    if three(s, s.size(), s.size()) != 12 { return 2 }

    if !(s == make(4)) || put(s, s.size()) != 8 { return 3 }

    if made != 1 || moves != 0 { return 4 }

    // A later operand that writes the value is the program's aliasing.
    if put(s, grow(&s)) != 10 { return 5 }

    var b = Box()
    var *p = &b
    made  = 0
    moves = 0
    p->s = make(s.size())
    if b.s.n != 5 || made != 1 { return 6 }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe
