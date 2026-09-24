// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-CompoundStmt (1)
// AST-NEXT:   `-LoopStmt
// AST-NEXT:     `-CompoundStmt (1)
// AST-NEXT:       `-DeclStmt
// AST-NEXT:         `-VariableDecl var x
// AST-NEXT:           `-IntegerLiteralExpr 1
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

{
loop {
var x = 1
    }
}
