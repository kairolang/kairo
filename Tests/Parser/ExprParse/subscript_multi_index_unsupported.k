// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// Multi-index subscript a[i, j] is NOT supported; only single-index a[i].
// Overload sig is fn op [](self, idx) so adding multi later is non-breaking.
// When multi-index lands, update this test to expect the two-index shape.
// AST: `-ExpressionStmt
// AST-NEXT:   `-SubscriptExpr
// AST-NEXT:     |-NamedIdentExpr a
// AST-NEXT:     `-NamedIdentExpr i
// ERR: error   [S054E]: expected ']' after index expression
a[i, j]
