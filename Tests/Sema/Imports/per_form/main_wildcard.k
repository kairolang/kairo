// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use_wildcard() -> i32
// AST-NEXT:   `-CompoundStmt (4)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var a
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-NamedIdentExpr id<i32>
// AST-NEXT:     |     | `-GenericArg 'i32'
// AST-NEXT:     |     `-IntegerLiteralExpr 1
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var c
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-NamedIdentExpr Box<i32>
// AST-NEXT:     |     | `-GenericArg 'i32'
// AST-NEXT:     |     `-IntegerLiteralExpr 3
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var e
// AST-NEXT:     |   `-BinaryOperatorExpr <
// AST-NEXT:     |     |-NamedIdentExpr limit
// AST-NEXT:     |     `-IntegerLiteralExpr 3
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-BinaryOperatorExpr +
// AST-NEXT:         |-NamedIdentExpr a
// AST-NEXT:         `-ChainExpr 'c.value'
// AST-NEXT:           |-NamedIdentExpr c
// AST-NEXT:           `-Step .value
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// CASE 1 (wildcard) / 3 (priv fact) / 11: `import bar::*` brings every top-level
// name UNQUALIFIED, non-pub included. Expect overlay keys: `id` (fn-set, pub),
// `Box` (type, pub), `limit` (type, pub), and `secret` (fn-set, PRIV  the fact
// N will later read to emit "exists but priv"). Bare `id<i32>`/`Box<i32>`
// disambiguate as generic; `limit < 3` stays a comparison (negative control).

import bar::*

fn use_wildcard() -> i32 {
    var a = id<i32>(1)
    var c = Box<i32>(3)
    var e = limit < 3
    return a + c.value
}
