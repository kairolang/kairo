// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr a
// AST-NEXT:     `-CallExpr (1 args)
// AST-NEXT:       |-NamedIdentExpr call
// AST-NEXT:       `-IntegerLiteralExpr 10
a = call(10)
