// `await` on a call of an `async` function (concurrency.mdx: `await
// async_fn()`; functions-declarations.mdx, Function Modifiers) yields the
// function's result.
//
// XFAIL: *
// Ticket "[Codegen] `async` closures and functions emit as plain ones"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today an `async` function
// compiles to an ordinary function returning its plain result, so `await f()`
// is SC086E "'await' requires a 'Future', not 'i32'". Nothing makes a Future.
// (Until async is lowered it should be gated SC116E.) When it XPASSes, delete
// the XFAIL -- the run below is already the real assertion.

fn f() async -> i32 {
    return 7
}

fn main() -> i32 {
    return await f()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
