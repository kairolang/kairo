// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-TupleLiteralExpr (4)
// AST-NEXT:       |-RangeExpr ..
// AST-NEXT:       | |-IntegerLiteralExpr 1
// AST-NEXT:       | `-IntegerLiteralExpr 10
// AST-NEXT:       |-RangeExpr ..=
// AST-NEXT:       | |-IntegerLiteralExpr 0
// AST-NEXT:       | `-IntegerLiteralExpr 5
// AST-NEXT:       |-RangeExpr ..
// AST-NEXT:       | `-IntegerLiteralExpr 3
// AST-NEXT:       `-RangeExpr ..
// AST-NEXT:         `-NamedIdentExpr y
x = (1..10, 0..=5, ..3, y..)
