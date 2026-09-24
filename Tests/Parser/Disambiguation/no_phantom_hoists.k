// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  main() -> i32
// AST-NEXT:   `-CompoundStmt (4)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var a
// AST-NEXT:     |   `-IntegerLiteralExpr 0
// AST-NEXT:     |-IndexedForStmt
// AST-NEXT:     | |-DeclStmt
// AST-NEXT:     | | `-VariableDecl var phantom: i32
// AST-NEXT:     | |   `-IntegerLiteralExpr 0
// AST-NEXT:     | |-BinaryOperatorExpr <
// AST-NEXT:     | | |-NamedIdentExpr phantom
// AST-NEXT:     | | `-IntegerLiteralExpr 10
// AST-NEXT:     | |-UnaryOperatorExpr prefix ++
// AST-NEXT:     | | `-NamedIdentExpr phantom
// AST-NEXT:     | `-CompoundStmt (1)
// AST-NEXT:     |   `-ExpressionStmt
// AST-NEXT:     |     `-AssignOperatorExpr =
// AST-NEXT:     |       |-NamedIdentExpr a
// AST-NEXT:     |       `-BinaryOperatorExpr +
// AST-NEXT:     |         |-NamedIdentExpr a
// AST-NEXT:     |         `-IntegerLiteralExpr 1
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var z
// AST-NEXT:     |   `-BinaryOperatorExpr <
// AST-NEXT:     |     |-NamedIdentExpr a
// AST-NEXT:     |     `-IntegerLiteralExpr 3
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// Bug 2 regression: a statement-position binding (for-header) must not be
// hoisted into the DisambigTable. Observable in the tree -- if `phantom` had
// been hoisted as generic (old indexer + old sentinel), `phantom < 3`
// after the loop would misparse as generic args.

fn main() -> i32 {
    var a = 0
    
    for var phantom: i32 = 0; phantom < 10; ++phantom {
        a = a + 1
    }

    var z = a < 3
    return 0
}
