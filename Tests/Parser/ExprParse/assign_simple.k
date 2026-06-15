// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
a = 2
// AST: AssignOperatorExpr =
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: IntegerLiteralExpr 2
