// Yielding a literal from a generator (functions-generators.mdx: `yield e`
// produces the next value; `e` must convert to `T`).
//
// XFAIL: *
// Ticket "[Codegen] Yielding a literal from a generator fails in clang"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today it type-checks and clang
// rejects the emitted C++: CL001E "non-const lvalue reference to type 'int'
// cannot bind to a temporary of type 'int'" -- the yield passes its operand
// to the runtime by non-const reference (Lib/builtin/types.k). Yielding a
// variable works. When it XPASSes, delete the XFAIL -- the run below is
// already the real assertion.

fn sevens() -> yield i32 {
    yield 7
    yield 3 + 4
}

fn main() -> i32 {
    var s = 0
    for v in sevens() { s += v }
    return s                                    // 14
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 14
