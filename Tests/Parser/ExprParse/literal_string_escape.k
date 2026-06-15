// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// String escape sequences are resolved in the literal value.
x = "tab	here"
// AST: AssignOperatorExpr =
// AST-NEXT: NamedIdentExpr x
// AST-NEXT: StringLiteralExpr
