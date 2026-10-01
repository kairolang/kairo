// Named constructor arguments, and a defaulted constructor parameter. The
// thunk is a static member of the struct.

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

struct P {
    var x: i32
    var y: i32
    fn P(self, x: i32, y: i32 = 9) { self.x = x; self.y = y }
}

fn main() -> i32 {
    var p = P(x: 1)
    var q = P(y: 2, x: 3)
    var n = chk(p.x == 1)
    n += chk(p.y == 9)
    n += chk(q.x == 3)
    n += chk(q.y == 2)
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 4
