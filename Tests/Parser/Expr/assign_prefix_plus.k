// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR --allow-empty
//
// `a=+3` is `a = (+3)`: unary `+` is a prefix operator (Spec/Docs/
// operators.md, the operator table and precedence level 4), so the `+` after
// `=` opens the right-hand side instead of being an unexpected token. Only
// syntax errors are ruled out: `a` is undeclared, which is Sema's R020E.
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr a
// AST-NEXT:     `-UnaryOperatorExpr prefix +
// AST-NEXT:       `-IntegerLiteralExpr 3
// AST-NEXT: -- 0 error(s), 0 warning(s) --
// ERR-NOT: error [S
a=+3
