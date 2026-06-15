// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// Hole in list literal (empty element between commas): recovers to a clean diag.
x = [1, , 3]
// AST: ListLiteralExpr (1)
// AST-NEXT: IntegerLiteralExpr 1
// ERR: error [S054E]: expected ']' to close array literal
