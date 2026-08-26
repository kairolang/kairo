// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// Indices chain with each other and with named steps, and a tuple index in
// index position must not fuse into one float: `t.0.1` is two ordinals.
// OK-NOT: error
// AST: |-ExpressionStmt
// AST-NEXT: | `-ChainExpr 't.0.1'
// AST-NEXT: |   |-NamedIdentExpr t
// AST-NEXT: |   |-Step .0  tuple-index
// AST-NEXT: |   `-Step .1  tuple-index
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-ChainExpr 't.0.field'
// AST-NEXT: |   |-NamedIdentExpr t
// AST-NEXT: |   |-Step .0  tuple-index
// AST-NEXT: |   `-Step .field
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-CallExpr (0 args)
// AST-NEXT: |   `-ChainExpr '(1, 2).0.bar'
// AST-NEXT: |     |-TupleLiteralExpr (2)
// AST-NEXT: |     | |-IntegerLiteralExpr 1
// AST-NEXT: |     | `-IntegerLiteralExpr 2
// AST-NEXT: |     |-Step .0  tuple-index
// AST-NEXT: |     `-Step .bar
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-ChainExpr 'arr[0].1'
// AST-NEXT: |   |-SubscriptExpr
// AST-NEXT: |   | |-NamedIdentExpr arr
// AST-NEXT: |   | `-IntegerLiteralExpr 0
// AST-NEXT: |   `-Step .1  tuple-index
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-RangeExpr ..
// AST-NEXT:     |-ChainExpr 't.0'
// AST-NEXT:     | |-NamedIdentExpr t
// AST-NEXT:     | `-Step .0  tuple-index
// AST-NEXT:     `-ChainExpr 't.1'
// AST-NEXT:       |-NamedIdentExpr t
// AST-NEXT:       `-Step .1  tuple-index
t.0.1
t.0.field
(1, 2).0.bar()
arr[0].1
t.0..t.1
