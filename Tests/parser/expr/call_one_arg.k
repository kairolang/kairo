// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-CallExpr (1 args)
// AST-NEXT:     |-NamedIdentExpr foo
// AST-NEXT:     `-IntegerLiteralExpr 1
foo(1)
