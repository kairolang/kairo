// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// (a) without a comma is grouping, not a tuple: produces the bare ident, no
// TupleLiteralExpr and no paren node.
x = (a)
// AST: AssignOperatorExpr =
// AST-NEXT: NamedIdentExpr x
// AST-NEXT: NamedIdentExpr a
// AST-NOT: TupleLiteralExpr
