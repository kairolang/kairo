// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// A pure access run coalesces into one ChainExpr over the base ident.
a.b.c.d.e.f
// AST: ChainExpr 'a.b.c.d.e.f'
// AST-NEXT: NamedIdentExpr a
