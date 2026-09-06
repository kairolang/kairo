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
///     candidate cells and fills the rest). A step rooted in a generic
///     param is marked Dependent for M2 (hard invariant #5).
///
///   \par One error, one home
///     "no member named X", "X is a type, use ::", "'::' after a value",
///     "'.' on a pointer (use ->)", ambiguous non-function members across
///     bases: HERE. Unknown head: N. Bad types: T. Access: AccessCheck.
///
///   Phase: RESOLVE (T stage, after TypeResolution)
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
import Sema::Resolve::MemberLookup::*;
import Sema::Resolve::ResolutionTrace::*;
import Sema::Resolve::ResolutionState::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

__inline_cpp("
#define RecursiveASTVisitor_ChainBinding RecursiveASTVisitor<ChainBinding>
");

/// \enum AnchorKind
/// \brief What the LEFT side of a step denotes.
enum AnchorKind derives u8 {
    Module = 0,      ///< a module/TU scope: `::` steps do plain table lookup.
    Type,            ///< a type: `::` steps do member lookup (statics, nested, variants).
    Value,           ///< a value with a canonical type: `.`/`->` steps do member lookup.
    NeedsInference,  ///< a value whose type is not declared.
    Dependent,       ///< rooted in a generic parameter.
    Foreign,         ///< behind an ffi anchor: the header's names live in clang.
    Errored,         ///< already diagnosed; stay silent.
}

/// \class Anchor
class Anchor {
    pub var kind:  AnchorKind   = AnchorKind::Errored;
    /// Module: every scope the base denotes. More than one when a name is
    /// bound to a module reopened across files -- they are ONE namespace,
    /// so a `::` step searches all of them (IMPORTS.md §4.3).
    pub var scopes: vec::<*DeclContext>;
    pub var decl:  *Decl        = &null;   ///< Type: the record decl. Value: the decl (for notes).
    pub var ty:    *Type        = &null;   ///< Type: its record. Value: the canonical.
    fn Anchor(self) { }
}

class ChainBinding derives RecursiveASTVisitor::<ChainBinding> {
    pub var sc: *SemaContext;
    var ml: MemberLookup;

    pub var n_bound:     usize = 0;
    pub var n_cands:     usize = 0;
    pub var n_inference: usize = 0;
    pub var n_dependent: usize = 0;
    pub var n_foreign:   usize = 0;
    pub var n_errored:   usize = 0;

    priv var _self_imm: u32 = u32(-1);

    fn ChainBinding(self, sc: *SemaContext) {
        self.sc = sc;
        self.ml = MemberLookup(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::NamesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        self._self_imm = self.sc->imm_table()->intern_ident_copy("self");
        self.ml.index_extensions();

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    // === The chain =============================================================

    fn traverse_chain_expr(self, n: *ChainExpr) -> *ChainExpr {
        if n == &null { return n; }
        // Base + generic args first (nested chains inside args bind too).
        var out = RecursiveASTVisitor_ChainBinding::traverse_chain_expr(n);

        var a = self._anchor_of_base(n);
        for var i: usize = 0; i < n->steps.size(); ++i {
            var st = n->steps.get(i);
            if st == &null { break; }
            if st->resolved_decl != &null { a = self._anchor_after(st->resolved_decl, st); continue; }   // idempotent re-run.
            a = self._bind_step(n, st, a);
        }
        if a.kind == AnchorKind::Dependent {
            n->expr_flags = static_cast::<Expr::ExprFlags>(
                static_cast::<u8>(n->expr_flags)
              | static_cast::<u8>(Expr::ExprFlags::IsDependent)
              | static_cast::<u8>(Expr::ExprFlags::IsInstantiationDependent));
        }
        return out;
    }

    /// What the base expression denotes, from N's binding + T's canonical.
    priv fn _anchor_of_base(self, n: *ChainExpr) -> Anchor {
        var a = Anchor{};

        if n->base == &null {
            // `::std::x`: global root.
            a.kind = AnchorKind::Module;
            a.scopes.push_back(static_cast::<*DeclContext>(self.sc->tu));
            return a;
        }
        if n->base->is_poisoned() { a.kind = AnchorKind::Errored; return a; }

        if isa::<NamedIdentExpr>(n->base) {
            var id = cast::<NamedIdentExpr>(n->base);
            if id->is_deferred() {
                // A cell of nothing but ModuleDecls is one reopened namespace,
                // not an overload set N failed to collapse: the canonicals are
                // distinct decls but the SCOPE is the union of their tables.
                // Anything else in the cell is a real overload set.
                var cell = id->candidate_cell;
                var all_mod = cell->size() > 0;
                for var i: usize = 0; i < cell->size(); ++i {
                    if !isa::<ModuleDecl>(cell->get(i)) { all_mod = false; break; }
                }
                if !all_mod { a.kind = AnchorKind::NeedsInference; return a; }
                a.kind = AnchorKind::Module;
                for var i: usize = 0; i < cell->size(); ++i {
                    a.scopes.push_back(NameLookup::context_of(cell->get(i)));
                }
                return a;
            }
            if !id->is_bound()   { a.kind = AnchorKind::Errored;        return a; }   // N diagnosed.
            return self._anchor_after(id->resolved_decl, &null);
        }

        // Any other base -- a call, a subscript, a paren, a literal -- has a
        // type only inference can name.
        a.kind = AnchorKind::NeedsInference;
        return a;
    }

    /// The anchor a bound decl provides for the NEXT step.
    priv fn _anchor_after(self, d: *Decl, st: *ChainExpr::Step) -> Anchor {
        var a = Anchor{};
        if d == &null { a.kind = AnchorKind::Errored; return a; }
        if d->is_poisoned() { a.kind = AnchorKind::Errored; return a; }

        switch d->kind {
            case DeclKind::ModuleDecl {
                a.kind = AnchorKind::Module;
                a.scopes.push_back(NameLookup::context_of(d));
                a.decl = d;
                return a;
            }
            case DeclKind::ClassDecl     { return self._type_anchor(d); }
            case DeclKind::StructDecl    { return self._type_anchor(d); }
            case DeclKind::UnionDecl     { return self._type_anchor(d); }
            case DeclKind::InterfaceDecl { return self._type_anchor(d); }
            case DeclKind::EnumDecl      { return self._type_anchor(d); }
            case DeclKind::TypeAliasDecl {
                var td = cast::<TypeAliasDecl>(d);
                if td->aliased == &null { a.kind = AnchorKind::Errored; return a; }
                var c = td->aliased->canonical;
                if c == &null {
                    a.kind = (AnchorKind::Dependent) if (td->aliased->is_dependent()) else (AnchorKind::Errored);
                    return a;
                }
                if isa::<RecordType>(c) { return self._type_anchor(cast::<RecordType>(c)->decl); }
                // Alias of a builtin/pointer/etc.: a type, but one with no
                // scope of its own. Extensions on it are still reachable.
                a.kind = AnchorKind::Type;
                a.decl = d;
                a.ty   = c;
                return a;
            }
            case DeclKind::ImportDecl {
                // `ffi "c++" import "h.hh" as my_h`: `my_h` is a scope FICTION.
                // The header's decls exist only inside clang until the
                // extraction pass, so every step after it is Foreign: no decl,
                // no diagnostic, no poison (IMPORTS.md §5).
                if cast::<ImportDecl>(d)->has_ffi_linkage() {
                    a.kind = AnchorKind::Foreign;
                    a.decl = d;
                    return a;
                }
                a.kind = AnchorKind::Errored;
                return a;
            }
            case DeclKind::GenericParamDecl {
                a.kind = AnchorKind::Dependent;
                a.decl = d;
                return a;
            }
            case DeclKind::ParamDecl {
                var p = cast::<ParamDecl>(d);
                return self._value_anchor(d, p->type_);
            }
            case DeclKind::VariableDecl {
                var v = cast::<VariableDecl>(d);
                return self._value_anchor(d, v->type_);
            }
            case DeclKind::FieldDecl {
                var f = cast::<FieldDecl>(d);
                return self._value_anchor(d, f->type_);
            }
            case DeclKind::EnumVariantDecl {
                // A variant is a value of its enum. The enum is the variant's
                // semantic_dc owner.
                if d->semantic_dc == &null { a.kind = AnchorKind::Errored; return a; }
                var edc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
                var ed  = edc->owner_decl();
                if ed == &null { a.kind = AnchorKind::Errored; return a; }
                var args = vec::<*Type>();
                a.kind = AnchorKind::Value;
                a.decl = d;
                a.ty   = self.sc->types->record(self._representative(ed), &args);
                if self._generic_count(ed) > 0 { a.kind = AnchorKind::Dependent; }
                return a;
            }
            case DeclKind::FunctionDecl {
                // A function value or a method: what follows is a call result.
                a.kind = AnchorKind::NeedsInference;
                a.decl = d;
                return a;
            }
            default {
                a.kind = AnchorKind::NeedsInference;
                a.decl = d;
                return a;
            }
        }
    }

    priv fn _type_anchor(self, d: *Decl) -> Anchor {
        var a = Anchor{};
        var canon = self._representative(d);
        a.kind = AnchorKind::Type;
        a.decl = canon;
        // The record with its own params as args (Self-shaped). For member
        // lookup only the decl matters; the args make Self/dependence right.
        var args = vec::<*Type>();
        var gps  = self._generic_params_of(canon);
        for var i: usize = 0; i < gps.size(); ++i {
            var gp = gps[i];
            if gp == &null { continue; }
            args.push_back(self.sc->types->generic_param(canon, gp->index, gp->is_pack));
        }
        a.ty = self.sc->types->record(canon, &args);
        return a;
    }

    /// A value's anchor is its declared type's canonical. No declared type,
    /// or a declared type that could not canonicalize, means inference.
    priv fn _value_anchor(self, d: *Decl, t: *Type) -> Anchor {
        var a = Anchor{};
        a.decl = d;
        if t == &null { a.kind = AnchorKind::NeedsInference; return a; }
        if t->is_poisoned() { a.kind = AnchorKind::Errored; return a; }
        if t->canonical == &null {
            a.kind = (AnchorKind::Dependent) if (t->is_dependent() || t->is_instantiation_dependent())
                     else (AnchorKind::NeedsInference);
            return a;
        }
        a.kind = AnchorKind::Value;
        a.ty   = t->canonical;
        return a;
    }

    // === One step ==================================================================

    priv fn _bind_step(self, chain: *ChainExpr, st: *ChainExpr::Step, a: Anchor) -> Anchor {
        var at  = st->range;
        var loc = st->range.start.id;
        if st->name != &null { at = st->name->range; loc = st->name->range.start.id; }

        // Unusable left side: record why and stop the chain.
        if a.kind == AnchorKind::Errored {
            if st->name != &null { st->name->poison(); }
            self._record(loc, MemberOutcome::Errored, &null, 0, &null);
            return a;
        }
        if a.kind == AnchorKind::NeedsInference {
            self._record(loc, MemberOutcome::NeedsInference, &null, 0, a.decl);
            self.n_inference += 1;
            return a;
        }
        if a.kind == AnchorKind::Dependent {
            self._record(loc, MemberOutcome::Dependent, &null, 0, a.decl);
            self.n_dependent += 1;
            return a;
        }
        if a.kind == AnchorKind::Foreign {
            // Foreign is absorbing: every later step is foreign too.
            self._record(loc, MemberOutcome::Foreign, &null, 0, a.decl);
            self.n_foreign += 1;
            return a;
        }

        // Operator and tuple-index steps need a typed operand: inference.
        if st->is_operator() || st->is_tuple_index() {
            self._record(loc, MemberOutcome::NeedsInference, &null, 0, a.decl);
            self.n_inference += 1;
            var r = Anchor{}; r.kind = AnchorKind::NeedsInference; r.decl = a.decl;
            return r;
        }
        if st->name == &null {
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }

        var imm = self._name_imm(st->name->name);
        if imm == u32(-1) {
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }
        var name = DeclName::ident(imm);
        var spelled = self.sc->ctx->get_spelling(st->name->name);

        var is_scope_sep = (st->access_kind == ChainExpr::AccessKind::ColonColon);

        // --- `::` -----------------------------------------------------------------
        if is_scope_sep {
            if a.kind == AnchorKind::Value {
                self._err(at, f"'::' cannot follow a value; use '.' to access a member of '{self._decl_name_str(a.decl)}\x27");
                st->name->poison();
                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
                var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
            }
            if a.kind == AnchorKind::Module {
                // Search every scope the anchor denotes and union the hits.
                var cands  = vec::<*Decl>();
                var nhit: usize = 0;
                var frozen: *OverloadCell = &null;
                for var si: usize = 0; si < a.scopes.size(); ++si {
                    var cell = self.ml.in_scope(a.scopes[si], name, spelled);
                    if cell == &null { continue; }
                    if cell->size() == 0 { continue; }
                    nhit  += 1;
                    frozen = cell;
                    for var i: usize = 0; i < cell->size(); ++i {
                        var d = cell->get(i);
                        if d == &null { continue; }
                        var dup = false;
                        for var k: usize = 0; k < cands.size(); ++k {
                            if cands[k] == d { dup = true; break; }
                        }
                        if !dup { cands.push_back(d); }
                    }
                }
                if cands.empty() {
                    // Nothing in the module's own table. Its pub/prot imports
                    // are part of its surface too, and they live in its
                    // OVERLAY rather than that table (IMPORTS.md §4.4).
                    for var si: usize = 0; si < a.scopes.size(); ++si {
                        var rx = self.ml.reexport_lookup(a.scopes[si], spelled);
                        if rx == &null { continue; }
                        for var i: usize = 0; i < rx->size(); ++i {
                            var d = rx->get(i);
                            if d == &null { continue; }
                            var dup = false;
                            for var k: usize = 0; k < cands.size(); ++k {
                                if cands[k] == d { dup = true; break; }
                            }
                            if !dup { cands.push_back(d); }
                        }
                    }
                }
                if cands.empty() {
                    var mn = ("the global scope") if (a.decl == &null) else (f"module '{self._decl_name_str(a.decl)}\x27");
                    self._err(at, f"no member named '{spelled}' in {mn}");
                    st->name->poison();
                    self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
                    var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
                }
                // A frozen cell may only be reused when it IS the answer: with
                // two contributing scopes the union is a new set.
                if nhit > 1 { frozen = &null; }
                return self._commit(st, loc, &cands, a.decl, frozen);
            }
            // Type: statics, nested types, enum variants, ctors -- member lookup.
            var cands = vec::<*Decl>();
            self.ml.lookup(a.ty, name, &cands);
            if cands.empty() {
                self._err(at, f"no member named '{spelled}' in '{self._decl_name_str(a.decl)}\x27");
                st->name->poison();
                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
                var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
            }
            return self._commit(st, loc, &cands, a.decl, &null);
        }

        // --- `.` `->` `?.` `?->` -----------------------------------------------------
        if a.kind == AnchorKind::Module {
            self._err(at, f"'.' cannot follow a module; use '::' to name a member of '{self._decl_name_str(a.decl)}\x27");
            st->name->poison();
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }
        if a.kind == AnchorKind::Type {
            self._err(at, f"'.' cannot follow a type; use '::' to name a member of '{self._decl_name_str(a.decl)}\x27");
            st->name->poison();
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }

        // Value. Peel the separator's expected wrapper off the canonical.
        var ty = a.ty;
        var arrow = (st->access_kind == ChainExpr::AccessKind::Arrow)
                 || (st->access_kind == ChainExpr::AccessKind::QuestionArrow);
        var maybe = (st->access_kind == ChainExpr::AccessKind::QuestionDot)
                 || (st->access_kind == ChainExpr::AccessKind::QuestionArrow);

        if maybe {
            if isa::<NullableType>(ty) {
                ty = cast::<NullableType>(ty)->inner;
            } else if isa::<RecordType>(ty) {
                // `T?` may have been lowered to `Null<T>` (lang item). Peel it.
                var rt = cast::<RecordType>(ty);
                var null_decl = self.sc->well_known.get(WellKnownType::Null);
                if (null_decl != &null) && (rt->decl == null_decl) && (rt->args.size() == 1) {
                    ty = rt->args[0];
                }
            }
            // `?.` on a non-nullable is a warning's worth, not an error; the
            // nullable checker owns it. Proceed on the type as-is.
        }
        if arrow {
            if !isa::<PointerType>(ty) {
                self._err(at, "'->' requires a pointer on its left; use '.' for a value");
                st->name->poison();
                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
                var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
            }
            ty = cast::<PointerType>(ty)->pointee;
        } else {
            if isa::<PointerType>(ty) {
                self._err(at, "'.' cannot be applied to a pointer; use '->\x27");
                st->name->poison();
                self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
                var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
            }
        }
        if ty == &null {
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }
        if ty->is_dependent() {
            self._record(loc, MemberOutcome::Dependent, &null, 0, a.decl);
            self.n_dependent += 1;
            var r = Anchor{}; r.kind = AnchorKind::Dependent; r.decl = a.decl; return r;
        }

        var cands = vec::<*Decl>();
        self.ml.lookup(ty, name, &cands);
        if cands.empty() {
            var tn = self._type_name_str(ty);
            self._err(at, f"no member named '{spelled}' in '{tn}\x27");
            st->name->poison();
            self._record(loc, MemberOutcome::Errored, &null, 0, a.decl);
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }
        var owner: *Decl = &null;
        if isa::<RecordType>(ty) { owner = cast::<RecordType>(ty)->decl; }
        return self._commit(st, loc, &cands, owner, &null);
    }

    /// Write the step's slots from a candidate set and produce the next anchor.
    ///
    ///   one decl            -> resolved_decl
    ///   all functions       -> candidate_cell (the frozen cell if they all came
    ///                          from one; a sema-owned merged cell otherwise)
    ///   mixed / >1 non-fn   -> ambiguous: two distinct entities under one
    ///                          name reached through different bases.
    priv fn _commit(self, st: *ChainExpr::Step, loc: u32, cands: *vec::<*Decl>,
                    owner: *Decl, frozen: *OverloadCell) -> Anchor {
        var n = cands->size();
        if n == 1 {
            var d = self._representative((*cands)[0]);
            st->resolved_decl = d;
            self._record(loc, MemberOutcome::Bound, d, 1, self._home_of(d));
            self.n_bound += 1;
            return self._anchor_after(d, st);
        }

        var all_fn = true;
        var nonfn: *Decl = &null;
        var nonfn2: *Decl = &null;
        for var i: usize = 0; i < n; ++i {
            var d = (*cands)[i];
            if !isa::<FunctionDecl>(d) {
                all_fn = false;
                if nonfn == &null { nonfn = d; } else if nonfn2 == &null { nonfn2 = d; }
            }
        }

        if !all_fn {
            // A redecl chain (fwd + def) collapses to one entity; only distinct
            // entities are ambiguous.
            var sole: *Decl = &null;
            var distinct = false;
            for var i: usize = 0; i < n; ++i {
                var r = self._representative((*cands)[i]);
                if sole == &null { sole = r; continue; }
                if sole != r { distinct = true; break; }
            }
            if !distinct {
                st->resolved_decl = sole;
                self._record(loc, MemberOutcome::Bound, sole, 1, self._home_of(sole));
                self.n_bound += 1;
                return self._anchor_after(sole, st);
            }
            var nm = self.sc->ctx->get_spelling(st->name->name);
            var b = self.sc->diag->report(DiagID::R001E, st->name->range.start,
                f"'{nm}' is ambiguous: it names more than one member reachable from here"
            );
            b.first(st->name->range);
            for var i: usize = 0; i < n; ++i {
                var d = (*cands)[i];
                b.note(DiagID::R001N, d->range.start, "candidate declared here").first(d->range);
            }
            b.emit();
            st->name->poison();
            self._record(loc, MemberOutcome::Errored, &null, n, owner);
            self.n_errored += 1;
            var r = Anchor{}; r.kind = AnchorKind::Errored; return r;
        }

        // Overload set. Reuse the frozen cell when it is exactly the set;
        // otherwise union into a sema-owned cell (dies with sema_alloc).
        var cell: *OverloadCell = &null;
        if (frozen != &null) && (frozen->size() == n) {
            cell = frozen;
        } else {
            cell = self.sc->ctx->alloc_init_sema_cleanup::<OverloadCell>();
            for var i: usize = 0; i < n; ++i { cell->append((*cands)[i]); }
        }
        st->candidate_cell = cell;
        self._record(loc, MemberOutcome::Candidates, &null, n, owner);
        self.n_cands += 1;
        var r = Anchor{}; r.kind = AnchorKind::NeedsInference; r.decl = owner; return r;
    }

    // === helpers ===================================================================

    /// The decl that OWNS `d`'s scope -- the type a member was declared in,
    /// which is what a reader wants to see, not the type it was reached
    /// through.
    priv fn _home_of(self, d: *Decl) -> *Decl {
        if (d == &null) || (d->semantic_dc == &null) { return &null; }
        var owner = reinterpret_cast::<*DeclContext>(d->semantic_dc)->owner_decl();
        if isa::<ExtensionDecl>(owner) {
            // An ExtensionDecl has no name of its own, so reporting it says
            // "[member of ]". The home a reader means is the type extended.
            var e = cast::<ExtensionDecl>(owner);
            if (e->target != &null) && (e->target->canonical != &null)
            && isa::<RecordType>(e->target->canonical) {
                return cast::<RecordType>(e->target->canonical)->decl;
            }
        }
        return owner;
    }

    priv fn _record(self, loc: u32, o: MemberOutcome, d: *Decl, ncand: usize, owner: *Decl) {
        self.sc->trace.member_result(loc, o, d, ncand, owner);
    }

    priv fn _err(self, at: SourceRange, msg: string) {
        // FIXME(diag-table): every diagnostic in this pass shares R001E until
        // the resolution codes are split.
        self.sc->diag->report(DiagID::R001E, at.start, msg).first(at).emit();
        self.n_errored += 1;
    }

    priv fn _name_imm(self, tok: Token) -> u32 {
        var im = self.sc->ctx->get_ident_imm(tok);
        if im != u32(-1) { return im; }
        if tok.kind == TokenKind::KwSelf { return self._self_imm; }
        return u32(-1);
    }

    priv fn _representative(self, d: *Decl) -> *Decl {
        if d == &null { return &null; }
        if isa::<ClassDecl>(d)     { return static_cast::<*Decl>(cast::<ClassDecl>(d)->canonical_decl());     }
        if isa::<StructDecl>(d)    { return static_cast::<*Decl>(cast::<StructDecl>(d)->canonical_decl());    }
        if isa::<UnionDecl>(d)     { return static_cast::<*Decl>(cast::<UnionDecl>(d)->canonical_decl());     }
        if isa::<InterfaceDecl>(d) { return static_cast::<*Decl>(cast::<InterfaceDecl>(d)->canonical_decl()); }
        if isa::<EnumDecl>(d)      { return static_cast::<*Decl>(cast::<EnumDecl>(d)->canonical_decl());      }
        if isa::<ModuleDecl>(d)    { return static_cast::<*Decl>(cast::<ModuleDecl>(d)->canonical_decl());    }
        return d;
    }

    priv fn _generic_params_of(self, d: *Decl) -> FrozenList::<*GenericParamDecl> {
        if d == &null { return create_empty_frozen_list::<*GenericParamDecl>(); }
        if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->generic_params;     }
        if isa::<StructDecl>(d)    { return cast::<StructDecl>(d)->generic_params;    }
        if isa::<UnionDecl>(d)     { return cast::<UnionDecl>(d)->generic_params;     }
        if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->generic_params; }
        if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->generic_params;      }
        return create_empty_frozen_list::<*GenericParamDecl>();
    }

    priv fn _generic_count(self, d: *Decl) -> usize {
        return self._generic_params_of(d).size();
    }

    /// Spelled with the decl's OWN context: a name reached through an import
    /// is interned in the source file's imm table, not this TU's.
    priv fn _decl_name_str(self, d: *Decl) -> string {
        if d == &null { return "<null>"; }
        var ctx = NameLookup::ctx_of(d);
        if ctx == &null { ctx = self.sc->ctx; }
        if isa::<ClassDecl>(d)        { return ctx->get_spelling(cast::<ClassDecl>(d)->name);        }
        if isa::<StructDecl>(d)       { return ctx->get_spelling(cast::<StructDecl>(d)->name);       }
        if isa::<UnionDecl>(d)        { return ctx->get_spelling(cast::<UnionDecl>(d)->name);        }
        if isa::<InterfaceDecl>(d)    { return ctx->get_spelling(cast::<InterfaceDecl>(d)->name);    }
        if isa::<EnumDecl>(d)         { return ctx->get_spelling(cast::<EnumDecl>(d)->name);         }
        if isa::<TypeAliasDecl>(d)    { return ctx->get_spelling(cast::<TypeAliasDecl>(d)->name);    }
        if isa::<ModuleDecl>(d)       { return ctx->get_spelling(cast::<ModuleDecl>(d)->name);       }
        if isa::<FunctionDecl>(d)     { return ctx->get_spelling(cast::<FunctionDecl>(d)->name);     }
        if isa::<ParamDecl>(d)        { return ctx->get_spelling(cast::<ParamDecl>(d)->name);        }
        if isa::<VariableDecl>(d)     { return ctx->get_spelling(cast::<VariableDecl>(d)->name);     }
        if isa::<FieldDecl>(d)        { return ctx->get_spelling(cast::<FieldDecl>(d)->name);        }
        if isa::<EnumVariantDecl>(d)  { return ctx->get_spelling(cast::<EnumVariantDecl>(d)->name);  }
        return "<decl>";
    }

    /// Diagnostic spelling of a canonical. Kept minimal on purpose: the
    /// TypePrinter is the real renderer and this must not grow into a second
    /// one.
    priv fn _type_name_str(self, t: *Type) -> string {
        if t == &null { return "<type>"; }
        if isa::<BuiltinType>(t) { return cast::<BuiltinType>(t)->spelling(); }
        if isa::<RecordType>(t)  { return self._decl_name_str(cast::<RecordType>(t)->decl); }
        if isa::<PointerType>(t) { return f"*{self._type_name_str(cast::<PointerType>(t)->pointee)}"; }
        if isa::<NullableType>(t){ return f"{self._type_name_str(cast::<NullableType>(t)->inner)}?"; }
        if isa::<VectorType>(t)  { return f"[{self._type_name_str(cast::<VectorType>(t)->element)}]"; }
        if isa::<TupleType>(t)   { return "a tuple"; }
        if isa::<MapType>(t)     { return "a map"; }
        if isa::<SetType>(t)     { return "a set"; }
        if isa::<FunctionPointerType>(t) { return "a function pointer"; }
        return "this type";
    }
}