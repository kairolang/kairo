// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-FunctionDecl  template() -> i32
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-IntegerLiteralExpr 0
// AST-NEXT: |-ClassDecl typedef
// AST-NEXT: | |-FieldDecl var signed: i32
// AST-NEXT: | `-FieldDecl var noexcept: i32
// AST-NEXT: |-FunctionDecl  ok_name(explicit: i32, __evil: i32, _Bad: i32, _lead: i32) -> i32
// AST-NEXT: | |-ParamDecl explicit: i32
// AST-NEXT: | |-ParamDecl __evil: i32
// AST-NEXT: | |-ParamDecl _Bad: i32
// AST-NEXT: | |-ParamDecl _lead: i32
// AST-NEXT: | `-CompoundStmt (3)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var friend: i32
// AST-NEXT: |   |   `-IntegerLiteralExpr 1
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var fine__here: i32
// AST-NEXT: |   |   `-IntegerLiteralExpr 2
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-NamedIdentExpr explicit
// AST-NEXT: |-EnumDecl Colors
// AST-NEXT: | |-EnumVariantDecl Red
// AST-NEXT: | `-EnumVariantDecl __protected
// AST-NEXT: |-TypeAliasDecl wchar_t = i32
// AST-NEXT: |-ModuleDecl namespace
// AST-NEXT: `-FunctionDecl  clean(a: i32, b: i32) -> i32
// AST-NEXT:   |-ParamDecl a: i32
// AST-NEXT:   |-ParamDecl b: i32
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-NamedIdentExpr a
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [SC004E]:
// AST: {{.*}}: error [SC004E]:
// AST: {{.*}}: error [SC004E]:
// AST: {{.*}}: error [SC004E]:
// AST: {{.*}}: error [SC004E]:
// AST: {{.*}}: warning [SC005W]:
// AST: {{.*}}: warning [SC005W]:
// AST: {{.*}}: warning [SC005W]:
// AST: {{.*}}: error [SC004E]:
// AST: {{.*}}: warning [SC005W]:
// AST: {{.*}}: warning [SC005W]:
// AST: {{.*}}: error [SC004E]:
// AST: {{.*}}: error [SC004E]:
// END-GENERATED-CHECKS

fn template() -> i32 { return 0 }

class typedef {
    var signed: i32;
    var noexcept: i32;
}

fn ok_name(explicit: i32, __evil: i32, _Bad: i32, _lead: i32) -> i32 {
    var friend: i32 = 1;
    var fine__here: i32 = 2;
    return explicit
}

enum Colors {
    Red,
    __protected,
}

type wchar_t = i32;

module namespace { }

fn clean(a: i32, b: i32) -> i32 { return a }
