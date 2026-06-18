// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// C-style ternary (?:) is NOT a grammar construct. Conditional expressions use
// the block form: if cond { e } else { e }. The ? is postfix-only (optional/try).
// CHECK: |-ExpressionStmt
// CHECK-NEXT: | `-NamedIdentExpr a
// CHECK-NEXT: |-ExpressionStmt
// CHECK-NEXT: | `-RecoveryExpr trying: ChainExpr
// CHECK-NEXT: |-RecoveryStmt trying: LabeledStmt
// CHECK-NEXT: `-ExpressionStmt
// CHECK-NEXT:   `-NamedIdentExpr c
// ERR: error   [S052E]: expected expression, found '?'
a ? b : c
