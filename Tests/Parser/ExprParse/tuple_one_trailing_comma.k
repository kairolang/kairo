// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// (a,) with trailing comma is a ONE-element tuple, distinct from grouping (a).
x = (a,)
// AST: TupleLiteralExpr (1)
// AST-NEXT: NamedIdentExpr a
