// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
sizeof i512
// AST: ExpressionStmt
// AST-NEXT: SizeOfExpr i512
// AST-NOT: [S0
