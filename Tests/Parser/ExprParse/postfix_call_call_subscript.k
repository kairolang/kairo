// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
obj.method(1)(2)[3]
// AST: SubscriptExpr
// AST-NEXT: CallExpr (1 args)
// AST-NEXT: CallExpr (1 args)
// AST-NEXT: ChainExpr 'obj.method'
// AST-NEXT: NamedIdentExpr obj
// AST-NEXT: IntegerLiteralExpr 1
// AST-NEXT: IntegerLiteralExpr 2
// AST-NEXT: IntegerLiteralExpr 3
