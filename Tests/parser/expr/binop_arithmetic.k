// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: |-ExpressionStmt
// AST-NEXT: | `-BinaryOperatorExpr +
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-NamedIdentExpr b
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-BinaryOperatorExpr -
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-NamedIdentExpr b
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-BinaryOperatorExpr *
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-NamedIdentExpr b
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-BinaryOperatorExpr /
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-NamedIdentExpr b
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-BinaryOperatorExpr %
// AST-NEXT:     |-NamedIdentExpr a
// AST-NEXT:     `-NamedIdentExpr b
a + b
a - b
a * b
a / b
a % b
