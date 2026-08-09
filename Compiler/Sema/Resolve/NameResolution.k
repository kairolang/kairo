/// --- The Kairo Project ------------------------ Sema/NameResolution.k --- ///
///
///   \brief Phase N: bind every identifier use to its declaration.
///
///   \detail
///     Two halves, one pass (run in order, not interleaved):
///
///       N(a) decl validation -- walks dc_decls per scope over the FROZEN
///            tables: link Redeclarable chains, validate overload sets,
///            attach tu->out_of_line, populate sc.well_known. Writes
///            decl-to-decl links only; never inserts into a frozen table.
///
///       N(b) binding -- RAV walk over the TU. Every NamedIdentExpr gets
///            resolved_decl (unique) or candidate_cell (overload set,
///            aliases the frozen cell). ANNOTATES nodes so jump-to-def /
///            completion can query resolution later.
///
///     Lookup itself lives in sc->lookup (NameLookup, the four
///     primitives); this pass owns POLICY only: the lexical local stack
///     (locals are excluded from symbol tables -- executable scopes have
///     no dc_symbols), binding order (locals -> unqualified -> miss),
///     and diagnostics. Redefinition + unresolved-ident + import-access
///     errors live HERE, nowhere else.
///
///   \par Explicitly NOT done here (see RESOLUTION.md hard invariant #3)
///     - overload SELECTION. A multi-candidate cell is handed through
///       whole; N never filters, not by arity, not by anything.
///     - ADL, types, inference, conformance, extension member lookup.
///     - FUNCTION redecl chains: distinguishing a redeclaration from an
///       overload needs signatures. Deferred deliberately.
///     - alias expansion (NameLookup::context_of returns null for aliases
///       on purpose; T owns expansion).
///     - chain SEGMENTS and pattern HEADS. A ChainExpr's base is an
///       ordinary unqualified name and IS bound; everything after the
///       first `::`/`.` waits for T. ConstructorPattern heads are skipped
///       entirely so a bare binder-shaped head never mis-errors.
///     - a BARE `case n` head. That is an UnresolvedConstructorPattern and
///       is genuinely ambiguous between a nullary ctor and a binder until
///       the scrutinee type exists; `case var n` IS handled. T owns it.
///
///   \par Statement-level binders
///     `for x in xs`, `catch e`, `var (a, b) = t`, context bindings and
///     `case var n` all DO bind: the parser synthesizes a VariableDecl per
///     binder (Binding::decl / CatchArm::decl / BindingPattern::decl) and N
///     pushes it onto the lexical stack for the construct's body. The
///     value/iterable expression is resolved in the OUTER scope first, so
///     `for x in x` names an outer `x`, matching `var x = x`.
///
///   Phase: RESOLVE
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::Context::ImportOverlay::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Patterns::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::ExprKind::*;
import AST::Kind::PatternKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

__inline_cpp("
#define RecursiveASTVisitor_NameResolution RecursiveASTVisitor<NameResolution>
");

///
/// \class LocalScope
/// \brief One executable-scope frame of the N(b) lexical stack: the
///        body locals declared so far in this block/function, in
///        declaration order. Executable scopes have no dc_symbols, so
///        this stack is the ONLY place body locals are findable.
///
///        Lookup walks frames innermost-first (shadowing); within a
///        frame, a local is visible only AFTER its DeclStmt is walked
///        (declare-before-use falls out of push order, no extra check).
///
///        Storage is parallel vecs with a linear scan. Frames are small;
///        do NOT build a hash map until a profile says so.
///
class LocalScope {
    pub var names: vec::<u32>;
    pub var decls: vec::<*Decl>;

    fn LocalScope(self) { }

    fn declare(self, imm: u32, d: *Decl) {
        self.names.push_back(imm);
        self.decls.push_back(d);
    }

    /// Index of \p imm in this frame, latest-first, or usize(-1) on miss.
    /// Latest-first so a same-frame reuse resolves to the newest binding
    /// even in the (diagnosed) redefinition case.
    fn index_of(self, imm: u32) -> usize {
        var n = self.names.size();
        for var i: usize = 0; i < n; ++i {
            var j = (n - 1) - i;
            if self.names[j] == imm { return j; }
        }
        return usize(-1);
    }

    fn find(self, imm: u32) -> *Decl {
        var i = self.index_of(imm);
        if i == usize(-1) { return &null; }
        return self.decls[i];
    }

    fn has(self, imm: u32) -> bool {
        return self.index_of(imm) != usize(-1);
    }
}

///
/// \class NameHit
/// \brief One `_resolve_name` outcome. Deliberately NOT a
///        SemaLookupResult: a local binding has no OverloadCell to point
///        at (locals are excluded from symbol tables) and synthesizing one
///        would mean handing out a pointer to a stack temporary.
///
///        Exactly three states:
///          miss      -> found == false
///          unique    -> found, decl != null, cell == null
///          overloaded-> found, decl == null, cell != null (aliases the
///                       FROZEN cell; never a copy)
///
class NameHit {
    pub var found:       bool          = false;
    pub var decl:        *Decl         = &null;
    pub var cell:        *OverloadCell = &null;
    pub var via_overlay: bool          = false;
    pub var from_local:  bool          = false;

    fn NameHit(self) { }

    static fn miss() -> NameHit {
        return NameHit{};
    }

    static fn local(d: *Decl) -> NameHit {
        var h = NameHit{};
        h.found      = true;
        h.decl       = d;
        h.from_local = true;
        return h;
    }
}

///
/// \class NameBindingVerifier
/// \brief N's exit test, as code.
///
///        THE invariant: no NamedIdentExpr reachable from tu->program is
///        left with BOTH binding slots null unless N poisoned it -- and N
///        only poisons alongside a diagnostic. A violation means a use site
///        silently fell through every path in visit_named_ident_expr, which
///        is exactly the failure mode that is invisible until T or codegen
///        dereferences the null.
///
///        Pattern heads are skipped for the same reason N skips them: they
///        are deliberately unbound, not accidentally unbound.
///
///        Reports through the DIAG SINK, not assert(): the build passes
///        -DNDEBUG even for `kbld --debug`, so an assert here is compiled
///        out and the check silently does nothing. A violation is a bug in
///        N, so it is reported as an error   loudly, where a test will see
///        it   rather than left to surface as a null deref in T or codegen.
///
class NameBindingVerifier derives RecursiveASTVisitor::<NameBindingVerifier> {
    pub var sc: *SemaContext;
    pub var violations: usize = 0;

    fn NameBindingVerifier(self, sc: *SemaContext) {
        self.sc = sc;
    }

    fn run(self) {
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }

    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if n == &null { return true; }
        if n->is_bound() || n->is_deferred() { return true; }
        if n->is_poisoned() { return true; }   // unbound BECAUSE it was diagnosed.

        self.violations += 1;
        var nm = self.sc->ctx->get_spelling(n->name);
        self.sc->diag->report(DiagID::R001E, n->range.start,
            f"internal: '{nm}' survived name resolution unbound and undiagnosed "
            "(NameResolution invariant violation, please report)"
        ).first(n->range).emit();
        return true;
    }

    fn traverse_constructor_pattern(self, n: *ConstructorPattern) -> *ConstructorPattern {
        if n == &null { return n; }
        for var i: usize = 0; i < n->subpatterns.size(); ++i {
            self.dyn()->dispatch_pattern(*(n->subpatterns.get(i)));
        }
        return n;
    }

    fn traverse_unresolved_constructor_pattern(self, n: *UnresolvedConstructorPattern)
            -> *UnresolvedConstructorPattern {
        if n == &null { return n; }
        for var i: usize = 0; i < n->subpatterns.size(); ++i {
            self.dyn()->dispatch_pattern(*(n->subpatterns.get(i)));
        }
        return n;
    }
}

///
/// \class NameResolution
/// \brief The N pass. One instance per TU per run; stateless across
///        runs (LSP rebuilds, batch runs once).
///
///        State is exactly two cursors:
///          cur_dc -- the innermost TABLE-OWNING scope (type/module/TU
///                    level). Moved by traverse_* overrides on
///                    scope-owning decls. Feeds sc->lookup.unqualified.
///          locals -- the lexical stack of executable scopes. Pushed/
///                    popped by traverse_compound_stmt /
///                    traverse_function_decl / traverse_closure_expr.
///                    Checked BEFORE unqualified (NameLookup contract).
///
class NameResolution derives RecursiveASTVisitor::<NameResolution> {
    pub var sc: *SemaContext;

    var cur_dc: *DeclContext = &null;     ///< table-owning scope cursor.
    var locals: vec::<LocalScope>;        ///< executable-scope stack.

    /// `self` lexes as KwSelf, not LitIdentifier, so ASTContext::
    /// get_ident_imm rejects it. We intern the spelling once and key both
    /// the `self` ParamDecl and every `self` use off that imm. No collision
    /// is possible: `self` is a keyword, so no user identifier shares it.
    priv var _self_imm: u32 = u32(-1);

    /// A function body's params live in the frame pushed by
    /// traverse_function_decl / traverse_closure_expr; the body's own
    /// CompoundStmt must NOT push a second frame or a local would silently
    /// shadow a param instead of colliding with it.
    priv var _suppress_next_block_frame: bool = false;

    fn NameResolution(self, sc: *SemaContext) {
        self.sc = sc;
    }

    /// Entry point. Preconditions are ASSERTED, not hoped for: if one
    /// fires, N is being called wrong and the bug is in the driver
    /// schedule (Sema.k), never here.
    /// Postcondition (advanced by the DRIVER, not here): NamesResolved.
    fn run(self) {
        self.sc->require_phase(SemaPhase::Verified);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        self._assert_entry(tu);

        self._self_imm = self.sc->imm_table()->intern_ident_copy("self");

        self._validate_decls(tu);          // N(a)
        self._bind(tu);                    // N(b)

        // Exit test: no NamedIdentExpr reachable from the program is left
        // with both binding slots null unless N poisoned it (which it only
        // does alongside a diagnostic). Cheap single walk, no allocation.
        var v = NameBindingVerifier(self.sc);
        v.run();
    }

    // === Entry assertions =================================================

    /// The six things that must be true before N may run. Each one is a
    /// driver-schedule contract, so a failure is an ICE, not a diagnostic.
    priv fn _assert_entry(self, tu: *TranslationUnit) {
        // 1. phase: already checked by require_phase(Verified) above.

        // 2. the overlay exists and is frozen (phase I ran to completion).
        assert((tu->import_overlay != &null)
               && r"NameResolution: tu->import_overlay is null (phase I did not run)");
        assert(tu->import_overlay->is_frozen()
               && r"NameResolution: tu->import_overlay is not frozen (phase I did not finish)");

        // 4. the shared lookup core is wired to THIS TU. A stale NameLookup
        //    would silently answer with another TU's overlay.
        assert((self.sc->lookup.tu == tu)
               && r"NameResolution: sc->lookup is not initialized with this TU");

        // 5. there is a program to walk.
        assert((tu->program != &null)
               && r"NameResolution: tu->program is null");

        // 3. every reachable dc_symbols table is frozen. N writes decl-to-decl
        //    links only; a live table here means the parser never froze.
        self._assert_frozen(static_cast::<*DeclContext>(tu));

        // 6. out_of_line holds exactly what the parser promised: non-null
        //    FunctionDecls carrying a `Class::` qualifier.
        for var i: usize = 0; i < tu->out_of_line.size(); ++i {
            var d = *(tu->out_of_line.get(i));
            assert((d != &null)
                   && r"NameResolution: null entry in tu->out_of_line");
            var f = dyn_cast::<FunctionDecl>(d);
            assert((f != &null)
                   && r"NameResolution: non-FunctionDecl in tu->out_of_line");
            assert(f->is_out_of_line()
                   && r"NameResolution: out_of_line entry has no Class:: qualifier");
        }
    }

    priv fn _assert_frozen(self, dc: *DeclContext) {
        if dc == &null { return; }
        if dc->dc_symbols != &null {
            assert(dc->dc_symbols->is_frozen()
                   && r"NameResolution: a dc_symbols table is not frozen (parse did not finish)");
        }
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            self._assert_frozen(NameLookup::context_of(*(dc->dc_decls.get(i))));
        }
    }

    // === N(a): decl validation ============================================
    //
    // No RAV needed -- this half never enters expressions. Walk dc_decls
    // per DeclContext, recursing through NameLookup::context_of for
    // nested type scopes (same shape as ConstraintExtraction's
    // _recurse_members).

    priv fn _validate_decls(self, tu: *TranslationUnit) {
        self._validate_context(static_cast::<*DeclContext>(tu));
        self._attach_out_of_line(tu);
        self._resolve_well_known(tu);
    }

    /// Validate one scope's frozen table, then recurse into every child
    /// scope. Pass-through containers (visibility groups, eval blocks, ffi
    /// blocks) are transparent: their members were keyed into THIS table by
    /// the parser, so their nested types are reached from here too.
    priv fn _validate_context(self, dc: *DeclContext) {
        if dc == &null { return; }

        if dc->dc_symbols != &null {
            var rows = vec::<SymbolTable::Entry>();
            dc->dc_symbols->collect_entries(rows);
            for var i: usize = 0; i < rows.size(); ++i {
                self._validate_cell(dc, rows[i]);
            }
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            self._descend(*(dc->dc_decls.get(i)));
        }
    }

    /// Recurse into a child decl's own scope, seeing through the
    /// table-less wrapper decls the parser also parks in dc_decls.
    priv fn _descend(self, d: *Decl) {
        if d == &null { return; }

        if isa::<VisibilityGroupDecl>(d) {
            var g = cast::<VisibilityGroupDecl>(d);
            for var i: usize = 0; i < g->members.count; ++i {
                self._descend(g->members[i]);
            }
            return;
        }
        if isa::<EvalBlockDecl>(d) {
            var b = cast::<EvalBlockDecl>(d);
            for var i: usize = 0; i < b->body.count; ++i {
                self._descend(b->body[i]);
            }
            return;
        }
        if isa::<FFIBlockDecl>(d) {
            var b = cast::<FFIBlockDecl>(d);
            for var i: usize = 0; i < b->body.count; ++i {
                self._descend(b->body[i]);
            }
            return;
        }

        self._validate_context(NameLookup::context_of(d));
    }

    /// One cell = one name in one scope. Size 1 is the overwhelming case
    /// and needs nothing. Size > 1 is one of exactly three things:
    ///
    ///   all FunctionDecl  -> an overload set. Legal, untouched: telling a
    ///                        redeclaration from an overload needs
    ///                        signatures, so function chains are deferred.
    ///   all one non-fn
    ///   redeclarable kind -> a redecl group. Link it, pick the canonical,
    ///                        error once if two links define.
    ///   anything else     -> redefinition. Sole home: HERE.
    ///
    priv fn _validate_cell(self, dc: *DeclContext, e: SymbolTable::Entry) {
        if e.cell == &null { return; }
        var n = e.cell->size();
        if n <= 1 { return; }

        var group = vec::<*Decl>();
        var all_fn = true;
        var kind_ok = true;
        var k0 = DeclKind::DeclKindCount;

        for var i: usize = 0; i < n; ++i {
            var d = e.cell->get(i);
            if d == &null { continue; }
            group.push_back(d);
            if !isa::<FunctionDecl>(d) { all_fn = false; }
            if k0 == DeclKind::DeclKindCount { k0 = d->kind; }
            else if d->kind != k0 { kind_ok = false; }
        }

        if group.size() <= 1 { return; }
        if all_fn { return; }               // overload set; nothing to judge yet.

        if !kind_ok {
            self._redefinition(e, &group, "declared with conflicting kinds");
            return;
        }

        // Same kind, non-function. Only the redeclarable kinds may legally
        // repeat; everything else (var, field, type alias, enum variant) is
        // a plain redefinition.
        switch k0 {
            case DeclKind::ClassDecl     { self._link_group::<ClassDecl>(e, &group);     }
            case DeclKind::StructDecl    { self._link_group::<StructDecl>(e, &group);    }
            case DeclKind::UnionDecl     { self._link_group::<UnionDecl>(e, &group);     }
            case DeclKind::InterfaceDecl { self._link_group::<InterfaceDecl>(e, &group); }
            case DeclKind::EnumDecl      { self._link_group::<EnumDecl>(e, &group);      }
            case DeclKind::ModuleDecl    { self._link_group::<ModuleDecl>(e, &group);    }
            default {
                self._redefinition(e, &group, "redefined");
            }
        }
    }

    /// Link a same-kind redecl group in SOURCE ORDER (cells are append-only,
    /// so cell order is source order), then point every link's canonical at
    /// the definition if there is one, else at the first decl.
    ///
    /// Idempotent by construction: linking is skipped when the two links
    /// already share a chain, and retarget_canonical recomputes the same
    /// target on a second run (LSP contract, exit criterion 7).
    priv fn <T> _link_group(self, e: SymbolTable::Entry, group: *vec::<*Decl>) {
        var first = cast::<T>((*group)[0]);
        if first == &null { return; }

        for var i: usize = 1; i < group->size(); ++i {
            var cur = cast::<T>((*group)[i]);
            if cur == &null { continue; }
            if cur->canonical_decl() != first->canonical_decl() {
                cur->set_prev(first);
            }
        }

        // At most one link may define. The parser's mark_definition guards
        // the single-decl case; only sema sees the whole chain, so the
        // two-definitions diagnostic is ours.
        var defs = vec::<*Decl>();
        for var i: usize = 0; i < group->size(); ++i {
            var cur = cast::<T>((*group)[i]);
            if cur == &null { continue; }
            if cur->is_this_definition { defs.push_back((*group)[i]); }
        }

        if defs.size() > 1 {
            var name = e.name.describe(self.sc->ctx);
            self.sc->diag->report(DiagID::R001E, defs[1]->range.start,
                f"redefinition of '{name}\x27"
            ).first(defs[1]->range).emit();
            self.sc->diag->report(DiagID::R001N, defs[0]->range.start,
                f"previous definition of '{name}' is here"
            ).first(defs[0]->range).emit();
            for var i: usize = 1; i < defs.size(); ++i { defs[i]->poison(); }
        }

        // canonical = the definition if the chain has one, else the first
        // decl (which retarget_canonical leaves as-is via first_decl).
        var def = first->definition();
        if def != &null {
            first->retarget_canonical(def);
        } else {
            first->retarget_canonical(first->first_decl());
        }
    }

    /// The sole home of the redefinition diagnostic. One error at the
    /// second decl, one note at the first, every loser poisoned so uses
    /// degrade instead of cascading.
    priv fn _redefinition(self, e: SymbolTable::Entry, group: *vec::<*Decl>, what: string) {
        var name = e.name.describe(self.sc->ctx);
        var prev = (*group)[0];
        for var i: usize = 1; i < group->size(); ++i {
            var d = (*group)[i];
            self.sc->diag->report(DiagID::R001E, d->range.start,
                f"'{name}' {what}"
            ).first(d->range).emit();
            self.sc->diag->report(DiagID::R001N, prev->range.start,
                f"previous declaration of '{name}' is here"
            ).first(prev->range).emit();
            d->poison();
        }
    }

    // --- out-of-line attachment -------------------------------------------

    /// `fn Class::method` never entered a table (the parser cannot resolve
    /// the qualifier); N attaches each one to the scope it belongs to by
    /// walking the qualifier path with the shared lookup primitives.
    ///
    /// Attachment here means: semantic_dc := the owning type's context, so
    /// N(b) resolves the body against the class and later passes know the
    /// lookup home. Linking the def into the in-class decl's redecl chain
    /// needs signature comparison to pick among overloads and is therefore
    /// part of the deferred FUNCTION-chain work, not this.
    priv fn _attach_out_of_line(self, tu: *TranslationUnit) {
        for var i: usize = 0; i < tu->out_of_line.size(); ++i {
            var d = *(tu->out_of_line.get(i));
            var f = dyn_cast::<FunctionDecl>(d);
            if f == &null { continue; }

            var home = self._resolve_qualifier(f);
            if home == &null {
                f->poison();
                continue;                    // diagnosed inside _resolve_qualifier
            }

            // The member must already be declared in the type. Missing =
            // an out-of-line definition of something the type never
            // declared, which is an error here and nowhere else.
            var key = self._member_key(f, home);
            if home->lookup_symbol(key) == &null {
                var nm = self.sc->ctx->get_spelling(f->name);
                self.sc->diag->report(DiagID::R001E, f->range.start,
                    f"out-of-line definition of '{nm}' does not match any declaration in its scope"
                ).first(f->range).emit();
                f->poison();
                continue;
            }

            f->semantic_dc = reinterpret_cast::<*void>(home);
        }
    }

    /// The DeclName an out-of-line def would have been keyed under inside
    /// \p home: ctor when the name matches the owning type, operator when
    /// `fn op`, plain identifier otherwise. Mirrors ASTParse::
    /// _index_symbol_decl so the probe and the table agree.
    priv fn _member_key(self, f: *FunctionDecl, home: *DeclContext) -> DeclName {
        if f->is_operator {
            var k0 = TokenKind::TkUnknown;
            var k1 = TokenKind::TkUnknown;
            if f->op_token.count > 0 { k0 = f->op_token[0].kind; }
            if f->op_token.count > 1 { k1 = f->op_token[1].kind; }
            return DeclName::op_name(k0, k1);
        }

        var im = self.sc->ctx->get_ident_imm(f->name);
        if (im != u32(-1)) && home->is_type_scope() {
            var owner = home->owner_decl();
            if (owner != &null) && (self._decl_name_imm(owner) == im) {
                return DeclName::ctor();
            }
        }
        return DeclName::ident(im);
    }

    /// Walk `Class::` / `Outer::Inner::` and return the context the
    /// definition belongs to, or null (diagnosed) if any segment misses.
    /// Uses the shared primitives only: unqualified for the head, then
    /// qualified_step per segment.
    priv fn _resolve_qualifier(self, f: *FunctionDecl) -> *DeclContext {
        var q = f->qualifier;
        if q == &null { return &null; }

        var head: *NamedIdentExpr = &null;
        var chain = dyn_cast::<ChainExpr>(q);
        if chain != &null {
            head = dyn_cast::<NamedIdentExpr>(chain->base);
        } else {
            head = dyn_cast::<NamedIdentExpr>(q);
        }
        if head == &null { return &null; }

        var im = self._name_imm(head->name);
        if im == u32(-1) { return &null; }

        var r = self.sc->lookup.unqualified(
                    static_cast::<*DeclContext>(self.sc->tu), DeclName::ident(im));
        if !r.found() {
            var nm = self.sc->ctx->get_spelling(head->name);
            self.sc->diag->report(DiagID::R001E, head->range.start,
                f"use of undeclared identifier '{nm}' in out-of-line definition"
            ).first(head->range).emit();
            head->poison();     // marks it diagnosed; N(b) will not re-report it.
            return &null;
        }
        // A cell answers with its FIRST link, which for `class Foo; class
        // Foo { ... }` is the forward declaration -- a scope with no members
        // in it. Members live on the DEFINITION, so every segment steps
        // through the chain's canonical, which _validate_decls (running
        // before this) already retargeted at the definition.
        var cur = self._representative(r.first());
        head->resolved_decl = cur;

        if chain != &null {
            for var i: usize = 0; i < chain->steps.size(); ++i {
                var st = chain->steps.get(i);
                if st->name == &null { return &null; }
                var sim = self._name_imm(st->name->name);
                if sim == u32(-1) { return &null; }
                var sr = self.sc->lookup.qualified_step(cur, DeclName::ident(sim));
                if !sr.found() {
                    var snm = self.sc->ctx->get_spelling(st->name->name);
                    self.sc->diag->report(DiagID::R001E, st->name->range.start,
                        f"no member named '{snm}' in the qualified scope of this out-of-line definition"
                    ).first(st->name->range).emit();
                    st->name->poison();
                    return &null;
                }
                cur = self._representative(sr.first());
                st->name->resolved_decl = cur;
            }
        }

        return NameLookup::context_of(cur);
    }

    // --- lang items --------------------------------------------------------

    /// Resolve the WellKnownType names once, by ordinary unqualified lookup
    /// (they are ordinary library decls arriving through ordinary imports;
    /// their names are NEVER special-cased in lookup).
    ///
    /// A miss is NOT diagnosed here. Per SemaContext.k the absence of a lang
    /// item is only an error at USE ("async used but Future unresolvable"),
    /// and that diagnosis belongs to the lowering pass that needs it. Erroring
    /// per TU would fire on every file that never mentions async.
    priv fn _resolve_well_known(self, tu: *TranslationUnit) {
        var root = static_cast::<*DeclContext>(tu);
        self._bind_well_known(root, WellKnownType::Future,   "Future");
        self._bind_well_known(root, WellKnownType::Range,    "Range");
        self._bind_well_known(root, WellKnownType::Yield,    "Yield");
        self._bind_well_known(root, WellKnownType::Ordering, "Ordering");
        self._bind_well_known(root, WellKnownType::Null,     "Null");
        self._bind_well_known(root, WellKnownType::Panic,    "Panic");

        self._bind_well_known(root, WellKnownType::String,   "string");
        self._bind_well_known(root, WellKnownType::Vector,   "vector");
        self._bind_well_known(root, WellKnownType::Slice,    "slice");
        self._bind_well_known(root, WellKnownType::Array,    "array");
        self._bind_well_known(root, WellKnownType::HashMap,  "map");
        self._bind_well_known(root, WellKnownType::HashSet,  "set");

        self._bind_well_known(root, WellKnownType::BigInt,   "int");
        self._bind_well_known(root, WellKnownType::BigFloat, "float");

        self._bind_well_known(root, WellKnownType::I8,   "i8");
        self._bind_well_known(root, WellKnownType::I16,  "i16");
        self._bind_well_known(root, WellKnownType::I32,  "i32");
        self._bind_well_known(root, WellKnownType::I64,  "i64");
        self._bind_well_known(root, WellKnownType::I128, "i128");
        self._bind_well_known(root, WellKnownType::I256, "i256");
        self._bind_well_known(root, WellKnownType::I512, "i512");
        
        self._bind_well_known(root, WellKnownType::U8,   "u8");
        self._bind_well_known(root, WellKnownType::U16,  "u16");
        self._bind_well_known(root, WellKnownType::U32,  "u32");
        self._bind_well_known(root, WellKnownType::U64,  "u64");
        self._bind_well_known(root, WellKnownType::U128, "u128");
        self._bind_well_known(root, WellKnownType::U256, "u256");
        self._bind_well_known(root, WellKnownType::U512, "u512");
        
        self._bind_well_known(root, WellKnownType::F8,   "f8");
        self._bind_well_known(root, WellKnownType::F16,  "f16");
        self._bind_well_known(root, WellKnownType::F32,  "f32");
        self._bind_well_known(root, WellKnownType::F64,  "f64");
        self._bind_well_known(root, WellKnownType::F128, "f128");
        self._bind_well_known(root, WellKnownType::F256, "f256");
    }

    priv fn _bind_well_known(self, root: *DeclContext, k: WellKnownType, spelling: string) {
        var im = self.sc->imm_table()->find_ident(spelling);
        if im == u32(-1) { return; }        // never interned in this TU: absent.
        var r = self.sc->lookup.unqualified(root, DeclName::ident(im));
        if !r.found() { return; }
        self.sc->well_known.set(k, r.first());
    }

    // === N(b): binding ====================================================

    priv fn _bind(self, tu: *TranslationUnit) {
        self.cur_dc = static_cast::<*DeclContext>(tu);

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

    /// THE core lookup policy, in binding order:
    ///   1. locals, innermost frame first   (body locals shadow everything)
    ///   2. sc->lookup.unqualified(cur_dc)  (DC chain -> import overlay)
    ///   3. miss                            (unresolved-ident diagnostic)
    priv fn _resolve_name(self, imm: u32) -> NameHit {
        if imm == u32(-1) { return NameHit::miss(); }

        var n = self.locals.size();
        for var i: usize = 0; i < n; ++i {
            var frame = &(self.locals[(n - 1) - i]);
            var idx = frame->index_of(imm);
            if idx != usize(-1) {
                return NameHit::local(frame->decls[idx]);
            }
        }

        var r = self.sc->lookup.unqualified(self.cur_dc, DeclName::ident(imm));
        if !r.found() { return NameHit::miss(); }

        var h = NameHit{};
        h.found       = true;
        h.via_overlay = r.via_overlay;

        if r.single() {
            h.decl = self._representative(r.first());
            return h;
        }

        // A multi-decl cell is not automatically an overload set: a redecl
        // chain fills one slot per link, so `class Foo; class Foo {}` looks
        // like two candidates while naming ONE entity. Collapse those to the
        // canonical rather than handing T a set with nothing to choose
        // between. A genuine overload set still goes through whole (hard
        // invariant #3: N never filters candidates).
        var sole = self._sole_entity(r.cell);
        if sole != &null { h.decl = sole; } else { h.cell = r.cell; }
        return h;
    }

    /// The canonical link of \p d's redecl chain, or null when \p d carries
    /// no chain N has judged. FunctionDecl is deliberately absent: its chains
    /// need signatures to link and are deferred, so its canonical is still
    /// itself and collapsing on it would be a lie.
    priv fn _chain_canonical(self, d: *Decl) -> *Decl {
        if d == &null { return &null; }
        if isa::<ClassDecl>(d)     { return static_cast::<*Decl>(cast::<ClassDecl>(d)->canonical_decl());     }
        if isa::<StructDecl>(d)    { return static_cast::<*Decl>(cast::<StructDecl>(d)->canonical_decl());    }
        if isa::<UnionDecl>(d)     { return static_cast::<*Decl>(cast::<UnionDecl>(d)->canonical_decl());     }
        if isa::<InterfaceDecl>(d) { return static_cast::<*Decl>(cast::<InterfaceDecl>(d)->canonical_decl()); }
        if isa::<EnumDecl>(d)      { return static_cast::<*Decl>(cast::<EnumDecl>(d)->canonical_decl());      }
        if isa::<ModuleDecl>(d)    { return static_cast::<*Decl>(cast::<ModuleDecl>(d)->canonical_decl());    }
        return &null;
    }

    /// The decl that REPRESENTS the entity \p d belongs to: the chain's
    /// canonical (the definition, once N(a) has retargeted it) when there is
    /// a chain, else \p d unchanged.
    priv fn _representative(self, d: *Decl) -> *Decl {
        var c = self._chain_canonical(d);
        if c == &null { return d; }
        return c;
    }

    /// The one entity a multi-decl cell denotes, or null when it holds a
    /// genuine overload set or a diagnosed conflict. Every entry must be a
    /// chain link, and every entry must agree on the canonical.
    priv fn _sole_entity(self, cell: *OverloadCell) -> *Decl {
        if cell == &null { return &null; }
        var rep: *Decl = &null;
        for var i: usize = 0; i < cell->size(); ++i {
            var c = self._chain_canonical(cell->get(i));
            if c == &null { return &null; }      // no chain: a real overload set.
            if rep == &null { rep = c; continue; }
            if rep != c { return &null; }        // distinct entities sharing a name.
        }
        return rep;
    }

    // --- scope cursor management ------------------------------------------
    //
    // Pattern for every override: save cursor / push frame -> call the
    // BASE traverse (recurses children) -> restore on EVERY exit path.
    // The RAV rebinding contract still holds: return what base returned.

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        if n == &null { return n; }

        var saved_dc = self.cur_dc;
        var saved_suppress = self._suppress_next_block_frame;

        // An out-of-line def resolves against the type it was written FOR,
        // not the scope it was written IN. N(a) recorded that as semantic_dc.
        if (n->semantic_dc != &null) && (n->semantic_dc != n->lexical_dc) {
            self.cur_dc = reinterpret_cast::<*DeclContext>(n->semantic_dc);
        } else {
            self.cur_dc = static_cast::<*DeclContext>(n);
        }

        // Params (and `self`) live in the function frame; the body's own
        // CompoundStmt joins that frame rather than nesting inside it, so a
        // top-level local colliding with a param is a redefinition, not
        // silent shadowing.
        self.locals.push_back(LocalScope{});
        for var i: usize = 0; i < n->generic_params.size(); ++i {
            var gp = n->generic_params[i];
            if gp == &null { continue; }
            self._declare_local(self._name_imm(gp->name), static_cast::<*Decl>(gp), gp->range);
        }
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if p == &null { continue; }
            self._declare_local(self._name_imm(p->name), static_cast::<*Decl>(p), p->range);
        }

        self._suppress_next_block_frame = true;
        var out = RecursiveASTVisitor_NameResolution::traverse_function_decl(n);

        self.locals.pop_back();
        self.cur_dc = saved_dc;
        self._suppress_next_block_frame = saved_suppress;
        return out;
    }

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        if n == &null { return n; }

        var saved_suppress = self._suppress_next_block_frame;

        self.locals.push_back(LocalScope{});
        for var i: usize = 0; i < n->generic_params.size(); ++i {
            var gp = n->generic_params[i];
            if gp == &null { continue; }
            self._declare_local(self._name_imm(gp->name), static_cast::<*Decl>(gp), gp->range);
        }
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if p == &null { continue; }
            self._declare_local(self._name_imm(p->name), static_cast::<*Decl>(p), p->range);
        }

        self._suppress_next_block_frame = true;
        var out = RecursiveASTVisitor_NameResolution::traverse_closure_expr(n);

        self.locals.pop_back();
        self._suppress_next_block_frame = saved_suppress;
        return out;
    }

    /// Every brace-delimited scope. Overriding traverse_compound_stmt (not
    /// traverse_block) is deliberate: dispatch_stmt routes a nested bare
    /// block straight here, so a traverse_block-only override would miss it.
    fn traverse_compound_stmt(self, n: *CompoundStmt) -> *CompoundStmt {
        if n == &null { return n; }

        var push = !self._suppress_next_block_frame;
        self._suppress_next_block_frame = false;

        if push { self.locals.push_back(LocalScope{}); }
        var out = RecursiveASTVisitor_NameResolution::traverse_compound_stmt(n);
        if push { self.locals.pop_back(); }

        return out;
    }

    // Type / module scopes: save-restore cur_dc into the decl's own DC. No
    // locals frame -- type scopes have tables, not lexical locals.

    fn traverse_class_decl(self, n: *ClassDecl) -> *ClassDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        var out = RecursiveASTVisitor_NameResolution::traverse_class_decl(n);
        self.cur_dc = saved;
        return out;
    }

    fn traverse_struct_decl(self, n: *StructDecl) -> *StructDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        var out = RecursiveASTVisitor_NameResolution::traverse_struct_decl(n);
        self.cur_dc = saved;
        return out;
    }

    fn traverse_union_decl(self, n: *UnionDecl) -> *UnionDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        var out = RecursiveASTVisitor_NameResolution::traverse_union_decl(n);
        self.cur_dc = saved;
        return out;
    }

    fn traverse_enum_decl(self, n: *EnumDecl) -> *EnumDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        var out = RecursiveASTVisitor_NameResolution::traverse_enum_decl(n);
        self.cur_dc = saved;
        return out;
    }

    fn traverse_interface_decl(self, n: *InterfaceDecl) -> *InterfaceDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        var out = RecursiveASTVisitor_NameResolution::traverse_interface_decl(n);
        self.cur_dc = saved;
        return out;
    }

    fn traverse_extension_decl(self, n: *ExtensionDecl) -> *ExtensionDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        self.cur_dc = static_cast::<*DeclContext>(n);
        var out = RecursiveASTVisitor_NameResolution::traverse_extension_decl(n);
        self.cur_dc = saved;
        return out;
    }

    fn traverse_module_decl(self, n: *ModuleDecl) -> *ModuleDecl {
        if n == &null { return n; }
        var saved = self.cur_dc;
        // An anonymous module owns no table; its decls were keyed into the
        // enclosing scope, so the cursor must NOT move into it.
        if !n->is_anonymous { self.cur_dc = static_cast::<*DeclContext>(n); }
        var out = RecursiveASTVisitor_NameResolution::traverse_module_decl(n);
        self.cur_dc = saved;
        return out;
    }

    // --- local declaration -------------------------------------------------

    /// A body-local `var`/`const`. The initializer is walked FIRST (by the
    /// base traverse) so `var x = x;` binds the OUTER x, and only then does
    /// the name enter the frame.
    fn traverse_variable_decl(self, n: *VariableDecl) -> *VariableDecl {
        if n == &null { return n; }

        var out = RecursiveASTVisitor_NameResolution::traverse_variable_decl(n);

        // Only body locals go on the stack. A file/type-scope `var` was
        // keyed into a real SymbolTable at parse time and is found by the
        // unqualified walk instead; declaring it here too would make it
        // visible before its own line.
        if !self.locals.empty() {
            self._declare_local(self._name_imm(n->name), static_cast::<*Decl>(n), n->range);
        }
        return out;
    }

    /// Push \p d into the innermost frame under \p imm. A same-frame
    /// duplicate is a redefinition; this is the sole home of that
    /// diagnostic for body locals (N(a) owns the decl-table half).
    ///
    /// Statement-level binders (`for x in xs`, `catch e`, `var (a, b) = t`,
    /// context bindings) and `case var n` patterns route here too, through
    /// the `decl` slot the parser now synthesizes on Binding / CatchArm /
    /// BindingPattern. A BARE `case n` does NOT: that head is an
    /// UnresolvedConstructorPattern and is genuinely ambiguous between a
    /// nullary constructor and a binder until the scrutinee type is known,
    /// so it stays deferred to T.
    priv fn _declare_local(self, imm: u32, d: *Decl, at: SourceRange) {
        if imm == u32(-1) { return; }
        if self.locals.empty() { return; }

        var frame = &(self.locals[self.locals.size() - 1]);
        var prev_i = frame->index_of(imm);
        if prev_i != usize(-1) {
            var prev = frame->decls[prev_i];
            var nm = self.sc->imm_table()->get_ident(imm);
            self.sc->diag->report(DiagID::R001E, at.start,
                f"redefinition of '{nm}\x27"
            ).first(at).emit();
            if prev != &null {
                self.sc->diag->report(DiagID::R001N, prev->range.start,
                    f"previous declaration of '{nm}' is here"
                ).first(prev->range).emit();
            }
            if d != &null { d->poison(); }
        }

        frame->declare(imm, d);
    }

    // --- statement-level binders -------------------------------------------
    //
    // Each of these introduces names into a scope the RAV does not model: the
    // binder list is walked as leaf data (the RAV explicitly skips `Binding`
    // name nodes), so N pushes its own frame, declares the binders, then lets
    // the base traverse walk the body inside that frame.
    //
    // Order matters and matches the language: the VALUE/ITERABLE expression is
    // resolved in the OUTER scope, before the binders exist. `for x in x` and
    // `var (a, b) = a` therefore refer to an outer `x` / `a`, exactly like
    // `var x = x` does.

    fn traverse_ranged_for_stmt(self, n: *RangedForStmt) -> *RangedForStmt {
        if n == &null { return n; }
        if self.dyn()->walkup_ranged_for_stmt(n) == false { return n; }

        if n->iterable != &null { n->iterable = self.dyn()->dispatch_expr(n->iterable); }

        self.locals.push_back(LocalScope{});
        self._declare_bindings(&(n->bindings));
        self._suppress_next_block_frame = true;
        n->body = self.dyn()->traverse_block(n->body);
        self.locals.pop_back();
        return n;
    }

    fn traverse_context_binding_stmt(self, n: *ContextBindingStmt) -> *ContextBindingStmt {
        if n == &null { return n; }
        if self.dyn()->walkup_context_binding_stmt(n) == false { return n; }

        if n->value != &null { n->value = self.dyn()->dispatch_expr(n->value); }

        self.locals.push_back(LocalScope{});
        self._declare_bindings(&(n->bindings));
        self._suppress_next_block_frame = true;
        n->body = self.dyn()->traverse_block(n->body);
        self.locals.pop_back();
        return n;
    }

    /// Destructuring declares into the ENCLOSING frame (it is a decl
    /// statement, not a scope), so there is no frame push here.
    fn traverse_destructuring_decl_stmt(self, n: *DestructuringDeclStmt)
            -> *DestructuringDeclStmt {
        if n == &null { return n; }
        if self.dyn()->walkup_destructuring_decl_stmt(n) == false { return n; }

        if n->value != &null { n->value = self.dyn()->dispatch_expr(n->value); }
        self._declare_bindings(&(n->bindings));
        return n;
    }

    fn traverse_try_catch_stmt(self, n: *TryCatchStmt) -> *TryCatchStmt {
        if n == &null { return n; }
        if self.dyn()->walkup_try_catch_stmt(n) == false { return n; }

        n->try_body = self.dyn()->traverse_block(n->try_body);
        for var i: usize = 0; i < n->arms.size(); ++i {
            if self.stop { break; }
            var arm = n->arms.get(i);
            if arm->filter != &null { self.dyn()->dispatch_type(arm->filter); }
            self.locals.push_back(LocalScope{});
            self._declare_binder_decl(arm->decl);
            self._suppress_next_block_frame = true;
            if arm->body != &null { self.dyn()->dispatch_stmt(arm->body); }
            self.locals.pop_back();
        }
        return n;
    }

    fn traverse_try_catch_expr(self, n: *TryCatchExpr) -> *TryCatchExpr {
        if n == &null { return n; }
        if self.dyn()->walkup_try_catch_expr(n) == false { return n; }

        if n->try_expr != &null { n->try_expr = self.dyn()->dispatch_expr(n->try_expr); }
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            if self.stop { break; }
            var arm = n->catch_arms.get(i);
            if arm->filter != &null { self.dyn()->dispatch_type(arm->filter); }
            self.locals.push_back(LocalScope{});
            self._declare_binder_decl(arm->decl);
            if arm->body != &null { self.dyn()->dispatch_expr(arm->body); }
            self.locals.pop_back();
        }
        return n;
    }

    /// One match arm: patterns bind, then the guard and body see those
    /// bindings. The arm is its own scope, so the frame wraps all three.
    fn traverse_match_case(self, mc: *MatchCase) {
        if mc == &null { return; }

        self.locals.push_back(LocalScope{});
        for var i: usize = 0; i < mc->patterns.size(); ++i {
            if self.stop { break; }
            var pat = *(mc->patterns.get(i));
            self._declare_pattern_binders(pat);
            self.dyn()->dispatch_pattern(pat);
        }
        if !self.stop {
            if mc->guard != &null { self.dyn()->dispatch_expr(mc->guard); }
            if mc->body  != &null {
                self._suppress_next_block_frame = true;
                self.dyn()->dispatch_stmt(mc->body);
            }
            if mc->expression != &null { self.dyn()->dispatch_expr(mc->expression); }
        }
        self.locals.pop_back();
    }

    priv fn _declare_bindings(self, list: *FrozenList::<Binding>) {
        for var i: usize = 0; i < list->size(); ++i {
            var b = (*list)[i];
            if b.is_discard { continue; }   // `_` binds nothing.
            self._declare_binder_decl(b.decl);
        }
    }

    priv fn _declare_binder_decl(self, d: *Decl) {
        if d == &null { return; }
        var vd = dyn_cast::<VariableDecl>(d);
        if vd == &null { return; }
        self._declare_local(self._name_imm(vd->name), d, d->range);
    }

    /// Walk a pattern tree declaring every explicit `var`/`const` binder.
    /// ConstructorPattern / UnresolvedConstructorPattern HEADS are skipped
    /// (see traverse_unresolved_constructor_pattern); only their subpatterns
    /// can contain binders.
    priv fn _declare_pattern_binders(self, p: *Pattern) {
        if p == &null { return; }
        switch p->kind {
            case PatternKind::BindingPattern {
                self._declare_binder_decl(cast::<BindingPattern>(p)->decl);
            } case PatternKind::TupleDestructurePattern {
                var n = cast::<TupleDestructurePattern>(p);
                for var i: usize = 0; i < n->elements.size(); ++i {
                    self._declare_pattern_binders(*(n->elements.get(i)));
                }
            } case PatternKind::ConstructorPattern {
                var n = cast::<ConstructorPattern>(p);
                for var i: usize = 0; i < n->subpatterns.size(); ++i {
                    self._declare_pattern_binders(*(n->subpatterns.get(i)));
                }
            } case PatternKind::UnresolvedConstructorPattern {
                var n = cast::<UnresolvedConstructorPattern>(p);
                for var i: usize = 0; i < n->subpatterns.size(); ++i {
                    self._declare_pattern_binders(*(n->subpatterns.get(i)));
                }
            } case PatternKind::SlicePattern {
                var n = cast::<SlicePattern>(p);
                for var i: usize = 0; i < n->prefix.size(); ++i {
                    self._declare_pattern_binders(*(n->prefix.get(i)));
                }
                for var i: usize = 0; i < n->suffix.size(); ++i {
                    self._declare_pattern_binders(*(n->suffix.get(i)));
                }
                self._declare_pattern_binders(n->rest_binding);
            } case PatternKind::AlternationPattern {
                // Every alternative binds the same set (PatternBindingCheck
                // already enforced that), so the first stands for the whole.
                var n = cast::<AlternationPattern>(p);
                if n->alternatives.size() > 0 {
                    self._declare_pattern_binders(*(n->alternatives.get(0)));
                }
            } default { 0; }
        }
    }

    // --- annotations -------------------------------------------------------

    /// Attribute names (`@my_macro`) are name uses too, but the RAV does not
    /// walk annotations at all (they hang off the Annotation mixin, not the
    /// child lists), so N reaches them from the decl family hook instead.
    ///
    /// A MISS IS NOT AN ERROR here, unlike every other name use: the vast
    /// majority of attributes are compiler builtins (`@inline`, `@packed`)
    /// with no declaration to find. N records the binding when one exists so
    /// jump-to-def works on user-defined attribute macros, and stays silent
    /// otherwise. Deciding which attribute names are legal is the attribute
    /// checker's job, not name resolution's.
    fn visit_decl(self, n: *Decl) -> bool {
        if n == &null { return true; }
        for var i: usize = 0; i < n->annotations.size(); ++i {
            var e = n->annotations.get(i);
            if e == &null { continue; }
            if e->kind != AnnotationKind::Attribute { continue; }
            if e->name == u32(-1) { continue; }
            if e->resolved_decl != &null { continue; }   // idempotent re-run.

            var h = self._resolve_name(e->name);
            if h.found && (h.decl != &null) {
                e->resolved_decl = reinterpret_cast::<*void>(h.decl);
            }
        }
        return true;
    }

    // --- binding hooks ----------------------------------------------------

    /// The heart of N. Every unqualified name use lands here.
    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if n == &null { return true; }

        // Already bound: `self`-style pre-binding, an out-of-line qualifier
        // segment resolved by N(a), or a second N run over the same AST.
        if n->is_bound() || n->is_deferred() { return true; }

        // Already DIAGNOSED. N(a) walks an out-of-line def's `Class::`
        // qualifier before the RAV ever reaches it, so without this the
        // same unresolvable head is reported twice -- once by
        // _resolve_qualifier and once here. Poison is the marker: one
        // error, one home.
        if n->is_poisoned() { return true; }

        var imm = self._name_imm(n->name);
        if imm == u32(-1) { return true; }   // not an identifier: nothing to bind.

        var h = self._resolve_name(imm);

        if !h.found {
            var nm = self.sc->ctx->get_spelling(n->name);
            self.sc->diag->report(DiagID::R001E, n->range.start,
                f"use of undeclared identifier '{nm}\x27"
            ).first(n->range).emit();
            n->poison();                      // both slots stay null; T skips.
            return true;
        }

        // Import access. I folded priv/prot names in on purpose and recorded
        // the visibility fact; the "exists but you can't touch it" error is
        // ours, and only fires when the ONLY way to see the name was the
        // overlay (a local decl shadows before we ever get here).
        if h.via_overlay && !self._overlay_access_ok(imm) {
            var nm = self.sc->ctx->get_spelling(n->name);
            self.sc->diag->report(DiagID::R001E, n->range.start,
                f"'{nm}' is imported but is declared private in its module"
            ).first(n->range).emit();
            n->poison();
            return true;
        }

        if h.decl != &null {
            n->resolved_decl = h.decl;
        } else {
            n->candidate_cell = h.cell;      // alias into the frozen cell.
        }
        return true;
    }

    /// False when every overlay target for \p imm is private. Protected is
    /// allowed through: enforcing it needs the same-library provenance that
    /// only member lookup carries, and a wrong reject is worse than a late
    /// one.
    priv fn _overlay_access_ok(self, imm: u32) -> bool {
        var tu = self.sc->tu;
        if tu == &null { return true; }
        if tu->import_overlay == &null { return true; }
        var entry = tu->import_overlay->entry(imm);
        if entry == &null { return true; }
        if entry->targets.size() == 0 { return true; }

        for var i: usize = 0; i < entry->targets.size(); ++i {
            if entry->targets[i].vis != OverlayVisibility::Private { return true; }
        }
        return false;
    }

    // --- deferred: pattern heads -------------------------------------------
    //
    // A ConstructorPattern / UnresolvedConstructorPattern head is a bare
    // path that may be a ctor OR a binder; deciding needs the scrutinee
    // type. Walking it as an ordinary expression would report
    // unresolved-ident on every binder-shaped head, so the head is skipped
    // outright and only the subpatterns are walked. The pass that rewrites
    // resolved ctor patterns owns this later.

    fn traverse_constructor_pattern(self, n: *ConstructorPattern) -> *ConstructorPattern {
        if n == &null { return n; }
        if self.dyn()->walkup_constructor_pattern(n) == false { return n; }
        for var i: usize = 0; i < n->subpatterns.size(); ++i {
            if self.stop { break; }
            self.dyn()->dispatch_pattern(*(n->subpatterns.get(i)));
        }
        return n;
    }

    fn traverse_unresolved_constructor_pattern(self, n: *UnresolvedConstructorPattern)
            -> *UnresolvedConstructorPattern {
        if n == &null { return n; }
        if self.dyn()->walkup_unresolved_constructor_pattern(n) == false { return n; }
        for var i: usize = 0; i < n->subpatterns.size(); ++i {
            if self.stop { break; }
            self.dyn()->dispatch_pattern(*(n->subpatterns.get(i)));
        }
        return n;
    }

    // --- helpers -----------------------------------------------------------

    /// The lookup key for a name token. `self` is KwSelf, not an
    /// identifier, so it gets the interned spelling instead; everything
    /// else routes through the ordinary imm path.
    priv fn _name_imm(self, tok: Token) -> u32 {
        var im = self.sc->ctx->get_ident_imm(tok);
        if im != u32(-1) { return im; }
        if tok.kind == TokenKind::KwSelf { return self._self_imm; }
        return u32(-1);
    }

    /// The imm of a decl's own name, for ctor-key detection. u32(-1) for
    /// kinds that have no name token.
    priv fn _decl_name_imm(self, d: *Decl) -> u32 {
        if d == &null { return u32(-1); }
        if isa::<ClassDecl>(d)     { return self.sc->ctx->get_ident_imm(cast::<ClassDecl>(d)->name);     }
        if isa::<StructDecl>(d)    { return self.sc->ctx->get_ident_imm(cast::<StructDecl>(d)->name);    }
        if isa::<UnionDecl>(d)     { return self.sc->ctx->get_ident_imm(cast::<UnionDecl>(d)->name);     }
        if isa::<InterfaceDecl>(d) { return self.sc->ctx->get_ident_imm(cast::<InterfaceDecl>(d)->name); }
        if isa::<EnumDecl>(d)      { return self.sc->ctx->get_ident_imm(cast::<EnumDecl>(d)->name);      }
        if isa::<ModuleDecl>(d)    { return self.sc->ctx->get_ident_imm(cast::<ModuleDecl>(d)->name);    }
        return u32(-1);
    }
}
