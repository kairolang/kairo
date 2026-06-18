// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// AST: |-ExpressionStmt
// AST-NEXT: | `-BinaryOperatorExpr +
// AST-NEXT: |   |-NamedIdentExpr a
// AST-NEXT: |   `-RecoveryExpr trying: ChainExpr
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-IntegerLiteralExpr 3
// ERR: error   [S052E]: expected expression, found '='
a + = 3
