// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
x = true
x = false
// AST: AssignOperatorExpr =
// AST-NEXT: NamedIdentExpr x
// AST-NEXT: BooleanLiteralExpr true
// AST: AssignOperatorExpr =
// AST-NEXT: NamedIdentExpr x
// AST-NEXT: BooleanLiteralExpr false
