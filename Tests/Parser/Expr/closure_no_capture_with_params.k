// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  Test()
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var f
// AST-NEXT:         `-ClosureExpr ->  i32
// AST-NEXT:           |-ParamDecl x: i32
// AST-NEXT:           |-ParamDecl y: i32
// AST-NEXT:           `-CompoundStmt (1)
// AST-NEXT:             `-ReturnStmt
// AST-NEXT:               `-BinaryOperatorExpr +
// AST-NEXT:                 |-NamedIdentExpr x
// AST-NEXT:                 `-NamedIdentExpr y
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

fn Test() { var f = fn (x: i32, y: i32) -> i32 { return x + y; }; }
