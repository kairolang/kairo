// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: |-ExpressionStmt
// AST-NEXT: | `-AssignOperatorExpr =
// AST-NEXT: |   |-NamedIdentExpr x
// AST-NEXT: |   `-BooleanLiteralExpr true
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-BooleanLiteralExpr false
x = true
x = false
