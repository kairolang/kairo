// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
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
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [SC064E]:
// AST: {{.*}}/bar.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]:
// AST: {{.*}}/baz.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]:
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: note [I900N]:
// END-GENERATED-CHECKS(AST)

// CASE 4: same function name imported from two modules -> ONE overlay key with
// TWO fn-set targets that UNION into one overload set. NO error (function sets
// merge; only non-function targets clash). Expect: overlay key `id` with 2
// targets, both fn-set, no R016.

import bar::{id}
import baz::{id}

fn use_union() -> i32 {
    return id<i32>(9)
}
