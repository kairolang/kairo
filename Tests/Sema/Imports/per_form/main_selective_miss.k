// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use_miss() -> i32
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-CallExpr (1 args)
// AST-NEXT:         |-NamedIdentExpr id<i32>
// AST-NEXT:         | `-GenericArg 'i32'
// AST-NEXT:         `-IntegerLiteralExpr 7
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R015E]:
// END-GENERATED-CHECKS

// CASE 2: selective import of a name that does NOT exist in the source module.
// `nonexistent` is not declared in bar. Expect: R015 "not declared in the
// imported module" emitted HERE (phase I, sole home). `id` still folds fine.

import bar::{id, nonexistent}

fn use_miss() -> i32 {
    return id<i32>(7)
}
