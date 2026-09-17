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
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
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

        if dyn()->literal_shape(e, &a) { return a; }
        a.ty = dyn()->type_of(e, &null);
        if (a.ty == &null) && (!e->is_poisoned()) { a.dependent = true; }
        a.cat      = e->value_category;          // set by the typer's finish (paren copies its inner).
        a.is_const = self._const_lvalue(e);
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
            dyn()->fail(u, f"cannot pass '{dyn()->tu.str(_op->type_)}' to an '@inout' parameter of type '{dyn()->tu.str(pt)}'; an '@inout' argument must be a mutable lvalue");
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
            dyn()->warn(a->expr,
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
            else if view.size() > 0 { p = view[view.size() - 1]; }   // pack tail
            if (p == &null) || (p->type_ == &null) { if a->lit != LitKind::None { dyn()->type_of(a->expr, &null); } continue; }
            var pt = p->type_->canonical;
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
            if pt != &null { dyn()->check_convertible(a->expr, pt); }
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

    /// The declared return type of \p f after deduction. Expression-bodied
    /// functions without an annotation are inferred on demand.
    fn call_result_type(self, f: *FunctionDecl, r: *OvlResult) -> *Type {
        if f->is_noreturn { return dyn()->tu.builtin(BuiltinKind::Never); }
        var rt = dyn()->fn_return_type(f);
        if rt == &null { return &null; }
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
        if f->generic_params.size() > 0 {
            var args = vec::<*Type>();
            var gps  = f->generic_params;
            var ok   = true;
            for var i: usize = 0; i < gps.size(); ++i {
                var gp = gps[i];
                if (gp == &null) || gp->is_pack { continue; }
                var b = r->ded.lookup(static_cast::<*Decl>(f), gp->index);
                if (b == &null) || b->is_dependent() { ok = false; break; }
                args.push_back(b);
            }
            if ok {
                dyn()->sc->instances->instance_for(NameLookup::representative(static_cast::<*Decl>(f)), &args,
                                                   dyn()->sc->ctx->fid, NameLookup::ctx_of(static_cast::<*Decl>(f)));
            }
        }
        return rt;
    }

    // === the call ===========================================================

    fn type_call(self, n: *CallExpr, expected: *Type) -> *Type {
        var callee = dyn()->tu.strip_parens(n->callee);
        if callee == &null { dyn()->fail(n, "call with no callee"); return &null; }

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
            if isa::<GenericParamDecl>(d) { dyn()->mark_unknown(n); self._type_args_blind(n); return &null; }
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

        var r = dyn()->ovl.resolve(&all, &args, has_receiver, n->range, name, recv);
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
        self._warn_unmarked(&args, &r);
        self._write_arg_map(n, r.decl, &args, &r);
        var rt = self.call_result_type(r.decl, &r);
        if rt == &null { dyn()->mark_unknown(n); return &null; }
        return rt;
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
    priv fn _ctor_call(self, n: *CallExpr, rec: *Type) -> *Type {
        var d = dyn()->tu.record_decl(rec);
        if d == &null {
            // an alias of a builtin, `i32(x)` style: not a call.
            dyn()->fail(n, f"'{dyn()->tu.str(rec)}' is not constructible with a call; use 'as\x27");
            return &null;
        }
        if rec->is_dependent() { dyn()->mark_unknown(n); self._type_args_blind(n); return &null; }

        var body = dyn()->tu.pattern_of(d);   // an unfilled instance has an empty table.
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
            dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                f"'{dyn()->tu.decl_name(d)}' declares no constructor taking arguments"
            ).first(n->range)
             .note(d->range.start, "type declared here").first(d->range)
             .emit();
            n->poison();
            return &null;
        }
        var args = vec::<ArgInfo>();
        var ok = self.build_args(n->args, &args);
        var r = dyn()->ovl.resolve(&cands, &args, true, n->range, dyn()->tu.decl_name(d), rec);
        if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
        if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
        if !ok { dyn()->poison_only(n); return &null; }
        r.ded.bind_from_record(rec);
        self.finish_call_args(r.decl, &args, &r);
        self._warn_unmarked(&args, &r);
        self._write_arg_map(n, r.decl, &args, &r);
        return rec;
    }

    /// Call through a function-pointer-typed value.
    priv fn _call_through(self, n: *CallExpr, t: *Type) -> *Type {
        if t == &null {
            self._type_args_blind(n);
            if !n->callee->is_poisoned() { dyn()->mark_unknown(n); } else { dyn()->poison_only(n); }
            return &null;
        }
        var ft = dyn()->tu.strip_nullable(t);
        if ft != t {
            // A nullable callable is not callable: there is no code to run on
            // the null side, and nothing implicitly unwraps it here either.
            self._type_args_blind(n);
            dyn()->fail(n, f"'{dyn()->tu.str(t)}' may be null; unwrap it before calling, with '??' or 'unwrap!()\x27");
            return &null;
        }
        ft = canon_unqual(ft);   // a `const` callable calls the same code.
        if (ft == &null) || (!isa::<FunctionPointerType>(ft)) {
            self._type_args_blind(n);
            dyn()->fail(n, f"'{dyn()->tu.str(t)}' is not callable");
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
            dyn()->fail(n, f"'{dyn()->tu.str(ft)}' takes {fp->params.size()} argument(s), {n->args.size()} given");
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
                    dyn()->warn(a, f"argument to '@inout' parameter {i + 1} of '{dyn()->tu.str(ft)}' is not "
                                   "marked with '&'; the marker will be required in a future release");
                }
                if target->type_ != &null {
                    var lref = dyn()->sc->types->cxx_lref(canon_unqual(pt));
                    var r = dyn()->conv.implicit_arg(target->type_, lref, target->value_category, self._const_lvalue(target));
                    if r == ImplicitRank::None {
                        dyn()->fail(target, f"cannot pass '{dyn()->tu.str(target->type_)}' to an '@inout' parameter of type '{dyn()->tu.str(pt)}'; an '@inout' argument must be a mutable lvalue");
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

