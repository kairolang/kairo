// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Chained subscript is left-associative: (a[i])[j].
// AST: `-ExpressionStmt
// AST-NEXT:   `-SubscriptExpr
// AST-NEXT:     |-SubscriptExpr
// AST-NEXT:     | |-NamedIdentExpr a
// AST-NEXT:     | `-NamedIdentExpr i
// AST-NEXT:     `-NamedIdentExpr j
a[i][j]
