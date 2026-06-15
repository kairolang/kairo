// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
sizeof broken(45)
// AST: ExpressionStmt
// AST-NEXT: SizeOfExpr broken
// AST: ExpressionStmt
// AST-NEXT: IntegerLiteralExpr 45
// AST-NOT: SizeOfExpr <error>
