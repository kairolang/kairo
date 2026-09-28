// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  Test()
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ExpressionStmt
// AST-NEXT:       `-CallExpr (2 args)
// AST-NEXT:         |-NamedIdentExpr foo
// AST-NEXT:         |-IntegerLiteralExpr 1
// AST-NEXT:         `-IntegerLiteralExpr 2
// AST: -- 2 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [S057E]: expected '}' to close block
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [S054E]: expected ')' to close function call argument list
// END-GENERATED-CHECKS

fn Test() { foo(1, 2
