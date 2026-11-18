// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s
// CHECK: |-ExpressionStmt
// CHECK-NEXT: | `-AlignOfExpr f
// CHECK-NEXT: `-ExpressionStmt
// CHECK-NEXT:   `-AlignOfExpr i8
alignof f
alignof i8
