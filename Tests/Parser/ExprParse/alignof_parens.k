// RUN: %kairo %s --print-ast=tree 2>/dev/null | %FileCheck %s
(alignof i16)
// CHECK: ExpressionStmt
// CHECK-NEXT: AlignOfExpr i16
