// RUN: %kairo %s --print-ast=tree 2>/dev/null | %FileCheck %s --check-prefix=AST
// RUN: %kairo %s --print-ast=tree 2>&1 1>/dev/null | %FileCheck %s --check-prefix=ERR
alignof 1 + 2
// AST: ExpressionStmt
// AST-NEXT: BinaryOperatorExpr +
// AST-NEXT: AlignOfExpr <error>
// AST-NEXT: IntegerLiteralExpr 2
// ERR: error [S053E]: expected type, found 'integer'
