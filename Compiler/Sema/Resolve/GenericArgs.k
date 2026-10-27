/// --- The Kairo Project ------------------- Sema/Resolve/GenericArgs.k --- ///
///
///   \brief Applying a written generic-argument list to a primary's
///          parameters: arity (defaults and a trailing pack counted), then
///          positional + named arguments into parameter order, defaults
///          filled, pack tail gathered.
///
///   \detail
///     The one copy. Three passes apply an argument list, and they used to
///     disagree: TypeResolve (a type position, `var v: std::vector<i32>`)
///     had the full rule; ExprTyper (`std::vector<i32>()` in expression
///     position) demanded an exact count and so rejected every C++ template
///     with a defaulted parameter; ChainBinding (`Foo<A>::x`) deferred
///     anything but the exact-count case to inference.
///
///     Defaults are READ here, never resolved. A Kairo primary's default is
///     resolved in the PRIMARY's scope with its own params in frame, which
///     only TypeResolve can set up, so it demands them before calling
///     (TypeResolve::_demand_default). ExprTyper and ChainBinding run after T
///     has resolved every one, and a foreign primary's defaults were settled
///     by its own TU. A default still without a canonical is dependent: its
///     slot is the parameter itself, and `inst_dependent` says so.
///
///     Nothing here poisons a node. A failure returns false with the
///     diagnostic already emitted (when `report` is set); the caller poisons
///     whatever node it owns -- a ChainType for T, an Expr for X.
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
import Sema::Type::ArgumentDeduction::*;
import AST::Context::ASTContext::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::DeclFacts::*;
import Token::Token::*;
import Diagnostic::Registry::*;

class GenericArgs {
    pub var sc: *SemaContext;

    /// Emit diagnostics. Off for a caller that only probes: ChainBinding
    /// binds `Foo<A>::x` ahead of X, which types the same expression
    /// afterwards and owns any error in it.
    pub var report: bool = true;

    /// Set by collect() when a slot stands in with the parameter itself: a
    /// dependent default, or (stand-in mode) a dependent argument with no
    /// canonical. The instance is then instantiation-dependent.
    pub var inst_dependent: bool = false;

    fn GenericArgs(self) { self.sc = &null; }
    fn GenericArgs(self, sc: *SemaContext) { self.sc = sc; }

    /// \p given arguments against \p gps. A parameter with a default is not
    /// required, and a pack takes any surplus. \p nm names \p d in the
    /// message; \p site is the argument list's range.
    fn check_arity(self, d: *Decl, nm: string, gps: FrozenList::<*GenericParamDecl>,
                   given: usize, site: SourceRange) -> bool {
        var total = gps.size();
        var required: usize = 0;
        var has_pack = false;
        for var i: usize = 0; i < total; ++i {
            var gp = gps[i];
            if gp == &null { continue; }
            if gp->is_pack { has_pack = true; continue; }
            if gp->default_type == &null { required += 1; }
        }

        if (given == 0) && (total == 0) { return true; }

        if (given > 0) && (total == 0) {
            if self.report {
                self.sc->diag->report(DiagID::R032E, site.start,
                    f"'{nm}' is not generic and takes no generic arguments"
                ).first(site)
                 .note(DiagID::R032N, d->range.start, "declared here").first(d->range).emit();
            }
            return false;
        }
        if given < required {
            if self.report {
                self.sc->diag->report(DiagID::R032E, site.start,
                    f"'{nm}' requires at least {required} generic argument(s), but {given} were given"
                ).first(site)
                 .note(DiagID::R032N, d->range.start, "declared here").first(d->range).emit();
            }
            return false;
        }
        if (!has_pack) && (given > total) {
            if self.report {
                self.sc->diag->report(DiagID::R032E, site.start,
                    f"'{nm}' takes at most {total} generic argument(s), but {given} were given"
                ).first(site)
                 .note(DiagID::R032N, d->range.start, "declared here").first(d->range).emit();
            }
            return false;
        }
        return true;
    }

    /// Positional + named \p gargs into parameter order, defaults filled,
    /// pack tail gathered. Out: one canonical per NON-pack param slot, then
    /// the pack's args flat (the store keys on the whole vector; a pack of
    /// two is two entries). Named args that name nothing, or name a slot
    /// twice, are errors.
    ///
    /// Whether \p cty is the kind of argument \p gp takes: a value (a
    /// canonical value_arg, or a value parameter standing in) for an `eval`
    /// parameter, a type for a type parameter. Reported when not.
    priv fn _kind_fits(self, primary: *Decl, gp: *GenericParamDecl, cty: *Type, a: *ChainType::GenericArg) -> bool {
        if gp == &null { return true; }
        var c = canon_unqual(cty);
        var is_value = false;
        if isa::<TypeExpr>(c) { is_value = cast::<TypeExpr>(c)->is_value; }
        else if isa::<GenericParamType>(c) {
            var g = cast::<GenericParamType>(c);
            var ps = decl_generic_params(g->owner);
            var ix = static_cast::<usize>(g->param_index);
            if (g->owner != &null) && (ix < ps.size()) && (ps[ix] != &null) { is_value = ps[ix]->is_const_param; }
        }
        if is_value == gp->is_const_param { return true; }
        if self.report {
            var nm  = self.sc->ctx->get_spelling(gp->name);
            var at  = (a->ty->range) if (a->ty != &null) else (a->name_range);
            var msg = (f"'{nm}' is a generic value parameter; it takes a compile-time value, not a type") if (gp->is_const_param) else (f"'{nm}' is a type parameter; it takes a type, not a value");
            var b = self.sc->diag->report(DiagID::R001E, at.start, msg);
            b.first(at);
            b.note(DiagID::R001N, gp->range.start, f"'{nm}' is declared here").first(gp->range);
            b.emit();
        }
        return false;
    }

    /// \p stand_in: a dependent argument with no canonical (a raw dependent
    /// composite) takes the parameter itself instead of failing. X and
    /// ChainBinding want that -- the result is a dependent pattern either
    /// way -- and T does not: its null slot is a poisoned type.
    fn collect(self, primary: *Decl, gps: FrozenList::<*GenericParamDecl>,
               gargs: FrozenList::<ChainType::GenericArg>, stand_in: bool,
               out: *vec::<*Type>) -> bool {
        var total = gps.size();
        var slots = vec::<*Type>();
        var filled = vec::<bool>();
        var pack_index: usize = usize(-1);
        for var i: usize = 0; i < total; ++i {
            slots.push_back(&null);
            filled.push_back(false);
            if (gps[i] != &null) && gps[i]->is_pack && (pack_index == usize(-1)) { pack_index = i; }
        }
        var pack_args = vec::<*Type>();

        var pos: usize = 0;
        for var i: usize = 0; i < gargs.size(); ++i {
            var a = gargs.get(i);

            // The slot this argument lands in, before its type is read, so a
            // stand-in can name the right parameter.
            var target: usize = usize(-1);
            if a->name != &null {
                var nimm = self.sc->ctx->get_ident_imm(a->name->name);
                for var j: usize = 0; j < total; ++j {
                    if (gps[j] != &null) && (self.sc->ctx->get_ident_imm(gps[j]->name) == nimm) { target = j; break; }
                }
                if target == usize(-1) {
                    if self.report {
                        var nm = self.sc->ctx->get_spelling(a->name->name);
                        self.sc->diag->report(DiagID::R033E, a->name_range.start,
                            f"no generic parameter named '{nm}\x27"
                        ).first(a->name_range).emit();
                    }
                    return false;
                }
                if filled[target] {
                    if self.report {
                        var nm = self.sc->ctx->get_spelling(a->name->name);
                        self.sc->diag->report(DiagID::R034E, a->name_range.start,
                            f"generic argument '{nm}' specified more than once"
                        ).first(a->name_range).emit();
                    }
                    return false;
                }
            } else if (pack_index != usize(-1)) && (pos >= pack_index) {
                target = pack_index;
            } else {
                if pos >= total { return false; }   // arity bounded this; defensive.
                target = pos;
            }

            var cty: *Type = &null;
            if a->ty != &null { cty = a->ty->canonical; }
            if (cty == &null) && stand_in && (a->ty != &null)
            && (a->ty->is_dependent() || a->ty->is_instantiation_dependent()) {
                cty = self.sc->types->generic_param(primary, gps[target]->index, false);
                self.inst_dependent = true;
            }

            // A value parameter takes a value (`Buf<4>`, `Buf<N>`), a type
            // parameter a type (EVAL.md 3).
            if (cty != &null) && (!self._kind_fits(primary, gps[target], cty, a)) { return false; }

            if a->name != &null {
                slots[target]  = cty;
                filled[target] = true;
                continue;
            }
            if target == pack_index {
                pack_args.push_back(cty);
                continue;
            }
            slots[target]  = cty;
            filled[target] = true;
            pos += 1;
        }

        // defaults + emit
        var c = NameLookup::ctx_of(primary);
        var foreign = (c != &null) && (c != self.sc->ctx);
        for var i: usize = 0; i < total; ++i {
            var gp = gps[i];
            if gp == &null { continue; }
            if gp->is_pack {
                for var k: usize = 0; k < pack_args.size(); ++k {
                    if pack_args[k] == &null { return false; }
                    out->push_back(pack_args[k]);
                }
                continue;
            }
            if !filled[i] {
                if gp->default_type == &null { return false; }   // arity said otherwise; defensive.
                var dc = gp->default_type->canonical;
                // A FOREIGN default comes back as the header's canonical, and
                // a default naming the primary's own params (`class A =
                // allocator<T>`) is dependent there. Every param before this
                // one is already placed, so substitute them in: without it
                // `std::vector<i32>` keyed as `vector<i32, allocator<T>>`, a
                // dependent type with no instance behind it, and nothing (the
                // clang fill included) ever looked past the pattern.
                if (dc != &null) && dc->is_dependent() && foreign {
                    var ded = Deduction(self.sc, &null);
                    var rep = NameLookup::representative(primary);
                    for var j: usize = 0; j < out->size(); ++j { ded.bind(rep, static_cast::<u32>(j), (*out)[j]); }
                    var sub = ded.substitute(dc);
                    if (sub != &null) && (!sub->is_dependent()) { dc = sub; }
                    else { dc = &null; }      // still names an unplaced param: the stand-in below.
                }
                if dc == &null {
                    if gp->default_type->is_poisoned() { return false; }
                    // Dependent default (mentions the primary's own params):
                    // substitution is M2's. Stand in with the param itself.
                    self.inst_dependent = true;
                    out->push_back(self.sc->types->generic_param(primary, gp->index, false));
                    continue;
                }
                out->push_back(dc);
                continue;
            }
            if slots[i] == &null { return false; }
            out->push_back(slots[i]);
        }
        return true;
    }
}
