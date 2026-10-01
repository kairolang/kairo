// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
//
// A block used as an expression on the right-hand side of a binding. The
// block is written parenthesised, `({ ... })`: the parens are what put `{` in
// expression position as a block rather than a set literal, and the block
// parses as a StmtExpr whose CompoundStmt carries the statements, with the
// last expression statement as the value.
//
// Asserted: it parses with no errors, the initializer of `x` is that StmtExpr,
// and nothing in this file was mistaken for a set literal or recovered from.
// Anchored on this file's TU: the prelude dumps the builtin TUs too, and they
// parse cleanly, so an unanchored error-count check could match THEIR footer
// and the negative checks would stop covering this file at all.
// AST: TranslationUnit '{{.*}}block_expr_as_rhs.k'
// AST-NOT: SetLiteralExpr
// AST-NOT: RecoveryExpr
// AST: VariableDecl var x
// AST-NEXT: StmtExpr
// AST-NEXT: CompoundStmt (2)
// AST-NOT: SetLiteralExpr
// AST-NOT: RecoveryExpr
// AST-NOT: ============== AST (tree) for fid
// AST: -- 0 error(s), 0 warning(s) --

fn main() -> i32 {
    var x = ({
        var t = 1
        t * 2
    })
    
    return x
}
