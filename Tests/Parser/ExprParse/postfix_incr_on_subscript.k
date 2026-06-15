// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
x = arr[i + 1]++
// AST: UnaryOperatorExpr postfix ++
// AST-NEXT: SubscriptExpr
// AST-NEXT: NamedIdentExpr arr
// AST-NEXT: BinaryOperatorExpr +
// AST-NEXT: NamedIdentExpr i
// AST-NEXT: IntegerLiteralExpr 1
