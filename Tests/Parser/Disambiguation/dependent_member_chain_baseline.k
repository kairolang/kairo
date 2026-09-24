// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl <T> probe(a: T) -> i32
// AST-NEXT:   |-GenericParamDecl 'T'
// AST-NEXT:   |-ParamDecl a: T
// AST-NEXT:   `-CompoundStmt (4)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var b
// AST-NEXT:     |   `-UnaryOperatorExpr prefix &
// AST-NEXT:     |     `-NamedIdentExpr a
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var r1
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-ChainExpr 'a.get<i32>'
// AST-NEXT:     |     | |-NamedIdentExpr a
// AST-NEXT:     |     | `-Step .get<i32>
// AST-NEXT:     |     `-IntegerLiteralExpr 10
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var r2
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-ChainExpr 'b->get_lit<T>'
// AST-NEXT:     |     | |-NamedIdentExpr b
// AST-NEXT:     |     | `-Step ->get_lit<T>
// AST-NEXT:     |     `-IntegerLiteralExpr 20
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// BASELINE (pre-DependentChain): dependent member chains chains rooted
// at a T-typed receiver. No DependentChain node exists yet; the `<` after
// a member is committed by the step-level tentative parse
// (_try_step_generic_args). These checks pin that baseline so changes to
// dependent-shape parsing are caught. When DependentChain lands, these
// expectations move to dependent_chain_future.k's.
//
// NOTE deep checks are intentionally loose (no exact chain-title
// strings): if this fails after a rebuild, diff against --print-ast=tree
// by hand before touching the expectations.

fn <T> probe(a: T) -> i32 {
    var b = &a
    var r1 = a.get<i32>(10)
    var r2 = b->get_lit<T>(20)
    return 0
}
