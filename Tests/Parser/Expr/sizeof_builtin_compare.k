// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s
// A builtin primitive takes no generic arguments, so `<` after `sizeof
// usize` compares (EVAL.md 4.2b); after a named type it still opens them.
// CHECK: |-ExpressionStmt
// CHECK-NEXT: | `-BinaryOperatorExpr <
// CHECK-NEXT: |   |-SizeOfExpr usize
// CHECK-NEXT: |   `-IntegerLiteralExpr 8
// CHECK: `-ExpressionStmt
// CHECK-NEXT:   `-BinaryOperatorExpr <
// CHECK-NEXT:     |-SizeOfExpr Box<i32>
// CHECK-NEXT:     `-IntegerLiteralExpr 8
sizeof usize < 8
sizeof Box<i32> < 8
