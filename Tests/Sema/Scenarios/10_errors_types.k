// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-StructDecl S
// AST-NEXT: | `-FieldDecl var a: i32
// AST-NEXT: `-FunctionDecl  f()
// AST-NEXT:   `-CompoundStmt (3)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var y: Nope
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var z: i32::Foo
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var q
// AST-NEXT:         `-ChainExpr 'S.a'
// AST-NEXT:           |-NamedIdentExpr S
// AST-NEXT:           `-Step .a
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [R021E]:
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [R024E]:
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [R027E]:
// END-GENERATED-CHECKS(AST)

// EXPECT: "unknown type name 'Nope'" once (T).
// EXPECT: "'i32' is a primitive type; it has no members" once (T).
// EXPECT: "'.' cannot follow a type; use '::'" once (ChainBinding).
// EXPECT: phase TypesResolved or Checked, 3 errors.
struct S { var a: i32 }

fn f() {
    var y: Nope
    var z: i32::Foo
    var q = S.a
}
