// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Negative literal is prefix-minus over a positive magnitude, NOT a signed
// literal token. The lexer does not fold the sign into the integer.
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-UnaryOperatorExpr prefix -
// AST-NEXT:       `-IntegerLiteralExpr 42
x = -42
