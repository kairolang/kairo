// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
sizeof i32 + 1
// AST: ExpressionStmt
// AST-NEXT: BinaryOperatorExpr +
// AST-NEXT: SizeOfExpr i32
// AST-NEXT: IntegerLiteralExpr 1
// AST-NOT: SizeOfExpr <error>
