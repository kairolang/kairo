/// --- The Kairo Project ---------------------- Sema/Type/CallTyping.k --- ///
///
///   \brief `callee(args)`: what the callee denotes, the candidate set that
///          gives, the arguments against it, and the result type.
///
///   \detail
///     Callee shapes, in the order they are recognised:
///
///       name            bound function        -> one candidate
///                       overload set          -> the cell
///                       type decl             -> constructor call
///                       value with fn type    -> call through a fn pointer
///       chain           last step is a method / set -> candidates with the
///                       chain's receiver
///                       last step is a type   -> constructor call
///                       otherwise a value     -> call through a fn pointer
///       Type<Args>      explicit instance     -> constructor on the instance
///       anything else   its type must be a fn pointer
///
///     Arguments are typed BEFORE resolution, except untyped literals, which
///     are ranked by shape and typed AFTER selection with the parameter type
///     (§5). Named arguments need a parser node; see the spec.
///
///   \par The `&` marker (AST/ParamMode.k)
///     `&x` in argument position is UnaryOperatorExpr(OpAmp, x): the parser
///     does not know the callee and cannot decide whether it is address-of
///     or the `@inout` marker. Nothing strips it before selection -- an
///     implementation that did would break every pointer argument in the
///     language. Instead arg_info records the operand's view alongside the
///     address-of view; OverloadResolution reads the operand's view against
///     an `@inout` parameter and the address-of view against everything
///     else; and finish_call_args, once the parameter is known, rewrites the
///     `&x` node to the operand's type (an lvalue) and sets is_mode_marker
///     so codegen emits the operand bare. An UNMARKED argument to `@inout`
///     binds with a warning (migration tolerance); the marker will become
///     required.
///
///     The one write to the tree outside `type_`: promoting a candidate cell
///     to the selected decl on the callee (NamedIdentExpr::resolved_decl or
///     Step::resolved_decl), which is the "cell -> decl: inference" line of
///     hard invariant #7. Plus the marker rewrite above, which is the one
///     place a memoized expression type is overwritten, and only after
///     selection, which is the only point the answer exists.
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
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::OverloadResolution::*;
import Sema::Type::ArgumentDeduction::*;
import Sema::Check::ClassLifecycle::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::ParamMode::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::ExprKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

/// The operand of a `&e` written as a call argument, or null when \p e is
/// not that shape. Bare `&e` only: `(&e)` is address-of, as in C++. One
/// decoder, three readers (arg_info, finish_call_args, _call_through).
fn mode_marker_operand(e: *Expr) -> *Expr {
    if e == &null { return &null; }
    if !isa::<UnaryOperatorExpr>(e) { return &null; }
    var u = cast::<UnaryOperatorExpr>(e);
    if u->op_token.kind != TokenKind::OpAmp { return &null; }
    return u->operand;
}

class <T> CallTyping {
    priv inline fn dyn(self) -> *T { return static_cast::<*T>(&self); }

    // === argument plumbing ==================================================

    /// Type \p e now unless it is an untyped literal, and describe it.
    ///
    /// A named argument has no node of its own: `f(x: 1)` is parsed as an
    /// AssignOperatorExpr whose operator token is `:` and whose lhs is a bare
    /// identifier. `named_call_arg_value` is the one decoder of that shape
    /// (the RAV skips the label for the same reason). Unwrap it here so that
    /// everything downstream -- literal shapes, conversion checks, the
    /// diagnostics -- sees the VALUE, with the name carried beside it for
    /// OverloadResolution to place.
    fn arg_info(self, e_in: *Expr) -> ArgInfo {
        var a = ArgInfo{};
        var e = e_in;
        a.carrier = e_in;
        var value = named_call_arg_value(e_in);
        if value != &null {
            var na = cast::<NamedArgExpr>(e_in);
            a.name       = dyn()->sc->ctx->get_spelling(na->name);
            a.name_range = na->name.range;
            e = value;
        }
        a.expr  = e;
        a.range = e->range;

        // The `&` marker: record the operand's view BEFORE the whole `&e` is
        // typed. Both views exist until selection decides which one the
        // parameter reads; typing the operand first makes the outer typing a
        // memo hit on it.
        var _op = mode_marker_operand(e);
        if _op != &null {
            dyn()->type_of(_op, &null);
            a.marked      = true;
            a.inner_ty    = _op->type_;
            a.inner_cat   = _op->value_category;
            a.inner_const = self._const_lvalue(_op);
        }

        if dyn()->list_literal_shape(e, &a) { return a; }
        if dyn()->literal_shape(e, &a) { return a; }
        if dyn()->dotted_variant_shape(e, &a) { return a; }
        a.ty = dyn()->type_of(e, &null);
        if (a.ty == &null) && (!e->is_poisoned()) { a.dependent = true; }
        a.cat      = e->value_category;          // set by the typer's finish (paren copies its inner).
        a.is_const = self._const_lvalue(e);
        // Passing a MOVE value moves it: the type decides, not the
        // expression, and Kairo has no std::move to write. So a MOVE lvalue
        // binds as the xvalue C++ would need: `v.push_back(m)` takes
        // push_back(T&&), and MoveCheck counts the call as the move. A const
        // one cannot be moved from and stays an lvalue.
        if (a.cat == Expr::ValueCategory::LValue) && (!a.is_const) && moves_on_pass(dyn()->sc, a.ty) {
            a.cat = Expr::ValueCategory::XValue;
        }
        return a;
    }

    /// An lvalue's const-ness as far as a reference parameter can see it: a
    /// `const` binding or parameter, or a `const T&`-typed result. Only a
    /// plain `T&` reads it -- a const lvalue does not bind there.
    priv fn _const_lvalue(self, e: *Expr) -> bool {
        var x = dyn()->tu.strip_parens(e);
        if x == &null { return false; }
        if x->type_ != &null {
            // The type says so: `*p` through a `*const i32`, a field of a
            // const object, a `const T&` result.
            var t = x->type_;
            if isa::<CXXLValueRefType>(t) { t = cast::<CXXLValueRefType>(t)->referee; }
            if canon_has_const(t) { return true; }
        }
        if !isa::<NamedIdentExpr>(x) { return false; }
        var d = cast::<NamedIdentExpr>(x)->resolved_decl;
        if d == &null { return false; }
        if isa::<VariableDecl>(d) { return cast::<VariableDecl>(d)->is_const(); }
        if isa::<ParamDecl>(d)    { return cast::<ParamDecl>(d)->is_const; }
        return false;
    }

    fn build_args(self, list: FrozenList::<*Expr>, out: *vec::<ArgInfo>) -> bool {
        var ok = true;
        for var i: usize = 0; i < list.size(); ++i {
            var e = list[i];
            if e == &null { continue; }
            var a = self.arg_info(e);
            if a.expr->is_poisoned() { ok = false; }
            out->push_back(a);
        }
        return ok;
    }

    /// The `&x` node, now known to be the marker: it reads as its operand.
    /// `&x` was typed as address-of before selection (it had to be: against
    /// `x: *i32` that is what it means); now that the parameter is known to
    /// be `@inout`, the node is an lvalue of T, not a `*T`. This is the one
    /// place a memoized expression type is rewritten, and only after
    /// selection, which is the only point the answer exists.
    ///
    /// \p pt is the substituted parameter canonical, or null when still
    /// dependent; the binding is re-checked against it so a deduced
    /// `@inout x: T` is judged on the type it actually became.
    priv fn _commit_marker(self, a: *ArgInfo, pt: *Type) {
        var _op = mode_marker_operand(a->expr);
        if _op == &null { return; }
        var u = cast::<UnaryOperatorExpr>(a->expr);
        u->is_mode_marker = true;
        u->type_          = _op->type_;
        u->value_category = Expr::ValueCategory::LValue;
        if _op->is_poisoned() { u->poison(); return; }
        if (pt == &null) || pt->is_dependent() { return; }
        if _op->type_ == &null { return; }
        var lref = dyn()->sc->types->cxx_lref(pt);
        var r = dyn()->conv.implicit_arg(_op->type_, lref, _op->value_category, self._const_lvalue(_op));
        if r == ImplicitRank::None {
            dyn()->fail(u, DiagID::SC097E, f"cannot pass '{dyn()->tu.str(_op->type_)}' to an '@inout' parameter of type '{dyn()->tu.str(pt)}'; an '@inout' argument must be a mutable lvalue");
        }
    }

    /// Migration tolerance: an unmarked argument to `@inout` bound; say so
    /// once per argument, at the argument, in words that say it will stop
    /// binding. No fixit by design (spec: MIGRATION).
    priv fn _warn_unmarked(self, args: *vec::<ArgInfo>, r: *OvlResult) {
        for var k: usize = 0; k < r->inout_unmarked.size(); ++k {
            var i = r->inout_unmarked[k];
            if i >= args->size() { continue; }
            var a  = &((*args)[i]);
            var pn = "<parameter>";
            if (k < r->inout_params.size()) && (r->inout_params[k] != &null) {
                pn = dyn()->tu.param_name(r->inout_params[k]);
            }
            dyn()->warn(a->expr, DiagID::SC097W,
                f"argument to '@inout' parameter '{pn}' is not marked with '&'; the marker "
                "will be required in a future release");
        }
    }

    /// After selection: type the untyped literals against their parameters,
    /// commit `&` markers, and re-check every argument against the
    /// substituted parameter type.
    fn finish_call_args(self, f: *FunctionDecl, args: *vec::<ArgInfo>, r: *OvlResult) {
        var params = vec::<*ParamDecl>();
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            params.push_back(p);
        }
        // The resolver's param indices exclude a bound receiver; rebuild that
        // view. TOLD, not inferred: the old guess ("self was skipped unless
        // some argument maps to 0") was wrong for every receiver call WITH an
        // argument -- once self is skipped the first real param IS index 0 --
        // and matched that argument against `self`: `x as Wrap` through a
        // converting ctor checked the operand against Wrap itself.
        var view = vec::<*ParamDecl>();
        for var i: usize = 0; i < params.size(); ++i {
            if (i == 0) && params[0]->is_self && r->receiver_bound { continue; }
            view.push_back(params[i]);
        }

        for var i: usize = 0; i < args->size(); ++i {
            var a  = &((*args)[i]);
            var pi = (r->arg_to_param[i]) if (i < r->arg_to_param.size()) else (usize(-1));
            var p: *ParamDecl = &null;
            if pi != usize(-1) { if pi < view.size() { p = view[pi]; } }
            else {
                // The pack tail. By is_pack, not position: a named-only
                // parameter may follow the pack, and the last one is then it.
                for var k: usize = 0; k < view.size(); ++k {
                    if view[k]->is_pack { p = view[k]; break; }
                }
            }
            if (p == &null) || (p->type_ == &null) { if a->lit != LitKind::None { dyn()->type_of(a->expr, &null); } continue; }
            var pt = self._self_first(f, r, p->type_->canonical, true);
            if (pt != &null) && pt->is_dependent() { pt = r->ded.substitute(pt); }
            // `other: Self` is `other: T`. Resolution already judged the
            // argument this way; this is the same rule applied to the winner.
            pt = r->ded.through_receiver(f, r->receiver, pt);

            // `@inout` with the marker: the operand is the argument.
            if (p->mode == ParamMode::Inout) && a->marked && (pi != usize(-1)) {
                self._commit_marker(a, (canon_unqual(pt)) if (pt != &null) else (&null));
                continue;
            }
            if a->lit != LitKind::None {
                dyn()->type_of(a->expr, pt);
                continue;
            }
            // Either side dependent -- only reachable through a dependent
            // constructor call -- is the instance's question, as it is for
            // an initializer field.
            if (pt != &null) && pt->is_dependent() { continue; }
            if a->dependent { continue; }
            if pt != &null {
                dyn()->lint_cast_into_slot(a->expr, pt);
                // The resolver admitted this argument by the boundary rung;
                // check_convertible asks the plain lattice and would refuse
                // the very widening that picked the winner.
                if f->is_imported() && (a->expr->type_ != &null)
                && (dyn()->conv.abi_widen(a->expr->type_, pt) != ImplicitRank::None) { continue; }
                dyn()->check_convertible(a->expr, pt);
            }
        }

        // The `name: value` wrapper is syntax, not a value: give it the type
        // of what it wraps so the dump does not report a hole where the
        // source only wrote a parameter name.
        for var i: usize = 0; i < args->size(); ++i {
            var a = &((*args)[i]);
            if (a->carrier == &null) || (a->carrier == a->expr) { continue; }
            if a->expr->is_poisoned() { a->carrier->poison(); }
            a->carrier->value_category = a->expr->value_category;   // the wrapper IS its value.
            dyn()->finish(a->carrier, a->expr->type_);
        }
    }

    /// \p t with an interface member's `Self` read as the receiver, BEFORE
    /// the deduction substitutes: a generic interface's Self is `I<T>` over
    /// its own parameters, and once `Container<i32>::get` binds T it reads
    /// `I<i32>`, which the Self rule no longer recognizes. A dependent
    /// receiver (a bound's T) goes first only for a parameter \p (any): a
    /// parameter left dependent is the instance's to check either way, while
    /// a return type has to substitute, and call_result_type says why that
    /// fails once Self is the caller's T.
    priv fn _self_first(self, f: *FunctionDecl, r: *OvlResult, t: *Type, any: bool) -> *Type {
        if (t == &null) || (r->receiver == &null) { return t; }
        if r->receiver->is_dependent() && (!any) { return t; }
        return r->ded.through_receiver(f, r->receiver, t);
    }

    /// The declared return type of \p f after deduction. Expression-bodied
    /// functions without an annotation are inferred on demand.
    fn call_result_type(self, f: *FunctionDecl, r: *OvlResult) -> *Type {
        if f->is_noreturn { return dyn()->tu.builtin(BuiltinKind::Never); }
        var rt = self._self_first(f, r, dyn()->fn_return_type(f), false);
        if rt == &null { return &null; }
        // A GENERIC interface's `-> Self` through a bound `C`: Self is
        // `I<T>`, dependent, so substituting first does not leave it alone
        // as it does a non-generic `record(I)` -- with the qualifier binding
        // T, it would read `I<i32>`. Read Self as C first, and let C stand
        // for itself in the substitution that follows, which the rest of
        // the type (`-> (Self, U)`) still needs.
        if rt->is_dependent() && (r->receiver != &null) && r->receiver->is_dependent() {
            var g = dyn_cast::<GenericParamType>(canon_unqual(r->receiver));
            var rs = r->ded.through_receiver(f, r->receiver, rt);
            if (g != &null) && (rs != rt) {
                r->ded.bind(g->owner, g->param_index, static_cast::<*Type>(g));
                rt = rs;
            }
        }
        if rt->is_dependent() {
            var s = r->ded.substitute(rt);
            if s == &null { return &null; }   // still dependent: caller marks unknown.
            rt = s;
        }
        // An interface member's `Self` is the receiver, so `-> Self` through a
        // bound `T impl I` reads back as T. AFTER the deduced substitution,
        // not before, and the order is not cosmetic: rewriting first turns
        // `-> Self` into `T`, and `T` is the CALLER's parameter, which this
        // call's deduction never binds -- substitute would fail and the call
        // would type as unknown. Substituting first leaves `record(I)` alone
        // (a non-generic interface's record is not dependent) and the rewrite
        // then lands on the finished type.
        rt = r->ded.through_receiver(f, r->receiver, rt);
        // Register the generic function instance for M1/EmitPlan (see spec).
        // An extension member's instance arguments are its extension's, then
        // its own: the order CXXSpell::template_params spells them in.
        var ext = decl_extension_of(static_cast::<*Decl>(f));
        var ext_n = (decl_generic_params(static_cast::<*Decl>(ext)).size()) if (ext != &null) else (usize(0));
        if (f->generic_params.size() > 0) || (ext_n > 0) {
            var args = vec::<*Type>();
            var ok = ((ext == &null) || self._bound_args(r, static_cast::<*Decl>(ext), &args))
                  && self._bound_args(r, static_cast::<*Decl>(f), &args);
            if ok {
                r->instance = dyn()->sc->instances->instance_for(NameLookup::representative(static_cast::<*Decl>(f)), &args,
                                                                 dyn()->sc->ctx->fid, NameLookup::ctx_of(static_cast::<*Decl>(f)));
            } else {
                // Dependent: keep what deduction found, for the enclosing
                // generic's instances to substitute (CallExpr::dep_args).
                r->dep_args.clear();
                var dok = ((ext == &null) || self._loose_args(r, static_cast::<*Decl>(ext), &(r->dep_args)))
                       && self._loose_args(r, static_cast::<*Decl>(f), &(r->dep_args));
                if !dok { r->dep_args.clear(); }
            }
        }
        return rt;
    }

    /// \p owner's deduced arguments, dependent ones included; false only on
    /// an unbound parameter or a pack.
    priv fn _loose_args(self, r: *OvlResult, owner: *Decl, out: *vec::<*Type>) -> bool {
        var gps = decl_generic_params(owner);
        for var i: usize = 0; i < gps.size(); ++i {
            var gp = gps[i];
            if (gp == &null) || gp->is_pack { return false; }
            var b = r->ded.lookup(owner, gp->index);
            if b == &null { return false; }
            out->push_back(b);
        }
        return true;
    }

    /// \p owner's deduced arguments, appended to \p out in parameter order.
    /// Packs are skipped; false on an unbound or still-dependent binding.
    priv fn _bound_args(self, r: *OvlResult, owner: *Decl, out: *vec::<*Type>) -> bool {
        var gps = decl_generic_params(owner);
        for var i: usize = 0; i < gps.size(); ++i {
            var gp = gps[i];
            if (gp == &null) || gp->is_pack { continue; }
            var b = r->ded.lookup(owner, gp->index);
            if (b == &null) || b->is_dependent() { return false; }
            out->push_back(b);
        }
        return true;
    }

    // === the call ===========================================================

    fn type_call(self, n: *CallExpr, expected: *Type) -> *Type {
        var callee = dyn()->tu.strip_parens(n->callee);
        if callee == &null { dyn()->fail(n, DiagID::SC093E, "call with no callee"); return &null; }

        // --- name -----------------------------------------------------------
        if isa::<NamedIdentExpr>(callee) {
            var id = cast::<NamedIdentExpr>(callee);
            if id->is_poisoned() { dyn()->poison_only(n); return &null; }

            if id->is_deferred() {
                var cands = vec::<*Decl>();
                for var i: usize = 0; i < id->candidate_cell->size(); ++i { cands.push_back(id->candidate_cell->get(i)); }
                return self._call_candidates(n, &cands, false, &null, dyn()->sc->ctx->get_spelling(id->name),
                                             id, &null, true);
            }
            // `u32(x)`: the parser admits a primitive before `(`, but Kairo
            // converts with `as` (casting.md), and a type is not callable.
            // N leaves the head unbound on purpose; without this the call
            // would fall to mark_unknown below and type as nothing, silently.
            if is_annotation(id->name.kind) {
                var sp = dyn()->sc->ctx->get_spelling(id->name);
                dyn()->sc->diag->report(DiagID::SC037E, n->range.start,
                    f"'{sp}' is a type, not a function; convert with 'x as {sp}\x27"
                ).first(n->range).emit();
                id->poison();
                n->poison();
                return &null;
            }
            if !id->is_bound() { dyn()->mark_unknown(n); return &null; }

            var d = id->resolved_decl;
            if isa::<FunctionDecl>(d) {
                var cands = vec::<*Decl>();
                cands.push_back(d);
                return self._call_candidates(n, &cands, false, &null, dyn()->sc->ctx->get_spelling(id->name), &null, &null, true);
            }
            if dyn()->tu.is_type_decl(d) {
                var rec = dyn()->denoted_type(callee);
                if rec == &null { dyn()->poison_only(n); return &null; }
                return self._ctor_call(n, rec);
            }
            if isa::<GenericParamDecl>(d) { return self._param_ctor_call(n, cast::<GenericParamDecl>(d)); }
            // a value: must be a function pointer.
            var vt = dyn()->type_of(callee, &null);
            return self._call_through(n, vt);
        }

        // --- chain ----------------------------------------------------------
        if isa::<ChainExpr>(callee) {
            var ce = cast::<ChainExpr>(callee);
            dyn()->type_of(callee, &null);
            if callee->is_poisoned() { dyn()->poison_only(n); return &null; }
            var info = dyn()->chain_info(ce);
            if info == &null { dyn()->mark_unknown(n); self._type_args_blind(n); return &null; }

            if info->last_is_type {
                var rec = dyn()->denoted_type(callee);
                if rec == &null { dyn()->poison_only(n); return &null; }
                return self._ctor_call(n, rec);
            }
            if info->callable_cands.size() > 0 {
                var last = ce->steps.get(ce->steps.size() - 1);
                var nm = "<operator>";
                if last->name != &null { nm = dyn()->sc->ctx->get_spelling(last->name->name); }
                return self._call_candidates(n, &(info->callable_cands), info->has_receiver, info->receiver,
                                             nm, &null, last);
            }
            if info->unknown { dyn()->mark_unknown(n); self._type_args_blind(n); return &null; }
            return self._call_through(n, callee->type_);
        }

        // --- anything else: a fn-pointer value ---------------------------------
        var t = dyn()->type_of(callee, &null);
        if callee->is_poisoned() { dyn()->poison_only(n); return &null; }
        return self._call_through(n, t);
    }

    /// \p t is an interface's own type: `I` as a call's qualifier.
    priv fn _is_interface_type(self, t: *Type) -> bool {
        if t == &null { return false; }
        var d = dyn()->tu.record_decl(canon_unqual(t));
        return (d != &null) && isa::<InterfaceDecl>(NameLookup::representative(dyn()->tu.pattern_of(d)));
    }

    priv fn _any_method(self, cands: *vec::<*Decl>) -> bool {
        for var i: usize = 0; i < cands->size(); ++i {
            var f = dyn_cast::<FunctionDecl>((*cands)[i]);
            if (f != &null) && f->is_method() { return true; }
        }
        return false;
    }

    priv fn _type_args_blind(self, n: *CallExpr) {
        for var i: usize = 0; i < n->args.size(); ++i { dyn()->type_of(n->args[i], &null); }
    }

    /// Resolve against \p cands, promote the winner onto \p ident or \p step.
    /// \param adl  the callee was an unqualified name: widen \p cands with
    ///             argument-dependent lookup before resolving.
    priv fn _call_candidates(self, n: *CallExpr, cands: *vec::<*Decl>, has_receiver: bool,
                             receiver: *Type, name: string, ident: *NamedIdentExpr,
                             step: *ChainExpr::Step, adl: bool = false) -> *Type {
        var args = vec::<ArgInfo>();
        var ok = self.build_args(n->args, &args);

        // ADL ([basic.lookup.argdep]): an unqualified call also sees functions
        // of the same name in the modules of its arguments' types -- how
        // `swap(a, b)` on two `std::` values finds `std::swap` unqualified.
        // AFTER build_args, because it needs the argument types; an untyped
        // literal has none and associates nothing. Suppressed, as in C++,
        // when ordinary lookup found a method.
        var all = vec::<*Decl>();
        for var i: usize = 0; i < cands->size(); ++i { all.push_back((*cands)[i]); }
        if adl && (!self._any_method(cands)) {
            var scopes = vec::<*DeclContext>();
            for var i: usize = 0; i < args.size(); ++i { dyn()->ml.associated_scopes(args[i].ty, &scopes); }
            var imm = dyn()->sc->imm_table()->find_ident(name);
            if (scopes.size() > 0) && (imm != u32(-1)) {
                dyn()->ml.adl_candidates(&scopes, DeclName::ident(imm), name, cands, &all);
            }
        }

        // The receiver goes IN, not on afterwards: an interface member's
        // `Self` is the receiver, and viability is judged against it.
        var recv: *Type = &null;
        if receiver != &null {
            recv = dyn()->tu.strip_nullable(receiver);
            var pt = dyn()->tu.pointee(recv);
            if pt != &null { recv = pt; }
        }

        // `I::m(x, ...)`, the qualified form of a requirement call: the
        // qualifier is the interface, not the receiver. `self` is the first
        // argument, so Self is ITS type, and the requirement's `Self` reads
        // as that (through_receiver), as it would for `x.m(...)`.
        // The qualifier stays on the call (CallExpr::witness_iface, until
        // ExtensionLowering writes the declaring instance over it): a GENERIC
        // interface's arguments are on it and nowhere else, and resolution
        // binds the requirement's interface parameters from it.
        var qual: *Type = &null;
        if (!has_receiver) && (args.size() > 0) && (args[0].ty != &null) && self._is_interface_type(recv) {
            qual = canon_unqual(recv);
            n->witness_iface = qual;
            recv = dyn()->tu.as_value(args[0].ty);
            // Bare `Container::get(b, 0)` names no instance. Which one b
            // conforms to could be deduced from its declarations when only one
            // fits, but that is a second lookup to keep sound; the arguments
            // are one edit away.
            var qr = dyn_cast::<RecordType>(qual);
            var qd = (NameLookup::representative(dyn()->tu.pattern_of(qr->decl))) if (qr != &null) else (&null);
            if (qd != &null) && (decl_generic_params(qd).size() > 0) && dyn()->ded_scratch()->own_args(qr, qd) {
                var iname = dyn()->tu.decl_name(qd);
                var d = dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                    f"'{iname}' is generic, and a qualified call names its instance: write '{iname}<...>::{name}\x27");
                d.first(n->range);
                d.note(qd->range.start, f"'{iname}' is declared here").first(qd->range);
                d.emit();
                dyn()->poison_only(n);
                return &null;
            }
        }

        if !self._narrow_args(&all, &args, has_receiver, recv) { dyn()->poison_only(n); return &null; }
        var r = dyn()->ovl.resolve(&all, &args, has_receiver, n->range, name, recv, qual);
        if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
        if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
        if !ok { dyn()->poison_only(n); return &null; }

        if recv != &null { r.ded.bind_from_record(canon_unqual(recv)); }

        // promote cell -> decl (hard invariant #7).
        if (ident != &null) && (ident->resolved_decl == &null) {
            ident->resolved_decl  = static_cast::<*Decl>(r.decl);
            ident->candidate_cell = &null;
        }
        if (step != &null) && (step->resolved_decl == &null) {
            step->resolved_decl  = static_cast::<*Decl>(r.decl);
            step->candidate_cell = &null;
        }

        self.finish_call_args(r.decl, &args, &r);
        if !self._check_constant_args(r.decl, &args, &r) { dyn()->poison_only(n); return &null; }
        self._warn_unmarked(&args, &r);
        self._write_arg_map(n, r.decl, &args, &r);
        var rt = self.call_result_type(r.decl, &r);
        n->instance = reinterpret_cast::<*void>(r.instance);
        if (r.instance == &null) && (r.dep_args.size() > 0) {
            var arr = dyn()->sc->ctx->alloc_array::<*Type>(r.dep_args.size());
            for var i: usize = 0; i < r.dep_args.size(); ++i { arr[i] = r.dep_args[i]; }
            n->dep_args.from_raw(arr, r.dep_args.size());
        }
        if rt == &null { dyn()->mark_unknown(n); return &null; }
        return rt;
    }

    /// Nullable places passed where only their VALUE fits (NULLABLE.md §4).
    /// Selection judges an argument by ArgInfo::ty, which for a `T?` place
    /// is `T?`, so `take(a)` with `fn take(x: i32)` would be "no matching
    /// overload" even after `if a?`. Only when no candidate takes the
    /// arguments as they are, and one does with the nullable places read as
    /// their values, are those reads made: each one narrowed when its place
    /// is proven non-null, else the nullness error (false: reported). A
    /// read some candidate does not need -- one still viable with that
    /// argument left nullable -- is left alone, so a `T?` parameter keeps
    /// its nullable and is never asked about. A `T?` overload, or a call
    /// that type-checks as written, is untouched.
    priv fn _narrow_args(self, cands: *vec::<*Decl>, args: *vec::<ArgInfo>, has_receiver: bool, recv: *Type) -> bool {
        var idx = vec::<usize>();
        for var i: usize = 0; i < args->size(); ++i {
            var a = &((*args)[i]);
            if (a->expr == &null) || a->marked || (a->ty == &null) { continue; }
            if dyn()->flow.narrowed_type(a->ty) == &null { continue; }
            idx.push_back(i);
        }
        if idx.size() == 0 { return true; }
        if dyn()->ovl.any_viable(cands, args, has_receiver, &null, &null, recv) { return true; }
        var alt = *args;
        for var j: usize = 0; j < idx.size(); ++j {
            alt[idx[j]].ty = dyn()->flow.narrowed_type(alt[idx[j]].ty);
        }
        if !dyn()->ovl.any_viable(cands, &alt, has_receiver, &null, &null, recv) { return true; }
        // Keep only the reads some viable candidate needs.
        var need = vec::<usize>();
        for var j: usize = 0; j < idx.size(); ++j {
            var keep = alt[idx[j]].ty;
            alt[idx[j]].ty = (*args)[idx[j]].ty;
            if dyn()->ovl.any_viable(cands, &alt, has_receiver, &null, &null, recv) { continue; }
            alt[idx[j]].ty = keep;
            need.push_back(idx[j]);
        }
        var ok = true;
        for var j: usize = 0; j < need.size(); ++j {
            var a = &((*args)[need[j]]);
            var o = dyn()->flow.read_value(a->expr, true);
            if o == 2 { ok = false; continue; }
            if o == 1 { a->ty = a->expr->type_; }
        }
        return ok;
    }

    /// A clang builtin's `I` positions take an integer constant. Checked
    /// here, at the Kairo argument: left to clang, the error lands on the
    /// emitted token stream, where the user wrote nothing.
    ///
    /// A constant is an integer, bool or char literal, a `sizeof` or
    /// `alignof`, either under unary `-`, `+`, `~`, `!`, or cast `as` an
    /// integer or bool type: all of these are ICEs to clang, and a sizeof /
    /// alignof of a dependent type is a value-dependent one it folds at
    /// instantiation. Nothing else is yet: the evaluator is a stub, so an
    /// `eval` binding has no value sema can read, and accepting one here would
    /// only move the error back into clang.
    priv fn _check_constant_args(self, f: *FunctionDecl, args: *vec::<ArgInfo>, r: *OvlResult) -> bool {
        if f->ffi_ice_mask == 0 { return true; }
        var ok = true;
        for var i: usize = 0; i < args->size(); ++i {
            var pi = (r->arg_to_param[i]) if (i < r->arg_to_param.size()) else (usize(-1));
            if pi >= 32 { continue; }                       // pack tail / C `...`: no mask bit.
            if (f->ffi_ice_mask & (u32(1) << u32(pi))) == 0 { continue; }
            var a = &((*args)[i]);
            if self._is_constant_arg(a->expr) { continue; }
            dyn()->fail(a->expr, DiagID::SC108E,
                f"argument {pi + 1} of '{dyn()->tu.decl_name(static_cast::<*Decl>(f))}' must be an integer constant");
            ok = false;
        }
        return ok;
    }

    priv fn _is_constant_arg(self, e_in: *Expr) -> bool {
        var e = dyn()->tu.strip_parens(e_in);
        if e == &null { return false; }
        if isa::<UnaryOperatorExpr>(e) {
            var u = cast::<UnaryOperatorExpr>(e);
            var k = u->op_token.kind;
            if (k == TokenKind::OpMinus) || (k == TokenKind::OpPlus)
            || (k == TokenKind::OpTilde) || (k == TokenKind::OpExclaim) {
                return self._is_constant_arg(u->operand);
            }
            return false;
        }
        if isa::<TypeCastExpr>(e) {
            // `alignof(T) as i32`: a cast keeps an ICE an ICE only when it
            // lands on an integer (or bool); `as f64` does not.
            var c = cast::<TypeCastExpr>(e);
            if (c->target == &null) || (c->target->canonical == &null) { return false; }
            var tt = c->target->canonical;
            if (!dyn()->tu.is_integer(tt)) && (!dyn()->tu.is_bool(tt)) { return false; }
            return self._is_constant_arg(c->operand);
        }
        if isa::<SizeOfExpr>(e) || isa::<AlignOfExpr>(e) { return true; }
        // Not literal_shape: that is the overload ranker's view, which takes
        // floats and `null` (not constants here) and refuses a bool, the
        // very literal `__builtin_coro_promise`'s third slot wants.
        return isa::<IntegerLiteralExpr>(e) || isa::<BooleanLiteralExpr>(e)
            || isa::<CharacterLiteralExpr>(e);
    }

    /// `CallExpr::arg_map`, written once, at Selected. Parallel to the CALLEE'S
    /// PARAMETERS with `self` in slot 0, holding the index into `args` of the
    /// argument bound to each parameter, -1 for "use the default", and for the
    /// pack the index of its first argument with `pack_len` beside it.
    ///
    /// The resolver's own `arg_to_param` is the other direction and over a
    /// receiver-EXCLUDED view, so it cannot be handed to CallLowering as-is:
    /// inverting it here means nothing downstream re-derives the mapping.
    priv fn _write_arg_map(self, n: *CallExpr, f: *FunctionDecl, args: *vec::<ArgInfo>, r: *OvlResult) {
        if (n == &null) || (f == &null) { return; }
        var np = f->params.size();
        var map: std::StackBuf::<i32, 8>;
        for var i: usize = 0; i < np; ++i { map.push_back(i32(-1)); }

        // view index -> f->params index. finish_call_args builds the same view
        // for the same reason; the offset is the receiver the resolver skipped.
        var off: usize = 0;
        if (np > 0) && (f->params[0] != &null) && f->params[0]->is_self && r->receiver_bound { off = 1; }

        // The receiver bound to `self` is no argument: -2, not -1, which reads
        // as "use the default" and would send CallLowering looking for one.
        if off == 1 { map[0] = i32(-2); }

        var pack_lo: i32   = i32(-1);
        var pack_n:  usize = 0;
        var pack_at        = usize(-1);
        for var i: usize = 0; i < np; ++i {
            if (f->params[i] != &null) && f->params[i]->is_pack { pack_at = i; break; }
        }

        for var i: usize = 0; i < args->size(); ++i {
            var pi = (r->arg_to_param[i]) if (i < r->arg_to_param.size()) else (usize(-1));
            if pi == usize(-2) { continue; }            // C `...` tail: no parameter at all.
            if pi == usize(-1) {
                // Pack tail. Its run is contiguous (SC022E rejects otherwise),
                // so the first index and the count describe it exactly.
                if pack_lo == i32(-1) { pack_lo = i32(i); }
                pack_n += 1;
                continue;
            }
            var slot = pi + off;
            if slot < np { map[slot] = i32(i); }
        }
        if (pack_at != usize(-1)) && (pack_lo != i32(-1)) { map[pack_at] = pack_lo; }

        n->arg_map.from_buf(map.data(), map.size(), dyn()->sc->ctx);
        n->pack_len = u32(pack_n);
    }

    /// `Foo(args)` on a record type: constructors live in the type's own
    /// table under DeclName::ctor(). No ctor + no args is the default ctor.
    ///
    /// A DEPENDENT record that can be named -- `Box<T>(p)` in a generic
    /// body -- is typed with that record, exactly as ControlTyping's
    /// _init_fields types `Box<T>{ ... }`: codegen ICEs on an untyped
    /// constructor call, and the type is right there to name. Its pattern's
    /// constructors are resolved in defer mode (resolve_deferred): a
    /// parameter still dependent through the record's arguments is assumed
    /// viable, a concrete one ranks and errors as in any call. A winner is
    /// written exactly as for a concrete call; a tie only the instance can
    /// break leaves ctor_decl null, and the emitted `Box<T>(args)` lets
    /// clang pick per instance (RESOLUTION.md §2.9). Only a head with no
    /// record to name -- an unbounded `T::Inner` -- stays unknown.
    priv fn _ctor_call(self, n: *CallExpr, rec: *Type) -> *Type {
        var d = dyn()->tu.record_decl(rec);
        var dep = rec->is_dependent();
        if (d == &null) && dep { dyn()->mark_unknown(n); self._type_args_blind(n); return &null; }
        if d == &null {
            // an alias of a builtin, `i32(x)` style: not a call.
            dyn()->fail(n, DiagID::SC037E, f"'{dyn()->tu.str(rec)}' is not constructible with a call; use 'as\x27");
            return &null;
        }

        var body = dyn()->sc->record_body(rec);   // an unfilled instance has an empty table; its body's (a selected partial's).
        if body == &null { body = dyn()->tu.pattern_of(d); }
        var dc   = NameLookup::context_of(body);
        var cands = vec::<*Decl>();
        if dc != &null {
            var cell = dyn()->sc->lookup.in_context(dc, DeclName::ctor());
            if cell.found() {
                for var i: usize = 0; i < cell.cell->size(); ++i { cands.push_back(cell.cell->get(i)); }
            }
        }
        if cands.size() == 0 {
            if n->args.size() == 0 { return rec; }   // implicit default ctor
            self._type_args_blind(n);
            dyn()->sc->diag->report(DiagID::SC038E, n->range.start,
                f"'{dyn()->tu.decl_name(d)}' declares no constructor taking arguments"
            ).first(n->range)
             .note(d->range.start, "type declared here").first(d->range)
             .emit();
            n->poison();
            return &null;
        }
        var args = vec::<ArgInfo>();
        var ok = self.build_args(n->args, &args);
        if (!dep) && (!self._narrow_args(&cands, &args, true, rec)) { dyn()->poison_only(n); return &null; }
        var r = OvlResult{};
        if dep {
            r = dyn()->ovl.resolve_deferred(&cands, &args, true, n->range, dyn()->tu.decl_name(d), rec);
        } else {
            r = dyn()->ovl.resolve(&cands, &args, true, n->range, dyn()->tu.decl_name(d), rec);
        }
        if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
        if r.outcome == OvlOutcome::Deferred {
            if !ok { dyn()->poison_only(n); return &null; }
            self._finish_args_unselected(&args);
            n->value_category = Expr::ValueCategory::RValue;
            return rec;
        }
        if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
        if !ok { dyn()->poison_only(n); return &null; }
        r.ded.bind_from_record(rec);
        self.finish_call_args(r.decl, &args, &r);
        self._warn_unmarked(&args, &r);
        self._write_arg_map(n, r.decl, &args, &r);
        n->ctor_decl = static_cast::<*Decl>(r.decl);
        if dep { n->value_category = Expr::ValueCategory::RValue; }
        return rec;
    }

    /// `T(args)` on a generic parameter. Typed as T when one of T's bounds
    /// promises a constructor of that arity (decl_is_ctor_requirement):
    /// every instance's `X(args)` then exists, ConformanceChecking having
    /// found it, so `var t = T()` has a type to carry into `t.m()`. Any
    /// other `T(args)` stays unknown, as it always was -- clang decides it
    /// per instance -- so a bound only ever adds a type, never accepts a
    /// call that was rejected. The arguments are not checked against the
    /// requirement: a conformer's constructor is matched exactly, so the
    /// C++ `T(args)` reaches it or fails at the concept.
    priv fn _param_ctor_call(self, n: *CallExpr, gp: *GenericParamDecl) -> *Type {
        self._type_args_blind(n);
        var t = dyn()->sc->types->generic_param(NameLookup::representative(gp->owner), gp->index, gp->is_pack);
        var bs = dyn()->bound_ifaces(t);
        for var i: usize = 0; i < bs.size(); ++i {
            var rt = dyn_cast::<RecordType>(bs[i]);
            if rt == &null { continue; }
            var idecl = dyn_cast::<InterfaceDecl>(NameLookup::representative(dyn()->tu.pattern_of(rt->decl)));
            if (idecl == &null) || (idecl->compose_state != 2) { continue; }
            for var j: usize = 0; j < idecl->requirements.size(); ++j {
                var m = dyn_cast::<FunctionDecl>(idecl->requirements.get(j)->decl);
                if (m == &null) || (!decl_is_ctor_requirement(m)) { continue; }
                var arity: usize = 0;
                for var k: usize = 0; k < m->params.size(); ++k { if (m->params[k] != &null) && (!m->params[k]->is_self) { arity += 1; } }
                if arity != n->args.size() { continue; }
                n->value_category = Expr::ValueCategory::RValue;
                return t;
            }
        }
        dyn()->mark_unknown(n);
        return &null;
    }

    /// finish_call_args with no winner: there is no parameter to type an
    /// untyped literal against, so it takes its default (what clang will
    /// see it as), and a `name: value` wrapper takes its value's type.
    priv fn _finish_args_unselected(self, args: *vec::<ArgInfo>) {
        for var i: usize = 0; i < args->size(); ++i {
            var a = &((*args)[i]);
            if a->lit != LitKind::None { dyn()->type_of(a->expr, &null); }
            if (a->carrier == &null) || (a->carrier == a->expr) { continue; }
            if a->expr->is_poisoned() { a->carrier->poison(); }
            a->carrier->value_category = a->expr->value_category;
            dyn()->finish(a->carrier, a->expr->type_);
        }
    }

    /// Call through a function-pointer-typed value.
    priv fn _call_through(self, n: *CallExpr, t: *Type) -> *Type {
        if t == &null {
            self._type_args_blind(n);
            if !n->callee->is_poisoned() { dyn()->mark_unknown(n); } else { dyn()->poison_only(n); }
            return &null;
        }
        // A nullable callable proven non-null here is called through its
        // value (NULLABLE.md §4); one that is not is the nullness error.
        if (dyn()->tu.nullable_inner(t) != &null) && (dyn()->flow.read_value(n->callee, false) == 1) { t = n->callee->type_; }
        else if dyn()->tu.nullable_inner(t) != &null {
            var o = dyn()->flow.read_value(n->callee, true);
            if o == 2 { self._type_args_blind(n); dyn()->poison_only(n); return &null; }
        }
        var ft = dyn()->tu.strip_nullable(t);
        if ft != t {
            // A nullable callable is not callable: there is no code to run on
            // the null side, and nothing implicitly unwraps it here either.
            self._type_args_blind(n);
            dyn()->fail(n, DiagID::SC098E, f"'{dyn()->tu.str(t)}' may be null; unwrap it before calling, with '??' or 'unwrap!()\x27");
            return &null;
        }
        ft = canon_unqual(ft);   // a `const` callable calls the same code.
        if (ft == &null) || (!isa::<FunctionPointerType>(ft)) {
            self._type_args_blind(n);
            dyn()->fail(n, DiagID::SC062E, f"'{dyn()->tu.str(t)}' is not callable");
            return &null;
        }
        var fp = cast::<FunctionPointerType>(ft);

        // No candidate set and no deduction: one signature, arguments
        // positional, each converted to its own parameter type. An
        // unprototyped C import declares no parameters to check against, so
        // the arguments are typed on their own and the declaration is trusted
        // -- exactly what C does with `void f()`.
        if fp->is_unprototyped {
            self._type_args_blind(n);
            return fp->return_type;
        }
        if n->args.size() != fp->params.size() {
            self._type_args_blind(n);
            dyn()->fail(n, DiagID::SC099E, f"'{dyn()->tu.str(ft)}' takes {fp->params.size()} argument(s), {n->args.size()} given");
            return &null;
        }

        var bad = false;
        for var i: usize = 0; i < n->args.size(); ++i {
            var a = n->args[i];
            if a == &null { continue; }
            var pt   = fp->params[i];
            var mode = (fp->modes[i]) if (i < fp->modes.size()) else (ParamMode::Value);

            if mode == ParamMode::Inout {
                // The type's `@inout` position: the argument is the operand of
                // a `&` marker, or (tolerated, warned) an unmarked lvalue. It
                // is judged as a `T&` binding, exactly as a declared
                // parameter's would be, and lends no type to a literal.
                var _op = mode_marker_operand(a);
                var target = (_op) if (_op != &null) else (a);
                dyn()->type_of(target, &null);
                if target->is_poisoned() { if _op != &null { a->poison(); } bad = true; continue; }
                if _op == &null {
                    dyn()->warn(a, DiagID::SC097W, f"argument to '@inout' parameter {i + 1} of '{dyn()->tu.str(ft)}' is not "
                                   "marked with '&'; the marker will be required in a future release");
                }
                if target->type_ != &null {
                    var lref = dyn()->sc->types->cxx_lref(canon_unqual(pt));
                    var r = dyn()->conv.implicit_arg(target->type_, lref, target->value_category, self._const_lvalue(target));
                    if r == ImplicitRank::None {
                        dyn()->fail(target, DiagID::SC097E, f"cannot pass '{dyn()->tu.str(target->type_)}' to an '@inout' parameter of type '{dyn()->tu.str(pt)}'; an '@inout' argument must be a mutable lvalue");
                        bad = true;
                        continue;
                    }
                }
                if _op != &null {
                    // Never typed as address-of on this path: the type said
                    // `@inout` before the node was reached. Commit it as its
                    // operand and record it as done for the RAV's later visit.
                    var u = cast::<UnaryOperatorExpr>(a);
                    u->is_mode_marker = true;
                    u->value_category = Expr::ValueCategory::LValue;
                    dyn()->finish(a, _op->type_);
                }
                continue;
            }

            // The parameter type is the EXPECTED type, not a post-hoc check:
            // an untyped literal argument takes it the same way it would
            // through an overload set (§5). `@move` ranks by value.
            dyn()->type_of(a, pt);
            if a->is_poisoned() { bad = true; continue; }
            if !dyn()->check_convertible(a, pt) { bad = true; }
        }
        if bad { dyn()->poison_only(n); return &null; }
        if fp->return_type == &null { dyn()->mark_unknown(n); return &null; }
        return fp->return_type;
    }
}

