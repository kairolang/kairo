// One of the constructs Compiler/ is written with, checked on Stage 1 ahead
// of self-hosting (2026-10-24 probe; tickets in private/IMPORTANT/TICKETS.TXT).
//
// Closures (closures.md): a local closure capturing by copy, called
// directly and passed where a `fn(i32) -> i32` is expected, beside a named
// function. Compiler/ declares ~220 of them (Lexer, FlagRegistry, ...).
//
// XFAIL: *
// Waiting on lambda emission: Sema accepts all of this, and EmitIR ICEs on
// the first closure ("EmitIR: closure; lambda emission is not written
// yet"). Not on the status page.
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

fn apply(f: fn(i32) -> i32, x: i32) -> i32 { return f(x) }
fn twice(x: i32) -> i32 { return x * 2 }

fn main() -> i32 {
    var base = 10
    var add = fn (x: i32) -> i32 { return x + base }
    var mk = fn (a: i32) -> (i32, i32) { return (a, a + 1) }
    var t = mk(1)
    return add(1) + apply(twice, 2) + t.1     // 11 + 4 + 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 17
