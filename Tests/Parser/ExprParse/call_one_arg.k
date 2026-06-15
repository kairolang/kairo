// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
foo(1)
// AST: CallExpr (1 args)
// AST-NEXT: NamedIdentExpr foo
// AST-NEXT: IntegerLiteralExpr 1
