// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
a = call(10)
// AST: AssignOperatorExpr =
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: CallExpr (1 args)
// AST-NEXT: NamedIdentExpr call
// AST-NEXT: IntegerLiteralExpr 10
