// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Empty braces parse as an empty set literal (not map, not block) in expr position.
x = {}
// AST: AssignOperatorExpr =
// AST-NEXT: NamedIdentExpr x
// AST-NEXT: SetLiteralExpr (0)
