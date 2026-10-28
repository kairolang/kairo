// A `finally` written right after a `try` / `catch` is the standalone
// `finally` (PANIC.md §3.3, USER 2026-10-27): it runs when its enclosing
// block is left, not when the `try` finishes, and a `return` / `break` /
// uncaught panic out of the `try` never reaches it. That is a warning,
// whether it shares the try's closing line (`} finally {`) or starts the
// next one: the parser makes the same two statements of both. No fix-it:
// no edit keeps the meaning and silences it. A `finally` anywhere else,
// including first in a block before the `try`, is not warned.

struct E { var code: i32 }

fn risky(k: i32) panic -> i32 {
    if k == 0 { panic E { code: 1 } }
    return k
}

fn note(x: i32) {}

fn same_line() {
    try { note(risky(1)) } catch { note(5) } finally { note(2) }
    note(3)
}

fn next_line(k: i32) -> i32 {
    try {
        note(risky(k))
    } catch e: E {
        note(e.code)
    }
    finally { note(2) }
    return 0
}

fn nested(k: i32) {
    if k > 0 {
        try { note(risky(k)) } catch { note(5) }
        finally { note(2) }
    }
}

fn in_closure() {
    var f = fn () { try { note(risky(1)) } catch { note(5) } finally { note(2) } }
    f()
}

// Not warned: a standalone `finally`, one first in its block, one with a
// statement between it and the `try`.
fn standalone() {
    finally { note(1) }
    note(2)
}

fn first_in_block(k: i32) {
    { finally { note(2) } try { note(risky(k)) } catch { note(5) } }
}

fn separated(k: i32) {
    try { note(risky(k)) } catch { note(5) }
    note(4)
    finally { note(2) }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: finally_after_try.k:20:46: warning [SC001W]: 'finally' runs when the enclosing block exits, like any 'finally', not when the 'try' before it finishes
// CHECK-NEXT: finally_after_try.k:22:1: note [SC001N]: it runs here, when this block is left
// CHECK-NEXT: finally_after_try.k:20:5: note [SC001N]: a 'return', 'break' or uncaught panic leaving this 'try' never reaches the 'finally', so it does not run on that path
// CHECK-NEXT: note [SC001N]: to run it as soon as the 'try' is done, and on every way out of it, put it first in a block of its own: '{ finally { ... } try { ... } catch { ... } }'
// CHECK-NOT: fix-it
// CHECK: finally_after_try.k:30:5: warning [SC001W]: 'finally' runs when the enclosing block exits
// CHECK-NEXT: finally_after_try.k:32:1: note [SC001N]: it runs here, when this block is left
// CHECK-NEXT: finally_after_try.k:25:5: note [SC001N]: a 'return', 'break' or uncaught panic
// CHECK: finally_after_try.k:37:9: warning [SC001W]: 'finally' runs when the enclosing block exits
// CHECK-NEXT: finally_after_try.k:38:5: note [SC001N]: it runs here, when this block is left
// CHECK-NEXT: finally_after_try.k:36:9: note [SC001N]: a 'return', 'break' or uncaught panic
// CHECK: finally_after_try.k:42:62: warning [SC001W]: 'finally' runs when the enclosing block exits
// CHECK-NEXT: finally_after_try.k:42:82: note [SC001N]: it runs here, when this block is left
// CHECK-NEXT: finally_after_try.k:42:21: note [SC001N]: a 'return', 'break' or uncaught panic
