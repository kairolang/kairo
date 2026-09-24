// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-TypeAliasDecl Meters = f64
// AST-NEXT: |-TypeAliasDecl Mat = {{\[\[}}T]]
// AST-NEXT: |-TypeAliasDecl A = B
// AST-NEXT: |-TypeAliasDecl B = A
// AST-NEXT: |-ModuleDecl M
// AST-NEXT: | |-StructDecl Inner
// AST-NEXT: | | `-FieldDecl var q: i32
// AST-NEXT: | `-TypeAliasDecl X = Inner
// AST-NEXT: `-FunctionDecl  use(m: Meters, g: Mat<i32>, i: M::X)
// AST-NEXT:   |-ParamDecl m: Meters
// AST-NEXT:   |-ParamDecl g: Mat<i32>
// AST-NEXT:   |-ParamDecl i: M::X
// AST-NEXT:   `-CompoundStmt (0)
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R035E]:
// END-GENERATED-CHECKS

// EXPECT: exactly one error: "type alias 'A' is defined in terms of itself" with B as a note.
// EXPECT: `Meters` canonical == f64; `Mat<i32>` marked instantiation-dependent, no error.
// EXPECT: `M::Inner` via alias `M::X` resolves inside module M.
type Meters = f64
type <T> Mat = [[T]]

type A = B
type B = A

module M {
    struct Inner { var q: i32 }
    type X = Inner
}

fn use(m: Meters, g: Mat<i32>, i: M::X) { }
