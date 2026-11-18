// `break outer` leaves the outer loop's body too, so the outer body's
// finally runs on that path, over the state after the inner move.
// MoveCheck finds the frame by the label (_target_frame).

class Tok {
    pub var v: i32
    pub fn Tok(self, v: i32) { self.v = v }
    @move fn Tok(self, other: Self) = default
}
fn take(@move t: Tok) { }
fn look(t: *Tok) -> i32 { return t->v }

fn labeled_break_outer() {
    var x = Tok(1)
    outer: while true {
        finally { look(&x) }        // error: `break outer` runs this after the move
        while true {
            take(x)
            break outer
        }
        x = Tok(3)
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: error
// CHECK: finally_labeled_break.k:16:25: error [SC052E]
// CHECK-NOT: error
