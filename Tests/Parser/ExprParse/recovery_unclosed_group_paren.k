// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// Unclosed grouping paren: inner expression is recovered, diagnostic emitted.
(a + b
// AST: BinaryOperatorExpr +
// AST-NEXT: NamedIdentExpr a
// AST-NEXT: NamedIdentExpr b
// ERR: error [S019E]: unclosed ')' opened here
