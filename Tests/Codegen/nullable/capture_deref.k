// P50 (NULLABLE.md 3.7), run: inside a `|*x|` closure, `(*x)?` narrows `*x`,
// and the narrowed read lowers to `(*x).__value()`, which reads (and
// writes) the captured variable itself. The error forms are
// Sema/Nullable/capture_deref.k.

import std::io::println

struct Node { pub var value: i32 = 4 }

fn main() -> i32 {
    var x: Node? = Node()
    var read = fn ()|*x| -> i32 {
        if (*x)? { return (*x).value }
        return -1
    }
    println(f"read: {read()}")

    var bump = fn ()|*x| {
        if (*x)? { (*x).value = (*x).value + 1 }
    }
    bump()
    if x? { println(f"bumped: {x.value}") }

    x = null
    println(f"after null: {read()}")

    var n: i32? = 9
    var plus = fn ()|*n| -> i32 {
        if (*n)? { return (*n) + 1 }
        return 0
    }
    println(f"plus: {plus()}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: __value()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      read: 4
// OUT-NEXT: bumped: 5
// OUT-NEXT: after null: -1
// OUT-NEXT: plus: 10
