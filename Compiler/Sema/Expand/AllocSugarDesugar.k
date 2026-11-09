/// --- The Kairo Project -------------- Sema/Expand/AllocSugarDesugar.k --- ///
///
///   \brief `@create` / `@destroy` in expression position, rewritten to the
///          library calls they are sugar for, before anything
///          resolves a name.
///
///   \detail
///     Lib/builtin/base/alloc.k declares `create<T>(...args) -> *T` and
///     `destroy<T>(p: *T)`; the attributes are their spelling in the docs'
///     voice, and nothing else (allocators.mdx). So the rewrite is purely
///     syntactic and every later pass sees an ordinary call:
///
///       @create<T>(args)      create<T>(args)     (the parser built it)
///       @create T(args)       create<T>(args)     T a name, a `::` path or
///                                                 a generic application
///       @destroy<T>(p)        destroy<T>(p)       (the parser built it)
///       @destroy p            destroy(p)
///       @destroy(p)           destroy(p)
///
///     The callee is alloc.k's own `create` / `destroy`, which C++ spells
///     `::builtin::base::alloc::create<T>`, and it needs no import. A path
///     cannot say that -- `builtin::...` is not nameable in an expression,
///     and the builtin prelude does not re-export alloc.k -- so the callee
///     is minted already BOUND to the lang item (WellKnownType::Create /
///     Destroy), and N leaves a bound name alone. Two halves make the item
///     exist: DepScanner puts alloc.k in the graph of a file that writes
///     the sugar, and the driver gives that TU an import EDGE to it that
///     binds no name (so alloc.k is typed first, and a hand-written
///     `create<T>(...)` with no import is still R020E). With no lang item
///     (`--no-prelude`, a custom builtins dir) the callee is left to
///     ordinary lookup, as before. A class cannot have its own allocator
///     (SC149E), so nothing reroutes the call.
///
///     What is left alone: `@create Point{ x: 1 }` (an initializer, not a
///     call) and every other expression attribute. FeatureGateCheck
///     reports those (SC116E) as before.
///
///   Phase: EXPAND (before N: the minted callee and type argument resolve
///          as written ones do)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::LangItems::{
    LangAttrs,
    WellKnownType,
}
import AST::Node::Base::{
    Expr,
    Type,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Expressions::{
    AttributedExpr,
    CallExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Types::ChainType
import AST::Visitor::ASTWriter::ASTWriter
import Location::SourceRange::SourceRange
import Sema::SemaContext::SemaContext
import Token::Token::Token

pub class AllocSugarDesugar derives ASTWriter<AllocSugarDesugar> {
    pub var sc: *SemaContext

    fn AllocSugarDesugar(self, sc: *SemaContext) {
        self.sc  = sc
        self.ctx = sc->ctx // ASTWriter rebuilds lists in this arena.
    }

    fn run(self) {
        if self.sc->tu == &null || !self.sc->tu->has_alloc_sugar {
            return
        }

        ASTWriter<AllocSugarDesugar>::run(self, self.sc->tu)
    }

    fn transform_attributed_expr(self, n: unsafe *AttributedExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<AllocSugarDesugar>::transform_attributed_expr(self, n)
        if out != (unsafe (n as unsafe *Expr)) || n->operand == &null || n->has_args {
            return out
        }

        var nm        = self.sc->ctx->get_spelling(n->name)
        var is_create = nm == LangAttrs::create()
        if !is_create && nm != LangAttrs::destroy() {
            return out
        }

        // The generic form: the parser already built `name<T>(args)`, with
        // the attribute's token as the callee's.
        var unsafe *opd = n->operand
        if isa<CallExpr>(opd) {
            var unsafe *c   = cast<CallExpr>(opd)
            var unsafe *cid = dyn_cast<NamedIdentExpr>(c->callee)
            if cid != &null && cid->name.range == n->name.range {
                self._bind_callee(cid, is_create)
                return opd
            }
        }

        if !is_create {
            var unsafe *callee = NamedIdentExpr::create(self.sc->ctx, n->name.range, n->name)
            self._bind_callee(callee, false)
            var unsafe *dc = CallExpr::create(
                self.sc->ctx,
                n->range,
                unsafe (callee as unsafe *Expr),
            )

            var unsafe **one = self.sc->ctx->alloc_array<unsafe *Expr>(1)
            one[0] = opd
            dc->args.from_raw(one, 1)
            return dc
        }

        // `@create T(args)`: T, the callee, becomes the type argument.
        if !isa<CallExpr>(opd) {
            return out
        }

        var unsafe *call = cast<CallExpr>(opd)
        var unsafe *ty   = self._expr_as_type(call->callee)
        if ty == &null {
            return out
        }

        var unsafe *ga = self.sc->ctx->alloc_array<ChainType::GenericArg>(1)
        ga[0].name       = &null
        ga[0].name_range = SourceRange::invalid()
        ga[0].ty         = ty
        var unsafe *callee = NamedIdentExpr::create(self.sc->ctx, n->name.range, n->name)
        callee->generic_args.from_raw(ga, 1)
        self._bind_callee(callee, true)
        var unsafe *cc = CallExpr::create(self.sc->ctx, n->range, callee)
        cc->args = call->args
        return cc
    }

    /// Bind the minted (or parser-built) callee to alloc.k's create /
    /// destroy. alloc.k was typed before this TU (the driver's edge), so
    /// the lang item is filled by now; when it is not, the name stays
    /// unbound and N looks it up as written.
    priv fn _bind_callee(self, id: unsafe *NamedIdentExpr, is_create: bool) {
        if id == &null || id->is_bound() || self.sc->well_known == &null {
            return
        }

        var unsafe *d = self.sc->well_known->get(
            if (is_create) => (WellKnownType::Create) else => WellKnownType::Destroy,
        )

        if d == &null {
            return
        }

        id->resolved_decl = d
    }

    /// The type a name, a `::` path or a generic application denotes, as
    /// the type parser builds it (DeclParse::_expr_as_type, restated: that
    /// one is the parser's). A primitive (`i32`) is a one-segment chain that
    /// TypeResolve binds by token kind. Null for any other expression.
    priv fn _expr_as_type(self, e: unsafe *Expr) -> unsafe *Type {
        var segs = cxx::std::vector<ChainType::ChainSegment>()
        if isa<NamedIdentExpr>(e) {
            var unsafe *id = cast<NamedIdentExpr>(e)
            self._push(
                &segs,
                id->name,
                id->generic_args,
                e->range,
                ChainType::SegmentSeparator::None,
            )
        } else if isa<ChainExpr>(e) {
            var unsafe *ch   = cast<ChainExpr>(e)
            var unsafe *base = dyn_cast<NamedIdentExpr>(ch->base)
            if base == &null {
                return &null
            }

            self._push(
                &segs,
                base->name,
                base->generic_args,
                base->range,
                ChainType::SegmentSeparator::None,
            )

            for var i: usize = 0; i < ch->steps.size(); ++i {
                var unsafe *st = ch->steps.get(i)
                if st->access_kind != ChainExpr::AccessKind::ColonColon
                    || st->is_operator()
                    || st->name == &null {
                    return &null
                }

                self._push(
                    &segs,
                    st->name->name,
                    st->generic_args,
                    st->range,
                    ChainType::SegmentSeparator::ColonColon,
                )
            }
        } else {
            return &null
        }

        var unsafe *buf = self.sc->ctx->alloc_array<ChainType::ChainSegment>(segs.size())
        for var i: usize = 0; i < segs.size(); ++i {
            buf[i] = segs[i]
        }

        var unsafe *ct = ChainType::create(self.sc->ctx, e->range)
        ct->segments.from_raw(buf, segs.size())
        return ct
    }

    priv fn _push(self,
                  @inout out: cxx::std::vector<ChainType::ChainSegment>,
                  name:       Token,
                  args:       FrozenList<ChainType::GenericArg>,
                  range:      SourceRange,
                  sep:        ChainType::SegmentSeparator) {
        var seg = ChainType::ChainSegment{}
        seg.name          = NamedIdentExpr::create(self.sc->ctx, name.range, name)
        seg.generic_args  = args
        seg.resolved_type = &null
        seg.resolved_decl = &null
        seg.range         = range
        seg.sep           = sep
        seg.seg_kind = if (args.size() > 0) => (ChainType::SegmentKind::GenericApp)
                       else => ChainType::SegmentKind::Named
        out.push_back(seg)
    }
}
