// RUN: %kairo %s --print-ast=tree 2>/dev/null | %FileCheck %s
alignof i32 + 1
// CHECK: ExpressionStmt
// CHECK-NEXT: BinaryOperatorExpr +
// CHECK-NEXT: AlignOfExpr i32
// CHECK-NEXT: IntegerLiteralExpr 1
// CHECK-NOT: AlignOfExpr <error>
