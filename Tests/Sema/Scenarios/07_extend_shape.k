// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-ExtensionDecl [T]
// AST-NEXT: | `-FunctionDecl  total(self) -> i32
// AST-NEXT: |   |-ParamDecl self
// AST-NEXT: |   `-IntegerLiteralExpr 0
// AST-NEXT: |-ExtensionDecl i32
// AST-NEXT: | `-FunctionDecl  twice(self) -> i32
// AST-NEXT: |   |-ParamDecl self
// AST-NEXT: |   `-BinaryOperatorExpr *
// AST-NEXT: |     |-NamedIdentExpr self
// AST-NEXT: |     `-IntegerLiteralExpr 2
// AST-NEXT: `-FunctionDecl  use(v: [i32], n: i32)
// AST-NEXT:   |-ParamDecl v: [i32]
// AST-NEXT:   |-ParamDecl n: i32
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var a
// AST-NEXT:     |   `-CallExpr (0 args)
// AST-NEXT:     |     `-ChainExpr 'v.total'
// AST-NEXT:     |       |-NamedIdentExpr v
// AST-NEXT:     |       `-Step .total
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var b
// AST-NEXT:         `-CallExpr (0 args)
// AST-NEXT:           `-ChainExpr 'n.twice'
// AST-NEXT:             |-NamedIdentExpr n
// AST-NEXT:             `-Step .twice
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// EXPECT: 0 errors. `v.total()` binds via `extend <T> [T]` (shape-keyed).
// EXPECT: `n.twice()` binds via `extend i32` (exact canonical).
extend <T> [T] {
    fn total(self) -> i32 = 0
}

extend i32 {
    fn twice(self) -> i32 = self * 2
}

fn use(v: [i32], n: i32) {
    var a = v.total()
    var b = n.twice()
}
