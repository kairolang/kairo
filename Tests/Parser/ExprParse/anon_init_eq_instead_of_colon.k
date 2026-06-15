// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
return { .x = 10, }
// AST: ReturnStmt
// AST-NEXT: AnonInitializerExpr
// ERR: error [S054E]: expected ':' after field name in anonymous initializer
// ERR: error [S054E]: expected '}' to close anonymous initializer
