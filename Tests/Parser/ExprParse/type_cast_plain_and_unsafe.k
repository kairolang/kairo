// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: |-ExpressionStmt
// AST-NEXT: | `-TypeCastExpr -> i32
// AST-NEXT: |   `-NamedIdentExpr foo
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-TypeCastExpr unsafe -> *i32
// AST-NEXT:     `-NamedIdentExpr foo
foo as i32
foo as unsafe *i32
