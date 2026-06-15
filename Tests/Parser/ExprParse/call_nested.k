// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
foo(bar(baz()))
// AST: CallExpr (1 args)
// AST-NEXT: NamedIdentExpr foo
// AST-NEXT: CallExpr (1 args)
// AST-NEXT: NamedIdentExpr bar
// AST-NEXT: CallExpr (0 args)
// AST-NEXT: NamedIdentExpr baz
