// Calling a value of an unbounded generic parameter, `f(x)` with `f: F`:
// the access is checked when the generic is instantiated, like a member
// call on a `T` (generics.mdx), so a closure or a function passed as F is
// called.
//
// XFAIL: *
// Ticket "[Sema] A generic parameter's call `f(x)` is SC062E \"not
// callable\"" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today: SC062E
// "'F' is not callable" at the definition. `fn <T> apply(f: fn(T) -> T, x:
// T)` works. When it XPASSes, delete the XFAIL -- the run below is already
// the real assertion.

fn <F> call(f: F, x: i32) -> i32 {
    return f(x)
}

fn inc(n: i32) -> i32 { return n + 1 }

fn main() -> i32 {
    var k = 10
    var add_k = fn (n: i32)|k| -> i32 { return n + k }
    return call(inc, 1) + call(add_k, 30)       // 2 + 40
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
