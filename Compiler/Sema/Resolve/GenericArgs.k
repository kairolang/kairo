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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::DeclFacts::decl_generic_params
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations::GenericParamDecl
import AST::Node::Types::{
    ChainType,
    GenericParamType,
    TypeExpr,
}
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Diagnostic::NoteText::{
    declared_here,
    named_declared_here,
}
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Sema::Type::ArgumentDeduction::Deduction

pub class GenericArgs {
    pub var sc: unsafe *SemaContext

    /// Emit diagnostics. Off for a caller that only probes: ChainBinding
    /// binds `Foo<A>::x` ahead of X, which types the same expression
    /// afterwards and owns any error in it.
    pub var report: bool = true

    /// Set by collect() when a slot stands in with the parameter itself: a
    /// dependent default, or (stand-in mode) a dependent argument with no
    /// canonical. The instance is then instantiation-dependent.
    pub var inst_dependent: bool = false

    fn GenericArgs(self) {
        self.sc = &null
    }

    fn GenericArgs(self, sc: unsafe *SemaContext) {
        self.sc = sc
    }

    /// \p given arguments against \p gps. A parameter with a default is not
    /// required, and a pack takes any surplus. \p nm names \p d in the
    /// message; \p site is the argument list's range.
    fn check_arity(self,
                   d:        unsafe *Decl,
                   const nm: string,
                   gps:      FrozenList<unsafe *GenericParamDecl>,
                   given:    usize,
                   site:     SourceRange) -> bool {
        var total           = gps.size()
        var required: usize = 0
        var has_pack        = false
        for var i: usize = 0; i < total; ++i {
            var unsafe *gp = gps[i]
            if gp == &null {
                continue
            }

            if gp->is_pack {
                has_pack = true
                continue
            }

            if gp->default_type == &null {
                required += 1
            }
        }

        if given == 0 && total == 0 {
            return true
        }

        if given > 0 && total == 0 {
            if self.report {
                self.sc->diag->report(
                    DiagID::R032E,
                    site.start,
                    f"'{nm}' is not generic and takes no generic arguments",
                ).first(site)->note(
                    DiagCode(DiagID::R032N),
                    d->range.start,
                    declared_here(),
                )->first(d->range)->emit()
            }

            return false
        }

        if given < required {
            if self.report {
                self.sc->diag->report(
                    DiagID::R032E,
                    site.start,
                    f"'{nm}' requires at least {required} generic argument(s), but {given} were given",
                ).first(site)->note(
                    DiagCode(DiagID::R032N),
                    d->range.start,
                    declared_here(),
                )->first(d->range)->emit()
            }

            return false
        }

        if !has_pack && given > total {
            if self.report {
                self.sc->diag->report(
                    DiagID::R032E,
                    site.start,
                    f"'{nm}' takes at most {total} generic argument(s), but {given} were given",
                ).first(site)->note(
                    DiagCode(DiagID::R032N),
                    d->range.start,
                    declared_here(),
                )->first(d->range)->emit()
            }

            return false
        }

        return true
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
    priv fn _kind_fits(self,
                       primary: unsafe *Decl,
                       gp:      unsafe *GenericParamDecl,
                       cty:     unsafe *Type,
                       a:       unsafe *ChainType::GenericArg) -> bool {
        if gp == &null {
            return true
        }

        var unsafe *c       = canon_unqual(cty)
        var        is_value = false
        if isa<TypeExpr>(c) {
            is_value = cast<TypeExpr>(c)->is_value
        } else if isa<GenericParamType>(c) {
            var unsafe *g = cast<GenericParamType>(c)
            var        ps = decl_generic_params(g->owner)
            var        ix = (g->param_index as usize)
            if g->owner != &null && ix < ps.size() && ps[ix] != &null {
                is_value = ps[ix]->is_const_param
            }
        }

        if is_value == gp->is_const_param {
            return true
        }

        if self.report {
            var nm = self.sc->ctx->get_spelling(gp->name)
            var at = if (a->ty != &null) => (a->ty->range) else => a->name_range
            var msg = if (gp->is_const_param) => (f"'{nm}' is a generic value parameter; it takes a compile-time value, not a type")
                      else => f"'{nm}' is a type parameter; it takes a type, not a value"
            var b = self.sc->diag->report(DiagID::R060E, at.start, msg)
            b.first(at)
            b.note(DiagCode(DiagID::R060N), gp->range.start, named_declared_here(nm))->first(
                gp->range,
            )

            b.emit()
        }

        return false
    }

    /// \p stand_in: a dependent argument with no canonical (a raw dependent
    /// composite) takes the parameter itself instead of failing. X and
    /// ChainBinding want that -- the result is a dependent pattern either
    /// way -- and T does not: its null slot is a poisoned type.
    fn collect(self,
               primary:  unsafe *Decl,
               gps:      FrozenList<unsafe *GenericParamDecl>,
               gargs:    FrozenList<ChainType::GenericArg>,
               stand_in: bool,
               out:      unsafe *cxx::std::vector<unsafe *Type>) -> bool {
        var total             = gps.size()
        var slots             = cxx::std::vector<unsafe *Type>()
        var filled            = cxx::std::vector<u8>()
        var pack_index: usize = usize::MAX
        for var i: usize = 0; i < total; ++i {
            slots.push_back(&null)
            filled.push_back(0)
            if gps[i] != &null && gps[i]->is_pack && pack_index == usize::MAX {
                pack_index = i
            }
        }

        var pack_args = cxx::std::vector<unsafe *Type>()

        var pos: usize = 0
        for var i: usize = 0; i < gargs.size(); ++i {
            var unsafe *a = gargs.get(i)

            // The slot this argument lands in, before its type is read, so a
            // stand-in can name the right parameter.
            var target: usize = usize::MAX
            if a->name != &null {
                var nimm = self.sc->ctx->get_ident_imm(a->name->name)
                for var j: usize = 0; j < total; ++j {
                    if gps[j] != &null && self.sc->ctx->get_ident_imm(gps[j]->name) == nimm {
                        target = j
                        break
                    }
                }

                if target == usize::MAX {
                    if self.report {
                        var nm = self.sc->ctx->get_spelling(a->name->name)
                        self.sc->diag->report(
                            DiagID::R033E,
                            a->name_range.start,
                            f"no generic parameter named '{nm}'",
                        ).first(a->name_range)->emit()
                    }

                    return false
                }

                if filled[target] != 0 {
                    if self.report {
                        var nm = self.sc->ctx->get_spelling(a->name->name)
                        self.sc->diag->report(
                            DiagID::R034E,
                            a->name_range.start,
                            f"generic argument '{nm}' specified more than once",
                        ).first(a->name_range)->emit()
                    }

                    return false
                }
            } else if pack_index != usize::MAX && pos >= pack_index {
                target = pack_index
            } else {
                if pos >= total { // arity bounded this; defensive.
                    return false
                }

                target = pos
            }

            var cty: unsafe *Type = &null
            if a->ty != &null {
                cty = a->ty->canonical
            }

            if cty == &null
                && stand_in
                && a->ty != &null
                && (a->ty->is_dependent() || a->ty->is_instantiation_dependent()) {
                cty = self.sc->types->generic_param(primary, gps[target]->index, false)
                self.inst_dependent = true
            }

            // A value parameter takes a value (`Buf<4>`, `Buf<N>`), a type
            // parameter a type (Compiler/Spec/Eval.md#generic-value-parameters).
            if cty != &null && !self._kind_fits(primary, gps[target], cty, a) {
                return false
            }

            if a->name != &null {
                slots[target]  = cty
                filled[target] = 1
                continue
            }

            if target == pack_index {
                pack_args.push_back(cty)
                continue
            }

            slots[target]  = cty
            filled[target] = 1
            pos += 1
        }

        // defaults + emit
        var unsafe *c      = NameLookup::ctx_of(primary)
        var        foreign = c != &null && c != self.sc->ctx
        for var i: usize = 0; i < total; ++i {
            var unsafe *gp = gps[i]
            if gp == &null {
                continue
            }

            if gp->is_pack {
                for var k: usize = 0; k < pack_args.size(); ++k {
                    if pack_args[k] == &null {
                        return false
                    }

                    out->push_back(pack_args[k])
                }

                continue
            }

            if filled[i] == 0 {
                if gp->default_type == &null { // arity said otherwise; defensive.
                    return false
                }

                var unsafe *dc = gp->default_type->canonical
                // A default naming the primary's own params (`class A =
                // allocator<T>`, `<K, V = K>`) is dependent on THEM. Every
                // param before this one is already placed, so substitute
                // them in: without it `std::vector<i32>` keyed as
                // `vector<i32, allocator<T>>` and `Pair<i32>` as
                // `Pair<i32, K>`, dependent types with no instance behind
                // them, and C++ was handed a `K` nothing declares.
                //
                // A FOREIGN result that is still dependent names an unplaced
                // param. A Kairo one may be dependent through its ARGUMENTS
                // (`Pair<U>` in a generic body is `Pair<U, U>`), which is a
                // real answer; only an unbound param (null) is not.
                if dc != &null && dc->is_dependent() {
                    var        ded  = Deduction(self.sc, &null)
                    var unsafe *rep = NameLookup::representative(primary)
                    for var j: usize = 0; j < out->size(); ++j {
                        ded.bind(rep, j as u32, (*out)[j])
                    }

                    var unsafe *sub = ded.substitute(dc)
                    if sub != &null && (!foreign || !sub->is_dependent()) {
                        dc = sub
                    } else {
                        dc = &null
                    } // still names an unplaced param: the stand-in below.
                }

                if dc == &null {
                    if gp->default_type->is_poisoned() {
                        return false
                    }

                    // A default substitution cannot place (it names a
                    // later param, or has no canonical): stand in with the
                    // param itself, instantiation-dependent.
                    self.inst_dependent = true
                    out->push_back(self.sc->types->generic_param(primary, gp->index, false))
                    continue
                }

                out->push_back(dc)
                continue
            }

            if slots[i] == &null {
                return false
            }

            out->push_back(slots[i])
        }

        return true
    }
}
