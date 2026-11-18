// In a try expression a default arm (bare `catch` or `catch e`) is
// terminal: any arm after it is a syntax error (S054E), typed or not. A
// `try` that is the bare operand or arm value of another `try` takes every
// arm that follows, past its default, and the outer one reports the
// nesting (S077E). Either way the file has a syntax error and Sema does
// not run, so the statement form's SC240E / SC008E never apply here.

struct E { var code: i32 }

fn thrower() panic(E) -> i32 { panic E { code: 1 } }

fn typed_after_bare() -> i32 {
    return try thrower() catch => 0 catch e: E => 1
}

fn typed_after_binding() -> i32 {
    return try thrower() catch e => 0 catch e2: E => 1
}

fn bare_after_bare() -> i32 {
    return try thrower() catch => 0 catch => 1
}

fn nested_value() -> i32 {
    return try thrower() catch e: E => try thrower() catch => 0 catch e2: E => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="[SC"
// CHECK: arm_order_expr.k:13:37: error [S054E]: no catch arm may follow a default 'catch' (the default is terminal)
// CHECK: arm_order_expr.k:17:39: error [S054E]: no catch arm may follow a default 'catch' (the default is terminal)
// CHECK: arm_order_expr.k:21:37: error [S054E]: no catch arm may follow a default 'catch' (the default is terminal)
// CHECK: arm_order_expr.k:25:40: error [S077E]: a 'try' expression here must be parenthesized
