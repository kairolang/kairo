// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
//
// Statement expression: `(` immediately followed by `{` opens one, and its
// value is the last statement of the block, which must be an ExpressionStmt.
// The block is a statement context even inside the parens, so a newline
// still ends a statement (`-u` in `b` below is its own statement, not `3 - u`).
// `}` and `)` may sit on different lines, as may `(` and `{` (`c`).
//
// Anchored on this file's TU: the prelude dumps the builtin TUs after it, and
// they parse cleanly, so an unanchored count would match their footer.
// AST: TranslationUnit '{{.*}}stmt_expr.k'
// AST-NEXT: `-FunctionDecl  Test() -> i32
// AST-NEXT:   `-CompoundStmt (5)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var a
// AST-NEXT:     |   `-StmtExpr
// AST-NEXT:     |     `-CompoundStmt (2)
// AST-NEXT:     |       |-DeclStmt
// AST-NEXT:     |       | `-VariableDecl var t
// AST-NEXT:     |       |   `-IntegerLiteralExpr 1
// AST-NEXT:     |       `-ExpressionStmt
// AST-NEXT:     |         `-BinaryOperatorExpr *
// AST-NEXT:     |           |-NamedIdentExpr t
// AST-NEXT:     |           `-IntegerLiteralExpr 2
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var b
// AST-NEXT:     |   `-StmtExpr
// AST-NEXT:     |     `-CompoundStmt (2)
// AST-NEXT:     |       |-DeclStmt
// AST-NEXT:     |       | `-VariableDecl var u
// AST-NEXT:     |       |   `-IntegerLiteralExpr 3
// AST-NEXT:     |       `-ExpressionStmt
// AST-NEXT:     |         `-UnaryOperatorExpr prefix -
// AST-NEXT:     |           `-NamedIdentExpr u
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var c
// AST-NEXT:     |   `-StmtExpr
// AST-NEXT:     |     `-CompoundStmt (1)
// AST-NEXT:     |       `-ExpressionStmt
// AST-NEXT:     |         `-BinaryOperatorExpr +
// AST-NEXT:     |           |-NamedIdentExpr a
// AST-NEXT:     |           `-NamedIdentExpr b
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var d
// AST-NEXT:     |   `-BinaryOperatorExpr +
// AST-NEXT:     |     |-StmtExpr
// AST-NEXT:     |     | `-CompoundStmt (1)
// AST-NEXT:     |     |   `-ExpressionStmt
// AST-NEXT:     |     |     `-StmtExpr
// AST-NEXT:     |     |       `-CompoundStmt (1)
// AST-NEXT:     |     |         `-ExpressionStmt
// AST-NEXT:     |     |           `-NamedIdentExpr c
// AST-NEXT:     |     `-IntegerLiteralExpr 1
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-NamedIdentExpr d
// AST-NOT: RecoveryExpr
// AST-NOT: ============== AST (tree) for fid
// AST: -- 0 error(s), 0 warning(s) --

fn Test() -> i32 {
    var a = ({ var t = 1; t * 2 })
    var b = ({
        var u = 3
        -u
    })
    var c = (
        { a + b }
    )
    var d = ({ ({ c }) }) + 1
    return d
}
