// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
(sizeof i16)
// AST: ExpressionStmt
// AST-NEXT: SizeOfExpr i16
