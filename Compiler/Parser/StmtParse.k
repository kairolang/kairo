// StmtParse.k
/// --- The Kairo Project ------------------ Compiler/Parser/StmtParse.k ----- ///
///
///   Statement parsing mixin.
///
/// ------------------------------------------------------------------------- ///

import ASTNode::Base::*;

class <T> StmtParse {
    priv inline fn dyn(self) -> *T {
        return static_cast::<*T>(&self);
    }

    fn parse_stmt(self) -> *Stmt { return &null; }
}