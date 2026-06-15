// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
x = (1..10, 0..=5, ..3, y..)
// AST: TupleLiteralExpr (4)
// AST-NEXT: RangeExpr ..
// AST-NEXT: IntegerLiteralExpr 1
// AST-NEXT: IntegerLiteralExpr 10
// AST-NEXT: RangeExpr ..=
// AST-NEXT: IntegerLiteralExpr 0
// AST-NEXT: IntegerLiteralExpr 5
// AST-NEXT: RangeExpr ..
// AST-NEXT: IntegerLiteralExpr 3
// AST-NEXT: RangeExpr ..
// AST-NEXT: NamedIdentExpr y
