// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
x = if a || b || c { 10 } else { 20 }
// AST: AssignOperatorExpr =
// AST-NEXT: NamedIdentExpr x
// AST-NEXT: IfExpr
// AST-NEXT: cond
// AST-NEXT: BinaryOperatorExpr ||
// AST-NEXT: BinaryOperatorExpr ||
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: NamedIdentExpr b
// AST-NEXT: NamedIdentExpr c
// AST-NEXT: then
// AST-NEXT: IntegerLiteralExpr 10
// AST-NEXT: else
// AST-NEXT: IntegerLiteralExpr 20
