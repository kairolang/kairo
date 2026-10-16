// MoveCheck walks a finally body at each exit of its block, over the state
// there (MoveCheck.k, Flow). `look(&x)` is a read; `take(x)` a move.
//
//   - break and return run the bodies they leave: a move in a loop body's
//     finally is visible after the loop through the break; a return from
//     an inner block runs the function body's finally after the move in
//     the inner block
//   - a call typed `!` leaves no block: no body runs after it
//   - an inner block's finally runs at THAT block's end, before what
//     follows it
//   - LIFO: of two finallys in one block the later one runs first
//   - a finally in one branch only: maybe-moved after the join
//   - a move in a finally then a reassignment is live again

class Tok {
    pub var v: i32
    pub fn Tok(self, v: i32) { self.v = v }
    @move fn Tok(self, other: Self) = default
}
fn take(@move t: Tok) { }
fn look(t: *Tok) -> i32 { return t->v }
fn die() -> ! { __builtin_trap() }

fn break_moves() {
    var x = Tok(1)
    while true {
        finally { take(x) }
        break
    }
    look(&x)                        // error: the break ran the move
}

fn return_runs_outer() {
    var x = Tok(1)
    finally { look(&x) }            // error: runs after the return below
    {
        take(x)
        return
    }
}

fn noreturn_skips() {               // ok
    var x = Tok(1)
    finally { look(&x) }
    take(x)
    die()
}

fn inner_scope_first() {            // ok
    var x = Tok(1)
    { finally { look(&x) } }
    take(x)
}

fn reassign_after() {               // ok
    var x = Tok(1)
    { finally { take(x) } }
    x = Tok(2)
    look(&x)
}

fn lifo_wrong() {
    var x = Tok(1)
    finally { look(&x) }            // error: the later finally moved x first
    finally { take(x) }
}

fn lifo_right() {                   // ok
    var x = Tok(1)
    finally { take(x) }
    finally { look(&x) }
}

fn one_branch(c: bool) {
    var x = Tok(1)
    if c { finally { take(x) } }
    look(&x)                        // error: maybe-moved
}

fn nested_bodies() {
    var x = Tok(1)
    finally {
        finally { take(x) }
        look(&x)                    // ok: the inner body runs at the outer's end
    }
}

fn nested_bodies_wrong() {
    var x = Tok(1)
    finally {
        { finally { take(x) } }
        look(&x)                    // error: the inner block ended first
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: error
// CHECK: finally_flow.k:30:11: error [SC052E]
// CHECK: finally_flow.k:35:21: error [SC052E]
// CHECK: finally_flow.k:64:21: error [SC052E]
// CHECK: finally_flow.k:77:11: error [SC052E]
// CHECK: finally_flow.k:92:15: error [SC052E]
// CHECK-NOT: error
