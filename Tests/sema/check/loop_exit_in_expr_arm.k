// A `break` that leaves an infinite loop from inside an expression:
// the arm of `try ... catch => break`, a jump StmtExpr inside a TryCatchExpr
// inside a DeclStmt. ControlFlowAnalysis sees a `break` in an expression arm too, so the
// code after the loop is not SC003W "unreachable" (no fix-it deletes it).
// A labeled `break` from a nested loop counts too; one that
// belongs to an inner loop does not, so the last function's tail is still
// unreachable.

struct E { var n: i32 }

fn p(n: i32) panic(E) -> i32 {
    if n == 0 { panic E { n: 0 } }
    return n
}

fn try_arm() -> i32 {
    var k = 3
    while true {
        var v = try p(k) catch => break
        k -= v
    }
    return k
}

fn labeled(n: i32) -> i32 {
    var k = n
    outer: loop {
        while k > 0 {
            var v = try p(k - 1) catch => break outer
            k -= v
        }
    }
    return k
}

fn inner_only(n: i32) -> i32 {
    var k = n
    loop {
        while true {
            var v = try p(k) catch => break
            k -= v
        }
    }
    return k
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: loop_exit_in_expr_arm.k:44:5: warning [SC003W]: unreachable code
// CHECK: fix-it:
// CHECK: note [I900N]: this loop never exits
