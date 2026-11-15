// A `const` rebinding in one scope (variables.mdx, Shadowing) is a new
// binding under the same name, and its initializer still reads the old one.
// So does a binding that shadows an outer local in a nested block. C++ has
// neither rule: each shadowing local is emitted under a name of its own.

class Box {
    pub var n: i32
    fn Box(self, n: i32) { self.n = n }
}

fn parse(s: string) -> i32 { return s.size() as i32 }

fn main() -> i32 {
    const raw = "4242"
    const raw = parse(raw)          // string to i32: reads the string
    const raw = raw * 2             // reads the i32
    if raw != 8 { return 1 }

    const b = Box(3)
    const b = Box(b.n + 1)          // a class-typed rebinding
    if b.n != 4 { return 2 }

    const x = 5
    var r = 0
    if r == 0 {
        const x = x + 1             // the outer x
        r = x
    }
    if r != 6 || x != 5 { return 3 }

    const k = 1
    const f = fn () -> i32 { return k }
    const k = 2
    if f() + k != 3 { return 4 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
