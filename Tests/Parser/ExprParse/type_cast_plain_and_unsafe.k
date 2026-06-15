// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
foo as i32
foo as unsafe *i32
// AST: TypeCastExpr -> i32
// AST-NEXT: NamedIdentExpr foo
// AST: TypeCastExpr unsafe -> *i32
// AST-NEXT: NamedIdentExpr foo
