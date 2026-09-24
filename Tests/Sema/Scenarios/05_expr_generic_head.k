// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-ClassDecl Box
// AST-NEXT: | |-FieldDecl var v: T
// AST-NEXT: | |-FunctionDecl  make() -> Box<T>
// AST-NEXT: | | `-CompoundStmt (1)
// AST-NEXT: | |   `-ReturnStmt
// AST-NEXT: | |     `-CallExpr (0 args)
// AST-NEXT: | |       `-NamedIdentExpr Box<T>
// AST-NEXT: | |         `-GenericArg 'T'
// AST-NEXT: | `-FunctionDecl  Box(self)
// AST-NEXT: |   |-ParamDecl self
// AST-NEXT: |   `-CompoundStmt (0)
// AST-NEXT: `-FunctionDecl  use()
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var a
// AST-NEXT:     |   `-CallExpr (0 args)
// AST-NEXT:     |     `-ChainExpr 'Box<i32>::make'
// AST-NEXT:     |       |-NamedIdentExpr Box<i32>
// AST-NEXT:     |       | `-GenericArg 'i32'
// AST-NEXT:     |       `-Step ::make
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var b
// AST-NEXT:         `-CallExpr (0 args)
// AST-NEXT:           `-ChainExpr 'Box<f64>::make'
// AST-NEXT:             |-NamedIdentExpr Box<f64>
// AST-NEXT:             | `-GenericArg 'f64'
// AST-NEXT:             `-Step ::make
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// EXPECT: 0 errors. step `::make` after `Box<i32>` head binds (Type anchor via registry).
// EXPECT: `Box<i32>::make` and `Box<f64>::make` are two RecordTypes (types section count).
class <T> Box {
    var v: T
    static fn make() -> Box<T> { return Box<T>() }
    fn Box(self) { }
}

fn use() {
    var a = Box<i32>::make()
    var b = Box<f64>::make()
}
