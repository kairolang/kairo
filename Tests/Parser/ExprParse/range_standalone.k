// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Range as a standalone expression (not wrapped in a tuple).
x = 0..10
// AST: AssignOperatorExpr =
// AST-NEXT: NamedIdentExpr x
// AST-NEXT: RangeExpr ..
// AST-NEXT: IntegerLiteralExpr 0
// AST-NEXT: IntegerLiteralExpr 10
