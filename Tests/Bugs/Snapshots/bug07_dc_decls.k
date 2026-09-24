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
// AST-NEXT: `-ClassDecl Point
// AST-NEXT:   |-FieldDecl var x: i32
// AST-NEXT:   |-FieldDecl var y: i32
// AST-NEXT:   `-FunctionDecl  dist() -> f64
// AST-NEXT:     `-CompoundStmt (1)
// AST-NEXT:       `-ExpressionStmt
// AST-NEXT:         `-FloatingLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

class Point {
    var x: i32
    var y: i32
    fn dist() -> f64 { 0.0 }
}
