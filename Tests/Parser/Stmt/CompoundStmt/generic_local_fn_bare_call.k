// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
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
// END-GENERATED-CHECKS

{
fn <T> nested() {
return T()
    }
var y = nested()
}
