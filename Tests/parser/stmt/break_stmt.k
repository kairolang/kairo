// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  caseX()
// AST-NEXT:   `-CompoundStmt (4)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var a
// AST-NEXT:     |   `-IntegerLiteralExpr 5
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var b
// AST-NEXT:     |   `-IntegerLiteralExpr 3
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var c
// AST-NEXT:     |   `-IntegerLiteralExpr 2
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var q
// AST-NEXT:         `-BinaryOperatorExpr >
// AST-NEXT:           |-BinaryOperatorExpr <
// AST-NEXT:           | |-NamedIdentExpr a
// AST-NEXT:           | `-NamedIdentExpr b
// AST-NEXT:           `-NamedIdentExpr c
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [SC067E]:
// END-GENERATED-CHECKS(AST)

fn caseX() {
    var a = 5;
    var b = 3;
    var c = 2;
    var q = a < b > (c);
}
