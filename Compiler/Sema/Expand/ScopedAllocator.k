/// --- The Kairo Project ---------------- Sema/Expand/ScopedAllocator.k --- ///
///
/// `@set_scoped_allocator(A)`: one attribute, one overload per node it is
/// written on, each a rewrite of the tree.
///
///   \detail
///     Each overload is what a library attribute macro would do, written as
///     its signature:
///
///       macro @set_scoped_allocator(node: *AST::FunctionDecl, A: type)
///           prepends to the body   var <fresh> = AllocatorScope<A>()
///       macro @set_scoped_allocator(node: *AST::Block, A: type)
///           prepends to the block  var <fresh> = AllocatorScope<A>()
///       macro @set_scoped_allocator(node: *AST::ClassDecl, A: type)
///       macro @set_scoped_allocator(node: *AST::StructDecl, A: type)
///           adds the fields        var __kairo_arena:     ObjectArena<A>     (first)
///                                  var __kairo_arena_end: ObjectArenaEnd<A>  (last)
///           and starts every method with
///                                  var <fresh> = ObjectArenaScope<A>(const &self.__kairo_arena)
///
///     AllocatorScope<A> (Lib/builtin/base/alloc.k) opens the scope when it
///     is constructed and closes it when it is destroyed, so the scope is
///     open from the body's first statement to every exit of it: a
///     `return`, the end of the block, a `break` or `continue` out of a
///     block, and a panic, which is a returned value that runs the
///     destructors of the locals it leaves. Several attributes on one node
///     open one scope each, in the order written, so the last one written
///     is the innermost and closes first.
///
///     The guard is an ordinary untyped local: `<fresh>` is a reserved
///     `__kairo_` name (VariableDecl::is_implicit, so the reserved-name rule
///     does not apply to it), and its initializer is a call whose callee
///     is spelled `AllocatorScope` and minted already BOUND to alloc.k's
///     class (WellKnownDecls::alloc_fn(AllocFn::Scope)), as
///     AllocSugarDesugar binds its callees, so the file needs no import.
///     With no alloc.k (`--no-prelude`) the name is left to ordinary
///     lookup. A is read from the attribute's one argument as a type
///     (Parser::DeclParse::expr_as_type: a name, a `::` path or a generic
///     application) and resolves where the body starts. Every minted node
///     carries the attribute's range, so an error about AllocatorScope<A>
///     (an A that is not a ScopedFullAllocator) lands on the attribute.
///     In a constructor the guard follows the base initializers
///     (`Base::Base(self, ...)`), which stay its first statements
///     (BaseInitCheck); it is recorded in SemaContext::scoped_lead, so a
///     constructor that initializes a field in place opens the scope where
///     the object exists (CtorInitLowering).
///
///     An expression-bodied function (`fn f() -> T = e`) becomes the block
///     it abbreviates first, as ExprBodyDesugar would make it: `{ return e }`,
///     or `{ e }` for `-> !`. One with no written return type is left alone:
///     its return type is inferred from the expression body, and a block
///     body would make it `void`.
///
///     On a class or struct the overload is two halves. Here, before T
///     (layout, lifecycle and TypeCycle read the fields), the two fields
///     join the record: the ObjectArena<A> before every other field and the
///     ObjectArenaEnd<A> after them, so the pair brackets the others'
///     construction, destruction and member-by-member assignment (alloc.k's
///     comment). Symbol tables are frozen after parsing, so nothing finds
///     the fields by name: each field type's head is bound to alloc.k's
///     class (TypeResolve takes a bound head as it is), and every reference
///     to a field is bound to its FieldDecl. Both are compiler declarations
///     (Decl::is_implicit): tools that mirror the source skip them, and
///     kfmt and kals, which read the parsed tree, never see them. The end field's range is the record's closing brace,
///     so a field an `eval if` decided in T is laid out before it
///     (EvalIfFolding::_fields_in_source_order). This pass runs after the
///     declaration-scope `eval if`s are folded, for the same reason.
///     The methods' guards are ScopedArenaMethods' (Sema/Expand/
///     ScopedArena.k), after T: an `extend`'s target is known only then.
///     The first use with one type argument is the record's; a second one
///     is ScopedAllocatorCheck's to report.
///
///     What is left alone, for ScopedAllocatorCheck to report: a use whose
///     arguments are not one type, a function with no body (or an
///     expression body with no return type), an `extend`, and the attribute
///     on any other node.
///
///   Phase: EXPAND, after EvalIfFolding (before N: the minted callee and
///          type argument resolve as written ones do)
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

import AST::Context::DeclContext::DeclContext
import AST::LangItems::{
    AllocFn,
    LangAttrs,
    LowerTargets,
    WellKnownDecls,
    alloc_fn_name,
}
import AST::Mixin::Annotation::{
    AnnotationEntry,
    AnnotationKind,
    VisibilityKind,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl, FieldDecl, FnBodyKind, FunctionDecl, StorageClass, StructDecl, VariableDecl,
}
import AST::Node::Expressions::{
    CallExpr,
    NamedArgExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::{
    CompoundStmt,
    DeclStmt,
    ExpressionStmt,
    ReturnStmt,
}
import AST::Node::Types::ChainType
import AST::Visitor::ASTWriter::{
    ASTWriter,
    ListBuilder,
}
import Location::SourceRange::SourceRange
import Parser::DeclParse::expr_as_type
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::SemaContext

pub class ScopedAllocatorExpand derives ASTWriter<ScopedAllocatorExpand> {
    pub var  sc:     *SemaContext
    priv var _synth: LowerSynth

    fn ScopedAllocatorExpand(self, sc: *SemaContext) {
        self.sc     = sc
        self.ctx    = sc->ctx // ASTWriter rebuilds lists in this arena.
        self._synth = LowerSynth(unsafe (sc as unsafe *SemaContext))
    }

    fn run(self) {
        if self.sc->tu == &null || !self.sc->tu->has_alloc_sugar {
            return
        }

        ASTWriter<ScopedAllocatorExpand>::run(self, self.sc->tu)
    }

    /// # what the check shares

    /// `e` is a `@set_scoped_allocator` attribute.
    pub static fn is_attr(sc: unsafe *SemaContext, e: unsafe *AnnotationEntry) -> bool {
        if e == &null || e->kind != AnnotationKind::Attribute || e->name == u32::MAX {
            return false
        }

        return sc->imm_table()->get_ident(e->name) == LangAttrs::set_scoped_allocator()
    }

    /// `n` carries at least one `@set_scoped_allocator`.
    pub static fn has_attr(sc: unsafe *SemaContext, n: unsafe *Stmt) -> bool {
        if n == &null || !n->has_attribute() {
            return false
        }

        for var i: usize = 0; i < n->annotations.size(); ++i {
            if ScopedAllocatorExpand::is_attr(sc, n->annotations.get(i)) {
                return true
            }
        }

        return false
    }

    /// The allocator type the attribute names: its one positional argument,
    /// read as a type. Null when the arguments are anything else (none,
    /// several, a keyword argument, an expression that is no type).
    pub static fn allocator_type(sc: unsafe *SemaContext,
                                 e:  unsafe *AnnotationEntry) -> unsafe *Type {
        if e->args.size() != 1 {
            return &null
        }

        var unsafe *a = e->args[0]
        if a == &null || isa<NamedArgExpr>(a) {
            return &null
        }

        return expr_as_type(sc->ctx, a)
    }

    /// The body the scope opens in, as a block: true for a block body, and
    /// for an expression body with a written return type (rewritten to a
    /// block first). False for a function with no body, and for an
    /// expression body whose return type is inferred.
    pub static fn has_scope_body(fd: unsafe *FunctionDecl) -> bool {
        if fd->body_kind == FnBodyKind::Block {
            return fd->body_block != &null
        }

        if fd->body_kind == FnBodyKind::Expr {
            return fd->body_expr != &null && (fd->return_type != &null || fd->is_noreturn)
        }

        return false
    }

    /// The use of the attribute that gives a class or struct its arena:
    /// the first with one type argument. Null when there is none.
    pub static fn record_attr(sc: unsafe *SemaContext, d: unsafe *Decl) -> unsafe *AnnotationEntry {
        if d == &null || !d->has_attribute() {
            return &null
        }

        for var i: usize = 0; i < d->annotations.size(); ++i {
            var unsafe *e = d->annotations.get(i)
            if ScopedAllocatorExpand::is_attr(sc, e)
                && ScopedAllocatorExpand::allocator_type(sc, e) != &null {
                return e
            }
        }

        return &null
    }

    /// The field `@set_scoped_allocator` gave record `d`: its ObjectArena<A>
    /// (`end` false) or its ObjectArenaEnd<A> (`end` true). Null for a
    /// record without the attribute, and with no alloc.k in the build. Told
    /// by its bound type head, never by name.
    pub static fn arena_field(well: unsafe *WellKnownDecls,
                              d:    unsafe *Decl,
                              end:  bool) -> unsafe *FieldDecl {
        if well == &null || d == &null {
            return &null
        }

        var        k    = if (end) => (AllocFn::ObjectArenaEnd) else => AllocFn::ObjectArena
        var unsafe *cls = well->alloc_fn(k)
        if cls == &null {
            return &null
        }

        var unsafe *cd = dyn_cast<ClassDecl>(d)
        var unsafe *sd = dyn_cast<StructDecl>(d)
        if cd == &null && sd == &null {
            return &null
        }

        var n = if (cd != &null) => (cd->fields.size()) else => sd->fields.size()
        for var i: usize = 0; i < n; ++i {
            var unsafe *f = if (cd != &null) => (cd->fields[i]) else => sd->fields[i]
            if f == &null || !f->is_implicit {
                continue
            }

            var unsafe *ct = dyn_cast<ChainType>(f->type_)
            if ct == &null || ct->segments.size() != 1 {
                continue
            }

            var unsafe *nm = ct->segments.get(0)->name
            if nm != &null && nm->resolved_decl == cls {
                return f
            }
        }

        return &null
    }

    /// `s` is a constructor called by name, `Base::Base(self, ...)`, the
    /// form a base initializer is written in. Read by shape: this runs
    /// before X binds the callee, and a constructor may be called by name
    /// only as a base initializer (BaseInitCheck).
    pub static fn is_base_init_shape(sc: unsafe *SemaContext, s: unsafe *Stmt) -> bool {
        var unsafe *es = dyn_cast<ExpressionStmt>(s)
        if es == &null || es->expr == &null {
            return false
        }

        var unsafe *call = dyn_cast<CallExpr>(es->expr)
        if call == &null {
            return false
        }

        var unsafe *ch = dyn_cast<ChainExpr>(call->callee)
        if ch == &null || ch->steps.size() == 0 {
            return false
        }

        var unsafe *last = ch->steps.get(ch->steps.size() - 1)
        if last->access_kind != ChainExpr::AccessKind::ColonColon || last->name == &null {
            return false
        }

        var owner: unsafe *NamedIdentExpr = &null
        if ch->steps.size() >= 2 {
            owner = ch->steps.get(ch->steps.size() - 2)->name
        } else {
            owner = dyn_cast<NamedIdentExpr>(ch->base)
        }

        if owner == &null {
            return false
        }

        return sc->ctx->get_spelling(owner->name) == sc->ctx->get_spelling(
            last->name->name,
        )
    }

    /// How many statements open `blk` as base initializers: where a guard
    /// goes, after them.
    pub static fn lead_base_inits(sc: unsafe *SemaContext, blk: unsafe *CompoundStmt) -> usize {
        var n: usize = 0
        while n < blk->body.size() && ScopedAllocatorExpand::is_base_init_shape(sc, blk->body[n]) {
            n += 1
        }

        return n
    }

    /// `blk` with `stmts` after its base initializers, each recorded in
    /// SemaContext::scoped_lead.
    pub static fn insert_lead(sc:          unsafe *SemaContext,
                              blk:         unsafe *CompoundStmt,
                              const stmts: [unsafe *Stmt]) {
        var at = ScopedAllocatorExpand::lead_base_inits(sc, blk)
        var b  = ListBuilder<unsafe *Stmt>(sc->ctx)
        for var i: usize = 0; i < at; ++i {
            b.push(blk->body[i])
        }

        for var i: usize = 0; i < stmts.size(); ++i {
            b.push(stmts[i])
            sc->scoped_lead.insert(stmts[i] as usize as u64)
        }

        for var i: usize = at; i < blk->body.size(); ++i {
            b.push(blk->body[i])
        }

        b.freeze_into(&blk->body)
    }

    /// An expression body as the block it abbreviates, as ExprBodyDesugar
    /// makes it: `{ return e }`, or `{ e }` for `-> !`. The function has a
    /// written return type, or is `-> !`.
    pub static fn expr_body_to_block(sc: unsafe *SemaContext, n: unsafe *FunctionDecl) {
        var unsafe *e              = n->body_expr
        var        s: unsafe *Stmt = &null
        if n->is_noreturn {
            s = ExpressionStmt::create(sc->ctx, e->range, e)
        } else {
            s = ReturnStmt::create(sc->ctx, e->range, e)
        }

        var stmts = ListBuilder<unsafe *Stmt>(sc->ctx)
        stmts.push(s)
        var unsafe *body = CompoundStmt::create(sc->ctx, e->range)
        stmts.freeze_into(&body->body)
        n->body_block = body
        n->body_expr  = &null
        n->body_kind  = FnBodyKind::Block
    }

    /// # the overloads

    fn transform_function_decl(self, n: unsafe *FunctionDecl) -> cxx::std::vector<unsafe *Decl> {
        var out = ASTWriter<ScopedAllocatorExpand>::transform_function_decl(
            self,
            n,
        )

        if !n->has_attribute() || !ScopedAllocatorExpand::has_scope_body(n) {
            return out
        }

        var guards = self._guards(unsafe (n as unsafe *Decl))
        if guards.size() == 0 {
            return out
        }

        if n->body_kind == FnBodyKind::Expr {
            ScopedAllocatorExpand::expr_body_to_block(
                unsafe (self.sc as unsafe *SemaContext),
                n,
            )
        }

        self._prepend(n->body_block, guards, true)
        return out
    }

    fn transform_compound_stmt(self, n: unsafe *CompoundStmt) -> cxx::std::vector<unsafe *Stmt> {
        var out = ASTWriter<ScopedAllocatorExpand>::transform_compound_stmt(
            self,
            n,
        )

        if !ScopedAllocatorExpand::has_attr(
            unsafe (self.sc as unsafe *SemaContext),
            n,
        ) {
            return out
        }

        var guards: [unsafe *AnnotationEntry]
        for var i: usize = 0; i < n->annotations.size(); ++i {
            var unsafe *e = n->annotations.get(i)
            if ScopedAllocatorExpand::is_attr(
                unsafe (self.sc as unsafe *SemaContext),
                e,
            ) {
                guards.push(e)
            }
        }

        self._prepend(n, guards, false)
        return out
    }

    fn transform_class_decl(self, n: unsafe *ClassDecl) -> cxx::std::vector<unsafe *Decl> {
        var out = ASTWriter<ScopedAllocatorExpand>::transform_class_decl(
            self,
            n,
        )

        self._add_arena(unsafe (n as unsafe *Decl))
        return out
    }

    fn transform_struct_decl(self, n: unsafe *StructDecl) -> cxx::std::vector<unsafe *Decl> {
        var out = ASTWriter<ScopedAllocatorExpand>::transform_struct_decl(
            self,
            n,
        )

        self._add_arena(unsafe (n as unsafe *Decl))
        return out
    }

    /// # the guard

    /// A declaration's `@set_scoped_allocator` attributes, in the order
    /// written.
    priv fn _guards(self, d: unsafe *Decl) -> [unsafe *AnnotationEntry] {
        var out: [unsafe *AnnotationEntry]
        for var i: usize = 0; i < d->annotations.size(); ++i {
            var unsafe *e = d->annotations.get(i)
            if ScopedAllocatorExpand::is_attr(
                unsafe (self.sc as unsafe *SemaContext),
                e,
            ) {
                out.push(e)
            }
        }

        return out
    }

    /// `blk` with one guard per attribute in `attrs` before its first
    /// statement, or in a function body after its base initializers
    /// (`body`). An attribute whose arguments are not one type gets none.
    /// A block that already holds the guards (a second Expand over the same
    /// tree) is left as it is.
    priv fn _prepend(self,
                     blk:         unsafe *CompoundStmt,
                     const attrs: [unsafe *AnnotationEntry],
                     body:        bool) {
        if blk == &null || attrs.size() == 0 || self._expanded(blk, attrs[0]) {
            return
        }

        var stmts: [unsafe *Stmt]
        for var i: usize = 0; i < attrs.size(); ++i {
            var unsafe *g = self._guard(attrs[i])
            if g != &null {
                stmts.push(g)
            }
        }

        if stmts.size() == 0 {
            return
        }

        if body {
            ScopedAllocatorExpand::insert_lead(
                unsafe (self.sc as unsafe *SemaContext),
                blk,
                stmts,
            )

            return
        }

        var b = self.list_builder<unsafe *Stmt>()
        for var i: usize = 0; i < stmts.size(); ++i {
            b.push(stmts[i])
        }

        for var i: usize = 0; i < blk->body.size(); ++i {
            b.push(blk->body[i])
        }

        b.freeze_into(&blk->body)
    }

    /// One of the block's leading statements (base initializers, then
    /// compiler-made locals) is the guard minted for `e`.
    priv fn _expanded(self, blk: unsafe *CompoundStmt, e: unsafe *AnnotationEntry) -> bool {
        for var i: usize = 0; i < blk->body.size(); ++i {
            var unsafe *s = blk->body[i]
            if ScopedAllocatorExpand::is_base_init_shape(
                unsafe (self.sc as unsafe *SemaContext),
                s,
            ) {
                continue
            }

            var unsafe *ds = dyn_cast<DeclStmt>(s)
            if ds == &null
                || ds->decl == &null
                || !isa<VariableDecl>(ds->decl)
                || !ds->decl->is_implicit {
                return false
            }

            if ds->decl->range == e->range {
                return true
            }
        }

        return false
    }

    /// `var <fresh> = AllocatorScope<A>()` for attribute `e`; null when its
    /// arguments are not one type.
    priv fn _guard(self, e: unsafe *AnnotationEntry) -> unsafe *Stmt {
        var unsafe *a = ScopedAllocatorExpand::allocator_type(
            unsafe (self.sc as unsafe *SemaContext),
            e,
        )

        if a == &null {
            return &null
        }

        var at = e->range
        var unsafe *callee = NamedIdentExpr::create(
            self.sc->ctx,
            at,
            self._synth.ident(at, alloc_fn_name(AllocFn::Scope)),
        )

        var unsafe *ga = self.sc->ctx->alloc_array<ChainType::GenericArg>(1)
        ga[0].name       = &null
        ga[0].name_range = SourceRange::invalid()
        ga[0].ty         = a
        callee->generic_args.from_raw(ga, 1)

        // alloc.k was typed before this TU (the driver's edge), so the entry
        // is filled by now; when it is not, N looks the name up as written.
        if self.sc->well_known != &null {
            var unsafe *d = self.sc->well_known->alloc_fn(AllocFn::Scope)
            if d != &null {
                callee->resolved_decl = d
            }
        }

        var unsafe *call = CallExpr::create(self.sc->ctx, at, callee)
        var unsafe *vd = VariableDecl::create(
            self.sc->ctx,
            at,
            self._synth.fresh(at, "alloc_scope"),
            StorageClass::Var,
        )

        vd->init        = call
        vd->is_implicit = true
        return unsafe (DeclStmt::create(self.sc->ctx, at, unsafe (vd as unsafe *Decl)) as unsafe *Stmt)
    }

    /// # the fields

    /// Record `d` (a class or struct) with its arena fields, when it carries
    /// the attribute with one type argument and does not have them yet:
    /// `__kairo_arena` before every other field, `__kairo_arena_end` after
    /// them, indices renumbered. Nothing without alloc.k in the build: no
    /// class to name.
    priv fn _add_arena(self, d: unsafe *Decl) {
        var unsafe *e = ScopedAllocatorExpand::record_attr(
            unsafe (self.sc as unsafe *SemaContext),
            d,
        )

        if e == &null || self.sc->well_known == &null {
            return
        }

        if self.sc->well_known->alloc_fn(AllocFn::ObjectArena) == &null
            || self.sc->well_known->alloc_fn(AllocFn::ObjectArenaEnd) == &null
            || ScopedAllocatorExpand::arena_field(self.sc->well_known, d, false) != &null {
            return
        }

        var unsafe *cd = dyn_cast<ClassDecl>(d)
        var unsafe *sd = dyn_cast<StructDecl>(d)
        var unsafe *dc = if (cd != &null) => (unsafe (cd as unsafe *DeclContext))
                         else => unsafe (sd as unsafe *DeclContext)
        var old = if (cd != &null) => (cd->fields) else => sd->fields
        var end = SourceRange::from_bounds(
            d->range.end.with_offset(-1),
            1 as u32,
        )

        var b = ListBuilder<unsafe *FieldDecl>(self.sc->ctx)
        b.push(
            self._field(
                dc,
                e,
                AllocFn::ObjectArena,
                LowerTargets::object_arena_field(),
                e->range,
            ),
        )

        for var i: usize = 0; i < old.size(); ++i {
            b.push(old[i])
        }

        b.push(
            self._field(
                dc,
                e,
                AllocFn::ObjectArenaEnd,
                LowerTargets::object_arena_end_field(),
                end,
            ),
        )

        if cd != &null {
            b.freeze_into(&cd->fields)
        } else {
            b.freeze_into(&sd->fields)
        }

        var now = if (cd != &null) => (cd->fields) else => sd->fields
        for var i: usize = 0; i < now.size(); ++i {
            if now[i] != &null {
                now[i]->index = (i as u32)
            }
        }
    }

    /// `var <name>: <k><A>`, A read from attribute `e`, the type's head
    /// bound to alloc.k's class `k`. The type carries the attribute's
    /// range, so an error about it (an A that is not an ArenaAllocator)
    /// lands there; the field itself is at `at`.
    priv fn _field(self,
                   dc:         unsafe *DeclContext,
                   e:          unsafe *AnnotationEntry,
                   k:          AllocFn,
                   const name: string,
                   at:         SourceRange) -> unsafe *FieldDecl {
        var spot = e->range
        var unsafe *head = NamedIdentExpr::create(
            self.sc->ctx,
            spot,
            self._synth.ident(spot, alloc_fn_name(k)),
        )

        head->resolved_decl = self.sc->well_known->alloc_fn(k)
        var unsafe *ga = self.sc->ctx->alloc_array<ChainType::GenericArg>(1)
        ga[0].name       = &null
        ga[0].name_range = SourceRange::invalid()
        ga[0].ty = ScopedAllocatorExpand::allocator_type(
            unsafe (self.sc as unsafe *SemaContext),
            e,
        )

        var unsafe *seg = self.sc->ctx->alloc_array<ChainType::ChainSegment>(1)
        seg[0].name          = head
        seg[0].resolved_type = &null
        seg[0].resolved_decl = &null
        seg[0].range         = spot
        seg[0].sep           = ChainType::SegmentSeparator::None
        seg[0].seg_kind      = ChainType::SegmentKind::GenericApp
        seg[0].generic_args.from_raw(ga, 1)
        var unsafe *ct = ChainType::create(self.sc->ctx, spot)
        ct->segments.from_raw(seg, 1)

        var unsafe *f = FieldDecl::create(
            self.sc->ctx,
            at,
            self._synth.ident(at, name),
            StorageClass::Var,
            unsafe (ct as unsafe *Type),
            0,
        )

        // Public: an `extend` in another file is emitted outside the
        // record, and its guard reads the field. No source can name it.
        f->is_implicit = true
        f->visibility  = VisibilityKind::Public
        f->lexical_dc  = dc
        f->semantic_dc = dc
        return f
    }
}
