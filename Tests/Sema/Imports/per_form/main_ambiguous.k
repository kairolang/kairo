// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use_ambiguous() -> i32
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R016E]:
// END-GENERATED-CHECKS

// CASE 5: same TYPE name imported from two modules -> ONE overlay key with TWO
// non-function targets -> AMBIGUOUS import. Expect: R016 emitted HERE (sole
// home), once, when the key tips to >=2 non-function targets. The overlay dump
// marks the `Box` key [AMBIGUOUS].

import bar::{Box}
import baz::{Box}

fn use_ambiguous() -> i32 {
    return 0
}
