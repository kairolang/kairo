// RUN: %kairo %s --print-ast=tree 2>/dev/null | %FileCheck %s --check-prefix=AST
// RUN: %kairo %s --print-ast=tree 2>&1 1>/dev/null | %FileCheck %s --check-prefix=ERR
alignof "hello there"
// AST: ExpressionStmt
// AST-NEXT: AlignOfExpr <error>
// ERR: error [S053E]: expected type, found 'string'
