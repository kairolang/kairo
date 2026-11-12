// A bounded generic's instance as a value, its bound met, compiles and
// runs: the instance named at the value use is the one a call would name.

interface Big { fn big(const self) -> i32 }

class W impl Big {
    pub var n: i32
    fn W(self, n: i32) { self.n = n }
    fn big(const self) -> i32 = self.n
}

fn <T impl Big> pick(x: T) -> i32 { return x.big() }

fn <U impl Big> forward(u: U) -> i32 {
    var f = pick<U>
    return f(u)
}

fn main() -> i32 {
    var f = pick<W>
    return f(W(4)) + forward(W(3))     // 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
