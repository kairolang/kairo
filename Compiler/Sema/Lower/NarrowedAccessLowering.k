/// --- The Kairo Project -------------- Sema/Lower/NarrowedAccessLowering.k --- ///
///
///   \brief Every narrowed read of a nullable becomes a call of the
///          Nullable's unchecked `__value()`.
///
///   \detail
///     NULLABLE.md §4, §5 step 3. The nullness analysis (Sema/Type/
///     NullnessFlow.k) typed each read it PROVED non-null as `T` and marked
///     it; this pass needs no analysis of its own, it only spells the mark:
///
///       a narrowed name          x               ->  x.__value()
///       a narrowed field path    o.cache   (T)   ->  o.cache.__value()
///       a path read through it   o.cache.v       ->  o.cache.__value().v
///       a pointer through it     p->m()          ->  p.__value()->m()
///
///     A mark sits on a NamedIdentExpr (narrowed_from) or on the chain step
///     that ends the narrowed path (ChainExpr::Step::narrowed_from); a step
///     in the middle of a chain splits it there, and the rest of the chain
///     continues from the call. Each mark holds the `T?` the place has, so
///     the receiver is put back to it and the call is the `T`.
///
///     `__value()` is UNCHECKED: it is called only where the analysis
///     proved a value, which is the whole point of the analysis. It is one
///     of the members EnumLayoutLowering mints on the Nullable lang item's
///     layout (AdtRole::ValueRef / ValueCref) and InterfaceEmitter writes in
///     C++, found by role as NullTestLowering finds `is_null()`. It returns
///     `T&` (`const T&` on a const nullable), so the call is an LVALUE: a
///     write through a narrowed record (`a.v = 3`) writes the nullable's
///     payload, and CopyMoveLowering's `x as T&&` around a narrowed `x`
///     (which it decided from `x`'s `T`) becomes `static_cast<T&&>(
///     x.__value())`, a move of the value, never of the whole nullable.
///
///   Phase: LOWER, after NullTestLowering, before NullableTypeLowering
///   (Sema.k). After CopyMoveLowering, whose casts it reaches inside. Before
///   NullableTypeLowering: the restored receiver is a NullableType, which
///   that pass then spells. Its order against NullTestLowering is free (a
///   null test's operand is never a narrowed read), it sits after it only
///   so the two halves of NULLABLE.md §5 read in order.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import Location::SourceRange::*;

class NarrowedAccessLowering derives ASTWriter::<NarrowedAccessLowering> {
    pub var sc: *SemaContext;
    priv var synth: LowerSynth;
    priv var _ref:  *FunctionDecl = &null;   ///< AdtRole::ValueRef:  `T& __value()`.
    priv var _cref: *FunctionDecl = &null;   ///< AdtRole::ValueCref: `const T& __value() const`.

    fn NarrowedAccessLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        // No builtin root: no `T?` was typed, so nothing was narrowed.
        if !self.sc->well_known->has(WellKnownType::Nullable) { return; }
        self._ref  = self.sc->nullable_member(AdtRole::ValueRef,  "NarrowedAccessLowering");
        self._cref = self.sc->nullable_member(AdtRole::ValueCref, "NarrowedAccessLowering");
        ICE_IF((self._ref == &null) || (self._cref == &null),
               "NarrowedAccessLowering: the Nullable layout has no " + LowerTargets::nullable_value()
               + "(); EnumLayoutLowering::_nullable_surface mints it");
        ASTWriter::<NarrowedAccessLowering>::run(self.sc->tu);
    }

    // --- the rewrites ---------------------------------------------------------

    fn transform_named_ident_expr(self, n: *NamedIdentExpr) -> *Expr {
        var out = ASTWriter::<NarrowedAccessLowering>::transform_named_ident_expr(n);
        if (n->narrowed_from == &null) || n->is_poisoned() { return out; }
        var t = n->type_;
        var e = static_cast::<*Expr>(n);
        e->type_         = n->narrowed_from;
        n->narrowed_from = &null;
        return self._value_of(e, t, e->range);
    }

    /// The base first (it may be a narrowed name), then the first marked
    /// step splits the chain: the path through it becomes the receiver of
    /// `__value()`, and the steps after it continue from that call.
    fn transform_chain_expr(self, n: *ChainExpr) -> *Expr {
        var out = ASTWriter::<NarrowedAccessLowering>::transform_chain_expr(n);
        if n->is_poisoned() { return out; }
        var k: usize = n->steps.size();
        for var i: usize = 0; i < n->steps.size(); ++i {
            if n->steps.get(i)->narrowed_from != &null { k = i; break; }
        }
        if k == n->steps.size() { return out; }

        var mark = n->steps.get(k);
        var t    = mark->resolved_type;       // the T the read was typed.
        var r    = SourceRange(n->range.start, mark->range.end);

        var pre   = ChainExpr::create(self.ctx, r, n->base);
        var psteps = ListBuilder::<ChainExpr::Step>(self.ctx);
        for var i: usize = 0; i <= k; ++i {
            var st = *(n->steps.get(i));
            if i == k {
                st.resolved_type = st.narrowed_from;
                st.narrowed_from = &null;
            }
            psteps.push(st);
        }
        psteps.freeze_into(&(pre->steps));
        var pe = static_cast::<*Expr>(pre);
        pe->expr_flags     = n->expr_flags;
        pe->type_          = mark->narrowed_from;
        pe->value_category = Expr::ValueCategory::LValue;
        var call = self._value_of(pe, t, r);

        if k + 1 == n->steps.size() {
            // The whole chain was the narrowed read: the call is it.
            call->expr_flags = n->expr_flags;
            return call;
        }
        var rest = ChainExpr::create(self.ctx, n->range, call);
        var rsteps = ListBuilder::<ChainExpr::Step>(self.ctx);
        for var i = k + 1; i < n->steps.size(); ++i { rsteps.push(*(n->steps.get(i))); }
        rsteps.freeze_into(&(rest->steps));
        rest->variant_decl = n->variant_decl;
        var re = static_cast::<*Expr>(rest);
        re->adopt_sema(static_cast::<*Expr>(n));
        // A later step may be marked too (`o.a.b` through two nullables).
        return self.transform_chain_expr(rest);
    }

    /// `recv.__value()`, typed \p t as the lvalue it is. The `const`
    /// accessor on a const nullable, so the C++ overload and the decl the
    /// call names agree.
    priv fn _value_of(self, recv: *Expr, t: *Type, r: SourceRange) -> *Expr {
        var m = self._ref;
        if canon_has_const(recv->type_) || canon_has_const(t) { m = self._cref; }
        var args = self.list_builder::<*Expr>();
        var call = self.synth.member_call(r, recv, static_cast::<*Decl>(m), &args, t);
        call->value_category = Expr::ValueCategory::LValue;
        return call;
    }
}
