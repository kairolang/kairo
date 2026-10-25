// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-DeclStmt
// AST-NEXT:   `-VariableDecl var a
// AST-NEXT:     `-BinaryOperatorExpr +
// AST-NEXT:       |-BinaryOperatorExpr +
// AST-NEXT:       | |-IntegerLiteralExpr 1
// AST-NEXT:       | `-IntegerLiteralExpr 2
// AST-NEXT:       `-RecoveryExpr trying: ChainExpr
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [R013E]:
// END-GENERATED-CHECKS(AST)

macro bad!(x) { x }
var a = bad!(1) + bad!(2) + nosuch!();
// poison recovery: exactly ONE error (the nosuch), no S052E cascade,
// and bad! still expands correctly around it
