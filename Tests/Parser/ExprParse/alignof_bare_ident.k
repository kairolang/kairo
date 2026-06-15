// RUN: %kairo %s --print-ast=tree 2>/dev/null | %FileCheck %s
alignof f
alignof i8
// CHECK: ExpressionStmt
// CHECK-NEXT: AlignOfExpr f
// CHECK: ExpressionStmt
// CHECK-NEXT: AlignOfExpr i8
