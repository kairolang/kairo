// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use_aliased() -> i32
// AST-NEXT:   `-CompoundStmt (3)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var e
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-ChainExpr 'b::id<i32>'
// AST-NEXT:     |     | |-NamedIdentExpr b
// AST-NEXT:     |     | `-Step ::id<i32>
// AST-NEXT:     |     `-IntegerLiteralExpr 3
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var f
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-ChainExpr 'b::Box<i32>'
// AST-NEXT:     |     | |-NamedIdentExpr b
// AST-NEXT:     |     | `-Step ::Box<i32>
// AST-NEXT:     |     `-IntegerLiteralExpr 4
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-BinaryOperatorExpr +
// AST-NEXT:         |-NamedIdentExpr e
// AST-NEXT:         `-ChainExpr 'f.value'
// AST-NEXT:           |-NamedIdentExpr f
// AST-NEXT:           `-Step .value
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// CASE 1 (aliased): `import bar as b` rebinds the handle to `b`; original
// name `bar` is unavailable. Expect: overlay key `b` -> 1 module target.

import bar as b

fn use_aliased() -> i32 {
    var e = b::id<i32>(3)
    var f = b::Box<i32>(4)
    return e + f.value
}
