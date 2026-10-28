// `spawn some_fn()` (concurrency.mdx: syntax sugar for detaching a thread)
// compiles; the program does not depend on the detached work.
//
// XFAIL: *
// Ticket "[Codegen] `spawn` and the `thread` expression ICE in EmitIR"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today `spawn work()` type-
// checks and ICEs: "EmitIR: spawn; the async lowering owns it" (`thread
// work()` likewise: "EmitIR: thread; the async lowering owns it"). status.mdx
// says they "do nothing yet"; until they are lowered they should be SC116E,
// not an ICE. When it XPASSes, delete the XFAIL -- the run below is already
// the real assertion.

fn work() { }

fn main() -> i32 {
    spawn work()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
