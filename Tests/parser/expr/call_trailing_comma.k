// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Trailing comma in argument list is tolerated.
// AST: `-ExpressionStmt
// AST-NEXT:   `-CallExpr (3 args)
// AST-NEXT:     |-NamedIdentExpr foo
// AST-NEXT:     |-IntegerLiteralExpr 1
// AST-NEXT:     |-IntegerLiteralExpr 2
// AST-NEXT:     `-IntegerLiteralExpr 3
foo(1, 2, 3,)
