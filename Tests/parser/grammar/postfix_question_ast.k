// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: UnaryOperatorExpr postfix ?
// AST-NEXT: `-NamedIdentExpr mem
fn Test() { var x = mem? }
