/// --- The Kairo Project ------------------- Codegen/Emit/EmitExprs.k ----- ///
///
///   \brief Expression emission. M2 scope: integer literals, identifier
///          references, binary operators, calls.
///
///   \par Literals are emitted verbatim
///     An integer literal is emitted as the bytes the user wrote. No
///     separator stripping, no suffix rewriting, no canonicalization.
///
///     That work is real and it has to happen somewhere   `1_000_000u32` is
///     not valid C++   but it needs the literal's semantic value and its
///     resolved type to decide the target spelling, and it can OVERFLOW,
///     which means it can diagnose. Sema's Lower/ stage does it and stamps
///     the canonical text on the node.
///
///     When that lands, the emitter reads the stamped spelling and routes it
///     through TokenSink::create_int. It still will not compute
///     one. The arena/ExpansionLoc plumbing behind that call is location
///     machinery and stays here; the DECISION never does.
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
import AST::Node::Base::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;

class EmitExprs {
    priv var _cg: obs::<CodegenContext>;

    default fn EmitExprs(self);

    fn EmitExprs(self, cg: *CodegenContext) {
        self._cg = cg;
    }

    fn emit(self, e: *Expr) {
        std::ICE(e != &null, "EmitExprs: null expr reached codegen");

        switch e->kind {
            case ExprKind::IntegerLiteralExpr {
                // Borrowed literal: the span IS the spelling, so synth
                // satisfies the literal rule for free. A literal whose C++
                // text differs from its source bytes is Lower/'s to
                // canonicalize, and arrives here via create_int.
                self._cg->sink->synth(
                    cast::<IntegerLiteralExpr>(e)->token,
                    clang::tok::numeric_constant);
            }
            case ExprKind::NamedIdentExpr {
                self._cg->sink->create(cast::<NamedIdentExpr>(e)->name);
            }
            case ExprKind::BinaryOperatorExpr {
                self._binary(cast::<BinaryOperatorExpr>(e));
            }
            case ExprKind::CallExpr {
                self._call(cast::<CallExpr>(e));
            }
            default {
                std::ICE(false,
                    "EmitExprs: expression kind not supported at M2");
            }
        }
    }

    /// `lhs op rhs`. The operator token is emitted through punct_kind, which
    /// is a 1:1 lexical map   an unmapped kind means Lower/ left a Kairo-only
    /// operator in the tree and CodegenContext ICEs there, not here.
    priv fn _binary(self, n: *BinaryOperatorExpr) {
        self.emit(n->lhs);
        self._cg->sink->create(n->op_token);
        self.emit(n->rhs);
    }

    /// `callee(a, b)`. CallExpr does not retain its paren or comma tokens, so
    /// all three families are synthesized: `(` against the first byte of the
    /// call, each `,` against the last byte of the argument it follows, `)`
    /// against the last byte of the call. Every synthesized caret then sits
    /// inside the construct a C++ user would expect it to blame.
    priv fn _call(self, n: *CallExpr) {
        var sink = self._cg->sink;

        self.emit(n->callee);
        sink->synth_at_end(n->callee->range, clang::tok::l_paren);

        for var i: usize = 0; i < n->args.size(); ++i {
            if i > 0 {
                sink->synth_at_end((*(n->args.get(i - 1)))->range, clang::tok::comma);
            }
            self.emit(*(n->args.get(i)));
        }

        sink->synth_at_end(n->range, clang::tok::r_paren);
    }
}
