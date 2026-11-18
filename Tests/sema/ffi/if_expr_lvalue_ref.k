// An `if` expression handed to an imported C++ `T&` parameter. The C++
// conditional of two lvalues is an lvalue, so `T&` would bind an arm and
// the callee could write it; Kairo treats the expression as a value. It is
// an error with its own message and no `&` fix-it: `&(if ...)` is the
// address of a temporary. A variable bound to the result passes as usual.

ffi "c++" import "if_expr_lvalue_ref.h"

fn main() -> i32 {
    var c      = true
    var i: i32 = 1
    var j: i32 = 2
    lone(if (c) => (i) else => j)
    lone((if (c) => (i) else => j))
    var r = both(if (c) => (i) else => j)
    var t = if (c) => (i) else => j
    lone(&t)
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: if_expr_lvalue_ref.k:13:10: error [SC357E]: an 'if' expression cannot be passed to the C++ 'T&' parameter 'x'; bind it to a variable
// CHECK-NOT: fix-it
// CHECK: if_expr_lvalue_ref.k:14:11: error [SC357E]: an 'if' expression cannot be passed
// CHECK: if_expr_lvalue_ref.k:15:18: error [SC357E]: an 'if' expression cannot be passed
// CHECK-NOT: error
