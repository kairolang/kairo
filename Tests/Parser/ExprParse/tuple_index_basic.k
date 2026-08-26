// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// A tuple index is a Step whose target is the ordinal instead of a name. It
// works through every member-access separator; `access_kind` still records
// which separator was written.
// OK-NOT: error
// AST: |-ExpressionStmt
// AST-NEXT: | `-ChainExpr 't.0'
// AST-NEXT: |   |-NamedIdentExpr t
// AST-NEXT: |   `-Step .0  tuple-index
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-ChainExpr 't.10'
// AST-NEXT: |   |-NamedIdentExpr t
// AST-NEXT: |   `-Step .10  tuple-index
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-ChainExpr 'p->0'
// AST-NEXT: |   |-NamedIdentExpr p
// AST-NEXT: |   `-Step ->0  tuple-index
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-ChainExpr 'p?.0'
// AST-NEXT: |   |-NamedIdentExpr p
// AST-NEXT: |   `-Step ?.0  tuple-index
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-ChainExpr 'p?->0'
// AST-NEXT:     |-NamedIdentExpr p
// AST-NEXT:     `-Step ?->0  tuple-index
t.0
t.10
p->0
p?.0
p?->0
