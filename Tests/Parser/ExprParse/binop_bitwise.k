// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
a & b
a | b
a ^ b
a << b
a >> b
// AST: BinaryOperatorExpr &
// AST: BinaryOperatorExpr |
// AST: BinaryOperatorExpr ^
// AST: BinaryOperatorExpr 
// AST: BinaryOperatorExpr >>
