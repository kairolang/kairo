// RUN: %kairo %s --print-ast=tree 2>/dev/null | %FileCheck %s
// CHECK: |-ExpressionStmt
// CHECK-NEXT: | `-AlignOfExpr broken
// CHECK-NEXT: `-ExpressionStmt
// CHECK-NEXT:   `-IntegerLiteralExpr 45
alignof broken(45)
