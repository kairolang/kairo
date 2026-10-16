// Where a loop can be left decides which states reach the code after it.
// A finite loop -- `while c`, a ranged `for`, a C-style `for` with a
// condition -- may run its body zero times, so the entry state reaches
// past it: a move before the loop that the body re-arms is still
// maybe-moved after. An infinite loop -- `loop`, `while true`, a C-style
// `for` whose condition is `true` -- is left only by `break`, so only the
// breaks' states do. `if` and `match` that re-arm on every arm are live.

class Tok {
    pub var v: i32
    pub fn Tok(self, v: i32) { self.v = v }
    @move fn Tok(self, other: Self) = default
}
fn take(@move t: Tok) { }
fn look(t: *Tok) -> i32 { return t->v }

// --- infinite: only the breaks reach past --------------------------------

fn loop_rearm() {                   // ok
    var x = Tok(1)
    take(x)
    loop { x = Tok(2); break }
    look(&x)
}

fn while_true_rearm() {             // ok
    var x = Tok(1)
    take(x)
    while true { x = Tok(2); break }
    look(&x)
}

fn for_true_rearm() {               // ok
    var x = Tok(1)
    take(x)
    for var i = 0; true; ++i { x = Tok(2); break }
    look(&x)
}

fn loop_conditional_break(k: bool) {    // ok: every break follows the re-arm
    var x = Tok(1)
    take(x)
    loop {
        x = Tok(2)
        if k { break }
    }
    look(&x)
}

fn loop_two_breaks(k: bool) {
    var x = Tok(1)
    take(x)
    loop {
        if k { break }              // leaves with x still moved
        x = Tok(2)
        break
    }
    look(&x)                        // error: one break carries the move
}

fn loop_move_then_break() {
    var x = Tok(1)
    loop { take(x); break }
    look(&x)                        // error
}

fn loop_no_break() {                // ok: nothing after the loop is reachable
    var x = Tok(1)
    take(x)
    loop { }
    look(&x)
}

fn loop_back_edge() {
    var x = Tok(1)
    loop {
        take(x)                     // error: iteration two moves a moved x
    }
}

fn loop_finally_rearms() {          // ok: the break runs the body's finally
    var x = Tok(1)
    take(x)
    loop {
        finally { x = Tok(2) }
        break
    }
    look(&x)
}

// --- finite: the entry state reaches past -------------------------------

fn while_cond(n: i32) {
    var x = Tok(1)
    take(x)
    while n > 0 { x = Tok(2); break }
    look(&x)                        // error: n <= 0 never enters
}

fn ranged_for(const xs: [i32; 2]) {
    var x = Tok(1)
    take(x)
    for i in xs { x = Tok(2); break }
    look(&x)                        // error: the range may be empty
}

fn indexed_for() {
    var x = Tok(1)
    take(x)
    for var i = 0; i < 2; ++i { x = Tok(2); break }
    look(&x)                        // error: the condition may fail at once
}

fn while_false_break() {
    var x = Tok(1)
    while false { take(x); break }
    look(&x)                        // error: path-insensitive, the break is a path
}

// --- branches -------------------------------------------------------------

fn if_both_rearm(k: bool) {         // ok
    var x = Tok(1)
    take(x)
    if k { x = Tok(2) } else { x = Tok(3) }
    look(&x)
}

fn if_one_rearm(k: bool) {
    var x = Tok(1)
    take(x)
    if k { x = Tok(2) }
    look(&x)                        // error
}

fn match_all_rearm(k: i32) {        // ok
    var x = Tok(1)
    take(x)
    match k { case 1 { x = Tok(2) } case _ { x = Tok(3) } }
    look(&x)
}

fn match_one_rearm(k: i32) {
    var x = Tok(1)
    take(x)
    match k { case 1 { x = Tok(2) } case _ { } }
    look(&x)                        // error
}

// --- nesting --------------------------------------------------------------

fn infinite_in_finite(n: i32) {     // ok: the inner loop always re-arms
    var x = Tok(1)
    var i = 0
    while i < n {
        take(x)
        loop { x = Tok(2); break }
        i += 1
    }
    look(&x)
}

fn labeled_inner_break() {
    var x = Tok(1)
    take(x)
    outer: loop {
        loop { break outer }        // leaves with x moved
        x = Tok(2)
        break
    }
    look(&x)                        // error
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: error
// CHECK: loop_exits.k:58:11: error [SC052E]
// CHECK: loop_exits.k:64:11: error [SC052E]
// CHECK: loop_exits.k:77:14: error [SC052E]
// CHECK: loop_exits.k:97:11: error [SC052E]
// CHECK: loop_exits.k:104:11: error [SC052E]
// CHECK: loop_exits.k:111:11: error [SC052E]
// CHECK: loop_exits.k:117:11: error [SC052E]
// CHECK: loop_exits.k:133:11: error [SC052E]
// CHECK: loop_exits.k:147:11: error [SC052E]
// CHECK: loop_exits.k:171:11: error [SC052E]
// CHECK-NOT: error
