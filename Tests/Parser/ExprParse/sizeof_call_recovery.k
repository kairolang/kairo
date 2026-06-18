// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: |-ExpressionStmt
// AST-NEXT: | `-SizeOfExpr broken
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-IntegerLiteralExpr 45
sizeof broken(45)
