// NO ORACLE: C++ puts the cv-qualifier of the implicit object parameter
// in the SIGNATURE, so there the in-class const decl and the non-const
// out-of-line def are two different functions and the def matches nothing.
// Kairo forbids const overloading, so they are ONE function whose two
// links disagree about const -- which is what must be reported.
//
// This is the case that proves _same_signature ignores const for
// Kairo-authored decls: it must MATCH and then disagree, not fail to
// match and report "does not match any declaration".
//
// EXPECT-ERROR: 5: modifier-disagreement (const)

class Bar {
    fn foo(const self) -> i32
}

fn Bar::foo(self) -> i32 { return 1 }

// --- lit wiring -----------------------------------------------------------
// Kept at the BOTTOM on purpose: the EXPECT-ERROR annotation above names an
// absolute LINE NUMBER in the code, so anything inserted above the code
// silently invalidates it.

// --- lit wiring -----------------------------------------------------------
// Kept at the BOTTOM on purpose: the EXPECT-ERROR annotation above names an
// absolute LINE NUMBER in the code, so anything inserted above the code
// silently invalidates it. Do not let gen_checks.py move it back up.
// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-ClassDecl Bar
// AST-NEXT: | `-FunctionDecl  foo(const self) -> i32
// AST-NEXT: |   `-ParamDecl const self
// AST-NEXT: `-FunctionDecl  foo(self) -> i32
// AST-NEXT:   |-ParamDecl self
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 1
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [R039E]:
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: note [R039N]:
// END-GENERATED-CHECKS(AST)
