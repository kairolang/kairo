// An if-expression with an arm of type `!` (functions.mdx, No Return): the
// never-returning arm joins any type, so `if c => 1 else => die()` is an
// i32.
//
// XFAIL: *
// Ticket "[Codegen] An if-expression with a `-> !` arm is a clang error"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today it type-checks, and
// EmitIR's _if_expr spells `(c ? 1 : static_cast<int>(die()))`, which clang
// rejects: CL001E "static_cast from 'void' to 'int' is not allowed". When
// it XPASSes, delete the XFAIL -- the run below is already the real
// assertion.

fn die() -> ! {
    while true { }
}

fn pick(c: bool, k: i32) -> i32 {
    var v = if c => k else => die()
    return v
}

fn main() -> i32 {
    return pick(true, 9)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
