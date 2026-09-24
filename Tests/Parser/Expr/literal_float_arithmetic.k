// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-BinaryOperatorExpr +
// AST-NEXT:       |-FloatingLiteralExpr 3.14
// The printer renders the PARSED VALUE, not the source spelling, so `2.0`
// prints as `2` (and `1e3` would print as `1000`). The node kind is what
// carries floatness here, not the text.
// AST-NEXT:       `-FloatingLiteralExpr 2
x = 3.14 + 2.0
