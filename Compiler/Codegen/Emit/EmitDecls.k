/// --- The Kairo Project ------------------- Codegen/Emit/EmitDecls.k ----- ///
///
///   \brief Declaration emission. M2 scope: free functions with a block body.
///
///   \par THE reorder
///     Kairo:  fn main() -> i32 { ... }
///     C++:    int main() { ... }
///
///     The return type moves from trailing position to leading and `fn`
///     vanishes. This is codegen's job and not sema's, because it is not a
///     translation of anything   nothing is renamed, nothing is chosen,
///     nothing can fail. It is the C++ surface syntax for a FunctionDecl. It
///     is also why codegen cannot be a linear walk of the token stream, which
///     is the entire reason this layer exists.
///
///     Location consequence: the leading return type borrows the Kairo RETURN
///     TYPE's span (`i32` at offset 13), not `fn`'s. A diagnostic about the
///     return type then blames `i32`, which is what the user wrote. Emitting
///     it at `fn`'s offset would blame two bytes that mean something else.
///
///   \par What this emitter refuses
///     Operators, generics, and an absent return type are all ICEs, and none
///     of them are "M3 emitter work". They are things Lower/ must resolve
///     before codegen sees the tree:
///
///       - `fn op +`     -> a FunctionDecl whose name Token is the interned
///                          `operator+`, borrowing the op token's span.
///       - `fn op in`    -> TWO FunctionDecls named `begin` and `end`. One
///                          Kairo decl becoming two C++ decls is a tree
///                          transformation; codegen emits decls, it does not
///                          invent them.
///       - `fn Foo(self)` in `class Foo` -> ctor form. Recognizing it needs
///                          the enclosing type, which is name lookup.
///       - no return type -> Lower/ materializes the void type node. Codegen
///                          inferring `void` from a null pointer is inference,
///                          and inference is sema.
///
///     Every one of those is a decision with a wrong answer available. This
///     file has no way to produce a diagnostic when it guesses wrong, so it
///     does not guess.
///
///   Import law: CodegenContext only. Reach the sink through cg->sink.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Codegen::CodegenContext::*;
import Codegen::Emit::EmitTypes::*;
import Codegen::Emit::EmitStmts::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;

class EmitDecls {
    priv var _cg:    obs::<CodegenContext>;
    priv var _types: EmitTypes;
    priv var _stmts: EmitStmts;

    fn EmitDecls(self, cg: *CodegenContext) {
        self._cg    = cg;
        self._types = EmitTypes(cg);
        self._stmts = EmitStmts(cg);
    }

    fn emit(self, d: *Decl) {
        std::ICE(d != &null, "EmitDecls: null decl reached codegen");
        std::ICE(d->kind != DeclKind::RecoveryDecl,
            "EmitDecls: poisoned node reached codegen   sema gate failure");

        switch d->kind {
            case DeclKind::FunctionDecl { self._function(cast::<FunctionDecl>(d)); }
            default {
                std::ICE(false, "EmitDecls: decl kind not supported at M2");
            }
        }
    }

    /// `fn NAME(params) -> RET { body }`  ->  `RET NAME(params) { body }`
    priv fn _function(self, n: *FunctionDecl) {
        std::ICE(!n->is_operator,
            "EmitDecls: operator decl reached codegen; Lower/ must rewrite it "
            "into a plain FunctionDecl carrying its C++ name");
        std::ICE(n->generic_params.is_empty(),
            "EmitDecls: generic function reached codegen; Lower/ must "
            "monomorphize or emit the template form");
        std::ICE(n->body_kind == FnBodyKind::Block,
            "EmitDecls: only block-bodied functions at M2; Lower/ must rewrite "
            "an expression body into a block");
        std::ICE(n->return_type != &null,
            "EmitDecls: function with no return type reached codegen; Lower/ "
            "must materialize the explicit type node   codegen does not infer");

        var sink = self._cg->sink;

        // 1. Return type, LEADING. Borrows the Kairo return type's own span.
        self._types.emit(n->return_type);

        // 2. Name, verbatim from its source bytes.
        sink->create(n->name);

        // 3. Parameter list. M2: empty only. The parens are synthesized
        //    against the name token, so a diagnostic about the signature
        //    blames the function name rather than a byte nobody wrote.
        std::ICE(n->params.is_empty(), "EmitDecls: parameters are M3");
        sink->synth_at_end(n->name.range, clang::tok::l_paren);
        sink->synth_at_end(n->name.range, clang::tok::r_paren);

        // 4. Body.
        self._stmts.emit_block(n->body_block);
    }
}
