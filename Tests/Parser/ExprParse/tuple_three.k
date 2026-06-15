// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
x = (a, b, c)
// AST: TupleLiteralExpr (3)
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: NamedIdentExpr b
// AST-NEXT: NamedIdentExpr c
