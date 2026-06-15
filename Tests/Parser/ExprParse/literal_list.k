// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
x = [1, 2, 3]
// AST: ListLiteralExpr (3)
// AST-NEXT: IntegerLiteralExpr 1
// AST-NEXT: IntegerLiteralExpr 2
// AST-NEXT: IntegerLiteralExpr 3
