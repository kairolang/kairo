/// --- The Kairo Project -------------------- Sema/Expand/ScopedArena.k --- ///
///
/// The methods half of `@set_scoped_allocator(A)` on a class or struct:
/// every method of the record, and of each `extend` of it, opens the
/// object's arena for its body.
///
///   \detail
///     ScopedAllocatorExpand gave the record its two fields before T. Here
///     each non-static method with a body, written in the record or in an
///     `extend` of it (in any file, generic or not), starts with
///
///       var <fresh> = ObjectArenaScope<A>(const &self.__kairo_arena)
///
///     and a transfer constructor marked `@move` with a body starts, before
///     that, with
///
///       self.__kairo_arena.take(&other.__kairo_arena)
///       self.__kairo_arena_end.take(&other.__kairo_arena_end)
///
///     Both fields were built with a fresh arena; `take` frees it and takes
///     the source's, so the blocks the body moves across stay with their
///     arena. A `@copy` constructor gets the guard alone: the copy has an
///     arena of its own. Constructors, `op finally`, operators, generic and
///     `const` methods are methods like any other (`const &` gives the
///     `*const ObjectArena<A>` the guard takes). Static methods, free
///     functions and a method with no body (`= default`, `= delete`,
///     `= virtual`, a declaration) get nothing. A class that derives from
///     the record does not inherit the attribute: its own methods get
///     nothing, and the base's methods open the base part's arena.
///
///     After T, because an `extend`'s target is known only then; the
///     record's own methods are done here too, so a method an `eval if`
///     decided in T gets its guard like the rest. Every node is minted
///     bound, as N and ChainBinding would have bound it: `self` and `other`
///     to their ParamDecls, a field step to the FieldDecl (no table holds
///     the fields), the guard's callee to alloc.k's ObjectArenaScope, and A
///     is the record's own type node, already resolved. `take` is the one
///     name left to X, a member of alloc.k's class. Every node carries the
///     attribute's range. In a constructor the statements follow the base
///     initializers and are recorded in SemaContext::scoped_lead (as
///     ScopedAllocatorExpand's function guard is): they belong to the
///     object's life, so CtorInitLowering moves them to the head of the
///     part that runs once the object exists.
///
///     An expression-bodied method becomes the block it abbreviates
///     first. What cannot get the guard is an error rather than a method
///     that silently allocates outside the arena:
///
///       - an expression body with no written return type: SC366E, a block
///         body would not infer it;
///       - a `yield` in the body: SC367E, the generator would suspend with
///         the arena's scope open on the thread;
///       - a method of an `extend` of a record whose A is one of the
///         record's own generic parameters: SC116E, the extension names its
///         own (or none).
///
///     Each with a note at the attribute.
///
///   Phase: after T (TypesResolved), first of the typed checks, before
///          ExprTyper, which types the minted statements as written ones
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::ASTSupport::FrozenList
import AST::DeclFacts::decl_is_instance
import AST::LangItems::{
    AllocFn,
    AllocNames,
    LangAttrs,
    LowerTargets,
    alloc_fn_name,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,  ExtensionDecl, FieldDecl,    FnBodyKind, FunctionDecl, ParamDecl, StorageClass,
    StructDecl, TransferKind,  VariableDecl,
}
import AST::Node::Expressions::{
    CallExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::{
    CompoundStmt,
    DeclStmt,
    ExpressionStmt,
}
import AST::Node::Types::ChainType
import AST::Visitor::ASTWriter::ListBuilder
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::ScopedAllocator::ScopedYieldScan
import Sema::Expand::ScopedAllocator::ScopedAllocatorExpand
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

pub class ScopedArenaMethods derives RecursiveASTVisitor<ScopedArenaMethods> {
    pub var  sc:     unsafe *SemaContext
    priv var _synth: LowerSynth
    priv var _tu:    TypeUtil
    priv var _scope: unsafe *Decl        = &null ///< alloc.k's ObjectArenaScope.
    /// Function bodies are walked for records declared in them only in a
    /// file that writes the attribute: no other file can declare one there.
    priv var _deep: bool = false

    fn ScopedArenaMethods(self, sc: unsafe *SemaContext) {
        self.sc     = sc
        self._synth = LowerSynth(sc)
        self._tu    = TypeUtil(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        if self.sc->tu == &null || self.sc->well_known == &null {
            return
        }

        self._scope = self.sc->well_known->alloc_fn(AllocFn::ObjectArenaScope)
        if self._scope == &null {
            return
        }

        self._deep = self.sc->tu->has_alloc_sugar
        RecursiveASTVisitor<ScopedArenaMethods>::run(self, self.sc->tu)
    }

    fn traverse_function_decl(self, n: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        if !self._deep {
            return n
        }

        return RecursiveASTVisitor<ScopedArenaMethods>::traverse_function_decl(
            self,
            n,
        )
    }

    fn visit_class_decl(self, n: *ClassDecl) -> bool {
        var unsafe *d = unsafe (n as unsafe *Decl)
        if !n->is_poisoned() && !decl_is_instance(d) {
            self._methods(d, n->methods, false)
        }

        return true
    }

    fn visit_struct_decl(self, n: *StructDecl) -> bool {
        var unsafe *d = unsafe (n as unsafe *Decl)
        if !n->is_poisoned() && !decl_is_instance(d) {
            self._methods(d, n->methods, false)
        }

        return true
    }

    fn visit_extension_decl(self, n: *ExtensionDecl) -> bool {
        if n->is_poisoned() || n->target == &null || n->target->canonical == &null {
            return true
        }

        var unsafe *rt = dyn_cast<RecordType>(
            canon_unqual(n->target->canonical),
        )

        if rt == &null || rt->decl == &null {
            return true
        }

        self._methods(self._tu.pattern_of(rt->decl), n->methods, true)

        return true
    }

    /// # one record

    /// Each method in `methods` (of record `rec`, or of an `extend` of it
    /// when `in_ext`) with the arena's guard, when `rec` has
    /// the arena fields. A method declared in the body and defined out of
    /// line is guarded at its definition.
    priv fn _methods(self,
                     rec:     unsafe *Decl,
                     methods: FrozenList<unsafe *FunctionDecl>,
                     in_ext:  bool) {
        var unsafe *first = ScopedAllocatorExpand::arena_field(
            self.sc->well_known,
            rec,
            false,
        )

        var unsafe *last = ScopedAllocatorExpand::arena_field(
            self.sc->well_known,
            rec,
            true,
        )

        if first == &null || last == &null {
            return
        }

        var unsafe *a = self._allocator(first)
        if a == &null {
            return
        }

        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null {
                continue
            }

            if !m->has_body() {
                m = m->definition()
            }

            if m != &null && !m->is_poisoned() {
                self._method(rec, m, first, last, a, in_ext)
            }
        }
    }

    /// The A of `ObjectArena<A>`: the record's type node, resolved in the
    /// record's scope.
    priv fn _allocator(self, first: unsafe *FieldDecl) -> unsafe *Type {
        var unsafe *ct = dyn_cast<ChainType>(first->type_)
        if ct == &null || ct->segments.size() != 1 {
            return &null
        }

        var unsafe *seg = ct->segments.get(0)
        if seg->generic_args.size() != 1 {
            return &null
        }

        var unsafe *a = seg->generic_args.get(0)->ty
        if a == &null || a->canonical == &null {
            return &null
        }

        return a
    }

    priv fn _method(self,
                    rec:    unsafe *Decl,
                    f:      unsafe *FunctionDecl,
                    first:  unsafe *FieldDecl,
                    last:   unsafe *FieldDecl,
                    a:      unsafe *Type,
                    in_ext: bool) {
        if !f->is_method() {
            return
        }

        var at = first->range
        if f->body_kind == FnBodyKind::Expr {
            if f->body_expr == &null {
                return
            }

            if f->return_type == &null && !f->is_noreturn {
                var nm = self._tu.decl_name(rec)
                self._report(
                    DiagID::SC366E,
                    f,
                    rec,
                    f" on '{nm}' opens its arena in each method's block body; this method's expression body has no written return type ('-> T'), which a block body would not infer",
                )

                return
            }
        }

        if f->body_kind != FnBodyKind::Block && f->body_kind != FnBodyKind::Expr {
            return
        }

        if f->body_kind == FnBodyKind::Block
            && (f->body_block == &null || self._guarded(f->body_block)) {
            return
        }

        // A that names the record's own generic parameter means nothing in
        // an `extend`, which names its own (or none).
        if in_ext && (a->canonical->is_dependent() || a->canonical->is_instantiation_dependent()) {
            var nm = self._tu.decl_name(rec)
            self._report(
                DiagID::SC116E,
                f,
                rec,
                f" on '{nm}' with a generic parameter of '{nm}' as the allocator, in a method of an 'extend', is not yet supported",
            )

            return
        }

        if f->body_kind == FnBodyKind::Block {
            var scan = ScopedYieldScan(
                self.sc,
                unsafe (f->body_block as unsafe *Stmt),
                at,
            )

            scan.dispatch_stmt(unsafe (f->body_block as unsafe *Stmt))
            if scan.found > 0 {
                return
            }
        } else {
            ScopedAllocatorExpand::expr_body_to_block(self.sc, f)
        }

        var unsafe *self_p                = f->params[0]
        var        stmts:  [unsafe *Stmt]
        if f->transfer == TransferKind::Move && f->params.size() >= 2 {
            var unsafe *other = f->params[1]
            stmts.push(
                self._take(
                    at,
                    self_p,
                    other,
                    first,
                    LowerTargets::object_arena_field(),
                ),
            )

            stmts.push(
                self._take(
                    at,
                    self_p,
                    other,
                    last,
                    LowerTargets::object_arena_end_field(),
                ),
            )
        }

        stmts.push(self._guard(at, self_p, first, a))
        ScopedAllocatorExpand::insert_lead(self.sc, f->body_block, stmts)
    }

    /// The body already opens the arena (a second run over the same tree).
    priv fn _guarded(self, blk: unsafe *CompoundStmt) -> bool {
        for var i: usize = 0; i < blk->body.size(); ++i {
            var unsafe *ds = dyn_cast<DeclStmt>(blk->body[i])
            if ds == &null || ds->decl == &null || !isa<VariableDecl>(ds->decl) {
                continue
            }

            var unsafe *vd = cast<VariableDecl>(ds->decl)
            if !vd->is_implicit || vd->init == &null || !isa<CallExpr>(vd->init) {
                continue
            }

            var unsafe *callee = dyn_cast<NamedIdentExpr>(
                cast<CallExpr>(vd->init)->callee,
            )

            if callee != &null && callee->resolved_decl == self._scope {
                return true
            }
        }

        return false
    }

    /// The attribute's name and `msg`, about method `f` of record `rec`, at
    /// the method's name, with a note at the attribute.
    priv fn _report(self,
                    id:        DiagID,
                    f:         unsafe *FunctionDecl,
                    rec:       unsafe *Decl,
                    const msg: string) {
        var an   = LangAttrs::quoted(LangAttrs::set_scoped_allocator())
        var note = if (id == DiagID::SC116E) => (DiagID::SC116N) else => DiagID::SC366N
        var b    = self.sc->diag->report(id, f->name.range.start, an + msg)
        b.first(f->name.range)
        b.note(
            DiagCode(note),
            self._attr_range(rec).start,
            "the attribute is here",
        )->child_first(self._attr_range(rec))
        b.emit()
    }

    /// Where the attribute is written: the arena field carries its range.
    priv fn _attr_range(self, rec: unsafe *Decl) -> SourceRange {
        return ScopedAllocatorExpand::arena_field(
            self.sc->well_known,
            rec,
            false,
        )->range
    }

    /// # the statements

    /// `p`, bound to the parameter.
    priv fn _param(self, at: SourceRange, p: unsafe *ParamDecl) -> unsafe *Expr {
        var unsafe *id = NamedIdentExpr::create(self.sc->ctx, at, p->name)
        id->resolved_decl = unsafe (p as unsafe *Decl)
        return unsafe (id as unsafe *Expr)
    }

    /// `p.<name>`, the step bound to `field`.
    priv fn _field_of(self,
                      at:         SourceRange,
                      p:          unsafe *ParamDecl,
                      field:      unsafe *FieldDecl,
                      const name: string) -> unsafe *Expr {
        var unsafe *chain = ChainExpr::create(
            self.sc->ctx,
            at,
            self._param(at, p),
        )

        var steps = ListBuilder<ChainExpr::Step>(self.sc->ctx)
        steps.push(self._step(at, name, unsafe (field as unsafe *Decl)))
        steps.freeze_into(&chain->steps)
        return unsafe (chain as unsafe *Expr)
    }

    /// A `.name` step, bound to `d` (null: left to X).
    priv fn _step(self, at: SourceRange, const name: string, d: unsafe *Decl) -> ChainExpr::Step {
        var st = ChainExpr::Step()
        st.name = NamedIdentExpr::create(
            self.sc->ctx,
            at,
            self._synth.ident(at, name),
        )

        st.name->resolved_decl = d
        st.target              = ChainExpr::StepTarget::Name
        st.range               = at
        st.access_kind         = ChainExpr::AccessKind::Dot
        st.resolved_decl       = d
        st.resolved_type       = &null
        return st
    }

    /// `&e`, or `const &e`.
    priv fn _addr(self, at: SourceRange, e: unsafe *Expr, is_const: bool) -> unsafe *Expr {
        var unsafe *u = UnaryOperatorExpr::create(
            self.sc->ctx,
            at,
            e,
            self._synth.punct(at, TokenKind::OpAmp),
            UnaryOperatorExpr::Fix::Prefix,
        )

        u->const_addr = is_const
        return unsafe (u as unsafe *Expr)
    }

    /// `self.<name>.take(&other.<name>)`.
    priv fn _take(self,
                  at:         SourceRange,
                  self_p:     unsafe *ParamDecl,
                  other:      unsafe *ParamDecl,
                  field:      unsafe *FieldDecl,
                  const name: string) -> unsafe *Stmt {
        var unsafe *recv = ChainExpr::create(
            self.sc->ctx,
            at,
            self._param(at, self_p),
        )

        var steps = ListBuilder<ChainExpr::Step>(self.sc->ctx)
        steps.push(self._step(at, name, unsafe (field as unsafe *Decl)))
        steps.push(self._step(at, AllocNames::arena_take(), &null))
        steps.freeze_into(&recv->steps)

        var unsafe *call = CallExpr::create(
            self.sc->ctx,
            at,
            unsafe (recv as unsafe *Expr),
        )

        var args = ListBuilder<unsafe *Expr>(self.sc->ctx)
        args.push(self._addr(at, self._field_of(at, other, field, name), false))
        args.freeze_into(&call->args)
        return unsafe (ExpressionStmt::create(self.sc->ctx, at, unsafe (call as unsafe *Expr)) as unsafe *Stmt)
    }

    /// `var <fresh> = ObjectArenaScope<A>(const &self.__kairo_arena)`.
    priv fn _guard(self,
                   at:     SourceRange,
                   self_p: unsafe *ParamDecl,
                   first:  unsafe *FieldDecl,
                   a:      unsafe *Type) -> unsafe *Stmt {
        var unsafe *callee = NamedIdentExpr::create(
            self.sc->ctx,
            at,
            self._synth.ident(at, alloc_fn_name(AllocFn::ObjectArenaScope)),
        )

        var unsafe *ga = self.sc->ctx->alloc_array<ChainType::GenericArg>(1)
        ga[0].name       = &null
        ga[0].name_range = SourceRange::invalid()
        ga[0].ty         = a
        callee->generic_args.from_raw(ga, 1)
        callee->resolved_decl = self._scope

        var unsafe *call = CallExpr::create(
            self.sc->ctx,
            at,
            unsafe (callee as unsafe *Expr),
        )

        var args = ListBuilder<unsafe *Expr>(self.sc->ctx)
        args.push(
            self._addr(
                at,
                self._field_of(
                    at,
                    self_p,
                    first,
                    LowerTargets::object_arena_field(),
                ),
                true,
            ),
        )

        args.freeze_into(&call->args)
        var unsafe *vd = VariableDecl::create(
            self.sc->ctx,
            at,
            self._synth.fresh(at, "arena_scope"),
            StorageClass::Var,
        )

        vd->init        = unsafe (call as unsafe *Expr)
        vd->is_implicit = true
        return unsafe (DeclStmt::create(self.sc->ctx, at, unsafe (vd as unsafe *Decl)) as unsafe *Stmt)
    }
}
