// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Redundant grouping parens produce no AST nodes; they only affect precedence.
((((a))))
// AST: ExpressionStmt
// AST-NEXT: NamedIdentExpr a
// AST-NOT: ParenExpr
