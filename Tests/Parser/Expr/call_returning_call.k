// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Call is a repeatable postfix: foo()() is call(call(foo)).
// AST: `-ExpressionStmt
// AST-NEXT:   `-CallExpr (0 args)
// AST-NEXT:     `-CallExpr (0 args)
// AST-NEXT:       `-NamedIdentExpr foo
foo()()
