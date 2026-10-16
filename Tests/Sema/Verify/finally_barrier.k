// A finally body is a barrier: the rules that make it a destructor body
// hold however deep the offending statement sits, and nothing outside the
// body -- an enclosing loop, an enclosing label -- is visible from in it.
// Loops the body declares are its own, and their break / continue are
// legal.

fn nested_finally() -> i32 {
    finally { finally { return 1 } }
    return 0
}

fn in_an_if(c: bool) {
    while c {
        finally {
            if c { break }
        }
    }
}

fn outer_label() {
    outer: while true {
        finally { break outer }
    }
}

fn continue_outer_label() {
    outer: while true {
        finally { continue outer }
    }
}

fn own_loops() {
    finally {
        var i = 0
        while i < 3 { i += 1; if i == 1 { continue } if i == 2 { break } }
        loop { break }
        inner: while true { break inner }
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: error
// CHECK: finally_barrier.k:8:25: error [SC014E]: `return`
// CHECK: finally_barrier.k:15:20: error [SC014E]: `break`
// CHECK: finally_barrier.k:22:19: error [SC012E]: `break` label does not name an enclosing loop
// CHECK: finally_barrier.k:28:19: error [SC012E]: `continue` label does not name an enclosing loop
// CHECK-NOT: error
