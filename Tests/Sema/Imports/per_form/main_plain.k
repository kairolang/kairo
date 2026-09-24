// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use_plain() -> i32
// AST-NEXT:   `-CompoundStmt (3)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var c
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-ChainExpr 'bar::id<i32>'
// AST-NEXT:     |     | |-NamedIdentExpr bar
// AST-NEXT:     |     | `-Step ::id<i32>
// AST-NEXT:     |     `-IntegerLiteralExpr 3
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var d
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-ChainExpr 'bar::Box<i32>'
// AST-NEXT:     |     | |-NamedIdentExpr bar
// AST-NEXT:     |     | `-Step ::Box<i32>
// AST-NEXT:     |     `-IntegerLiteralExpr 4
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-BinaryOperatorExpr +
// AST-NEXT:         |-NamedIdentExpr c
// AST-NEXT:         `-ChainExpr 'd.value'
// AST-NEXT:           |-NamedIdentExpr d
// AST-NEXT:           `-Step .value
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// CASE 1/11 (plain): `import bar` binds the module handle; bar::foo is
// qualified. Also case 11: bare `<` after a qualified segment disambiguates
// as generic via the chain-step path. Expect: overlay key `bar` -> 1 module
// target (src fid = bar), and the AST shows generic call/type nodes.

import bar

fn use_plain() -> i32 {
    var c = bar::id<i32>(3)
    var d = bar::Box<i32>(4)
    return c + d.value
}
