// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// A decimal point must be followed by a digit, so `1.` is no longer the float
// 1.0. That makes `1.foo()` a method call on an integer literal. The leading-dot
// float in value position (`= .5`) is unaffected: only what precedes the dot
// decides, and `=` cannot end a postfix chain.
// OK-NOT: error
// AST: |-ExpressionStmt
// AST-NEXT: | `-CallExpr (0 args)
// AST-NEXT: |   `-ChainExpr '1.foo'
// AST-NEXT: |     |-IntegerLiteralExpr 1
// AST-NEXT: |     `-Step .foo
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-AssignOperatorExpr =
// AST-NEXT: |   |-NamedIdentExpr x
// AST-NEXT: |   `-FloatingLiteralExpr 0.5
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr y
// AST-NEXT:     `-FloatingLiteralExpr 0.5
1.foo()
x = .5
y = 0.5
