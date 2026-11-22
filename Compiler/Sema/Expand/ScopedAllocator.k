/// --- The Kairo Project ---------------- Sema/Expand/ScopedAllocator.k --- ///
///
/// `@set_scoped_allocator(A)`: one attribute, one overload per node it is
/// written on, each a rewrite of the tree before anything resolves a name.
///
///   \detail
///     Each overload is what a library attribute macro would do, written as
///     its signature:
///
///       macro @set_scoped_allocator(node: *AST::FunctionDecl, A: type)
///           prepends to the body   var <fresh> = AllocatorScope<A>()
///       macro @set_scoped_allocator(node: *AST::Block, A: type)
///           prepends to the block  var <fresh> = AllocatorScope<A>()
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
///
///     An expression-bodied function (`fn f() -> T = e`) becomes the block
///     it abbreviates first, as ExprBodyDesugar would make it: `{ return e }`,
///     or `{ e }` for `-> !`. One with no written return type is left alone:
///     its return type is inferred from the expression body, and a block
///     body would make it `void`.
///
///     What is left alone, for ScopedAllocatorCheck to report: a use whose
///     arguments are not one type, a function with no body (or an
///     expression body with no return type), a class, struct or `extend`,
///     and the attribute on any other node.
///
///   Phase: EXPAND (before N: the minted callee and type argument resolve
///          as written ones do)
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

import AST::LangItems::{
    AllocFn,
    LangAttrs,
    alloc_fn_name,
}
import AST::Mixin::Annotation::{
    AnnotationEntry,
    AnnotationKind,
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
    FnBodyKind,
    FunctionDecl,
    StorageClass,
    VariableDecl,
}
import AST::Node::Expressions::{
    CallExpr,
    NamedArgExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
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
            var unsafe *e              = n->body_expr
            var        s: unsafe *Stmt = &null
            if n->is_noreturn {
                s = ExpressionStmt::create(self.ctx, e->range, e)
            } else {
                s = ReturnStmt::create(self.ctx, e->range, e)
            }

            var stmts = self.list_builder<unsafe *Stmt>()
            stmts.push(s)
            var unsafe *body = CompoundStmt::create(self.ctx, e->range)
            stmts.freeze_into(&body->body)
            n->body_block = body
            n->body_expr  = &null
            n->body_kind  = FnBodyKind::Block
        }

        self._prepend(n->body_block, guards)
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

        self._prepend(n, guards)
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
    /// statement. An attribute whose arguments are not one type gets none.
    /// A block that already starts with the guards (a second Expand over the
    /// same tree) is left as it is.
    priv fn _prepend(self, blk: unsafe *CompoundStmt, const attrs: [unsafe *AnnotationEntry]) {
        if blk == &null || attrs.size() == 0 || self._expanded(blk, attrs[0]) {
            return
        }

        var stmts = self.list_builder<unsafe *Stmt>()
        var added = false
        for var i: usize = 0; i < attrs.size(); ++i {
            var unsafe *g = self._guard(attrs[i])
            if g != &null {
                stmts.push(g)
                added = true
            }
        }

        if !added {
            return
        }

        for var i: usize = 0; i < blk->body.size(); ++i {
            stmts.push(blk->body[i])
        }

        stmts.freeze_into(&blk->body)
    }

    /// The block's first statement is the guard minted for `e`.
    priv fn _expanded(self, blk: unsafe *CompoundStmt, e: unsafe *AnnotationEntry) -> bool {
        if blk->body.size() == 0 {
            return false
        }

        var unsafe *ds = dyn_cast<DeclStmt>(blk->body[0])
        if ds == &null || ds->decl == &null || !isa<VariableDecl>(ds->decl) {
            return false
        }

        return ds->decl->is_implicit && ds->decl->range == e->range
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
}
