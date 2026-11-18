// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s
// CHECK: `-ExpressionStmt
// CHECK-NEXT:   `-AlignOfExpr i16
(alignof i16)
