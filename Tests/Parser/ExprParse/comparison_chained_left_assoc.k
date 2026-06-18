// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Chained comparison is syntactically legal and left-associative: (a < b) < c.
// The resulting bool < c is a SEMA type error, not a parse error.
// AST: `-ExpressionStmt
// AST-NEXT:   `-BinaryOperatorExpr <
// AST-NEXT:     |-BinaryOperatorExpr <
// AST-NEXT:     | |-NamedIdentExpr a
// AST-NEXT:     | `-NamedIdentExpr b
// AST-NEXT:     `-NamedIdentExpr c
a < b < c
