// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-CallExpr (0 args)
// AST-NEXT:       `-ChainExpr 'a.b->c?.d::e'
// AST-NEXT:         |-NamedIdentExpr a
// AST-NEXT:         |-Step .b
// AST-NEXT:         |-Step ->c
// AST-NEXT:         |-Step ?.d
// AST-NEXT:         `-Step ::e
x = a.b->c?.d::e()
