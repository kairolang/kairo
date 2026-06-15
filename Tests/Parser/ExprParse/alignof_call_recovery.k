// RUN: %kairo %s --print-ast=tree 2>/dev/null | %FileCheck %s
alignof broken(45)
// CHECK: ExpressionStmt
// CHECK-NEXT: AlignOfExpr broken
// CHECK: ExpressionStmt
// CHECK-NEXT: IntegerLiteralExpr 45
// CHECK-NOT: AlignOfExpr <error>
