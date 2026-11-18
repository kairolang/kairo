// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
//
// f-string interpolation: each `{...}` hole is parsed as a real expression and
// hangs off the literal as a child, in source order. The node is still a
// StringLiteralExpr (no dedicated interpolated-string node); the holes being
// children is what distinguishes it from a plain literal, so the -NEXT chain
// below is the assertion -- a regression to flat text drops every child.
// Anchored on this file's TU so the builtin TUs dumped after it cannot match.
// AST: TranslationUnit '{{.*}}fstring_interpolation.k'
// AST-NEXT: ExpressionStmt
// AST-NEXT: StringLiteralExpr "n is {n} and {m+1}"
// AST-NEXT: NamedIdentExpr n
// AST-NEXT: BinaryOperatorExpr +
// AST-NEXT: NamedIdentExpr m
// AST-NEXT: IntegerLiteralExpr 1
// AST-NEXT: -- 0 error(s), 0 warning(s) --
f"n is {n} and {m+1}"
