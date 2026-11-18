// A member of `extend <T impl Comparable> Pair<T>` is callable on every
// instance whose argument conforms, on a named value and on a temporary.

interface Comparable {
    fn op <(const self, other: Self) -> bool
}

struct <T> Pair {
    pub var first: T
    pub var second: T
}

extend <T impl Comparable> Pair<T> {
    pub fn max(const self) -> T {
        return if self.first < self.second => self.second else => self.first
    }
}

struct Good {
    pub var n: i32
    pub fn op <(const self, other: Self) -> bool { return self.n < other.n }
}

fn main() -> i32 {
    var p = Pair<Good> { first: Good { n: 1 }, second: Good { n: 2 } }
    var m = p.max()
    var t = Pair<Good> { first: Good { n: 9 }, second: Good { n: 4 } }.max()
    return m.n + t.n - 11
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
