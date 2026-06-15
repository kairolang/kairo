// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
x = a++
x = a--
// AST: UnaryOperatorExpr postfix ++
// AST-NEXT: NamedIdentExpr a
// AST: UnaryOperatorExpr postfix --
// AST-NEXT: NamedIdentExpr a
