// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// A pure access run coalesces into one ChainExpr over the base ident.
// AST: `-ExpressionStmt
// AST-NEXT:   `-ChainExpr 'a.b.c.d.e.f'
// AST-NEXT:     |-NamedIdentExpr a
// AST-NEXT:     |-Step .b
// AST-NEXT:     |-Step .c
// AST-NEXT:     |-Step .d
// AST-NEXT:     |-Step .e
// AST-NEXT:     `-Step .f
a.b.c.d.e.f
