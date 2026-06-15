// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
foo()...
// AST: PackExpansionExpr
// AST-NEXT: CallExpr (0 args)
// AST-NEXT: NamedIdentExpr foo
