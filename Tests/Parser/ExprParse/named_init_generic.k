// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
Foo<i32>{ a: 1 }
// AST: NamedInitializerExpr
// AST-NEXT: NamedIdentExpr Foo<i32>
// AST-NEXT: Field a
// AST-NEXT: IntegerLiteralExpr 1
