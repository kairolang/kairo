// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// AST: `-ReturnStmt
// AST-NEXT:   `-AnonInitializerExpr
// AST-NEXT:     `-Field .x
// AST-NEXT:       `-IntegerLiteralExpr 10
// ERR: error   [S054E]: expected '.field: value' in anonymous initializer
return { .x: 10, y: 10}
