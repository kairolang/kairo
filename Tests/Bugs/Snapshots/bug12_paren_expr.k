// CHARACTERIZATION SNAPSHOT -- NOT A SPECIFICATION.
//
// This file is a reproducer for a reported issue, and the checks below were
// GENERATED FROM CURRENT COMPILER OUTPUT. They record what the compiler does
// today so a change is noticed; they do NOT assert that what it does is right.
// The filename says what was reported to be wrong with it.
//
// If you are fixing that issue: expect this test to fail, and replace the
// generated block with the behaviour you intend (or XFAIL it, as
// B3-*.k and B8-*.k already are). Do not "fix" it by regenerating.
//
// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  main()
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-ExpressionStmt
// AST-NEXT:     | `-CallExpr (1 args)
// AST-NEXT:     |   |-NamedIdentExpr foo
// AST-NEXT:     |   `-NamedIdentExpr bar
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var x
// AST-NEXT:         `-IntegerLiteralExpr 1
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R020E]:
// AST: {{.*}}: error [R020E]:
// END-GENERATED-CHECKS

fn main() {
    foo((bar))
    var x = (((1)))
}
