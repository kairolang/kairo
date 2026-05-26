// DeclParse.k
/// --- The Kairo Project ------------------ Compiler/Parser/DeclParse.k ----- ///
///
///   Declaration parsing mixin.
///
/// ------------------------------------------------------------------------- ///

import ASTNode::Base::*;

class <T> DeclParse {
    priv inline fn dyn(self) -> *T {
        return static_cast::<*T>(&self);
    }

    fn parse_decl(self) -> *Decl { return &null; }
}