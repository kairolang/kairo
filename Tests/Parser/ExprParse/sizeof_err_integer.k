// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
sizeof 1 + 2
// AST: ExpressionStmt
// AST-NEXT: BinaryOperatorExpr +
// AST-NEXT: SizeOfExpr <error>
// AST-NEXT: IntegerLiteralExpr 2
// ERR: error [S053E]: expected type, found 'integer'
