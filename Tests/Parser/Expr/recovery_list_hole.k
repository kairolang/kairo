// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// Hole in list literal (empty element between commas): recovers to a clean diag.
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-ListLiteralExpr (2)
// AST-NEXT:       |-IntegerLiteralExpr 1
// AST-NEXT:       `-IntegerLiteralExpr 3
// ERR: error [S052E]: expected expression, found ','
x = [1, , 3]
