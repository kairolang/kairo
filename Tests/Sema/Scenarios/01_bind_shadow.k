// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var g: i32
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: `-FunctionDecl  f(x: i32) -> i32
// AST-NEXT:   |-ParamDecl x: i32
// AST-NEXT:   `-CompoundStmt (8)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-FunctionDecl  helper(y: i32) -> i32
// AST-NEXT:     |   |-ParamDecl y: i32
// AST-NEXT:     |   `-BinaryOperatorExpr +
// AST-NEXT:     |     |-NamedIdentExpr y
// AST-NEXT:     |     `-IntegerLiteralExpr 1
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-ClassDecl Local
// AST-NEXT:     |   |-FieldDecl var next: *Local
// AST-NEXT:     |   `-FieldDecl var v: i32
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var l: Local
// AST-NEXT:     |-ExpressionStmt
// AST-NEXT:     | `-AssignOperatorExpr =
// AST-NEXT:     |   |-ChainExpr 'l.v'
// AST-NEXT:     |   | |-NamedIdentExpr l
// AST-NEXT:     |   | `-Step .v
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-NamedIdentExpr helper
// AST-NEXT:     |     `-NamedIdentExpr x
// AST-NEXT:     |-IndexedForStmt
// AST-NEXT:     | |-DeclStmt
// AST-NEXT:     | | `-VariableDecl var i
// AST-NEXT:     | |   `-IntegerLiteralExpr 0
// AST-NEXT:     | |-BinaryOperatorExpr <
// AST-NEXT:     | | |-NamedIdentExpr i
// AST-NEXT:     | | `-IntegerLiteralExpr 3
// AST-NEXT:     | |-UnaryOperatorExpr postfix ++
// AST-NEXT:     | | `-NamedIdentExpr i
// AST-NEXT:     | `-CompoundStmt (1)
// AST-NEXT:     |   `-ExpressionStmt
// AST-NEXT:     |     `-AssignOperatorExpr +=
// AST-NEXT:     |       |-NamedIdentExpr g
// AST-NEXT:     |       `-NamedIdentExpr i
// AST-NEXT:     |-IndexedForStmt
// AST-NEXT:     | |-DeclStmt
// AST-NEXT:     | | `-VariableDecl var i
// AST-NEXT:     | |   `-IntegerLiteralExpr 0
// AST-NEXT:     | |-BinaryOperatorExpr <
// AST-NEXT:     | | |-NamedIdentExpr i
// AST-NEXT:     | | `-IntegerLiteralExpr 3
// AST-NEXT:     | |-UnaryOperatorExpr postfix ++
// AST-NEXT:     | | `-NamedIdentExpr i
// AST-NEXT:     | `-CompoundStmt (1)
// AST-NEXT:     |   `-ExpressionStmt
// AST-NEXT:     |     `-AssignOperatorExpr -=
// AST-NEXT:     |       |-NamedIdentExpr g
// AST-NEXT:     |       `-NamedIdentExpr i
// AST-NEXT:     |-CompoundStmt (2)
// AST-NEXT:     | |-DeclStmt
// AST-NEXT:     | | `-VariableDecl var x
// AST-NEXT:     | |   `-IntegerLiteralExpr 10
// AST-NEXT:     | `-ExpressionStmt
// AST-NEXT:     |   `-AssignOperatorExpr +=
// AST-NEXT:     |     |-NamedIdentExpr g
// AST-NEXT:     |     `-NamedIdentExpr x
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-BinaryOperatorExpr +
// AST-NEXT:         |-NamedIdentExpr x
// AST-NEXT:         `-NamedIdentExpr g
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// EXPECT: 0 errors. `x` in inner block shadows param x (trace shows shadows).
// EXPECT: two `for var i` loops -> no redefinition.
// EXPECT: `helper` and `Local` bind (statement-scope decls), `Local` resolves as a type.
var g: i32 = 1

fn f(x: i32) -> i32 {
    fn helper(y: i32) -> i32 = y + 1

    class Local {
        var next: *Local
        var v: i32
    }

    var l: Local
    l.v = helper(x)

    for var i = 0; i < 3; i++ { g += i }
    for var i = 0; i < 3; i++ { g -= i }

    {
        var x = 10
        g += x
    }
    return x + g
}
