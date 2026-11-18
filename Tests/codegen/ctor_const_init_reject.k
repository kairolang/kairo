// Neighbouring shapes of a constructor that initializes a const field: a
// const assigned first, one assigned last after a var field, and two consts
// assigned across a branch. Each compiles and runs without an internal
// error and keeps the value written.

class A {
    pub const k: i32
    pub var v: i32 = 1
    fn A(self, n: i32) { self.k = n + 1 }
}

class B {
    pub var v: i32 = 1
    pub const k: i32
    fn B(self, n: i32) { self.v = n; self.k = self.v * 2 }
}

class C {
    pub const a: i32
    pub const b: i32
    fn C(self, n: i32) {
        if n > 0 { self.a = n } else { self.a = -n }
        self.b = self.a + 1
    }
}

fn main() -> i32 {
    if A(2).k != 3 { return 1 }
    if B(4).k != 8 { return 2 }
    if B(4).v != 4 { return 3 }
    if C(-5).a != 5 { return 4 }
    if C(-5).b != 6 { return 5 }
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -w -o %t.exe 2>&1 | %FileCheck %s --allow-empty --implicit-check-not='I003E' --implicit-check-not='internal'
// RUN: %t.exe
