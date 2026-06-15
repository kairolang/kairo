// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
sizeof (i64
// AST: ExpressionStmt
// AST-NEXT: SizeOfExpr i64
// ERR: error [S054E]: expected ')' after type in 'sizeof(T)'
