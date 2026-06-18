// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-TupleLiteralExpr (3)
// AST-NEXT:       |-NamedIdentExpr a
// AST-NEXT:       |-NamedIdentExpr b
// AST-NEXT:       `-NamedIdentExpr c
x = (a, b, c)
