// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
a += 3
// AST: AssignOperatorExpr +=
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: IntegerLiteralExpr 3
