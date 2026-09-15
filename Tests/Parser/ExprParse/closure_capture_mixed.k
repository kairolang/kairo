// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
//
// `|a, *b|`: unqualified names are captured by COPY, `*`-prefixed by pointer.
// `const *c` is a pointer capture the closure may not write through. A
// capture NAMES an outer binding, so the three must exist to resolve.
// AST: -- 0 error(s), 0 warning(s) --
// AST: ClosureExpr
// AST-NEXT: Capture a
// AST-NEXT: Capture *b
// AST-NEXT: Capture const *c
// AST-NOT: RecoveryExpr

fn Test() {
    var a = 1;
    var b = 2;
    var c = 3;
    var f = fn ()|a, *b, const *c| { };
}