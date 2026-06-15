// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
sizeof "hello there"
// AST: ExpressionStmt
// AST-NEXT: SizeOfExpr <error>
// ERR: error [S053E]: expected type, found 'string'
