// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// Trailing dot with no member name at EOF: clean diagnostic, base ident survives.
a.
// AST: ExpressionStmt
// AST-NEXT: NamedIdentExpr a
// ERR: error [S052E]: expected identifier after
