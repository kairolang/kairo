// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Chained subscript is left-associative: (a[i])[j].
a[i][j]
// AST: SubscriptExpr
// AST-NEXT: SubscriptExpr
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: NamedIdentExpr i
// AST-NEXT: NamedIdentExpr j
