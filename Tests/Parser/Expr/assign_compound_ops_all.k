// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: |-ExpressionStmt
// AST-NEXT: | `-AssignOperatorExpr -=
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-IntegerLiteralExpr 3
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-AssignOperatorExpr *=
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-NamedIdentExpr b
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-AssignOperatorExpr <<=
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-IntegerLiteralExpr 2
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-AssignOperatorExpr >>=
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-IntegerLiteralExpr 2
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-AssignOperatorExpr &=
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-AssignOperatorExpr |=
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-AssignOperatorExpr ^=
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-AssignOperatorExpr %=
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-IntegerLiteralExpr 2
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr /=
// AST-NEXT:     |-NamedIdentExpr a
// AST-NEXT:     `-IntegerLiteralExpr 2
a -= 3
a *= b
a <<= 2
a >>= 2
a &= 1
a |= 1
a ^= 1
a %= 2
a /= 2
