// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// `.*` `->*` `?.*` `?->*` are binary operators at their own precedence level,
// not access separators: the RHS is a full expression, not an id-expression.
// They bind tighter than every other binary operator (including `^^`) and
// looser than unary, and they are left-associative.
// OK-NOT: error
// AST: |-ExpressionStmt
// AST-NEXT: | `-BinaryOperatorExpr +
// AST-NEXT: |   |-BinaryOperatorExpr .*
// AST-NEXT: |   | |-NamedIdentExpr a
// AST-NEXT: |   | `-NamedIdentExpr p
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-BinaryOperatorExpr ^^
// AST-NEXT: |   |-BinaryOperatorExpr ->*
// AST-NEXT: |   | |-NamedIdentExpr a
// AST-NEXT: |   | `-NamedIdentExpr p
// AST-NEXT: |   `-IntegerLiteralExpr 2
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-BinaryOperatorExpr .*
// AST-NEXT: |   |-BinaryOperatorExpr .*
// AST-NEXT: |   | |-NamedIdentExpr a
// AST-NEXT: |   | `-NamedIdentExpr p
// AST-NEXT: |   `-NamedIdentExpr q
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-BinaryOperatorExpr ?.*
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-NamedIdentExpr p
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-BinaryOperatorExpr ?->*
// AST-NEXT:     |-NamedIdentExpr a
// AST-NEXT:     `-NamedIdentExpr p
a.*p + 1
a->*p ^^ 2
a.*p.*q
a?.*p
a?->*p
