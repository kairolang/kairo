// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use_union() -> i32
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-CallExpr (1 args)
// AST-NEXT:         |-NamedIdentExpr id<i32>
// AST-NEXT:         | `-GenericArg 'i32'
// AST-NEXT:         `-IntegerLiteralExpr 9
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// CASE 4: same function name imported from two modules -> ONE overlay key with
// TWO fn-set targets that UNION into one overload set. NO error (function sets
// merge; only non-function targets clash). Expect: overlay key `id` with 2
// targets, both fn-set, no R016.

import bar::{id}
import baz::{id}

fn use_union() -> i32 {
    return id<i32>(9)
}
