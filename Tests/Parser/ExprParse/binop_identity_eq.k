// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Strict identity equality, Equality-tier binary operator (distinct from ==).
// AST: `-ExpressionStmt
// AST-NEXT:   `-BinaryOperatorExpr ===
// AST-NEXT:     |-NamedIdentExpr a
// AST-NEXT:     `-NamedIdentExpr b
a === b
