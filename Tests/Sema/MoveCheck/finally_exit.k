// A finally body runs when its block is left, so it is checked against the
// state at each exit, not at its statement: a read there of a binding moved
// later in the block is a use after move, and an assignment there re-arms
// the binding only on the paths that actually leave through it.

class Tok {
    pub var v: i32
    pub fn Tok(self, v: i32) { self.v = v }
    @move fn Tok(self, other: Self) = default
}

fn take(@move t: Tok) { }
fn peek(const t: Tok) -> i32 { return t.v }

fn read_after_later_move() {
    var x = Tok(1)
    finally { peek(x) }      // error: runs at exit, x moved below
    take(x)
}

fn assign_does_not_legalize() -> Tok {
    var x = Tok(1)
    take(x)
    finally { x = Tok(2) }   // runs after the return value is computed
    return x                 // error: x moved
}

fn assign_then_fallthrough() -> i32 {
    var x = Tok(1)
    {
        take(x)
        finally { x = Tok(2) }
    }                        // the body ran here: x is live again
    return peek(x)           // ok
}

fn loop_move_in_body() {
    var x = Tok(1)
    var i = 0
    while i < 2 {
        finally { take(x) }  // error: iteration two's exit moves a moved x
        i += 1
    }
}

fn continue_runs_body() {
    var i = 0
    while i < 2 {
        var x = Tok(1)
        finally { peek(x) }  // ok: x is this iteration's, and live on both exits
        i += 1
        if i == 1 { continue }
        take(x)              // error: the body runs after this on the fallthrough exit
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s
// CHECK-COUNT-4: error
