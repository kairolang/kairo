// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
sizeof i256)
// AST: ExpressionStmt
// AST-NEXT: SizeOfExpr i256
// AST: ExpressionStmt
// AST-NEXT: RecoveryExpr trying: ChainExpr
// ERR: error [S052E]: expected expression, found ')'
