// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s
// CHECK: `-ExpressionStmt
// CHECK-NEXT:   `-BinaryOperatorExpr +
// CHECK-NEXT:     |-AlignOfExpr i32
// CHECK-NEXT:     `-IntegerLiteralExpr 1
alignof i32 + 1
