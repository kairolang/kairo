// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use_selective() -> i32
// AST-NEXT:   `-CompoundStmt (3)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var a
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-NamedIdentExpr id<i32>
// AST-NEXT:     |     | `-GenericArg 'i32'
// AST-NEXT:     |     `-IntegerLiteralExpr 1
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var c
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-NamedIdentExpr Boxx<i32>
// AST-NEXT:     |     | `-GenericArg 'i32'
// AST-NEXT:     |     `-IntegerLiteralExpr 3
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-BinaryOperatorExpr +
// AST-NEXT:         |-NamedIdentExpr a
// AST-NEXT:         `-ChainExpr 'c.value'
// AST-NEXT:           |-NamedIdentExpr c
// AST-NEXT:           `-Step .value
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// CASE 1 (selective + item alias) / 11: `import bar::{id, Box as Boxx}` brings
// both names UNQUALIFIED; `Box` aliased to `Boxx`. Expect: overlay keys `id`
// (fn-set) and `Boxx` (type, resolved from source `Box`). Bare generic uses
// disambiguate via the import edge.

import bar::{id, Box as Boxx}

fn use_selective() -> i32 {
    var a = id<i32>(1)
    var c = Boxx<i32>(3)
    return a + c.value
}
