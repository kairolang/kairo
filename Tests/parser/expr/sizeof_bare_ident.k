// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: |-ExpressionStmt
// AST-NEXT: | `-SizeOfExpr f
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-SizeOfExpr i8
sizeof f
sizeof i8
