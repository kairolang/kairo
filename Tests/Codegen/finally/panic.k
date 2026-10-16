// A panic leaving a block runs the block's `finally` bodies like any other
// exit (control-flow.md, panic.md), and a try-attached `finally` runs after
// the try body or the catch arm that handled it.
//
// XFAIL: *
// Waiting on PanicLowering: EmitIR ICEs on every `panic` ("EmitIR: panic;
// PanicLowering owns it"). When it lands this test XPASSes; replace the
// XFAIL with nothing -- the run below is already the real assertion.

var trace: i64 = 0
fn mark(d: i64) { trace = trace * 10 + d }

fn risky(k: i64) panic -> i64 {
    finally { mark(3) }
    if k == 0 { panic 1 }
    return k
}

fn panic_exit() -> bool {
    trace = 0
    try { risky(0) } catch { mark(5) }
    return trace == 35
}

fn try_finally() -> bool {
    trace = 0
    try { mark(risky(1)) } catch { mark(5) } finally { mark(2) }
    return trace == 312
}

fn main() -> i32 {
    if !panic_exit()  { return 1 }
    if !try_finally() { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
