// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-DeclStmt
// AST-NEXT:   `-VariableDecl var a
// AST: -- 1 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R006E]:
// AST: {{.*}}: error [S052E]:
// END-GENERATED-CHECKS

macro np!() { 1 }
var a = np!(1);
// R007E parameterless, args given
