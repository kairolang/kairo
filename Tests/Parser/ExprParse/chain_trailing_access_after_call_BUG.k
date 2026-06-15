// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// BUG: a trailing access after a call/subscript is dropped as a node and
// survives only in the ChainExpr label string. Here .c has no node: the outer
// ChainExpr (a.b().c) directly wraps only the CallExpr, with nothing modeling
// the .c field access. A sema pass cannot resolve .c because there is no node.
// Correct behavior: .c must be a real access node over the call result.
// This test SHOULD FAIL until the chain representation models every access.
a.b().c
// AST: ChainExpr
// The trailing access must appear as structure, not only in a label string.
// Once fixed, tighten this to the real node shape.
// AST: CallExpr (0 args)
// AST-NEXT: ChainExpr 'a.b'
// AST-NEXT: NamedIdentExpr a
// AST: NamedIdentExpr c
