// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-FunctionDecl  foo(i32)
// AST-NEXT: | `-ParamDecl i32
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var scale
// AST-NEXT: |   `-IntegerLiteralExpr 3
// AST-NEXT: `-FunctionDecl  main() -> i32
// AST-NEXT:   `-CompoundStmt (4)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var limit
// AST-NEXT:     |   `-IntegerLiteralExpr 9
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var x
// AST-NEXT:     |   `-BinaryOperatorExpr <
// AST-NEXT:     |     |-NamedIdentExpr foo
// AST-NEXT:     |     `-NamedIdentExpr limit
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var y
// AST-NEXT:     |   `-BinaryOperatorExpr <
// AST-NEXT:     |     |-NamedIdentExpr scale
// AST-NEXT:     |     `-IntegerLiteralExpr 4
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// Bug 1 regression (the damaging shape): a `<` after a known non-generic
// name with NO closing `>`-continuation must parse as a comparison, never
// as an unclosed generic-arg list. The old num_params-sentinel table
// marked every entry generic and misparsed these.

fn foo(i32)

var scale = 3

fn main() -> i32 {
    var limit = 9
    var x = foo < limit
    var y = scale < 4
    return 0
}
