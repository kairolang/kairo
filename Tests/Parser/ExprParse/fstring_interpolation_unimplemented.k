// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// XFAIL: *
// f-string interpolation is not parsed yet, the body is currently emitted as a
// flat StringLiteralExpr with {n}/{m+1} as literal text. Interpolation has its
// own Python-like grammar; will be implemented before Stage 1 ships, after sema
// has started. These CHECK lines describe the TARGET shape: embedded exprs must
// parse. When this starts XPASSing, interpolation works, update/remove XFAIL.
f"n is {n} and {m+1}"
// AST: InterpolatedStringExpr
// AST: NamedIdentExpr n
// AST: BinaryOperatorExpr +
// AST-NEXT: NamedIdentExpr m
// AST-NEXT: IntegerLiteralExpr 1
