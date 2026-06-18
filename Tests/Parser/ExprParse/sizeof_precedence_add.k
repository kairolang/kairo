// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-BinaryOperatorExpr +
// AST-NEXT:     |-SizeOfExpr i32
// AST-NEXT:     `-IntegerLiteralExpr 1
sizeof i32 + 1
