// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=CHECK
// C-style ternary (?:) is NOT a grammar construct. Conditional expressions use
// the block form: if cond { e } else { e }. The ? is postfix-only (optional/try).
//
// `a ? b : c` therefore parses as the postfix `a?`, followed by `b : c` - which
// the statement layer tries as a label and rejects. The ternary is still an
// error; it is simply no longer the `?` itself that is unparseable.
// CHECK: |-ExpressionStmt
// CHECK-NEXT: | `-UnaryOperatorExpr postfix ?
// CHECK-NEXT: |   `-NamedIdentExpr a
// CHECK-NEXT: |-RecoveryStmt trying: LabeledStmt
// CHECK-NEXT: `-ExpressionStmt
// CHECK-NEXT:   `-NamedIdentExpr c
// ERR: error [S059E]: a label may only be applied to a loop
a ? b : c
