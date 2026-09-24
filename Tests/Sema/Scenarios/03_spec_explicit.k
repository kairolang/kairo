// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-ClassDecl Box
// AST-NEXT: | `-FieldDecl var items: [T]
// AST-NEXT: |-ClassDecl Box [spec=explicit <bool>]
// AST-NEXT: | `-FieldDecl var bits: u8
// AST-NEXT: |-ExtensionDecl Box<T>
// AST-NEXT: | `-FunctionDecl  describe(self) -> i32
// AST-NEXT: |   |-ParamDecl self
// AST-NEXT: |   `-IntegerLiteralExpr 0
// AST-NEXT: `-FunctionDecl  use()
// AST-NEXT:   `-CompoundStmt (5)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var b
// AST-NEXT:     |   `-ChainType 'Box<bool>'
// AST-NEXT:     |     `-GenericArg 'bool'
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var c
// AST-NEXT:     |   `-ChainType 'Box<i32>'
// AST-NEXT:     |     `-GenericArg 'i32'
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var k
// AST-NEXT:     |   `-ChainExpr 'b.bits'
// AST-NEXT:     |     |-NamedIdentExpr b
// AST-NEXT:     |     `-Step .bits
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var d
// AST-NEXT:     |   `-CallExpr (0 args)
// AST-NEXT:     |     `-ChainExpr 'b.describe'
// AST-NEXT:     |       |-NamedIdentExpr b
// AST-NEXT:     |       `-Step .describe
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var e
// AST-NEXT:         `-ChainExpr 'c.items'
// AST-NEXT:           |-NamedIdentExpr c
// AST-NEXT:           `-Step .items
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// EXPECT: 0 errors. `b.bits` binds (member of the EXPLICIT spec, not the primary).
// EXPECT: `b.describe()` binds via the primary's extension `extend <T> Box<T>`.
// EXPECT: `c.items` binds through the implicit instantiation -> pattern walk.
class <T> Box {
    var items: [T]
}

class <> Box<bool> {
    var bits: u8
}

extend <T> Box<T> {
    fn describe(self) -> i32 = 0
}

fn use() {
    var b: Box<bool>
    var c: Box<i32>
    var k = b.bits
    var d = b.describe()
    var e = c.items
}
