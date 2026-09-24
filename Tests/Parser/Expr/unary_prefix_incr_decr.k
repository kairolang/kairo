// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: |-ExpressionStmt
// AST-NEXT: | `-AssignOperatorExpr =
// AST-NEXT: |   |-NamedIdentExpr x
// AST-NEXT: |   `-UnaryOperatorExpr prefix ++
// AST-NEXT: |     `-NamedIdentExpr a
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-AssignOperatorExpr =
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-UnaryOperatorExpr prefix --
// AST-NEXT:       `-NamedIdentExpr a
x = ++a
x = --a
