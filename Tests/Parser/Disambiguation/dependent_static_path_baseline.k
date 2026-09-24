// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl <T> probe2() -> i32
// AST-NEXT:   |-GenericParamDecl 'T'
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var r
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-ChainExpr 'T::static_fn<20>'
// AST-NEXT:     |     | |-NamedIdentExpr T
// AST-NEXT:     |     | `-Step ::static_fn<20>
// AST-NEXT:     |     `-IntegerLiteralExpr 30
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// BASELINE (pre-DependentChain): T-rooted static path with a const
// generic argument. `T::` is a dependent type-path; nothing marks it
// dependent yet the `::` step's generic args commit via the step
// tentative parse (T is not in the DisambigTable, and generic params are
// not yet bound into LexicalScope).

fn <T> probe2() -> i32 {
    var r = T::static_fn<20>(30)
    return 0
}
