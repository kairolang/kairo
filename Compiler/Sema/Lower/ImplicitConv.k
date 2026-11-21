/// --- The Kairo Project -------------------- Sema/Lower/ImplicitConv.k --- ///
///
/// An implicit conversion through an extension's `@implicit op as`
/// becomes the cast it stands for.
///
///   \detail
///       extend string { @implicit fn op as (const self) -> Path { ... } }
///       open(s)          ->  open(s as Path)
///       var p: Path = s  ->  var p: Path = s as Path
///
///     A member's `@implicit op as` is a C++ conversion function, which C++
///     applies at the site by itself. An extension's is a static member of
///     its scope struct, which C++ never looks up, so the call has to be in
///     the tree. X recorded where one was accepted and what it converts to
///     (SemaContext::implicit_convs / implicit_conv_targets); this pass
///     wraps each such expression in the TypeCastExpr an explicit `as` would
///     have been, and OperatorLowering and ExtensionLowering turn that into
///     the call, as they do for a written cast.
///
///     A fixed array's member, and an operator, that its slice view
///     declares (Compiler/Spec/MemberLookup.md#fixed-arrays) is reached the
///     same way, through the view: the receiver becomes the
///     ImplicitBoundaryCastExpr `var s: [T;] = a` converts with, a view over
///     the array's own storage. `a.size()` and `a.is_empty()` on one are
///     its extent, and are written as the constant.
///
///   Phase: LOWER, first: the record is keyed by the expression node, and
///   every later lowering may replace nodes.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "llvm/ADT/DenseMap.h"

import AST::DeclFacts::decl_extension_of
import AST::Node::Base::{
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
}
import AST::Node::Declarations::FunctionDecl
import AST::Node::Expressions::{
    CallExpr,
    CastMode,
    ImplicitBoundaryCastExpr,
    TypeCastExpr,
}
import AST::Node::PrimaryExpressions::ChainExpr
import AST::Node::Types::PointerType
import AST::Visitor::ASTWriter::{
    ASTWriter,
    ListBuilder,
}
import Location::SourceRange::SourceRange
import Sema::Check::ConstEval::{
    ArrayExtentCall,
    ConstEval,
}
import Sema::Lower::LowerStep::LowerStep
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}

pub class ImplicitConvLowering derives ASTWriter<ImplicitConvLowering> {
    pub var  sc:    *SemaContext
    priv var synth: LowerSynth

    fn ImplicitConvLowering(self, sc: *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.synth = LowerSynth(unsafe (sc as unsafe *SemaContext))
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        self.sc->begin_lower(LowerStep::ImplicitConv)
        if self.sc->tu == &null
            || self.sc->implicit_conv_targets.empty() && self.sc->conversion_hops == 0 {
            return
        }

        ASTWriter<ImplicitConvLowering>::run(self, self.sc->tu)
    }

    /// `b.windows(2)`, its last step a member of what `b` converts to
    /// (ChainExpr::Step::hop_conv): the chain before the step becomes the
    /// operand of the cast, and the step is read from the cast.
    ///
    ///     b.windows       ->  (b as View<T>).windows
    ///     a.b.windows     ->  (a.b as View<T>).windows
    ///     p->windows      ->  (*p as View<T>).windows
    ///
    /// Written for a member's `op as` as well as an extension's: C++ applies
    /// a conversion function to an argument, never to the object of a
    /// member access.
    pub fn transform_chain_expr(self, n: unsafe *ChainExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<ImplicitConvLowering>::transform_chain_expr(
            self,
            n,
        )

        if n->is_poisoned() || n->steps.size() == 0 {
            return out
        }

        var        k     = n->steps.size() - 1
        var unsafe *mark = n->steps.get(k)
        if mark->hop_type == &null {
            return out
        }

        var unsafe *recv = n->base
        if k > 0 {
            var unsafe *last = n->steps.get(k - 1)
            var unsafe *pre = ChainExpr::create(
                self.ctx,
                SourceRange(n->range.start, last->range.end),
                n->base,
            )

            var psteps = ListBuilder<ChainExpr::Step>(self.ctx)
            for var i: usize = 0; i < k; ++i {
                psteps.push(*n->steps.get(i))
            }

            psteps.freeze_into(&pre->steps)
            recv                 = unsafe (pre as unsafe *Expr)
            recv->expr_flags     = n->expr_flags
            recv->type_          = last->resolved_type
            recv->value_category = Expr::ValueCategory::LValue
        }

        if recv == &null || recv->type_ == &null {
            kairo::std::ice_fail(
                "ImplicitConvLowering: a member reached through a conversion has an untyped receiver; MemberTyping types every step before it",
            )
        }

        if mark->access_kind == ChainExpr::AccessKind::Arrow {
            var unsafe *pt = dyn_cast<PointerType>(canon_unqual(recv->type_))
            if pt == &null {
                kairo::std::ice_fail(
                    "ImplicitConvLowering: `->` into a member reached through a conversion on a non-pointer; ChainBinding admits the step for a pointer only",
                )
            }

            recv = self.synth.deref(recv->range, recv, pt->pointee)
        }

        var unsafe *to              = mark->hop_type
        var        c:  unsafe *Expr = &null
        if mark->hop_conv == &null {
            // A fixed array's member is its slice view's: the view over the
            // array's own storage, as `var s: [T;] = a` builds it.
            c = self._array_view(recv, to)
        } else {
            var unsafe *tc = TypeCastExpr::create(
                self.ctx,
                recv->range,
                recv,
                to,
                false,
                CastMode::Default,
            )

            tc->type_          = to
            tc->value_category = Expr::ValueCategory::RValue
            tc->resolved_op    = cast<FunctionDecl>(mark->hop_conv)
            c                  = tc
        }

        var step = *mark
        step.hop_conv    = &null
        step.hop_type    = &null
        step.access_kind = ChainExpr::AccessKind::Dot
        var unsafe *rest = ChainExpr::create(self.ctx, n->range, c)

        var rsteps = ListBuilder<ChainExpr::Step>(self.ctx)
        rsteps.push(step)
        rsteps.freeze_into(&rest->steps)
        rest->variant_decl = n->variant_decl
        var unsafe *re = unsafe (rest as unsafe *Expr)
        re->adopt_sema(n)
        return re
    }

    /// `a.size()` / `a.is_empty()` on a fixed array is its extent
    /// (ConstEval::array_extent_call): written as the constant, so neither
    /// the view nor the call is emitted, and an eval context that reads it
    /// is a C++ constant expression.
    pub fn transform_call_expr(self, n: unsafe *CallExpr) -> unsafe *Expr {
        var extent: u64 = 0
        var which = ConstEval(unsafe (self.sc as unsafe *SemaContext)).array_extent_call(
            unsafe (n as unsafe *Expr),
            &extent,
        )

        if which == ArrayExtentCall::Size {
            return self.synth.int_literal(n->range, extent, BuiltinKind::USize)
        }

        if which == ArrayExtentCall::IsEmpty {
            return self.synth.bool_literal(n->range, extent == (0 as u64))
        }

        return ASTWriter<ImplicitConvLowering>::transform_call_expr(self, n)
    }

    /// `[T; N]` `recv` viewed as the slice `view`, a value over its
    /// storage (Conversion::array_views_as); EmitIR spells it.
    priv fn _array_view(self, recv: unsafe *Expr, view: unsafe *Type) -> unsafe *Expr {
        var unsafe *c = ImplicitBoundaryCastExpr::create(
            self.ctx,
            recv->range,
            recv,
            recv->type_,
            view,
        )

        c->type_          = view
        c->value_category = Expr::ValueCategory::RValue
        return c
    }

    pub fn transform_expr(self, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<ImplicitConvLowering>::transform_expr(
            self,
            e,
        )

        if e == &null || out == &null {
            return out
        }

        var key = e as usize as u64
        // An operator's fixed-array operand, viewed (OperatorTyping's
        // resolve_user_op). Erased once written: a later walk over this
        // node must not view it again.
        var av = self.sc->array_view_operands.find(key)
        if av != self.sc->array_view_operands.end() {
            var unsafe *view = av->second
            self.sc->array_view_operands.erase(key)
            return self._array_view(out, view)
        }

        var tt = self.sc->implicit_conv_targets.find(key)
        if tt == self.sc->implicit_conv_targets.end() {
            return out
        }

        var ft = self.sc->implicit_convs.find(key)
        if ft == self.sc->implicit_convs.end() {
            return out
        }

        if decl_extension_of(ft->second) == &null && self.sc->hop_operands.count(key) == 0 {
            return out
        }

        var unsafe *to = tt->second
        var unsafe *c = TypeCastExpr::create(
            self.ctx,
            out->range,
            out,
            to,
            false,
            CastMode::Default,
        )

        c->type_          = to
        c->value_category = Expr::ValueCategory::RValue
        c->resolved_op    = ft->second
        var it = self.sc->implicit_conv_instances.find(key)
        if it != self.sc->implicit_conv_instances.end() {
            c->op_instance = it->second
        }

        // One cast per accepted conversion: a later walk over this node
        // must not wrap it again.
        self.sc->implicit_conv_targets.erase(key)
        return c
    }
}
