// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-BinaryOperatorExpr +
// AST-NEXT:       |-FloatingLiteralExpr 3.14
// AST-NEXT:       `-FloatingLiteralExpr 2.0
x = 3.14 + 2.0
