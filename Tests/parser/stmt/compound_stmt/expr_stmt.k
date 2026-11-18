// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-CompoundStmt (1)
// AST-NEXT:   `-ExpressionStmt
// AST-NEXT:     `-IntegerLiteralExpr 1
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS(AST)

{
    1
}
