// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-UnsafeExpr
// AST-NEXT:     `-CallExpr (0 args)
// AST-NEXT:       `-NamedIdentExpr foo
unsafe foo()
