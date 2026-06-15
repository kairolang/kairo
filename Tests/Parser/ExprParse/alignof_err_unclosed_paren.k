// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
alignof (i64
// AST: ExpressionStmt
// AST-NEXT: AlignOfExpr i64
// ERR: error [S019E]: unclosed ')' opened here
// ERR: error [S054E]: expected ')' after type in 'alignof(T)'
