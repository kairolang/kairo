// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  Test()
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var x
// AST-NEXT:         `-BinaryOperatorExpr ??
// AST-NEXT:           |-NamedIdentExpr a
// AST-NEXT:           `-BinaryOperatorExpr ??
// AST-NEXT:             |-NamedIdentExpr b
// AST-NEXT:             `-NamedIdentExpr c
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [R020E]:
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [R020E]:
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [R020E]:
// END-GENERATED-CHECKS(AST)

fn Test() { var x = a ?? b ?? c; }
