// An arm of a `try` expression may leave instead of producing a value
// (PANIC.md §3.2): `=> return v` from the enclosing function, `=> break` /
// `=> continue` out of an enclosing loop, a label included. Such an arm
// has type `!`, so it fits beside arms of any type. The jump is checked as
// the statement it is: the returned value against the function's return
// type (the one error below), a `break` against its loop.

struct E { var code: i32 }

fn thrower() panic(E) -> i32 { panic E { code: 1 } }

fn leaves(n: i32) -> i32 {
    var first = try thrower() catch => return -1
    var total = 0
    outer: for var i: i32 = 0; i < n; ++i {
        total += try thrower() catch e: E => continue
        total += try thrower() catch => break outer
    }
    return first + total
}

fn void_return(n: i32) {
    var v = try thrower() catch => return
}

fn wrong_value(n: i32) -> i32 {
    var v = try thrower() catch => return "no"
    return v
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: jump_arms.k:27:43: error [SC028E]: cannot convert 'string' to 'i32'
//
// The arms print back as written (the flat form spells a try with braces).
// RUN: { %kairo %s --type-check-only --print-ast=flat 2>&1 || true; } | %FileCheck %s --check-prefix=FLAT
// FLAT: var first = try { thrower() } catch { return -1 }
// FLAT-SAME: catch e: E { continue }
// FLAT-SAME: catch { break outer }
