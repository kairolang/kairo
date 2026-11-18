// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-NamedInitializerExpr
// AST-NEXT:       |-NamedIdentExpr Foo
// AST-NEXT:       |-Field a
// AST-NEXT:       | `-IntegerLiteralExpr 1
// AST-NEXT:       `-Field b
// AST-NEXT:         `-NamedInitializerExpr
// AST-NEXT:           |-NamedIdentExpr Inner
// AST-NEXT:           `-Field c
// AST-NEXT:             `-IntegerLiteralExpr 2
x = Foo { a: 1, b: Inner { c: 2 } }
