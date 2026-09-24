// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var a
// AST-NEXT: `-DeclStmt
// AST-NEXT:   `-VariableDecl var b
// AST: -- 2 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R006E]:
// AST: {{.*}}: error [R006E]:
// AST: {{.*}}: error [S052E]:
// AST: {{.*}}: error [S052E]:
// END-GENERATED-CHECKS

macro two!(x, y) { x + y }
var a = two!(1);
var b = two!(1, 2, 3);
// R006E arity both directions
