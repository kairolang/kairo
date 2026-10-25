// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-ClassDecl Pair
// AST-NEXT: | |-FieldDecl var a: T
// AST-NEXT: | `-FieldDecl var b: T
// AST-NEXT: |-ClassDecl Pair [spec=explicit <bool>]
// AST-NEXT: |-ClassDecl Pair [spec=explicit <bool>]
// AST-NEXT: | `-FieldDecl var packed: u8
// AST-NEXT: |-ClassDecl Pair [spec=explicit <i32>]
// AST-NEXT: | `-FieldDecl var x: i32
// AST-NEXT: |-ClassDecl Pair [spec=explicit <i32>]
// AST-NEXT: | `-FieldDecl var y: i32
// AST-NEXT: |-ClassDecl Late
// AST-NEXT: | `-FieldDecl var v: T
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var early
// AST-NEXT: |   `-ChainType 'Late<u8>'
// AST-NEXT: |     `-GenericArg 'u8'
// AST-NEXT: |-ClassDecl Late [spec=explicit <u8>]
// AST-NEXT: | `-FieldDecl var w: u8
// AST-NEXT: `-ClassDecl Orphan [spec=explicit <i32>]
// AST-NEXT:   `-FieldDecl var z: i32
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [R029E]:
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: note [R029N]:
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [R042E]:
// END-GENERATED-CHECKS(AST)

// EXPECT: error "redefinition of specialization 'Pair'" (two definitions for <i32>).
// EXPECT: error "explicit specialization of 'Late' after it was already instantiated".
// EXPECT: error "'Orphan' is declared as a specialization, but no primary template".
// EXPECT: fwd spec + def of Pair<bool> links silently (no error for that pair).
class <T> Pair { var a: T; var b: T }

class <> Pair<bool>;
class <> Pair<bool> { var packed: u8 }

class <> Pair<i32> { var x: i32 }
class <> Pair<i32> { var y: i32 }

class <T> Late { var v: T }
var early: Late<u8>
class <> Late<u8> { var w: u8 }

class <> Orphan<i32> { var z: i32 }
