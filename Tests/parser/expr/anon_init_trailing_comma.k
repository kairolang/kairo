// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ReturnStmt
// AST-NEXT:   `-AnonInitializerExpr
// AST-NEXT:     `-Field .x
// AST-NEXT:       `-IntegerLiteralExpr 10
return { .x: 10, }
