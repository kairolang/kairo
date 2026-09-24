// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-FunctionDecl  id(x: i32) -> i32
// AST-NEXT: | |-ParamDecl x: i32
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-BinaryOperatorExpr +
// AST-NEXT: |       |-NamedIdentExpr x
// AST-NEXT: |       `-IntegerLiteralExpr 1
// AST-NEXT: `-FunctionDecl  use_shadowing() -> i32
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-CallExpr (1 args)
// AST-NEXT:         |-NamedIdentExpr id
// AST-NEXT:         `-IntegerLiteralExpr 3
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// CASE 8: shadowing, not ambiguity. main defines its OWN `id`, and also
// imports bar's `id`. Both exist: the local decl in the TU's frozen table, the
// import in the overlay. NO error from phase I (local-vs-import is shadowing;
// unqualified lookup consults the overlay LAST, so the local wins). Ambiguity
// is strictly overlay-vs-overlay. Expect: overlay key `id` present (1 fn-set
// target from bar); local `id` in the TU symbol table; no diagnostic.

import bar::{id}

fn id(x: i32) -> i32 {
    return x + 1
}

fn use_shadowing() -> i32 {
    return id(3)
}
