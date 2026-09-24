// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  f()
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var x
// AST-NEXT:     |   `-NamedIdentExpr nope
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var w
// AST-NEXT:         `-ChainExpr 'Self::a'
// AST-NEXT:           |-NamedIdentExpr Self
// AST-NEXT:           `-Step ::a
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R020E]:
// AST: {{.*}}: error [R030E]:
// END-GENERATED-CHECKS

// EXPECT: "use of undeclared identifier 'nope'" once.
// EXPECT: "'Self' used outside of a type body" once (expression position).
// EXPECT: phase NamesResolved, 2 errors.
fn f() {
    var x = nope
    var w = Self::a
}
