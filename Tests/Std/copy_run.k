// std::copy(x) returns a copy of x and leaves x untouched. A class that
// declares `fn copy(const self) -> Self` is copied by that method, even when
// it also has a copy constructor; any other COPY class, a primitive and a
// pointer are copied by their copy constructor. Each case is told apart at
// run time by what its copy does to `n`.

import std

class Plain {
    pub var n: i32
    pub fn Plain(self, n: i32) {
        self.n = n
    }
}

class Counted {
    pub var n: i32
    pub fn Counted(self, n: i32) {
        self.n = n
    }

    @copy pub fn Counted(self, const other: Self) {
        self.n = other.n + 1
    }
}

class Unique {
    pub var n: i32
    pub fn Unique(self, n: i32) {
        self.n = n
    }

    @move pub fn Unique(self, other: Self) {
        self.n = other.n
    }

    pub fn copy(const self) -> Unique {
        return Unique(self.n + 1000)
    }
}

class Both {
    pub var n: i32
    pub fn Both(self, n: i32) {
        self.n = n
    }

    @copy pub fn Both(self, const other: Self) {
        self.n = other.n + 1
    }

    pub fn copy(const self) -> Both {
        return Both(self.n + 500)
    }
}

fn main() -> i32 {
    var p   = Plain(1)
    var c   = Counted(2)
    var u   = Unique(3)
    var b   = Both(4)
    var n   = 7
    var *q  = &n
    var p2  = std::copy(p)
    var c2  = std::copy(c)
    var u2  = std::copy(u)
    var b2  = std::copy(b)
    var n2  = std::copy(n)
    var *q2 = std::copy(q)
    if p2.n != 1 || p.n != 1 {
        return 1
    }

    if c2.n != 3 || c.n != 2 { // the copy constructor ran
        return 2
    }

    if u2.n != 1003 || u.n != 3 { // copy(), and u is still usable
        return 3
    }

    if b2.n != 504 { // copy() alone, not the constructor
        return 4
    }

    if b.n != 4 {
        return 5
    }

    if n2 != 7 || q2 != q {
        return 6
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
