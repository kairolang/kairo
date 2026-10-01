// Defaults accumulate across a redeclaration chain: each parameter's default
// may sit on a different declaration, and every one of them reaches a call.
// An out-of-line method's defaults come from its in-class declaration.

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

fn f0(i: i32, j: i32, k: i32 = 3) -> i32
fn f0(i: i32, j: i32 = 2, k: i32) -> i32
fn f0(i: i32 = 1, j: i32, k: i32) -> i32
fn f0(i: i32, j: i32, k: i32) -> i32 { return i * 100 + j * 10 + k }

fn g(x: i32 = 4) -> i32
fn g(x: i32) -> i32 { return x }

class C {
    pub fn C(self) { }
    pub fn m(self, i: i32 = 8, j: i32 = 9) -> i32
}

fn C::m(self, i: i32, j: i32) -> i32 { return i * 10 + j }

fn main() -> i32 {
    var n = chk(f0() == 123)
    n += chk(f0(4) == 423)
    n += chk(f0(k: 7) == 127)
    n += chk(g() == 4)
    var c = C()
    n += chk(c.m() == 89)
    n += chk(c.m(1) == 19)
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 6
