// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
x = {1, 2}
// AST: SetLiteralExpr (2)
// AST-NEXT: IntegerLiteralExpr 1
// AST-NEXT: IntegerLiteralExpr 2
