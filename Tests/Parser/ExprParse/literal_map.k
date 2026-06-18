// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-MapLiteralExpr (2 entries)
// AST-NEXT:       |-Entry
// AST-NEXT:       | |-StringLiteralExpr "k"
// AST-NEXT:       | `-IntegerLiteralExpr 1
// AST-NEXT:       `-Entry
// AST-NEXT:         |-StringLiteralExpr "v"
// AST-NEXT:         `-IntegerLiteralExpr 2
x = {"k": 1, "v": 2}
