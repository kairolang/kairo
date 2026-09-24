// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
//
// `|*|`: capture everything by POINTER. Kairo has no reference captures --
// a capture is a pointer the closure stores, so AMT tracks its lifetime and
// provenance like any other pointer. See Spec/Docs/closures.md.
// AST: -- 0 error(s), 0 warning(s) --
// AST: ClosureExpr
// AST-NEXT: Capture *
// AST-NOT: RecoveryExpr

fn Test() { var f = fn ()|*| { }; }