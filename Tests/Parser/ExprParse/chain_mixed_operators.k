// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
x = a.b->c?.d::e()
// AST: CallExpr (0 args)
// AST-NEXT: ChainExpr 'a.b->c?.d::e'
// AST-NEXT: NamedIdentExpr a
