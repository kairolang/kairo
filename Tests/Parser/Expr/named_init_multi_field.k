// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  Test()
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var c
// AST-NEXT:         `-NamedInitializerExpr
// AST-NEXT:           |-NamedIdentExpr Color
// AST-NEXT:           |-Field r
// AST-NEXT:           | `-IntegerLiteralExpr 255
// AST-NEXT:           |-Field g
// AST-NEXT:           | `-IntegerLiteralExpr 0
// AST-NEXT:           `-Field b
// AST-NEXT:             `-IntegerLiteralExpr 128
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R020E]:
// END-GENERATED-CHECKS

fn Test() { var c = Color { r: 255, g: 0, b: 128 }; }
