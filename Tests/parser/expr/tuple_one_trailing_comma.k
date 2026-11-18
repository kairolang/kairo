// `(a,)` is not a one-element tuple: no tuple has arity one (a tuple is
// the record of its arity, and none has one field), so the trailing comma
// is an error with a fix-it that strikes it, and the parentheses group.
// The diagnostic is flushed after the tree, so it is checked last.
// RUN: { %kairo %s --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-NamedIdentExpr a
// AST: error [S054E]: a one-element tuple does not exist; remove the trailing comma to parenthesize the expression
x = (a,)
