// CHARACTERIZATION SNAPSHOT -- NOT A SPECIFICATION.
//
// This file is a reproducer for a reported issue, and the checks below were
// GENERATED FROM CURRENT COMPILER OUTPUT. They record what the compiler does
// today so a change is noticed; they do NOT assert that what it does is right.
// The filename says what was reported to be wrong with it.
//
// If you are fixing that issue: expect this test to fail, and replace the
// generated block with the behaviour you intend (or XFAIL it, as
// B3-*.k and B8-*.k already are). Do not "fix" it by regenerating.
//
// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl <T> probe(a: T) -> i32
// AST-NEXT:   |-GenericParamDecl 'T'
// AST-NEXT:   |-ParamDecl a: T
// AST-NEXT:   `-CompoundStmt (5)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var b
// AST-NEXT:     |   `-UnaryOperatorExpr prefix &
// AST-NEXT:     |     `-NamedIdentExpr a
// AST-NEXT:     |-ExpressionStmt
// AST-NEXT:     | `-CallExpr (1 args)
// AST-NEXT:     |   |-ChainExpr 'a.get<i32>'
// AST-NEXT:     |   | |-NamedIdentExpr a
// AST-NEXT:     |   | `-Step .get<i32>
// AST-NEXT:     |   `-IntegerLiteralExpr 10
// AST-NEXT:     |-ExpressionStmt
// AST-NEXT:     | `-CallExpr (1 args)
// AST-NEXT:     |   |-ChainExpr 'b->get_lit<T>'
// AST-NEXT:     |   | |-NamedIdentExpr b
// AST-NEXT:     |   | `-Step ->get_lit<T>
// AST-NEXT:     |   `-IntegerLiteralExpr 20
// AST-NEXT:     |-ExpressionStmt
// AST-NEXT:     | `-CallExpr (1 args)
// AST-NEXT:     |   |-ChainExpr 'T::static_fn<20>'
// AST-NEXT:     |   | |-NamedIdentExpr T
// AST-NEXT:     |   | `-Step ::static_fn<20>
// AST-NEXT:     |   `-IntegerLiteralExpr 30
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

/// PROBE, not a regression test: documents what the parser currently does
/// with dependent postfix chains (chains rooted in a generic-param type).
/// DependentChain (handoff section C) is NOT implemented no node marks
/// these as instantiation-dependent, and every `<...>` bracket below is
/// being committed by the tentative parse instead of deferred.
///
/// What SHOULD eventually happen (settled design):
///   - the whole chain rooted at a T-typed receiver becomes ONE
///     DependentChain node, every `<...>` stored un-committed
///   - instantiation resolves each bracket left-to-right against the
///     then-concrete type; both-parses-valid -> hard error at the bracket
///
/// Run: kairo Tests/Bugs/Snapshots/bug14_dependent_chain_probe.k --print-ast=tree

fn <T> probe(a: T) -> i32 {
    var b = &a

    // receiver `a` has type T: dependent member chain. Currently the `<`
    // after `get` is decided by the tentative parse, NOT marked dependent.
    a.get<i32>(10)

    // through a pointer, with the enclosing T as the generic ARG.
    b->get_lit<T>(20)

    // T-rooted static path with a const generic arg. `T::` is a dependent
    // type-path; `<20>` in expression position.
    T::static_fn<20>(30)

    return 0
}
