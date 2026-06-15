// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
sizeof f
sizeof i8
// AST: ExpressionStmt
// AST-NEXT: SizeOfExpr f
// AST: ExpressionStmt
// AST-NEXT: SizeOfExpr i8
