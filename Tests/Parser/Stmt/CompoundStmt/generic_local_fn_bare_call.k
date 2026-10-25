// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-CompoundStmt (2)
// AST-NEXT:   |-DeclStmt
// AST-NEXT:   | `-FunctionDecl <T> nested()
// AST-NEXT:   |   |-GenericParamDecl 'T'
// AST-NEXT:   |   `-CompoundStmt (1)
// AST-NEXT:   |     `-ReturnStmt
// AST-NEXT:   |       `-CallExpr (0 args)
// AST-NEXT:   |         `-NamedIdentExpr T
// AST-NEXT:   `-DeclStmt
// AST-NEXT:     `-VariableDecl var y
// AST-NEXT:       `-CallExpr (0 args)
// AST-NEXT:         `-NamedIdentExpr nested
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [SC063E]:
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: note [I900N]:
// END-GENERATED-CHECKS(AST)

{
fn <T> nested() {
return T()
    }
var y = nested()
}
