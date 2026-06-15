// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Prefix * (deref) is valid as a binary operand: a + (*b).
a + * b
// AST: BinaryOperatorExpr +
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: UnaryOperatorExpr prefix *
// AST-NEXT: NamedIdentExpr b
