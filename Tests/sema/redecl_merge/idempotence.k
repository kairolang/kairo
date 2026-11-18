// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  one()
// AST-NEXT:   `-CompoundStmt (3)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var x
// AST-NEXT:     |   `-IntegerLiteralExpr 1
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var y
// AST-NEXT:     |   `-IntegerLiteralExpr 2
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var z
// AST-NEXT:         `-IntegerLiteralExpr 3
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS(AST)

// Not a language rule: a REGRESSION for the driver. Running sema twice
// over one TU must be a no-op the second time. This shape produced a
// bogus [overload set x3] when the same path was passed twice on one
// command line (source manager interns by path -> same fid -> sema ran
// again over an already-Checked TU, and decls were re-inserted).
//
// Growth was triangular (1, 3, 6, 10: run N appended N), so a two-run
// assertion is enough to catch a regression.
//
// EXPECT-CLEAN
// EXPECT-SEMA: <tu> declares one and only one, exactly once
// RUN TWICE: pass this path twice in one invocation; both dumps identical

fn one() {
    var x = 1
    var y = 2
    var z = 3
}
