// A malformed expression attribute is one error at the attribute, and the
// statement after it parses: no name after `@` (S046E), nothing for the
// attribute to apply to (S052E naming it, not the operand parser's
// "expected expression, found ')'" and its cascade).

fn f() {
    var a = @ 5
    var b = @create
    var c = (@create)
    var d = 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: attributed_expr_errors.k:7:13: error [S046E]: expected attribute name after '@'
// DIAG: attributed_expr_errors.k:8:13: error [S052E]: expected an expression after '@create'; an attribute in an expression applies to the expression that follows it
// DIAG: attributed_expr_errors.k:9:14: error [S052E]: expected an expression after '@create'
// DIAG-NOT: attributed_expr_errors.k:10
