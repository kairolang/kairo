// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-CallExpr (1 args)
// AST-NEXT:     |-NamedIdentExpr foo
// AST-NEXT:     `-CallExpr (1 args)
// AST-NEXT:       |-NamedIdentExpr bar
// AST-NEXT:       `-CallExpr (0 args)
// AST-NEXT:         `-NamedIdentExpr baz
foo(bar(baz()))
