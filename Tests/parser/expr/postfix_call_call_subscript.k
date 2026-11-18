// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-SubscriptExpr
// AST-NEXT:     |-CallExpr (1 args)
// AST-NEXT:     | |-CallExpr (1 args)
// AST-NEXT:     | | |-ChainExpr 'obj.method'
// AST-NEXT:     | | | |-NamedIdentExpr obj
// AST-NEXT:     | | | `-Step .method
// AST-NEXT:     | | `-IntegerLiteralExpr 1
// AST-NEXT:     | `-IntegerLiteralExpr 2
// AST-NEXT:     `-IntegerLiteralExpr 3
obj.method(1)(2)[3]
