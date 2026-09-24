// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// Null-coalescing operator. Was tokenized (OpQuestionQuestion) but never wired
// into the Pratt precedence table, regression guard against that gap.
// AST: `-ExpressionStmt
// AST-NEXT:   `-BinaryOperatorExpr ??
// AST-NEXT:     |-NamedIdentExpr a
// AST-NEXT:     `-NamedIdentExpr b
a ?? b
