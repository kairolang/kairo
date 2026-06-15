// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// ?? is right-associative: a ?? (b ?? c). Each ?? defaults to everything on
// its right; the rightmost operand is the final fallback.
a ?? b ?? c
// AST: BinaryOperatorExpr ??
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: BinaryOperatorExpr ??
// AST-NEXT: NamedIdentExpr b
// AST-NEXT: NamedIdentExpr c
