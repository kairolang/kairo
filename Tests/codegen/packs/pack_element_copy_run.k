// A pack element given away by value copies it at every instance: an
// instance of copyable elements runs, and the element is copied, not moved
// out of the pack (`Cp` counts its copies: one into the pack, since `c` is
// read after the call, and one into `one`).

var copies: i32 = 0

class Cp {
    pub var id: i32
    pub fn Cp(self, id: i32) { self.id = id; }
    @copy fn Cp(self, const other: Self) { self.id = other.id; copies = copies + 1; }
}

fn <T> one(x: T) -> i32 { return 1 }

fn <...T> count(...args: T) -> i32 {
    var n = 0
    for arg in args {
        n += one(arg)
    }
    return n
}

fn main() -> i32 {
    var c = Cp(3)
    var n = count(1, c, 2.5, true)              // 4, two copies of c
    return n + copies * 10 + c.id               // 4 + 20 + 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe; test $? -eq 27
