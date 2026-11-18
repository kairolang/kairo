// A panic leaving a block runs the block's `finally` bodies like any other
// exit (control-flow.md, panic.md): the panic is a return (PANIC.md §3.3,
// §4.5a J). A `finally` written after a `try` is a standalone one
// (panic.mdx, "identical to standalone `finally`"): it runs when its block
// is left, after the try body or the catch arm that handled the error.

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
    { try { mark(risky(1)) } catch { mark(5) } finally { mark(2) } }
    return trace == 312
}

fn try_finally_caught() -> bool {
    trace = 0
    { try { mark(risky(0)) } catch { mark(5) } finally { mark(2) } }
    return trace == 352
}

// The panic leaves through the caller's `finally` too: it propagates.
fn passes(k: i64) panic -> i64 {
    finally { mark(4) }
    return risky(k) + 1
}

fn propagated() -> bool {
    trace = 0
    var v = try passes(0) catch => 7
    return (trace == 34) && (v == 7)
}

fn main() -> i32 {
    if !panic_exit()  { return 1 }
    if !try_finally() { return 2 }
    if !try_finally_caught() { return 3 }
    if !propagated() { return 4 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
