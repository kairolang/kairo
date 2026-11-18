// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-FunctionDecl  f(cond: bool)
// AST-NEXT: | |-ParamDecl cond: bool
// AST-NEXT: | `-CompoundStmt (2)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var count: i32
// AST-NEXT: |   |   `-IntegerLiteralExpr 0
// AST-NEXT: |   `-ConditionalStmt
// AST-NEXT: |     |-cond
// AST-NEXT: |     | `-NamedIdentExpr cond
// AST-NEXT: |     `-then
// AST-NEXT: |       `-CompoundStmt (1)
// AST-NEXT: |         `-DeclStmt
// AST-NEXT: |           `-VariableDecl var count: i32
// AST-NEXT: |             `-IntegerLiteralExpr 1
// AST-NEXT: `-FunctionDecl  g(cond: bool)
// AST-NEXT:   |-ParamDecl cond: bool
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl const raw: i32
// AST-NEXT:     |   `-IntegerLiteralExpr 1
// AST-NEXT:     `-ConditionalStmt
// AST-NEXT:       |-cond
// AST-NEXT:       | `-NamedIdentExpr cond
// AST-NEXT:       `-then
// AST-NEXT:         `-CompoundStmt (1)
// AST-NEXT:           `-DeclStmt
// AST-NEXT:             `-VariableDecl const raw: bool
// AST-NEXT:               `-BooleanLiteralExpr true
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: warning [R048W]:
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: note [R048N]:
// END-GENERATED-CHECKS(AST)

// NO ORACLE: Rust does not lint shadowing at all; C++ -Wshadow fires on
// every shadow regardless of type and is off by default for that reason.
// Kairo warns only on SAME-TYPE shadowing, which is the case that means
// you probably wanted an assignment.
//
// EXPECT-WARN: 4: shadow-same-type
// EXPECT-CLEAN otherwise

fn f(cond: bool) {
    var count: i32 = 0
    if cond {
        var count: i32 = 1
    }
}

fn g(cond: bool) {
    const raw: i32 = 1
    if cond {
        const raw: bool = true
    }
}
