// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
x = -a + ~b * !c ^^ 2 << 3 & mask | bits
// AST: BinaryOperatorExpr |
// AST-NEXT: BinaryOperatorExpr &
// AST-NEXT: BinaryOperatorExpr 
// AST-NEXT: BinaryOperatorExpr +
// AST-NEXT: UnaryOperatorExpr prefix -
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: BinaryOperatorExpr *
// AST-NEXT: UnaryOperatorExpr prefix ~
// AST-NEXT: NamedIdentExpr b
// AST-NEXT: BinaryOperatorExpr ^^
// AST-NEXT: UnaryOperatorExpr prefix !
// AST-NEXT: NamedIdentExpr c
// AST-NEXT: IntegerLiteralExpr 2
// AST-NEXT: IntegerLiteralExpr 3
// AST-NEXT: NamedIdentExpr mask
// AST-NEXT: NamedIdentExpr bits
