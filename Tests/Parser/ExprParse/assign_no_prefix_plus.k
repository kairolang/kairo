// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
a=+3
// AST: AssignOperatorExpr =
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: RecoveryExpr trying: ChainExpr
// AST: IntegerLiteralExpr 3
// ERR: error [S052E]: expected expression, found '+'
