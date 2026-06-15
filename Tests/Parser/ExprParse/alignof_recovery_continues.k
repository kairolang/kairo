// RUN: %kairo %s --print-ast=tree 2>/dev/null | %FileCheck %s
alignof i512
// CHECK: ExpressionStmt
// CHECK-NEXT: AlignOfExpr i512
// CHECK-NOT: [S0
