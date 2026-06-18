// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// ?? binds LOOSER than ||: a ?? (b || c), not (a ?? b) || c. Binding ?? tighter
// would force its left operand to be bool and defeat the T? unwrap purpose.
// AST: `-ExpressionStmt
// AST-NEXT:   `-BinaryOperatorExpr ??
// AST-NEXT:     |-NamedIdentExpr a
// AST-NEXT:     `-BinaryOperatorExpr ||
// AST-NEXT:       |-NamedIdentExpr b
// AST-NEXT:       `-NamedIdentExpr c
a ?? b || c
