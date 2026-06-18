// RUN: %kairo %s --print-ast=tree 2>/dev/null | %FileCheck %s
// CHECK: `-ExpressionStmt
// CHECK-NEXT:   `-AlignOfExpr i512
alignof i512
