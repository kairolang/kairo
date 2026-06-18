// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Assignment stays lowest: x = (a ?? b), ?? binds tighter than =.
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-BinaryOperatorExpr ??
// AST-NEXT:       |-NamedIdentExpr a
// AST-NEXT:       `-NamedIdentExpr b
x = a ?? b
