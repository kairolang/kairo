// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Chained cast is left-associative: ((a as i32) as i64).
a as i32 as i64
// AST: TypeCastExpr -> i64
// AST-NEXT: TypeCastExpr -> i32
// AST-NEXT: NamedIdentExpr a
