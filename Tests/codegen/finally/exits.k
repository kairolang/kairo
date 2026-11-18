// Every way out of a block runs the `finally` bodies the path reached, and
// only those: break and continue run the loop body's (and every block
// nested in it), a labeled break the bodies of every loop it leaves, a
// return every open block's, innermost first. A `finally` the path never
// reached is a local never declared: nothing runs. Each case builds a
// digit trace and compares it whole, so an extra, missing or reordered
// body fails the case.

var trace: i64 = 0
fn mark(d: i64) { trace = trace * 10 + d }
fn reset() { trace = 0 }

// break from a nested block: the inner block's body, then the loop body's.
fn break_nested() -> bool {
    reset()
    while true {
        finally { mark(1) }
        {
            finally { mark(2) }
            break
        }
    }
    mark(3)
    return trace == 213
}

// `break outer` from the inner loop leaves both loop bodies.
fn labeled_break() -> bool {
    reset()
    var i: i64 = 0
    outer: while i < 3 {
        finally { mark(1) }
        i += 1
        while true {
            finally { mark(2) }
            break outer
        }
    }
    return (trace == 21) && (i == 1)
}

// `continue outer` runs the inner body's finally, then the outer body's,
// once per outer iteration.
fn labeled_continue() -> bool {
    reset()
    var i: i64 = 0
    outer: while i < 2 {
        i += 1
        finally { mark(1) }
        while true {
            finally { mark(2) }
            continue outer
        }
    }
    return trace == 2121
}

// A return three blocks deep runs each block's body innermost first, the
// function body's last; the loop's earlier iterations ran theirs at the
// end of each.
fn deep_return(k: i64) -> i64 {
    finally { mark(9) }
    var i: i64 = 0
    while i < 10 {
        finally { mark(1) }
        {
            finally { mark(2) }
            if i == k { return i }
        }
        i += 1
    }
    return -1
}

fn multi_exit() -> bool {
    reset()
    var r = deep_return(1)
    return (r == 1) && (trace == 21219)
}

// `loop` with a conditional break: one body run per iteration, three in all.
fn loop_kw() -> bool {
    reset()
    var i: i64 = 0
    loop {
        finally { mark(1) }
        i += 1
        if i == 3 { break }
    }
    return trace == 111
}

// A continue BEFORE the `finally` skips it on that iteration.
fn continue_before() -> bool {
    reset()
    var i: i64 = 0
    while i < 3 {
        i += 1
        if i == 2 { continue }
        finally { mark(i) }
    }
    return trace == 13
}

// A return before the `finally` never declares the guard.
fn ret_before(early: bool) {
    if early { return }
    finally { mark(1) }
}

fn not_reached() -> bool {
    reset()
    ret_before(true)
    ret_before(false)
    return trace == 1
}

// The indexed loop's body ends before the update: the body reads i as it
// was in that iteration.
fn indexed() -> bool {
    reset()
    for var i: i64 = 1; i < 4; ++i { finally { mark(i) } }
    return trace == 123
}

// A match arm's block is the scope: its finally runs at the arm's end,
// before anything after the match.
fn arm(k: i64) {
    match k {
        case 1 { finally { mark(1) } mark(2) }
        case _ { finally { mark(3) } mark(4) }
    }
    mark(5)
}

fn match_arm() -> bool {
    reset()
    arm(1)
    arm(2)
    return trace == 215435
}

// Only the branch taken declares its guard.
fn branch(c: bool) {
    if c { mark(1) } else { finally { mark(2) } mark(3) }
    mark(4)
}

fn else_only() -> bool {
    reset()
    branch(true)
    branch(false)
    return trace == 14324
}

// Each function's guard is its own record; the names do not collide.
fn one() { finally { mark(1) } }
fn two() { finally { mark(2) } finally { mark(3) } }

fn per_function() -> bool {
    reset()
    one()
    two()
    one()
    return trace == 1321
}

// The exit code names the first case that failed; 0 is all of them passed.
fn main() -> i32 {
    if !break_nested()     { return 1 }
    if !labeled_break()    { return 2 }
    if !labeled_continue() { return 3 }
    if !multi_exit()       { return 4 }
    if !loop_kw()          { return 5 }
    if !continue_before()  { return 6 }
    if !not_reached()      { return 7 }
    if !indexed()          { return 8 }
    if !match_arm()        { return 9 }
    if !else_only()        { return 10 }
    if !per_function()     { return 11 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
