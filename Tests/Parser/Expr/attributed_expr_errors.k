// A malformed expression attribute is one error at the attribute, and the
// statement after it parses: no name after `@` (S046E), nothing for the
// attribute to apply to (S052E naming it, not the operand parser's
// "expected expression, found ')'" and its cascade). A parameter mode at a
// call (`f(@inout x)`, `f(@move x)`) is not an attribute: it is S069E, the
// binding sites' error, with the call-site spelling as the fix-it (`&x`,
// `x`), and the argument parses on.

fn f() {
    var a = @ 5
    var b = @create
    var c = (@create)
    var d = 1
}

fn g(x: i32) {
    h(@inout x, @move x)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: attributed_expr_errors.k:10:13: error [S046E]: expected attribute name after '@'
// DIAG: attributed_expr_errors.k:11:13: error [S052E]: expected an expression after '@create'; an attribute in an expression applies to the expression that follows it
// DIAG: attributed_expr_errors.k:12:14: error [S052E]: expected an expression after '@create'
// DIAG-NOT: attributed_expr_errors.k:13
// DIAG: attributed_expr_errors.k:17:7: error [S069E]: '@inout' and '@move' are parameter passing modes; a mode can only be written on a function or closure parameter, and a call passes '&x' to an '@inout' parameter and 'x' to a '@move' one
// DIAG-NEXT: fix-it:{{.*}}:{17:7-17:13}:"&"
// DIAG-NEXT: attributed_expr_errors.k:17:17: error [S069E]
// DIAG-NEXT: fix-it:{{.*}}:{17:17-17:22}:""
// DIAG-NOT: error
