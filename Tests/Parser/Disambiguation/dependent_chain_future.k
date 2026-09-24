// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl <T> probe3(a: T) -> i32
// AST-NEXT:   |-GenericParamDecl 'T'
// AST-NEXT:   |-ParamDecl a: T
// AST-NEXT:   `-CompoundStmt (6)
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
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var r3
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-ChainExpr 'T::static_fn<20>'
// AST-NEXT:     |     | |-NamedIdentExpr T
// AST-NEXT:     |     | `-Step ::static_fn<20>
// AST-NEXT:     |     `-IntegerLiteralExpr 30
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var r4
// AST-NEXT:     |   `-CallExpr (0 args)
// AST-NEXT:     |     `-ChainExpr 'T::some_type<i32>(1, 2, 3).get<10>'
// AST-NEXT:     |       |-CallExpr (3 args)
// AST-NEXT:     |       | |-ChainExpr 'T::some_type<i32>'
// AST-NEXT:     |       | | |-NamedIdentExpr T
// AST-NEXT:     |       | | `-Step ::some_type<i32>
// AST-NEXT:     |       | |-IntegerLiteralExpr 1
// AST-NEXT:     |       | |-IntegerLiteralExpr 2
// AST-NEXT:     |       | `-IntegerLiteralExpr 3
// AST-NEXT:     |       `-Step .get<10>
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// CONTRACT for dependent postfix chains (supersedes the old DependentChain
// design from the handoff, per the simplified-resolver decision):
//
//   In postfix-member position, `name<...>` that parses as generic
//   arguments IS generic arguments. Parenthesize to force comparison.
//
// The parse shape is type-independent and identical for every
// instantiation. The dependent resolver is then just: collect the
// instantiations of a generic fn, substitute the concrete T, type-check
// the already-shaped body, and report conformance failures at the bracket
// with the concrete T and the instantiation site. No DependentChain node,
// no un-committed brackets, no re-parse at instantiation.

fn <T> probe3(a: T) -> i32 {
    var b = &a
    var r1 = a.get<i32>(10)
    var r2 = b->get_lit<T>(20)
    var r3 = T::static_fn<20>(30)
    var r4 = T::some_type<i32>(1, 2, 3).get<10>()
    return 0
}
