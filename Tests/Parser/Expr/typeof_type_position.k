// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  Test()
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var x
// AST-NEXT:     |   `-IntegerLiteralExpr 42
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var y: typeof(...)
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS(AST)

fn Test() { var x = 42; var y: typeof x = 100; }
