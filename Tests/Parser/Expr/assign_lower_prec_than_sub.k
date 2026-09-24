// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr a
// AST-NEXT:     `-AssignOperatorExpr =
// AST-NEXT:       |-BinaryOperatorExpr -
// AST-NEXT:       | |-NamedIdentExpr b
// AST-NEXT:       | `-IntegerLiteralExpr 8
// AST-NEXT:       `-IntegerLiteralExpr 5
a = b - 8 = 5
