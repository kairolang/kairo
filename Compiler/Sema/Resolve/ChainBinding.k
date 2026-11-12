/// --- The Kairo Project ------------------ Sema/Resolve/ChainBinding.k --- ///
///
///   \brief Bind every chain step: `a.b`, `p->x`, `Foo::Bar`, `m::f`.
///
///   \detail
///     N binds the HEAD of a chain (an ordinary unqualified name) and hands
///     every later step through untouched, because a step's meaning depends
///     on what the previous one denotes -- a type's members, a module's
///     table, a value's TYPE's members -- and the value case needs
///     canonicals that only exist after T. This pass runs after T, walks
///     each chain left to right, and binds what is decidable from DECLARED
///     types.
///
///     What is decidable: any step whose left side is a type, a module, or a
///     value with a declared type (param, field, typed var, the synthesized
///     `self` receiver). That is `this->x` in C++ terms, and it is why
///     `self.x` in a method binds to the field here rather than in inference.
///
///     What is NOT: a step after a call (`f().x`), after an inferred `var`
///     (`var a = g(); a.x`), or after an overload set. Those are marked
///     NeedsInference and left with null slots -- NOT poisoned, NOT
///     diagnosed. TypeInference owns them (one writer rule: it promotes
///     candidate cells and fills the rest).
///
///     A step rooted in a GENERIC PARAMETER is decided by that parameter's
///     declaration, not deferred wholesale
///     A bounded `<T impl I>` / `<T derives B>` resolves against the bound's
///     members right here, once, at the template. An unbounded `<T>` has no
///     members at all and says so -- at the template, which is the whole
///     difference from C++. Only a dependent COMPOSITE (`[T]`, an unfilled
///     `Foo<T>::Inner`) is still Dependent for M2 (hard invariant #5).
///
///   \par One error, one home
///     "no member named X", "X is a type, use ::", "'::' after a value",
///     "'.' on a pointer (use ->)", ambiguous non-function members across
///     bases, "T has no members": HERE. Unknown head: N. Bad types: T.
///     Access: AccessCheck. Whether an INSTANTIATION satisfies the bound:
///     ConformanceChecking.
///
///   Phase: RESOLVE (T stage, after TypeResolution)
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
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::SymbolTable::{
    DeclName,
    OverloadCell,
}
import AST::DeclFacts::{
    decl_cxx_spelling,
    decl_generic_params,
    decl_pattern,
    ffi_hide_tags,
}
import AST::Kind::DeclKind::DeclKind
import AST::LangItems::WellKnownType
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,    BuiltinKind,       BuiltinType, QualifiedType, RecordType, builtin_for_token,
    canon_has_const, canon_has_volatile, canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    ConstraintExpr,
    ParenExpr,
    TypeOfExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::ConditionalStmt
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, ChainType, FunctionPointerType, GenericParamType, MapType,
    NullableType,     PointerType,      SetType,   VectorType,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Support::FileIO::Path::Path
import Sema::Resolve::GenericArgs::GenericArgs
import Sema::Resolve::MemberLookup::MemberLookup
import Sema::Resolve::NameLookup::NameLookup
import Sema::Resolve::ResolutionTrace::MemberOutcome
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::ArgumentDeduction::Deduction
import Sema::Type::Substitution::Substitution
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    is_annotation,
    token_kind_to_readable_string,
}

/// \enum AnchorKind
/// \brief What the LEFT side of a step denotes.
pub enum AnchorKind derives u8 {
    Module = 0,     ///< a module/TU scope: `::` steps do plain table lookup.
    Type,           ///< a type: `::` steps do member lookup (statics, nested, variants).
    Value,          ///< a value with a canonical type: `.`/`->` steps do member lookup.
    NeedsInference, ///< a value whose type is not declared.
    Dependent,      ///< rooted in a generic parameter.
    Errored,        ///< already diagnosed; stay silent.
}

/// \class Anchor
pub class Anchor {
    pub var kind: AnchorKind = AnchorKind::Errored
    /// Module: every scope the base denotes. More than one when a name is
    /// bound to a module reopened across files -- they are ONE namespace,
    /// so a `::` step searches all of them (Compiler/Spec/Imports.md#overlays-and-visibility).
    pub var scopes: cxx::std::vector<unsafe *DeclContext>
    pub var decl:   unsafe *Decl                          = &null ///< Type: the record decl. Value: the decl (for notes).
    pub var ty:     unsafe *Type                          = &null ///< Type: its record. Value: the canonical.
    fn Anchor(self) { }
}

pub class ChainBinding derives RecursiveASTVisitor<ChainBinding> {
    pub var sc: unsafe *SemaContext
    var     ml: MemberLookup

    pub var n_bound:     usize = 0
    pub var n_cands:     usize = 0
    pub var n_inference: usize = 0
    pub var n_dependent: usize = 0
    pub var n_errored:   usize = 0

    priv var _self_imm: u32 = u32::MAX
    /// _bind_step is running for ExprTyper (bind_step), not for run().
    priv var _from_typer: bool = false

    /// Default ctor so ChainBinding can be a MEMBER of a pass that builds it
    /// in its own body (ExprTyper holds one). Leaves sc null: every entry
    /// point dereferences it, so a default-constructed binder must be
    /// assigned a real one before use.
    fn ChainBinding(self) {
        self.sc = &null
    }

    fn ChainBinding(self, sc: unsafe *SemaContext) {
        self.sc = sc
        self.ml = MemberLookup(sc)
    }

    /// One-time setup the STEP BINDER needs, split out of run() because
    /// ExprTyper drives bind_step() directly without ever walking the program
    /// here. Idempotent: run() calls it too, and calling it twice costs an
    /// intern hit and a re-index, not correctness.
    fn prepare(self) {
        self._self_imm = self.sc->imm_table()->intern_ident_copy(token_kind_to_readable_string(TokenKind::KwSelf))
        self.ml.index_extensions()
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::NamesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        self.prepare()

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop {
                break
            }

            var item = *items->get(i)
            match item.get_kind() {
                case TopLevelKind::Decl {
                    self.dyn()->dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dyn()->dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dyn()->dispatch_expr(item.as_expr())
                }
            }
        }
    }

    /// # The chain

    fn traverse_chain_expr(self, n: unsafe *ChainExpr) -> unsafe *ChainExpr {
        if n == &null {
            return n
        }

        // Base + generic args first (nested chains inside args bind too).
        var unsafe *out = RecursiveASTVisitor<ChainBinding>::traverse_chain_expr(self, n)

        var a = self._anchor_of_base(n)
        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *st = n->steps.get(i)
            if st == &null {
                break
            }

            if st->resolved_decl != &null { // idempotent re-run.
                a = self._anchor_after(st->resolved_decl, st, self._through_of(a, st))
                continue
            }

            a = self._bind_step(n, st, a)
        }

        if a.kind == AnchorKind::Dependent {
            n->expr_flags.set(Expr::ExprFlags::IsDependent)
            n->expr_flags.set(Expr::ExprFlags::IsInstantiationDependent)
        }

        return out
    }

    /// What the base expression denotes, from N's binding + T's canonical.
    priv fn _anchor_of_base(self, n: unsafe *ChainExpr) -> Anchor {
        var a = Anchor()

        if n->base == &null {
            // `::std::x`: global root.
            a.kind = AnchorKind::Module
            a.scopes.push_back(unsafe (self.sc->tu as unsafe *DeclContext))
            return a
        }

        if n->base->is_poisoned() {
            a.kind = AnchorKind::Errored
            return a
        }

        if isa<NamedIdentExpr>(n->base) {
            var unsafe *id = cast<NamedIdentExpr>(n->base)
            if id->is_deferred() {
                // A cell of nothing but ModuleDecls is one reopened namespace,
                // not an overload set N failed to collapse: the canonicals are
                // distinct decls but the SCOPE is the union of their tables.
                // Anything else in the cell is a real overload set.
                var unsafe *cell   = id->candidate_cell
                var        all_mod = cell->size() > 0
                for var i: usize = 0; i < cell->size(); ++i {
                    if !isa<Declarations::ModuleDecl>(cell->get(i)) {
                        all_mod = false
                        break
                    }
                }

                if !all_mod {
                    a.kind = AnchorKind::NeedsInference
                    return a
                }

                a.kind = AnchorKind::Module
                // Each candidate's whole ring, deduped (module_scopes skips a
                // scope already pushed): two reopenings of one ring would
                // otherwise contribute it twice.
                for var i: usize = 0; i < cell->size(); ++i {
                    NameLookup::module_scopes(cell->get(i), &a.scopes)
                }

                return a
            }

            // A primitive head (`f128::MAX`). N leaves it unbound on purpose;
            // this is the first pass that sees the member after it. A
            // primitive declares no members, so this is the type-position
            // R024E in expression position, naming what was asked for.
            if is_annotation(id->name.kind) {
                // `i32::make()`, `void::probe()`: a static an `extend` of the
                // primitive declares (extends.mdx: an extension adds static
                // functions to any type it can extend). Only a `::` step this
                // TU can see an extension member for; anything else is the
                // R024E below (P325).
                var unsafe *pt = self._primitive_static_head(id, n)
                if pt != &null {
                    a.kind = AnchorKind::Type
                    a.ty   = pt
                    return a
                }

                var sp   = self.sc->ctx->get_spelling(id->name)
                var what = "a member"
                if n->steps.size() > 0 {
                    var unsafe *st0 = n->steps.get(0)
                    if st0 != &null && st0->name != &null {
                        what = f"'{self.sc->ctx->get_spelling(st0->name->name)}'"
                    }
                }

                self.sc->diag->report(
                    DiagID::R024E,
                    n->range.start,
                    f"'{sp}' is a primitive type; it has no member {what}",
                ).first(n->range)->emit()
                id->poison()
                n->poison()
                a.kind = AnchorKind::Errored
                return a
            }

            if !id->is_bound() { // N diagnosed.
                a.kind = AnchorKind::Errored
                return a
            }

            if !id->generic_args.is_empty() {
                return self._anchor_of_generic_head(id)
            }

            return self._anchor_after(id->resolved_decl, &null)
        }

        // Any other base -- a call, a subscript, a paren, a literal -- has a
        // type only inference can name.
        a.kind = AnchorKind::NeedsInference
        return a
    }

    /// `Box<i32>::make()` / `Stack<i32>()`: a type head with explicit args in
    /// EXPRESSION position. T resolved the arg TYPES (the RAV dispatches them);
    /// the application is GenericArgs', the rule a type position uses --
    /// defaults, named args and a pack tail included. Probed silently: X
    /// types this expression afterwards and owns any arity error, so a list
    /// that does not apply leaves the step to inference.
    priv fn _anchor_of_generic_head(self, id: unsafe *NamedIdentExpr) -> Anchor {
        return self._anchor_of_generic(id->resolved_decl, &id->generic_args, id->range)
    }

    /// The instance a record named with explicit args denotes, as a head
    /// (`Box<i32>::make()`) or as a `::` step (`ns::Box<i32>::make()`,
    /// `cxx::std::is_same<A, B>::value`). The step form used to anchor the
    /// PATTERN: a member the pattern declares outright still bound, but one
    /// only the instance has -- through a base that depends on the args,
    /// `is_same<A, B> : integral_constant<bool, __is_same(A, B)>` -- was
    /// R025E "no member named 'value'", and nothing was ever filled.
    priv fn _anchor_of_generic(self,
                               d:     unsafe *Decl,
                               gargs: *FrozenList<ChainType::GenericArg>,
                               range: SourceRange) -> Anchor {
        var        a      = Anchor()
        var unsafe *canon = NameLookup::representative(d)
        a.decl = canon
        var gps = decl_generic_params(canon)
        if gps.size() == 0 {
            a.kind = AnchorKind::NeedsInference // not a record with params.
            return a
        }

        for var i: usize = 0; i < gargs->size(); ++i {
            var unsafe *g = gargs->get(i)
            if g->ty == &null || g->ty->is_poisoned() {
                a.kind = AnchorKind::Errored
                return a
            }

            if g->ty->canonical == &null
                && !g->ty->is_dependent()
                && !g->ty->is_instantiation_dependent() {
                a.kind = AnchorKind::Errored
                return a // T left it unresolved and undiagnosed: ICE territory.
            }
        }

        var ga = GenericArgs(self.sc)
        ga.report = false
        var args = cxx::std::vector<unsafe *Type>()
        if !ga.check_arity(canon, "", gps, gargs->size(), range)
            || !ga.collect(canon, gps, *gargs, true, unsafe &args) {
            a.kind = AnchorKind::NeedsInference
            return a
        }

        var dep = ga.inst_dependent
        for var i: usize = 0; i < args.size(); ++i {
            if args[i]->is_dependent() || args[i]->is_instantiation_dependent() {
                dep = true
            }
        }

        if dep {
            a.kind = AnchorKind::Dependent
            return a
        }

        var unsafe *e = self.sc->instances->instance_for(
            canon,
            unsafe &args,
            self.sc->ctx->fid,
            NameLookup::ctx_of(canon),
        )

        var unsafe *inst = if (e != &null) => (e->decl) else => canon
        a.kind = AnchorKind::Type
        a.ty   = self.sc->types->record(inst, unsafe &args) // lookup walks inst's body: the spec's, if any.
        return a
    }

    /// The anchor a bound decl provides for the NEXT step.
    priv fn _anchor_after(self,
                          d:       unsafe *Decl,
                          st:      unsafe *ChainExpr::Step,
                          through: unsafe *Type = &null) -> Anchor {
        var a = Anchor()
        if d == &null {
            a.kind = AnchorKind::Errored
            return a
        }

        if d->is_poisoned() {
            a.kind = AnchorKind::Errored
            return a
        }

        // `::Name<args>`: the instance, exactly as for a head.
        if st != &null
            && !st->generic_args.is_empty()
            && (isa<Declarations::ClassDecl>(d)
                || isa<Declarations::StructDecl>(d)
                || isa<Declarations::UnionDecl>(d)) {
            return self._anchor_of_generic(d, &st->generic_args, st->range)
        }

        match d->kind {
            case DeclKind::ModuleDecl {
                a.kind = AnchorKind::Module
                // N collapses a reopened module's cell to its canonical, so a
                // single decl arrives here -- but it DENOTES every block in its
                // ring. One scope would make `Util::b` miss when `b` lives in
                // the second `module Util { }`.
                NameLookup::module_scopes(d, &a.scopes)
                a.decl = d
                return a
            } case DeclKind::ClassDecl {
                return self._type_anchor_seen(d, through)
            } case DeclKind::StructDecl {
                return self._type_anchor_seen(d, through)
            } case DeclKind::UnionDecl {
                return self._type_anchor_seen(d, through)
            } case DeclKind::InterfaceDecl {
                return self._type_anchor(d)
            } case DeclKind::EnumDecl {
                return self._type_anchor_seen(d, through)
            } case DeclKind::TypeAliasDecl {
                var unsafe *td = cast<Declarations::TypeAliasDecl>(d)
                // An associated type reached through a dependent head
                // (`T::Item` then `::make`): abstract, whatever its default.
                // Which type it is depends on the head, which the typer
                // forms (MemberTyping), and the next step binds there.
                if td->is_associated {
                    a.kind = AnchorKind::NeedsInference
                    a.decl = d
                    return a
                }

                if td->aliased == &null {
                    a.kind = AnchorKind::Errored
                    return a
                }

                var unsafe *c = canon_unqual(td->aliased->canonical)
                if c == &null {
                    a.kind = if (td->aliased->is_dependent()) => (AnchorKind::Dependent)
                             else => AnchorKind::Errored
                    return a
                }

                if isa<RecordType>(c) {
                    return self._type_anchor(cast<RecordType>(c)->decl)
                }

                // Alias of a builtin/pointer/etc.: a type, but one with no
                // scope of its own. Extensions on it are still reachable.
                a.kind = AnchorKind::Type
                a.decl = d
                a.ty   = c
                return a
            } case DeclKind::ImportDecl {
                // Never a lookup answer: a plain import binds the source's
                // ModuleDecl and an ffi alias binds each header TU's own
                // module_self (ImportResolution::_resolve_ffi). A head bound
                // to the ImportDecl itself is an upstream bug with no
                // diagnostic to add here.
                a.kind = AnchorKind::Errored
                return a
            } case DeclKind::GenericParamDecl {
                // `T::Name` in expression position. Dependent, but NOT opaque:
                // the canonical is what the bound lookup keys on, so a
                // Dependent anchor carries it exactly as a Value anchor does.
                var unsafe *gp = cast<Declarations::GenericParamDecl>(d)
                // A value parameter of an eval class (`<eval C: Config>`,
                // Compiler/Spec/Eval.md#eval-classes) is a value of that class: `C.size` is Config's
                // field, as for any Config value.
                if gp->is_const_param
                    && gp->value_type != &null
                    && gp->value_type->canonical != &null
                    && isa<RecordType>(canon_unqual(gp->value_type->canonical))
                    && !gp->value_type->canonical->is_dependent() {
                    return self._value_anchor(d, gp->value_type)
                }

                a.kind = AnchorKind::Dependent
                a.decl = d
                if gp->owner != &null {
                    a.ty = self.sc->types->generic_param(
                        NameLookup::representative(gp->owner),
                        gp->index,
                        gp->is_pack,
                    )
                }

                return a
            } case DeclKind::ParamDecl {
                var unsafe *p = cast<Declarations::ParamDecl>(d)
                // A pack reads as its Slice<E>, not the element its type_
                // names. Over a dependent element there is no slice yet:
                // Dependent, exactly as a generic param, never Errored.
                if p->is_pack {
                    if p->type_ == &null || p->type_->is_poisoned() {
                        return self._value_anchor(d, p->type_)
                    }

                    var        tu  = TypeUtil(self.sc)
                    var unsafe *st = tu.param_value_type(p)
                    if st == &null {
                        a.kind = AnchorKind::Dependent
                        a.decl = d
                        return a
                    }

                    return self._value_anchor_from(d, st)
                }

                return self._value_anchor(d, p->type_)
            } case DeclKind::VariableDecl {
                var unsafe *v = cast<Declarations::VariableDecl>(d)
                return self._value_anchor(d, v->type_)
            } case DeclKind::FieldDecl {
                var unsafe *f    = cast<Declarations::FieldDecl>(d)
                var unsafe *seen = self._seen_through(f->type_, through)
                if seen != &null {
                    return self._value_anchor_from(d, seen)
                }

                return self._value_anchor(d, f->type_)
            } case DeclKind::EnumVariantDecl {
                // A variant is a value of its enum. The enum is the variant's
                // semantic_dc owner.
                if d->semantic_dc == &null {
                    a.kind = AnchorKind::Errored
                    return a
                }

                var unsafe *edc = d->semantic_dc
                var unsafe *ed  = edc->owner_decl()
                if ed == &null {
                    a.kind = AnchorKind::Errored
                    return a
                }

                var args = cxx::std::vector<unsafe *Type>()
                a.kind = AnchorKind::Value
                a.decl = d
                a.ty   = self.sc->types->record(NameLookup::representative(ed), unsafe &args)
                if self._generic_count(ed) > 0 {
                    a.kind = AnchorKind::Dependent
                }

                // `L<i32>::Color::Green` is an `L<i32>::Color`.
                var unsafe *tr = if (through != &null) => (canon_unqual(through)) else => &null
                if tr != &null
                    && isa<RecordType>(tr)
                    && cast<RecordType>(tr)->outer != &null
                    && NameLookup::representative(
                        cast<RecordType>(tr)->decl,
                    ) == NameLookup::representative(ed) {
                    a.ty = tr
                }

                return a
            } case DeclKind::FunctionDecl {
                // A function value or a method: what follows is a call result.
                a.kind = AnchorKind::NeedsInference
                a.decl = d
                return a
            } case DeclKind::ExtensionDecl {
                var unsafe *e = cast<Declarations::ExtensionDecl>(d)
                if e->target == &null || e->target->is_poisoned() {
                    a.kind = AnchorKind::Errored
                    return a
                }

                var unsafe *c = canon_unqual(e->target->canonical)
                if c == &null {
                    a.kind = if (e->target->is_dependent()) => (AnchorKind::Dependent)
                             else => AnchorKind::Errored
                    return a
                }

                if isa<RecordType>(c) {
                    var ta = self._type_anchor(cast<RecordType>(c)->decl)
                    ta.ty = c // `extend <T> Wrap<Box<T>>`: Self is Wrap<Box<T>>, not Wrap<its own T>.
                    return ta
                }

                a.kind = AnchorKind::Type
                a.decl = d
                a.ty   = c
                return a
            } default {
                a.kind = AnchorKind::NeedsInference
                a.decl = d
                return a
            }
        }
    }

    /// _type_anchor for a member type reached through \p through (`::P` on
    /// the type anchor `L<i32>`): seen through it, `L<i32>::P` (GH#91),
    /// rather than the pattern's P.
    priv fn _type_anchor_seen(self, d: unsafe *Decl, through: unsafe *Type) -> Anchor {
        var a = self._type_anchor(d)
        if through == &null || a.ty == &null || !a.ty->in_generic_owner() {
            return a
        }

        var unsafe *r = canon_unqual(through)
        if r == &null || !isa<RecordType>(r) {
            return a
        }

        var ded = Deduction(self.sc, &null)
        ded.bind_from_record(r)
        var unsafe *s = ded.substitute(a.ty)
        if s != &null {
            a.ty = s
        }

        return a
    }

    /// What a step's member is read through: the receiver's type for `.` /
    /// `->`, the type itself for `::` on a type.
    priv fn _through_of(self, const a: Anchor, st: unsafe *ChainExpr::Step) -> unsafe *Type {
        if st != &null
            && st->access_kind == ChainExpr::AccessKind::ColonColon
            && a.kind == AnchorKind::Type {
            return a.ty
        }

        return self._receiver_of(a, st)
    }

    priv fn _type_anchor(self, d: unsafe *Decl) -> Anchor {
        var        a      = Anchor()
        var unsafe *canon = NameLookup::representative(d)
        a.kind = AnchorKind::Type
        a.decl = canon
        // The record with its own params as args (Self-shaped). For member
        // lookup only the decl matters; the args make Self/dependence right.
        var args = cxx::std::vector<unsafe *Type>()
        var gps  = decl_generic_params(canon)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null {
                continue
            }

            args.push_back(self.sc->types->generic_param(canon, gp->index, gp->is_pack))
        }

        a.ty = self.sc->types->record(canon, unsafe &args)
        return a
    }

    /// A field's declared type as seen through the record it was reached
    /// through: `inner: T` on a `Wrap<Box<U>>` is `Box<U>`. Null when that
    /// changes nothing (a non-dependent field, or a receiver whose args are
    /// the record's own params, as in its own body), so the caller keeps the
    /// declared-type path. Deduction is built without a Conversion:
    /// member_through only binds and substitutes, it never ranks.
    priv fn _seen_through(self, t: unsafe *Type, through: unsafe *Type) -> unsafe *Type {
        if t == &null || t->is_poisoned() || t->canonical == &null || through == &null {
            return &null
        }

        if !t->canonical->is_dependent() && !t->canonical->in_generic_owner() {
            return &null
        }

        var unsafe *r = canon_unqual(through)
        if !isa<RecordType>(r) {
            return &null
        }

        if cast<RecordType>(r)->args.size() == 0 && cast<RecordType>(r)->outer == &null {
            return &null
        }

        var        ded = Deduction(self.sc, &null)
        var unsafe *s  = ded.member_through(r, t->canonical)
        return if (s != t->canonical) => (s) else => &null
    }

    /// A value's anchor is its declared type's canonical. No declared type,
    /// or a declared type that could not canonicalize, means inference.
    priv fn _value_anchor(self, d: unsafe *Decl, t: unsafe *Type) -> Anchor {
        var a = Anchor()
        a.decl = d
        if t == &null {
            a.kind = AnchorKind::NeedsInference
            return a
        }

        if t->is_poisoned() {
            a.kind = AnchorKind::Errored
            return a
        }

        if t->canonical == &null {
            a.kind = if (t->is_dependent()
                         || t->is_instantiation_dependent()) => (AnchorKind::Dependent)
                     else => AnchorKind::NeedsInference
            return a
        }

        return self._value_anchor_from(d, t->canonical)
    }

    /// The same anchor built from a canonical that has no syntax node behind
    /// it -- ExprTyper's case, where the left side of a step is the type of an
    /// EXPRESSION (`f().x`) and there is no declared type to read.
    priv fn _value_anchor_from(self, d: unsafe *Decl, canonical: unsafe *Type) -> Anchor {
        var a = Anchor()
        a.decl = d
        if canonical == &null {
            a.kind = AnchorKind::NeedsInference
            return a
        }

        a.kind = AnchorKind::Value
        a.ty   = canonical
        return a
    }

    /// # The binder, for a second caller
    ///
    /// ExprTyper reaches the steps ChainBinding had to leave alone: the ones
    /// whose left side only becomes knowable once expressions have types. It
    /// uses the SAME binder rather than a copy of it, which is the whole reason
    /// these three are public.

    /// Bind one `::`/`.` step against \p a, exactly as run() would.
    /// PRE: prepare() has been called on this instance.
    fn bind_step(self,
                 chain:   unsafe *ChainExpr,
                 st:      unsafe *ChainExpr::Step,
                 const a: Anchor) -> Anchor {
        self._from_typer = true
        var r = self._bind_step(chain, st, a)
        self._from_typer = false
        return r
    }

    /// Anchor for a value of canonical type \p canonical. \p d is optional and
    /// only feeds diagnostics ("declared here").
    fn anchor_for_value(self, d: unsafe *Decl, canonical: unsafe *Type) -> Anchor {
        return self._value_anchor_from(d, canonical)
    }

    /// Anchor for a TYPE the typer computed: a record resolves to its decl so
    /// member lookup can walk the table; anything else can still answer
    /// `T::assoc`-shaped questions from the type alone.
    fn anchor_for_type(self, t: unsafe *Type) -> Anchor {
        if t == &null {
            var e = Anchor()
            e.kind = AnchorKind::Errored
            return e
        }

        var unsafe *u = canon_unqual(t)
        if isa<RecordType>(u) {
            return self._type_anchor(cast<RecordType>(u)->decl)
        }

        var a = Anchor()
        a.kind = AnchorKind::Type
        a.ty   = t
        return a
    }

    /// # One step

    priv fn _bind_step(self,
                       chain: unsafe *ChainExpr,
                       st:    unsafe *ChainExpr::Step,
                       a:     Anchor) -> Anchor {
        var at  = st->range
        var loc = st->range.start.id
        if st->name != &null {
            at  = st->name->range
            loc = st->name->range.start.id
        }

        // Unusable left side: record why and stop the chain.
        if a.kind == AnchorKind::Errored {
            if st->name != &null {
                st->name->poison()
            }

            self._record(loc, MemberOutcome::Errored, &null, 0, &null)
            return a
        }

        if a.kind == AnchorKind::NeedsInference {
            self._record(loc, MemberOutcome::NeedsInference, &null, 0, a.decl)
            self.n_inference += 1
            return a
        }

        if a.kind == AnchorKind::Dependent {
            return self._bind_dependent_step(st, a)
        }

        // Operator and tuple-index steps need a typed operand: inference.
        if st->is_operator() || st->is_tuple_index() {
            self._record(loc, MemberOutcome::NeedsInference, &null, 0, a.decl)
            self.n_inference += 1
            var r = Anchor()
            r.kind = AnchorKind::NeedsInference
            r.decl = a.decl
            return r
        }

        if st->name == &null {
            var r = Anchor()
            r.kind = AnchorKind::Errored
            return r
        }

        var imm = self._name_imm(st->name->name)
        if imm == u32::MAX {
            var r = Anchor()
            r.kind = AnchorKind::Errored
            return r
        }

        var name    = DeclName::ident(imm)
        var spelled = self.sc->ctx->get_spelling(st->name->name)

        var is_scope_sep = st->access_kind == ChainExpr::AccessKind::ColonColon

        /// ## `::`
        if is_scope_sep {
            if a.kind == AnchorKind::Value {
                self._err(
                    DiagID::R027E,
                    at,
                    f"'::' cannot follow a value; use '.' to access a member of '{self._decl_name_str(a.decl)}'",
                )

                st->name->poison()
                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl)
                var r = Anchor()
                r.kind = AnchorKind::Errored
                return r
            }

            if a.kind == AnchorKind::Module {
                // Search every scope the anchor denotes and union the hits.
                var cands                        = cxx::std::vector<unsafe *Decl>()
                var nhit:   usize                = 0
                var frozen: unsafe *OverloadCell = &null
                for var si: usize = 0; si < a.scopes.size(); ++si {
                    var unsafe *cell = self.ml.in_scope(a.scopes[si], name, spelled)
                    if cell == &null {
                        continue
                    }

                    if cell->size() == 0 {
                        continue
                    }

                    nhit += 1
                    frozen = cell
                    for var i: usize = 0; i < cell->size(); ++i {
                        var unsafe *d = cell->get(i)
                        if d == &null {
                            continue
                        }

                        var dup = false
                        for var k: usize = 0; k < cands.size(); ++k {
                            if cands[k] == d {
                                dup = true
                                break
                            }
                        }

                        if !dup {
                            cands.push_back(d)
                        }
                    }
                }

                if cands.empty() {
                    // Nothing in the module's own table. Its pub/prot imports
                    // are part of its surface too, and they live in its
                    // OVERLAY rather than that table (Compiler/Spec/Imports.md#re-exports).
                    for var si: usize = 0; si < a.scopes.size(); ++si {
                        var unsafe *rx = self.ml.reexport_lookup(a.scopes[si], spelled)
                        if rx == &null {
                            continue
                        }

                        for var i: usize = 0; i < rx->size(); ++i {
                            var unsafe *d = rx->get(i)
                            if d == &null {
                                continue
                            }

                            var dup = false
                            for var k: usize = 0; k < cands.size(); ++k {
                                if cands[k] == d {
                                    dup = true
                                    break
                                }
                            }

                            if !dup {
                                cands.push_back(d)
                            }
                        }
                    }
                }

                if cands.empty() {
                    var mn = if (a.decl == &null) => ("the global scope")
                             else => f"module '{self._decl_name_str(a.decl)}'"
                    self._err_contained(DiagID::R025E, at, f"no member named '{spelled}' in {mn}")
                    st->name->poison()
                    self._record(loc, MemberOutcome::Errored, &null, 0, a.decl)
                    var r = Anchor()
                    r.kind = AnchorKind::Errored
                    return r
                }

                // A frozen cell may only be reused when it IS the answer: with
                // two contributing scopes the union is a new set.
                if nhit > 1 {
                    frozen = &null
                }

                return self._commit(st, loc, unsafe &cands, a.decl, frozen)
            }

            // A dependent head the typer computed (`T::Item` then `::make`):
            // what its declaration promised, as `.` on a value of it reads.
            if a.ty != &null && isa<AssocType>(canon_unqual(a.ty)) {
                var dep0 = Anchor()
                dep0.kind = AnchorKind::Dependent
                dep0.decl = a.decl
                dep0.ty   = canon_unqual(a.ty)
                return self._bind_dependent_step(st, dep0)
            }

            // Type: statics, nested types, enum variants, ctors -- member lookup.
            var cands = cxx::std::vector<unsafe *Decl>()
            self.ml.lookup(a.ty, name, unsafe &cands)
            if cands.empty() {
                self._ctors_by_name(a, spelled, &cands)
            }

            if cands.empty() {
                var dn = self._decl_name_str(a.decl)
                self._err_member_miss(at, f"no member named '{spelled}' in '{dn}'", a.ty, name, spelled, dn)

                st->name->poison()
                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl)
                var r = Anchor()
                r.kind = AnchorKind::Errored
                return r
            }

            return self._commit(st, loc, unsafe &cands, a.decl, &null, a.ty)
        }

        /// ## `.` `->` `?.` `?->`
        if a.kind == AnchorKind::Module {
            self._err(
                DiagID::R027E,
                at,
                f"'.' cannot follow a module; use '::' to name a member of '{self._decl_name_str(a.decl)}'",
            )

            st->name->poison()
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl)
            var r = Anchor()
            r.kind = AnchorKind::Errored
            return r
        }

        if a.kind == AnchorKind::Type {
            self._err(
                DiagID::R027E,
                at,
                f"'.' cannot follow a type; use '::' to name a member of '{self._decl_name_str(a.decl)}'",
            )

            st->name->poison()
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl)
            var r = Anchor()
            r.kind = AnchorKind::Errored
            return r
        }

        // `.` / `->` on a declared NULLABLE value: whether it reads the value
        // depends on whether the nullness analysis proves it non-null at
        // this use (Compiler/Spec/Nullables.md#narrowed-reads), which only MemberTyping knows; it binds
        // the step on the narrowed type, or reports the nullness error.
        // Left for it, as an inferred anchor is. Not when MemberTyping is
        // the caller: its anchor is already what the analysis left, and an
        // unproven nullable there is the error below ("no member in 'T?'").
        if !self._from_typer
            && (st->access_kind == ChainExpr::AccessKind::Dot
                || st->access_kind == ChainExpr::AccessKind::Arrow) {
            var unsafe *vc = canon_unqual(self.ml.peel_ref(a.ty))
            if vc != &null && isa<NullableType>(vc) {
                // A member an `extend T?` declares is the NULLABLE's own
                // (P325-1, decided 2026-11-12): `self` is the `T?`, so the
                // call reads no value and is legal null or not. It binds
                // here, on the nullable, before any narrowing could make it
                // a lookup in T; MemberTyping leaves such a step alone
                // (binds_nullable_member).
                var ncands = cxx::std::vector<unsafe *Decl>()
                if !vc->is_dependent() && self.ml.lookup(vc, name, unsafe &ncands) {
                    return self._commit(st, loc, unsafe &ncands, &null, &null, vc)
                }

                self._record(loc, MemberOutcome::NeedsInference, &null, 0, a.decl)
                self.n_inference += 1
                var r = Anchor()
                r.kind = AnchorKind::NeedsInference
                r.decl = a.decl
                return r
            }
        }

        // Value. Peel the separator's expected wrapper off the canonical.
        // Null means the separator does not fit the value; re-derive which
        // way only here, on the error path, so _receiver_of stays silent for
        // the idempotent re-run that shares it.
        var unsafe *ty = self._receiver_of(a, st)
        if ty == &null {
            var arrow = st->access_kind == ChainExpr::AccessKind::Arrow
                || st->access_kind == ChainExpr::AccessKind::QuestionArrow
            var unsafe *pre = self._peel_maybe(self.ml.peel_ref(a.ty), st)
            if arrow && !isa<PointerType>(pre) {
                self._err(
                    DiagID::R027E,
                    at,
                    "'->' requires a pointer on its left; use '.' for a value",
                )
            } else if !arrow && isa<PointerType>(pre) {
                self._err(DiagID::R027E, at, "'.' cannot be applied to a pointer; use '->'")
            } else {
                var r = Anchor()
                r.kind = AnchorKind::Errored
                return r
            }

            st->name->poison()
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl)
            var r = Anchor()
            r.kind = AnchorKind::Errored
            return r
        }

        // A dependent RECORD still has a known decl, and MemberLookup keys on
        // the decl: `self.x` in `class <T> Foo` binds to the field today, and
        // only the NEXT anchor (the field's type) carries the dependence. A
        // dependent non-record (`T`, `*T`, `[T]`) has no scope of its own --
        // what it has is whatever its DECLARATION promised, which is the
        // dependent path's question. Hand it the PEELED type: `p->draw()` on
        // a `p: *T` asks about T, not about the pointer.
        if ty->is_dependent() && !isa<RecordType>(ty) {
            var dep = Anchor()
            dep.kind = AnchorKind::Dependent
            dep.decl = a.decl
            dep.ty   = ty
            return self._bind_dependent_step(st, dep)
        }

        var cands = cxx::std::vector<unsafe *Decl>()
        self.ml.lookup(ty, name, unsafe &cands)
        if cands.empty() {
            var tn = self._type_name_str(ty)
            self._err_member_miss(at, f"no member named '{spelled}' in '{tn}'", ty, name, spelled, tn)
            st->name->poison()
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl)
            var r = Anchor()
            r.kind = AnchorKind::Errored
            return r
        }

        var owner: unsafe *Decl = &null
        if isa<RecordType>(ty) {
            owner = cast<RecordType>(ty)->decl
        }

        return self._commit(st, loc, unsafe &cands, owner, &null, ty)
    }

    /// The record a `.`/`->`/`?.`/`?->` step actually reads from: \p a's
    /// canonical with a C++ reference, the `?` of a maybe-separator and the
    /// pointer of an arrow peeled off. Null unless \p a is a Value anchor,
    /// and null when the separator does not fit (an arrow on a non-pointer,
    /// a dot on a pointer); _bind_step diagnoses those. Shared with the
    /// idempotent re-run in traverse_chain_expr so the receiver a field is
    /// read through cannot differ between the first bind and the re-run.
    priv fn _receiver_of(self, const a: Anchor, st: unsafe *ChainExpr::Step) -> unsafe *Type {
        if a.kind != AnchorKind::Value || st == &null {
            return &null
        }

        if st->access_kind == ChainExpr::AccessKind::ColonColon {
            return &null
        }

        // A C++ reference first, before any separator rule: it is transparent
        // to `.` and `->` alike, and `vector&` must answer as `vector`.
        var unsafe *ty = self._peel_maybe(self.ml.peel_ref(a.ty), st)
        if ty == &null {
            return &null
        }

        var arrow = st->access_kind == ChainExpr::AccessKind::Arrow
            || st->access_kind == ChainExpr::AccessKind::QuestionArrow
        if arrow {
            // A record's `op ->` (a C++ iterator's, a smart pointer's): the
            // member is read from what it points to. Null when it has none.
            if !isa<PointerType>(ty) {
                return Substitution(self.sc).arrow_target(self.ml.peel_ref(a.ty), &self.ml)
            }

            return self.ml.peel_ref(cast<PointerType>(ty)->pointee)
        }

        if isa<PointerType>(ty) {
            return &null
        }

        return ty
    }

    /// \p st is bound to a member an `extend T?` declares: a member of the
    /// nullable itself, so a `.` on it reads no value (P325-1). MemberTyping
    /// asks before it narrows a nullable receiver or reports it unchecked.
    fn binds_nullable_member(self, st: unsafe *ChainExpr::Step) -> bool {
        if st == &null {
            return false
        }

        var unsafe *d = st->resolved_decl
        if d == &null && st->candidate_cell != &null && st->candidate_cell->size() > 0 {
            d = st->candidate_cell->get(0)
        }

        if d == &null || d->semantic_dc == &null || d->semantic_dc->dc_kind != DeclContextKind::Extension {
            return false
        }

        var unsafe *x = dyn_cast<Declarations::ExtensionDecl>(d->semantic_dc->owner_decl())
        return x != &null
            && x->target != &null
            && x->target->canonical != &null
            && isa<NullableType>(canon_unqual(x->target->canonical))
    }

    /// MemberTyping's question before it reads nullable receiver \p cur at
    /// \p st: is the step a member of `extend T?`? A step this binder left
    /// unbound (a field path, `h.n.f()`) is bound here first, on the
    /// nullable, when such an extension declares the name.
    fn nullable_member_step(self, chain: unsafe *ChainExpr, st: unsafe *ChainExpr::Step, cur: unsafe *Type) -> bool {
        if st == &null || cur == &null {
            return false
        }

        if st->resolved_decl != &null || st->candidate_cell != &null {
            return self.binds_nullable_member(st)
        }

        if st->name == &null || st->name->is_poisoned() || st->is_operator() || st->is_tuple_index() {
            return false
        }

        var unsafe *vc = canon_unqual(self.ml.peel_ref(cur))
        var        imm = self._name_imm(st->name->name)
        if vc == &null || !isa<NullableType>(vc) || vc->is_dependent() || imm == u32::MAX {
            return false
        }

        var probe = cxx::std::vector<unsafe *Decl>()
        if !self.ml.lookup(vc, DeclName::ident(imm), unsafe &probe) {
            return false
        }

        self.bind_step(chain, st, self.anchor_for_value(&null, vc))
        return self.binds_nullable_member(st)
    }

    /// `?.`/`?->` peel the nullable they guard. `T?` may have been lowered to
    /// `Nullable<T>` (lang item), so that spelling peels too. `?.` on a
    /// non-nullable proceeds as-is here; MemberTyping reports it (SC001E,
    /// Compiler/Spec/Nullables.md#safe-access).
    priv fn _peel_maybe(self, t: unsafe *Type, st: unsafe *ChainExpr::Step) -> unsafe *Type {
        var maybe = st->access_kind == ChainExpr::AccessKind::QuestionDot
            || st->access_kind == ChainExpr::AccessKind::QuestionArrow
        if !maybe || t == &null {
            return t
        }

        if isa<NullableType>(t) {
            return cast<NullableType>(t)->inner
        }

        if isa<RecordType>(t) {
            var unsafe *rt        = cast<RecordType>(t)
            var unsafe *null_decl = self.sc->well_known->get(WellKnownType::Nullable)
            if null_decl != &null && rt->decl == null_decl && rt->args.size() == 1 {
                return rt->args[0]
            }
        }

        return t
    }

    /// Write the step's slots from a candidate set and produce the next anchor.
    ///
    ///   one decl            -> resolved_decl
    ///   all functions       -> candidate_cell (the frozen cell if they all came
    ///                          from one; a sema-owned merged cell otherwise)
    ///   mixed / >1 non-fn   -> ambiguous: two distinct entities under one
    ///                          name reached through different bases.
    priv fn _commit(self,
                    st:      unsafe *ChainExpr::Step,
                    loc:     u32,
                    cands:   unsafe *cxx::std::vector<unsafe *Decl>,
                    owner:   unsafe *Decl,
                    frozen:  unsafe *OverloadCell,
                    through: unsafe *Type = &null) -> Anchor {
        // C++ tag hiding between header decls (`struct timezone` beside
        // `extern long timezone`): an aliased ffi import unions every
        // closure header's scope, so the two can meet in one step. The set
        // shrinks, so the frozen cell no longer is it.
        var unsafe *exact = frozen
        if ffi_hide_tags(cands) {
            exact = &null
        }

        var n = cands->size()
        if n == 1 {
            var unsafe *d = NameLookup::representative((*cands)[0])
            st->resolved_decl = d
            self._record(loc, MemberOutcome::Bound, d, 1, self._home_of(d))
            self.n_bound += 1
            return self._anchor_after(d, st, through)
        }

        var all_fn               = true
        var nonfn:  unsafe *Decl = &null
        var nonfn2: unsafe *Decl = &null
        for var i: usize = 0; i < n; ++i {
            var unsafe *d = (*cands)[i]
            if !isa<Declarations::FunctionDecl>(d) {
                all_fn = false
                if nonfn == &null {
                    nonfn = d
                } else if nonfn2 == &null {
                    nonfn2 = d
                }
            }
        }

        if !all_fn {
            // A redecl chain (fwd + def) collapses to one entity; only distinct
            // entities are ambiguous.
            var sole:    unsafe *Decl = &null
            var distinct              = false
            for var i: usize = 0; i < n; ++i {
                var unsafe *r = NameLookup::representative((*cands)[i])
                if sole == &null {
                    sole = r
                    continue
                }

                if sole != r {
                    distinct = true
                    break
                }
            }

            if !distinct {
                st->resolved_decl = sole
                self._record(loc, MemberOutcome::Bound, sole, 1, self._home_of(sole))
                self.n_bound += 1
                return self._anchor_after(sole, st, through)
            }

            // Distinct ModuleDecls are one namespace reopened across TUs --
            // libc++ opens `std` in dozens of headers, each its own decl --
            // not an ambiguity: the anchor is the union of their scopes, as
            // _anchor_of_base does for a head and TypeResolve for `::` in a
            // type. Without it `cxx::std::vector<i32>()` was R028E while the
            // same path as a type resolved.
            var all_mod = true
            for var i: usize = 0; i < n; ++i {
                if !isa<Declarations::ModuleDecl>((*cands)[i]) {
                    all_mod = false
                    break
                }
            }

            if all_mod {
                var unsafe *md = NameLookup::representative((*cands)[0])
                st->resolved_decl = md
                self._record(loc, MemberOutcome::Bound, md, 1, self._home_of(md))
                self.n_bound += 1
                var ma = Anchor()
                ma.kind = AnchorKind::Module
                ma.decl = md
                for var i: usize = 0; i < n; ++i {
                    NameLookup::module_scopes((*cands)[i], &ma.scopes)
                }

                return ma
            }

            var nm = self.sc->ctx->get_spelling(st->name->name)
            var b = self.sc->diag->report(
                DiagID::R028E,
                st->name->range.start,
                f"'{nm}' is ambiguous: it names more than one member reachable from here",
            )

            b.first(st->name->range)
            for var i: usize = 0; i < n; ++i {
                var unsafe *d = (*cands)[i]
                b.note(DiagCode(DiagID::R028N), d->range.start, "candidate declared here")->first(
                    d->range,
                )
            }

            b.emit()
            st->name->poison()
            self._record(loc, MemberOutcome::Errored, &null, n, owner)
            self.n_errored += 1
            var r = Anchor()
            r.kind = AnchorKind::Errored
            return r
        }

        // Overload set. Reuse the frozen cell when it is exactly the set;
        // otherwise union into a sema-owned cell (dies with sema_alloc).
        var cell: unsafe *OverloadCell = &null
        if exact != &null && exact->size() == n {
            cell = exact
        } else {
            cell = self.sc->ctx->alloc_init_sema_cleanup<OverloadCell>()
            for var i: usize = 0; i < n; ++i {
                cell->append((*cands)[i])
            }
        }

        st->candidate_cell = cell
        self._record(loc, MemberOutcome::Candidates, &null, n, owner)
        self.n_cands += 1
        var r = Anchor()
        r.kind = AnchorKind::NeedsInference
        r.decl = owner
        return r
    }

    /// # The dependent regimes
    ///
    /// A step whose left side is a generic parameter has THREE possible
    /// answers, and which one applies is a property of the parameter's
    /// DECLARATION, not of the step:
    ///
    ///   `<T: type>`            duck: defer everything to instantiation, the
    ///                          C++ rule. No diagnostic here, ever.
    ///   `<T impl I>` /         bounded: the parameter's members are exactly
    ///   `<T derives B>`        the bound's members. Resolved NOW, at the
    ///                          template, once -- not once per instantiation.
    ///   `<T>`                  opaque: no bound, so no members. `x.anything`
    ///                          is an error AT THE TEMPLATE, which is the whole
    ///                          difference from C++.
    ///
    /// Everything below is the middle case doing real work; the other two are
    /// one branch each.

    /// \class ParamBounds
    /// \brief What a generic parameter's declaration lets a body see.
    class ParamBounds {
        pub var duck:       bool                                   = false ///< `: type`: defer everything.
        pub var interfaces: cxx::std::vector<unsafe *Decl> ///< `impl I` bounds.
        pub var bases:      cxx::std::vector<unsafe *Decl> ///< `derives B` bounds.
        pub var param:      unsafe *Declarations::GenericParamDecl = &null
        fn ParamBounds(self) { }
    }

    /// The declaring GenericParamDecl behind a canonical, or null when the
    /// canonical is not a bare parameter (`*T`, `[T]`: no declaration to ask).
    priv fn _param_of(self, t: unsafe *Type) -> unsafe *Declarations::GenericParamDecl {
        if t == &null || !isa<GenericParamType>(t) {
            return &null
        }

        var unsafe *g = cast<GenericParamType>(t)
        if g->owner == &null {
            return &null
        }

        var gps = decl_generic_params(g->owner)
        if (g->param_index as usize) >= gps.size() {
            return &null
        }

        return gps[g->param_index as usize]
    }

    /// The bounds \p gp's declaration promised. The requires clause is the
    /// SINGLE source of truth for conformance: RequiresDesugar hoisted every
    /// inline `impl`/`derives` into it and cleared the inline lists, and
    /// ConstraintExtraction filed the partition in sc->bounds. Only the kind
    /// bound stays on the parameter, because it describes the slot rather
    /// than conjoining a constraint.
    priv fn _bounds_of(self,
                       gp:    unsafe *Declarations::GenericParamDecl,
                       owner: unsafe *Decl) -> Self::ParamBounds {
        var b = Self::ParamBounds()
        if gp == &null {
            return b
        }

        b.param = gp
        b.duck  = gp->kind_bound == Declarations::GenericParamKindBound::Duck

        var it = self.sc->bounds.find(owner as usize as u64)
        if it != self.sc->bounds.end() {
            var *_set = &it->second
            for var i: usize = 0; i < _set->impl_constraints.size(); ++i {
                var unsafe *c = _set->impl_constraints[i]
                if !self._constraint_names(c, gp) {
                    continue
                }

                var unsafe *d = self._record_decl_of(c->rhs)
                if d != &null {
                    b.interfaces.push_back(d)
                }
            }

            for var i: usize = 0; i < _set->derives_constraints.size(); ++i {
                var unsafe *c = _set->derives_constraints[i]
                if !self._constraint_names(c, gp) {
                    continue
                }

                var unsafe *d = self._record_decl_of(c->rhs)
                if d != &null {
                    b.bases.push_back(d)
                }
            }
        }

        // The `eval if gp impl I` branches this step stands in: I is a bound
        // there (traverse_conditional_stmt).
        for var i: usize = 0; i < self._narrow_params.size(); ++i {
            if self._narrow_params[i] == gp {
                b.interfaces.push_back(self._narrow_ifaces[i])
            }
        }

        return b
    }

    /// # eval if A impl I
    ///
    /// A function-body `eval if` stays C++'s `if constexpr` (Compiler/Spec/Pipeline.md
    /// §2.3), decided per instantiation by the interface's concept
    /// (EmitIR::_constraint). In its TAKEN branch the test holds, so a
    /// parameter it names has that interface's members, exactly as if the
    /// bound had been declared: `A::resize(...)` binds to Resizer's
    /// requirement and is spelled through its witness. The else branch and
    /// everything after see the declared bounds only. Only conjuncts narrow
    /// (`A impl I && B impl J`); a test under `||` or `!` promises nothing.

    /// Parallel stacks: while a taken branch is walked, its parameters and
    /// the interface each one gained. Pushed and popped around then_ only.
    priv var _narrow_params: cxx::std::vector<unsafe *Declarations::GenericParamDecl>
    priv var _narrow_ifaces: cxx::std::vector<unsafe *Decl>

    fn traverse_conditional_stmt(self, n: unsafe *ConditionalStmt) -> unsafe *ConditionalStmt {
        if n == &null || !n->is_eval {
            return RecursiveASTVisitor<ChainBinding>::traverse_conditional_stmt(self, n)
        }

        if self.dyn()->walkup_conditional_stmt(n) == false {
            return n
        }

        if n->cond != &null {
            n->cond = self.dyn()->dispatch_expr(n->cond)
        }

        // `eval if typeof T == U` over a generic parameter: which
        // branch runs is known per instance only, and the unselected ones
        // are not checked (eval.md "Type-based branching"), so no branch
        // reports here; C++ checks the one each instance takes.
        var dep  = self._typeof_param(n->cond)
        var mark = self._narrow_params.size()
        self._narrow_from(n->cond)
        if dep {
            self.sc->diag->push_suppress()
        }

        n->then_ = self.dyn()->traverse_block(n->then_)
        if dep {
            self.sc->diag->pop_suppress()
        }

        while self._narrow_params.size() > mark {
            self._narrow_params.pop_back()
            self._narrow_ifaces.pop_back()
        }

        var sup_else = dep && n->else_ != &null && !isa<ConditionalStmt>(n->else_)
        if sup_else {
            self.sc->diag->push_suppress()
        }

        if n->else_ != &null {
            n->else_ = self.dyn()->dispatch_stmt(n->else_)
        }

        if sup_else {
            self.sc->diag->pop_suppress()
        }

        return n
    }

    /// \p e0 holds `typeof P` with P a generic parameter.
    priv fn _typeof_param(self, e0: unsafe *Expr) -> bool {
        var unsafe *e = e0
        while e != &null && isa<ParenExpr>(e) {
            e = cast<ParenExpr>(e)->inner
        }

        if e == &null {
            return false
        }

        var unsafe *t = dyn_cast<TypeOfExpr>(e)
        if t != &null {
            var unsafe *o = t->operand
            while o != &null && isa<ParenExpr>(o) {
                o = cast<ParenExpr>(o)->inner
            }

            var unsafe *id = dyn_cast<NamedIdentExpr>(o)
            return id != &null
                && id->resolved_decl != &null
                && isa<Declarations::GenericParamDecl>(id->resolved_decl)
        }

        var unsafe *b = dyn_cast<BinaryOperatorExpr>(e)
        if b != &null {
            return self._typeof_param(b->lhs) || self._typeof_param(b->rhs)
        }

        var unsafe *u = dyn_cast<UnaryOperatorExpr>(e)
        if u != &null {
            return self._typeof_param(u->operand)
        }

        return false
    }

    /// Pushes each `P impl I` conjunct of \p e0 whose P is a generic
    /// parameter and whose I names a record.
    priv fn _narrow_from(self, e0: unsafe *Expr) {
        var unsafe *e = e0
        while e != &null && isa<ParenExpr>(e) {
            e = cast<ParenExpr>(e)->inner
        }

        if e == &null {
            return
        }

        var unsafe *b = dyn_cast<BinaryOperatorExpr>(e)
        if b != &null
            && (b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd) {
            self._narrow_from(b->lhs)
            self._narrow_from(b->rhs)
            return
        }

        var unsafe *c = dyn_cast<ConstraintExpr>(e)
        if c == &null || c->is_derives() || c->lhs == &null {
            return
        }

        var unsafe *id = dyn_cast<NamedIdentExpr>(c->lhs)
        if id == &null {
            return
        }

        var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(id->resolved_decl)
        if gp == &null {
            return
        }

        var unsafe *d = self._record_decl_of(c->rhs)
        if d == &null {
            return
        }

        self._narrow_params.push_back(gp)
        self._narrow_ifaces.push_back(d)
    }

    /// Whether conjunct \p c constrains \p gp. The lhs is an ordinary
    /// identifier N bound like any other, so this is a pointer compare and not
    /// a name compare: `fn <T> f() requires T impl I` inside `class <T> C`
    /// constrains the FUNCTION's T, and the two T are different entities.
    priv fn _constraint_names(self,
                              c:  unsafe *ConstraintExpr,
                              gp: unsafe *Declarations::GenericParamDecl) -> bool {
        if c == &null || c->lhs == &null {
            return false
        }

        var unsafe *id = dyn_cast<NamedIdentExpr>(c->lhs)
        if id == &null {
            return false
        }

        return id->resolved_decl == gp
    }

    /// The record decl of canonical \p c0, or null.
    priv fn _record_decl_of_canon(self, c0: unsafe *Type) -> unsafe *Decl {
        var unsafe *c = canon_unqual(c0)
        if c == &null || !isa<RecordType>(c) {
            return &null
        }

        return NameLookup::representative(cast<RecordType>(c)->decl)
    }

    /// The record decl a bound's written type names, or null if it names none
    /// (a builtin, a pointer: nothing with members to offer).
    priv fn _record_decl_of(self, t: unsafe *Type) -> unsafe *Decl {
        if t == &null || t->canonical == &null {
            return &null
        }

        var unsafe *c = canon_unqual(t->canonical)
        if !isa<RecordType>(c) {
            return &null
        }

        return NameLookup::representative(cast<RecordType>(c)->decl)
    }

    /// One step whose left side is dependent.
    priv fn _bind_dependent_step(self, st: unsafe *ChainExpr::Step, a: Anchor) -> Anchor {
        var at  = st->range
        var loc = st->range.start.id
        if st->name != &null {
            at  = st->name->range
            loc = st->name->range.start.id
        }

        var unsafe *gp = self._param_of(a.ty)
        var        b   = Self::ParamBounds()
        var unsafe *assoc = if (a.ty != &null) => (dyn_cast<AssocType>(canon_unqual(a.ty)))
                            else => &null
        if gp == &null && assoc != &null {
            // `x.show()` on `x: T::Item`, and `T::Item::make()`: the
            // associated type's own bounds (`type Item impl Display`) are
            // its members, as a parameter's are, read through what it was
            // reached by (Substitution::bound_ifaces) -- the same lookup,
            // `.` or `::`, at any depth.
            var bis = Substitution(self.sc).bound_ifaces(a.ty)
            for var i: usize = 0; i < bis.size(); ++i {
                var unsafe *bd = self._record_decl_of_canon(bis[i])
                if bd != &null {
                    b.interfaces.push_back(bd)
                }
            }

            if b.interfaces.size() == 0 {
                var ts    = TypeUtil(self.sc).str(a.ty)
                var what0 = "this member"
                if st->name != &null {
                    what0 = f"'{self.sc->ctx->get_spelling(st->name->name)}'"
                }

                var d0 = self.sc->diag->report(
                    DiagID::R051E,
                    at.start,
                    f"'{ts}' has no members, so {what0} cannot be resolved",
                )

                d0.first(at)
                if assoc->assoc != &null && assoc->assoc->range.is_valid() {
                    d0.note(
                        DiagCode(DiagID::R051N),
                        assoc->assoc->range.start,
                        "the associated type is declared with no bound; add 'impl <Interface>' to give it members",
                    )->first(assoc->assoc->range)
                }

                d0.emit()
                if st->name != &null {
                    st->name->poison()
                }

                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl)
                self.n_errored += 1
                var r0 = Anchor()
                r0.kind = AnchorKind::Errored
                return r0
            }

            return self._bind_through_bounds(st, a, unsafe &b, TypeUtil(self.sc).str(a.ty), at, loc)
        }

        if gp == &null {
            // A dependent COMPOSITE (`[T]`, an unfilled `Foo<T>::Inner`, or a
            // parameter whose declarer T never stamped): no single declaration
            // to read a promise off. Undecidable before M2.
            self._record(loc, MemberOutcome::Dependent, &null, 0, a.decl)
            self.n_dependent += 1
            return a
        }

        var unsafe *owner = cast<GenericParamType>(a.ty)->owner
        b = self._bounds_of(gp, owner)

        // `: type` -- the C++ regime. Not a hole we failed to fill: a hole the
        // author asked for.
        if b.duck {
            self._note_duck_use(gp, at)
            self._record(loc, MemberOutcome::Dependent, &null, 0, a.decl)
            self.n_dependent += 1
            return a
        }

        var pname = self._decl_name_str(unsafe (gp as unsafe *Decl))
        if b.interfaces.size() == 0 && b.bases.size() == 0 {
            var what = "this member"
            if st->name != &null {
                what = f"'{self.sc->ctx->get_spelling(st->name->name)}'"
            }

            var d = self.sc->diag->report(
                DiagID::R051E,
                at.start,
                f"'{pname}' has no members, so {what} cannot be resolved",
            )

            d.first(at)
            d.note(
                DiagCode(DiagID::R051N),
                gp->range.start,
                f"'{pname}' is declared with no bound; add 'impl <Interface>' to give it members",
            )->first(gp->range)
            d.emit()
            if st->name != &null {
                st->name->poison()
            }

            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl)
            self.n_errored += 1
            var r = Anchor()
            r.kind = AnchorKind::Errored
            return r
        }

        return self._bind_through_bounds(st, a, unsafe &b, pname, at, loc)
    }

    /// The member \p st names among bounds \p b (a parameter's, or an
    /// associated type's own), \p pname spelling what they bound.
    priv fn _bind_through_bounds(self,
                                 st:          unsafe *ChainExpr::Step,
                                 const a:     Anchor,
                                 b:           unsafe *Self::ParamBounds,
                                 const pname: string,
                                 at:          SourceRange,
                                 loc:         u32) -> Anchor {
        // An operator or a tuple index through a bound needs the operand's
        // TYPE, which is the typer's to supply, not this pass's.
        if st->is_operator() || st->is_tuple_index() || st->name == &null {
            self._record(loc, MemberOutcome::NeedsInference, &null, 0, a.decl)
            self.n_inference += 1
            var r = Anchor()
            r.kind = AnchorKind::NeedsInference
            r.decl = a.decl
            return r
        }

        var imm = self._name_imm(st->name->name)
        if imm == u32::MAX {
            var r = Anchor()
            r.kind = AnchorKind::Errored
            return r
        }

        var name    = DeclName::ident(imm)
        var spelled = self.sc->ctx->get_spelling(st->name->name)
        var cands   = cxx::std::vector<unsafe *Decl>()
        var empty   = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < b->interfaces.size(); ++i {
            self.ml.lookup(
                self.sc->types->record(b->interfaces[i], unsafe &empty),
                name,
                unsafe &cands,
            )
        }

        for var i: usize = 0; i < b->bases.size(); ++i {
            self.ml.lookup(self.sc->types->record(b->bases[i], unsafe &empty), name, unsafe &cands)
        }

        // `T::Name` names the bounds' statics and nested types only: static
        // fns, static fields/vars, and type members, from interface and base
        // bounds alike. An instance member reached by `::` is the wrong
        // separator, not a missing name, and says so.
        if st->access_kind == ChainExpr::AccessKind::ColonColon {
            var inst: unsafe *Decl = &null
            var keep               = cxx::std::vector<unsafe *Decl>()
            for var i: usize = 0; i < cands.size(); ++i {
                if self._is_scope_member(cands[i]) {
                    keep.push_back(cands[i])
                } else if inst == &null {
                    inst = cands[i]
                }
            }

            if keep.empty() && inst != &null {
                self._err(
                    DiagID::R027E,
                    at,
                    f"'{spelled}' is an instance member of the bounds of '{pname}'; use '.' on a value of '{pname}'",
                )

                st->name->poison()
                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl)
                var r = Anchor()
                r.kind = AnchorKind::Errored
                return r
            }

            cands = keep
        }

        if cands.empty() {
            self._err_contained(
                DiagID::R025E,
                at,
                f"no member named '{spelled}' in the bounds of '{pname}'",
            )
            st->name->poison()
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl)
            var r = Anchor()
            r.kind = AnchorKind::Errored
            return r
        }

        // _commit binds it like any other member, and the anchor it hands back
        // is already right: an interface method yields NeedsInference (a call
        // result), a base field yields that field's declared type.
        return self._commit(st, loc, unsafe &cands, self._bound_owner(b), &null)
    }

    /// Whether \p d is reachable through `::`: a static fn, a static field or
    /// variable, or a nested type. Mirrors NameResolution's static/instance
    /// split (a FunctionDecl that is not a method is static).
    priv fn _is_scope_member(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        var unsafe *f = dyn_cast<Declarations::FieldDecl>(d)
        if f != &null {
            return f->is_static()
        }

        var unsafe *v = dyn_cast<Declarations::VariableDecl>(d)
        if v != &null {
            return v->is_static()
        }

        var unsafe *fn_ = dyn_cast<Declarations::FunctionDecl>(d)
        if fn_ != &null {
            return !fn_->is_method()
        }

        return isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::EnumDecl>(d)
            || isa<Declarations::InterfaceDecl>(d)
            || isa<Declarations::TypeAliasDecl>(d)
    }

    /// The decl a bound-resolved member is REPORTED against: the sole bound
    /// when there is one, nothing when several could have answered (naming
    /// one of them would be a guess).
    priv fn _bound_owner(self, b: unsafe *Self::ParamBounds) -> unsafe *Decl {
        if b->interfaces.size() == 1 && b->bases.size() == 0 {
            return b->interfaces[0]
        }

        if b->bases.size() == 1 && b->interfaces.size() == 0 {
            return b->bases[0]
        }

        return &null
    }

    /// # helpers

    /// The decl that OWNS `d`'s scope -- the type a member was declared in,
    /// which is what a reader wants to see, not the type it was reached
    /// through.
    priv fn _home_of(self, d: unsafe *Decl) -> unsafe *Decl {
        if d == &null || d->semantic_dc == &null {
            return &null
        }

        var unsafe *owner = (d->semantic_dc)->owner_decl()
        if isa<Declarations::ExtensionDecl>(owner) {
            // An ExtensionDecl has no name of its own, so reporting it says
            // "[member of ]". The home a reader means is the type extended.
            var unsafe *e = cast<Declarations::ExtensionDecl>(owner)
            if e->target != &null && e->target->canonical != &null {
                var unsafe *c = canon_unqual(e->target->canonical)
                if isa<RecordType>(c) {
                    return cast<RecordType>(c)->decl
                }
            }
        }

        return owner
    }

    /// The first member step through `: type` parameter \p gp. Its presence
    /// is what tells FlagGates that deleting the bound would turn this body
    /// into an R051E (an opaque `T` has no members), so the fix-it is off.
    priv fn _note_duck_use(self, gp: unsafe *Declarations::GenericParamDecl, at: SourceRange) {
        for var i: usize = 0; i < self.sc->duck_member_params.size(); ++i {
            if self.sc->duck_member_params[i] == gp {
                return
            }
        }

        self.sc->duck_member_params.push_back(gp)
        self.sc->duck_member_at.push_back(at)
    }

    priv fn _record(self,
                    loc:   u32,
                    o:     MemberOutcome,
                    d:     unsafe *Decl,
                    ncand: usize,
                    owner: unsafe *Decl) {
        self.sc->trace.member_result(loc, o, d, ncand, owner)
    }

    priv fn _err(self, id: DiagID, at: SourceRange, const msg: string) {
        self.sc->diag->report(id, at.start, msg).first(at)->emit()
        self.n_errored += 1
    }

    /// _err for a miss whose step name the caller then poisons: every use of
    /// it is silent downstream, so the damage is fenced off and the stage gate
    /// (Sema::_hard_stop) must not stop the TU. Stopping hid every later,
    /// independent miss -- `make().dump()` after a `t.dump()` -- because
    /// call-result steps only bind in the expression typer (P808).
    priv fn _err_contained(self, id: DiagID, at: SourceRange, const msg: string) {
        self.sc->contained_errors += 1
        self._err(id, at, msg)
    }

    /// R025E for a member lookup miss on \p ty. When an `extend` of the type
    /// in a file this TU does not import declares the name, the miss is the
    /// extension-visibility rule (MemberLookup::extension_visible), so say
    /// which file and offer the import.
    priv fn _err_member_miss(self,
                             at:          SourceRange,
                             const msg:   string,
                             ty:          unsafe *Type,
                             name:        DeclName,
                             const spelled: string,
                             const tn:    string) {
        self.sc->contained_errors += 1
        self.n_errored            += 1
        var b = self.sc->diag->report(DiagID::R025E, at.start, msg)
        b.first(at)
        var e: unsafe *Declarations::ExtensionDecl = &null
        if ty != &null {
            e = self.ml.hidden_extension(ty, name)
        }

        var unsafe *sm = self.sc->ctx->sm
        if e != &null && sm != &null {
            var epath = Path(sm->get_filename(e->range.start))
            var file  = epath.filename()
            b.note(
                e->range.start,
                f"an extension of '{tn}' in '{file}' declares '{spelled}'; import it to use it",
            )
            var mp = self._import_spelling(Path(sm->get_filename(at.start)), epath)
            var unsafe *tu = self.sc->tu
            if mp.size() > 0 && tu != &null && tu->imports.size() > 0 {
                // After the line the last import ends on: an ImportDecl's
                // range may stop at its keyword.
                var unsafe *last = *tu->imports.get(tu->imports.size() - 1)
                if last != &null && last->range.start.is_valid() {
                    var at_end = last->range.start
                    if last->range.end.is_valid() && sm->same_file(at_end, last->range.end) &&
                        sm->get_offset(last->range.end) > sm->get_offset(at_end) {
                        at_end = last->range.end
                    }

                    var col  = sm->get_line_col(at_end).column
                    var off  = sm->get_offset(at_end) + 1 - col
                    var eol  = sm->get_loc(sm->get_fid(at_end), off + sm->get_full_line(at_end).size())
                    b.insert(eol, f"\nimport self::{mp}", f"import 'self::{mp}'")
                }
            }
        }

        b.emit()
    }

    /// The `a::b::c` that imports file \p to from \p from's directory, or
    /// "" when it is not under it (then no fix-it: a search-root spelling
    /// would be a guess).
    priv fn _import_spelling(self, const from: Path, const to: Path) -> string {
        var here = Path(from.parent_path())
        var rel  = to.relative_to(here)
        var o: string = ""
        var n  = rel.size()
        if n > 2 && rel[n - 2] == ('.' as u8) && rel[n - 1] == ('k' as u8) {
            n = n - 2
        }

        for var i: usize = 0; i < n; ++i {
            var c = rel[i]
            if c == ('/' as u8) || c == ('\\' as u8) {
                o += "::"
            } else {
                o.push_back(c)
            }
        }

        return o
    }

    priv fn _name_imm(self, tok: Token) -> u32 {
        var im = self.sc->ctx->get_ident_imm(tok)
        if im != u32::MAX {
            return im
        }

        // Unwrapped: a `self` passed as a macro argument reaches here as a
        // TkMacroExpand token, and matching only the raw kind left it
        // unbound (the I003E invariant error for `check!(self.x, ...)`).
        if self.sc->ctx->unwrap_token(tok).kind == TokenKind::KwSelf {
            return self._self_imm
        }

        return u32::MAX
    }

    priv fn _generic_count(self, d: unsafe *Decl) -> usize {
        return decl_generic_params(d).size()
    }

    /// Spelled with the decl's OWN context: a name reached through an import
    /// is interned in the source file's imm table, not this TU's.
    /// `Animal::Animal`: a record's constructors, named by the record's own
    /// name after `::` (classes-inheritance.md: `Animal::Animal(self, name)`
    /// initializes a base). They live under DeclName::ctor(), never under
    /// the identifier, so member lookup cannot find them; only the record's
    /// OWN table is read -- a constructor is not inherited. Whether the call
    /// is one Kairo allows (a base, from a derived constructor's first
    /// statements) is BaseInitCheck's question, not name binding's.
    priv fn _ctors_by_name(self,
                           const a:       Anchor,
                           const spelled: string,
                           @inout out:    cxx::std::vector<unsafe *Decl>) {
        if a.decl == &null || !isa<Declarations::ClassDecl>(a.decl) || a.ty == &null {
            return
        }

        if spelled != self._decl_name_str(a.decl) {
            return
        }

        var unsafe *body = self.sc->record_body(a.ty)
        if body == &null {
            body = decl_pattern(a.decl)
        }

        var unsafe *dc = NameLookup::context_of(body)
        if dc == &null {
            return
        }

        var cell = self.sc->lookup.in_context(dc, DeclName::ctor())
        if !cell.found() {
            return
        }

        for var i: usize = 0; i < cell.cell->size(); ++i {
            var unsafe *d = cell.cell->get(i)
            if d != &null && isa<Declarations::FunctionDecl>(d) {
                out.push_back(d)
            }
        }
    }

    /// The builtin type \p id names when \p n's first step is a `::` to a
    /// member an extension of it declares, visible here; null otherwise.
    priv fn _primitive_static_head(self, id: unsafe *NamedIdentExpr, n: unsafe *ChainExpr) -> unsafe *Type {
        if n->steps.size() == 0 {
            return &null
        }

        var unsafe *st0 = n->steps.get(0)
        if st0 == &null || st0->name == &null || st0->access_kind != ChainExpr::AccessKind::ColonColon {
            return &null
        }

        var bk = builtin_for_token(id->name.kind)
        if bk == BuiltinKind::COUNT {
            return &null
        }

        var unsafe *bt = self.sc->builtin(bk)
        var imm = self._name_imm(st0->name->name)
        if bt == &null || imm == u32::MAX {
            return &null
        }

        var cands = cxx::std::vector<unsafe *Decl>()
        self.ml.lookup(bt, DeclName::ident(imm), unsafe &cands)
        return if (cands.empty()) => (&null) else => bt
    }

    priv fn _decl_name_str(self, d: unsafe *Decl) -> string {
        if d == &null {
            return "<null>"
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            ctx = self.sc->ctx
        }

        if isa<Declarations::ClassDecl>(d) {
            return ctx->get_spelling(cast<Declarations::ClassDecl>(d)->name)
        }

        if isa<Declarations::StructDecl>(d) {
            return ctx->get_spelling(cast<Declarations::StructDecl>(d)->name)
        }

        if isa<Declarations::UnionDecl>(d) {
            return ctx->get_spelling(cast<Declarations::UnionDecl>(d)->name)
        }

        if isa<Declarations::InterfaceDecl>(d) {
            return ctx->get_spelling(cast<Declarations::InterfaceDecl>(d)->name)
        }

        if isa<Declarations::EnumDecl>(d) {
            return ctx->get_spelling(cast<Declarations::EnumDecl>(d)->name)
        }

        if isa<Declarations::TypeAliasDecl>(d) {
            return ctx->get_spelling(cast<Declarations::TypeAliasDecl>(d)->name)
        }

        if isa<Declarations::ModuleDecl>(d) {
            return ctx->get_spelling(cast<Declarations::ModuleDecl>(d)->name)
        }

        if isa<Declarations::FunctionDecl>(d) {
            return ctx->get_spelling(cast<Declarations::FunctionDecl>(d)->name)
        }

        if isa<Declarations::ParamDecl>(d) {
            return ctx->get_spelling(cast<Declarations::ParamDecl>(d)->name)
        }

        if isa<Declarations::VariableDecl>(d) {
            return ctx->get_spelling(cast<Declarations::VariableDecl>(d)->name)
        }

        if isa<Declarations::FieldDecl>(d) {
            return ctx->get_spelling(cast<Declarations::FieldDecl>(d)->name)
        }

        if isa<Declarations::EnumVariantDecl>(d) {
            return ctx->get_spelling(cast<Declarations::EnumVariantDecl>(d)->name)
        }

        if isa<Declarations::GenericParamDecl>(d) {
            return ctx->get_spelling(cast<Declarations::GenericParamDecl>(d)->name)
        }

        return "<decl>"
    }

    /// Diagnostic spelling of a canonical. Kept minimal on purpose: the
    /// TypePrinter is the real renderer and this must not grow into a second
    /// one.
    priv fn _type_name_str(self, t: unsafe *Type) -> string {
        if t == &null {
            return "<type>"
        }

        if isa<BuiltinType>(t) {
            return cast<BuiltinType>(t)->spelling()
        }

        if isa<RecordType>(t) {
            // A clang-backed record is named the way the C++ header spells it
            // (`basic<int>`, `ns::Foo`); its bare Kairo name drops the template
            // arguments and the namespace, which is what the user needs to
            // tell two receivers apart.
            var cxx = decl_cxx_spelling(cast<RecordType>(t)->decl)
            if cxx.length() > 0 {
                return if cxx.starts_with("::") => cxx.subslice(2, cxx.length() - 2) else => cxx
            }

            return self._decl_name_str(cast<RecordType>(t)->decl)
        }

        if isa<PointerType>(t) {
            return f"*{self._type_name_str(cast<PointerType>(t)->pointee)}"
        }

        if isa<NullableType>(t) {
            var unsafe *inner = cast<NullableType>(t)->inner
            if isa<NullableType>(inner) { // `T??` is the operator.
                return f"({self._type_name_str(inner)})?"
            }

            return f"{self._type_name_str(inner)}?"
        }

        if isa<CXXLValueRefType>(t) {
            var unsafe *lr = cast<CXXLValueRefType>(t)
            return f"{self._type_name_str(lr->referee)}&"
        }

        if isa<QualifiedType>(t) {
            var unsafe *q = cast<QualifiedType>(t)
            var        s  = if (canon_has_const(t)) => ("const ") else => ""
            if canon_has_volatile(t) {
                s += "volatile "
            }

            return s + self._type_name_str(q->inner)
        }

        if isa<CXXRValueRefType>(t) {
            return f"{self._type_name_str(cast<CXXRValueRefType>(t)->referee)}&&"
        }

        if isa<VectorType>(t) {
            return f"[{self._type_name_str(cast<VectorType>(t)->element)}]"
        }

        if TypeUtil(self.sc).is_tuple(t) {
            return "a tuple"
        }

        if isa<MapType>(t) {
            return "a map"
        }

        if isa<SetType>(t) {
            return "a set"
        }

        if isa<FunctionPointerType>(t) {
            return "a function pointer"
        }

        // No spelling of its own here: the Sema printer names every type, and
        // "this type" hides exactly what the user needs to see.
        return TypeUtil(self.sc).str(t)
    }
}
