// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Three-way comparison (spaceship), Comparison-tier binary operator.
// AST: `-ExpressionStmt
// AST-NEXT:   `-BinaryOperatorExpr <=>
// AST-NEXT:     |-NamedIdentExpr a
// AST-NEXT:     `-NamedIdentExpr b
a <=> b
