// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Maximal munch: a +++ b lexes as (a++) + b. Postfix ++ binds to a first,
// then the remaining + is the binary operator. Not a + (++b).
a +++ b
// AST: BinaryOperatorExpr +
// AST-NEXT: UnaryOperatorExpr postfix ++
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: NamedIdentExpr b
