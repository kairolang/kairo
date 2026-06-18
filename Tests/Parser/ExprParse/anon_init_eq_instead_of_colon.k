// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// AST: `-ReturnStmt
// AST-NEXT:   `-AnonInitializerExpr
// ERR: error   [S054E]: expected ':' after field name in anonymous initializer
return { .x = 10, }
