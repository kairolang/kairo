// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use_transitivity() -> i32
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-CallExpr (2 args)
// AST-NEXT:         |-ChainExpr 'foo::sub'
// AST-NEXT:         | |-NamedIdentExpr foo
// AST-NEXT:         | `-Step ::sub
// AST-NEXT:         |-IntegerLiteralExpr 5
// AST-NEXT:         `-IntegerLiteralExpr 2
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// CASE 6: transitivity wall. main imports foo; foo does `priv import bar::*`.
// A private import edge is NOT an export, so bar's names (id, Box, limit,
// secret) must be ABSENT from main's overlay. foo's OWN name `sub` must be
// present. Expect: overlay has `foo` (module handle); walking foo sees `sub`
// but NOT bar's names.

import foo

fn use_transitivity() -> i32 {
    return foo::sub(5, 2)
}
