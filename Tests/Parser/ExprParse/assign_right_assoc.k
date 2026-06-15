// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
a = b = 5
// AST: AssignOperatorExpr =
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: AssignOperatorExpr =
// AST-NEXT: NamedIdentExpr b
// AST-NEXT: IntegerLiteralExpr 5
