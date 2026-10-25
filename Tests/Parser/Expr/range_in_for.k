// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  Test()
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-RangedForStmt i
// AST-NEXT:       |-RangeExpr ..
// AST-NEXT:       | |-IntegerLiteralExpr 0
// AST-NEXT:       | `-IntegerLiteralExpr 10
// AST-NEXT:       `-CompoundStmt (0)
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS(AST)

fn Test() { for i in 0..10 { } }
