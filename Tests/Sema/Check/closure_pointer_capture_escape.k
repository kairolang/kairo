// A closure that captures a stack local by pointer and outlives it is a
// Tether error (closures.mdx, Tether and Lifetime Safety: "Capturing stack-
// local variables by pointer in a closure that escapes the current scope is
// always a Tether error").
//
// XFAIL: *
// Ticket "[Codegen] A `|*x|` closure that outlives `x` dangles"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today it compiles, cdcc738f
// emits `x = &x`, and the returned closure reads a dead stack slot
// (status.mdx, Not Diagnosed; waits on Tether). The code is not decided; the
// check asks for an error at the marked line. When it XPASSes, delete the
// XFAIL and pin the code and message.

fn make_closure() -> fn() -> i32 {
    var x = 42
    return fn ()|*x| -> i32 { return *x }
// CHECK: closure_pointer_capture_escape.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
