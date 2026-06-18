// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// AST: |-ExpressionStmt
// AST-NEXT: | `-SizeOfExpr i256
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-RecoveryExpr trying: ChainExpr
// ERR: error   [S034E]: unexpected ')' with no matching opener
sizeof i256)
