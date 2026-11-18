// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-DeclStmt
// AST-NEXT:   `-VariableDecl var a
// AST: -- 1 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [R006E]:
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [S052E]:
// END-GENERATED-CHECKS(AST)

macro np!() { 1 }
var a = np!(1);
// R007E parameterless, args given
