// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-AlignOfExpr i32
// AST-NEXT:     `-AssignOperatorExpr =
// AST-NEXT:       |-BinaryOperatorExpr -
// AST-NEXT:       | |-AlignOfExpr i64
// AST-NEXT:       | `-AlignOfExpr f80
// AST-NEXT:       `-AlignOfExpr f64
alignof i32 = alignof i64 - alignof f80 = alignof f64
