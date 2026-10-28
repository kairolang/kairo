// A `finally` after a `try` / `catch` is the standalone `finally` (PANIC.md
// §3.3, USER 2026-10-27): it runs when its block is left. So the order is
// the try body (or the arm that caught), then the statements after the
// `finally`, then the `finally` at the block's exit -- and a `return` out of
// the `try` leaves before the `finally` is reached, so it does not run.
// Compiling warns (Sema/Panic/finally_after_try.k); the program still runs.

var trace: i64 = 0
fn mark(d: i64) { trace = trace * 10 + d }

struct E { var code: i32 }

fn risky(k: i64) panic -> i64 {
    if k == 0 { panic E { code: 1 } }
    return k
}

// try (1), next statement (4), then the finally (2) at the function's exit.
fn ok_path() -> bool {
    trace = 0
    try { mark(risky(1)) } catch { mark(5) } finally { mark(2) }
    mark(4)
    return trace == 14              // the finally has not run yet
}

// The arm (5), the next statement (4), then the finally (2).
fn caught_path() {
    try { mark(risky(0)) } catch { mark(5) }
    finally { mark(2) }
    mark(4)
}

// In a block: the finally runs at the block's closing brace, before 6.
fn in_block() {
    {
        try { mark(risky(3)) } catch { mark(5) } finally { mark(2) }
        mark(4)
    }
    mark(6)
}

// A `return` out of the `try` never reaches the `finally`.
fn returns_early() -> i64 {
    try { return risky(7) } catch { mark(5) } finally { mark(2) }
    return 0
}

fn main() -> i32 {
    if !ok_path() { return 1 }
    if trace != 142 { return 2 }
    trace = 0
    caught_path()
    if trace != 542 { return 3 }
    trace = 0
    in_block()
    if trace != 3426 { return 4 }
    trace = 0
    if returns_early() != 7 { return 5 }
    if trace != 0 { return 6 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
