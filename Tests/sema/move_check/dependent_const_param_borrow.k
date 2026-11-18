// A `const` parameter borrows its argument for the call. In a generic body
// the argument's type is not known to be MOVE, and a later use of it is
// still a use of a live value at an instance whose type cannot be copied.

class M {
    pub var n: i32
    pub fn M(self, n: i32) { self.n = n }
    @move pub fn M(self, other: Self) { self.n = other.n }
}

fn <T> peek(const x: T) -> i32 { return 1 }
fn <T> keep(x: T) -> i32 { return 2 }

fn <T> both(x: T) -> i32 {
    var a = peek(x)
    return a + keep(x)
}

fn main() -> i32 {
    return both(M(1)) - 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
