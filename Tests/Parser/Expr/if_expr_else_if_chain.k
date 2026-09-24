// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  Test()
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var x
// AST-NEXT:         `-IfExpr
// AST-NEXT:           |-cond
// AST-NEXT:           | `-NamedIdentExpr a
// AST-NEXT:           |-then
// AST-NEXT:           | `-IntegerLiteralExpr 1
// AST-NEXT:           |-else-if
// AST-NEXT:           | |-NamedIdentExpr b
// AST-NEXT:           | `-IntegerLiteralExpr 2
// AST-NEXT:           `-else
// AST-NEXT:             `-IntegerLiteralExpr 3
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R020E]:
// AST: {{.*}}: error [R020E]:
// END-GENERATED-CHECKS

fn Test() { var x = if a { 1 } else if b { 2 } else { 3 }; }
