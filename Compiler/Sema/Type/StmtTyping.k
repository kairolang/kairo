/// --- The Kairo Project ----------------------- Sema/Type/StmtTyping.k --- ///
///
///   \brief The statement half: function frames, `return` against the
///          signature, declarations that infer, conditions that must be bool,
///          binders that take their type from what they iterate or destructure.
///
///   \detail
///     This is what "TypeChecking" was going to be. A statement never has a
///     type; it decides what its expressions are expected to be and hands
///     that down. The RAV drives the walk; every override here calls
///     `type_of` with the right expected type BEFORE the base traversal
///     could reach the expression with none.
///
///     Frames: one per function or closure body, carrying the declared
///     return type (or null when inferring) and the join of the returns seen
///     so far. `fn_return_type(f)` is the demand entry other mixins use for a
///     callee: declared -> canonical; `-> !` -> Never; expression-bodied with
///     no annotation -> typed on demand under a rstate cycle guard, so a
///     recursive `fn f() = f()` is one diagnostic rather than a stack.
///
///     Inferred slots receive the canonical node itself. A canonical is
///     self-canonical, so every consumer that reads `->canonical` is
///     unchanged, and no node is allocated.
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
import AST::Context::DeclContext::DeclContext
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::{
    decl_instantiated_from,
    decl_is_imported,
    decl_is_instance,
    param_is_type_pack,
}
import AST::Kind::ExprKind::ExprKind
import AST::LangItems::{
    LangAttrs,
    LowerTargets,
    WellKnownType,
    entry_point_name,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    QUAL_CONST,
    QUAL_VOLATILE,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,
    EnumDecl,
    EnumVariantDecl,
    FieldDecl,
    FnBodyKind,
    FunctionDecl,
    IntConst,
    ParamDecl,
    VariableDecl,
    pointer_shorthand_spelling,
}
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    ClosureExpr,
    RangeExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    ChainExpr,
    NamedIdentExpr,
    NullLiteralExpr,
}
import AST::Node::Statements
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, FixedArrayType, FunctionPointerType, MapType,
    NullableType,     PointerType,      SetType,        TupleType,           TypeOfType,
    VectorType,
}
import AST::ParamMode::ParamMode
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Diagnostic::NoteText::named_declared_here
import Location::SourceRange::SourceRange
import Sema::Check::ConstEval::ConstEval
import Sema::Lower::LowerSynth::LowerSynth
import Sema::Resolve::NameLookup::NameLookup
import Sema::Resolve::ResolutionState::ResolveState
import Sema::Type::OverloadResolution::{
    ArgInfo,
    OvlOutcome,
}
import Token::TokenKind::TokenKind

/// The first name in a default argument that binds to a parameter of \p fn,
/// `self` included. A default is evaluated by a nullary thunk (CallLowering),
/// so it has no parameters to read; this is a language rule, not a lowering
/// limit.
pub class DefaultRefScan derives RecursiveASTVisitor<DefaultRefScan> {
    pub var fn_decl: unsafe *FunctionDecl   = &null
    pub var hit:     unsafe *NamedIdentExpr = &null

    fn visit_named_ident_expr(self, n: unsafe *NamedIdentExpr) -> bool {
        if self.hit != &null || n == &null {
            return true
        }

        var unsafe *p = dyn_cast<ParamDecl>(n->resolved_decl)
        if p == &null {
            return true
        }

        for var i: usize = 0; i < self.fn_decl->params.size(); ++i {
            if self.fn_decl->params[i] == p {
                self.hit = n
                return true
            }
        }

        return true
    }
}

pub class TyperFrame {
    pub var fn_decl:          unsafe *FunctionDecl = &null ///< null for a closure.
    pub var closure:          unsafe *ClosureExpr  = &null
    pub var declared:         unsafe *Type         = &null ///< return type, null = infer.
    pub var inferred:         unsafe *Type         = &null ///< join of `return e` seen so far.
    pub var saw_return_value: bool                 = false
    pub var saw_bare_return:  bool                 = false
    /// `-> yield T`: `declared` is the canonical, which carries cv only and
    /// drops the qualifier, so the frame keeps it here.
    pub var is_generator: bool = false
    /// A generator's element: `T` of its Yield<T>, what each `yield` is
    /// typed against. Null otherwise, and null for a closure (which cannot
    /// yield yet).
    pub var yield_elem: unsafe *Type = &null
    fn TyperFrame(self) { }
}

/// Derives the RAV rather than sitting beside it: these traverse_ methods are
/// OVERRIDES, and two sibling bases declaring the same name is an ambiguity in
/// the emitted C++, not an override. ExprTyper therefore reaches the visitor
/// through this mixin and does not derive it a second time.
// TODO(DUCK-GENERIC): T uses arg_info, call_result_type, check_convertible, conv, ded_scratch, discr_enum, dispatch_stmt, fail, flow, frames, mark_list_storage, match_arm_enter, ... (30). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> StmtTyping derives RecursiveASTVisitor<T> {
    @move
    fn StmtTyping(self, other: Self) = default
    fn StmtTyping(self) = default
    priv inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    /// # frames

    fn push_fn_frame(self, f: unsafe *FunctionDecl, declared: unsafe *Type) {
        var fr = TyperFrame()
        fr.fn_decl      = f
        fr.declared     = declared
        fr.is_generator = f != &null && self.dyn()->tu.is_generator_return(f->return_type)
        if f != &null {
            fr.declared = self._effect_inner(f->return_type, declared)
        }

        if fr.is_generator
            && declared != &null
            && self.dyn()->tu.is_lang(declared, WellKnownType::Yield) {
            var args = self.dyn()->tu.record_args(declared)
            if args.size() > 0 {
                fr.yield_elem = args[0]
            }
        }

        self.dyn()->frames.push_back(fr)
        self.dyn()->flow.enter() // a body starts knowing nothing about any nullable.
    }

    fn push_closure_frame(self, c: unsafe *ClosureExpr, declared: unsafe *Type) {
        var fr = TyperFrame()
        fr.closure      = c
        fr.declared     = declared
        fr.is_generator = c != &null && self.dyn()->tu.is_generator_return(c->return_type)
        if c != &null {
            fr.declared = self._effect_inner(c->return_type, declared)
        }

        self.dyn()->frames.push_back(fr)
        // A closure may run anywhere: what it captures is Maybe inside it
        // (Compiler/Spec/Nullables.md#aliases-and-closures), which a fresh state says.
        self.dyn()->flow.enter(c)
    }

    /// `-> async T` canonicalizes to Future<T> (TypeResolve), but the body
    /// `return`s a T: the Future is what the CALLER sees. Unwrap it for the
    /// frame. A generator keeps Yield<T>; its returns are bare and the
    /// is_generator branch owns them.
    priv fn _effect_inner(self, written: unsafe *Type, declared: unsafe *Type) -> unsafe *Type {
        if written == &null || declared == &null {
            return declared
        }

        if !written->is_async() {
            return declared
        }

        if !self.dyn()->tu.is_lang(declared, WellKnownType::Future) {
            return declared
        }

        var args = self.dyn()->tu.record_args(declared)
        return if (args.size() > 0) => (args[0]) else => declared
    }

    fn pop_frame(self) {
        if !self.dyn()->frames.empty() {
            self.dyn()->frames.pop_back()
            self.dyn()->flow.leave()
        }
    }

    fn cur_frame(self) -> unsafe *TyperFrame {
        if self.dyn()->frames.empty() {
            return &null
        }

        return &self.dyn()->frames[self.dyn()->frames.size() - 1]
    }

    fn frame_inferred_return(self) -> unsafe *Type {
        var unsafe *fr = self.cur_frame()
        if fr == &null {
            return &null
        }

        if fr->inferred == &null && !fr->saw_return_value {
            return self.dyn()->tu.builtin(BuiltinKind::Void)
        }

        return fr->inferred
    }

    fn in_unsafe(self) -> bool {
        if self.dyn()->unsafe_depth > 0 {
            return true
        }

        var unsafe *fr = self.cur_frame()
        if fr != &null && fr->fn_decl != &null && fr->fn_decl->is_unsafe() {
            return true
        }

        return false
    }

    /// # return type on demand

    /// PRE: T ran. Declared -> canonical; `!` -> Never; expr-bodied without an
    /// annotation -> typed now under a cycle guard; a foreign one is read.
    fn fn_return_type(self, f: unsafe *FunctionDecl) -> unsafe *Type {
        if f == &null {
            return &null
        }

        if f->is_noreturn {
            return self.dyn()->tu.builtin(BuiltinKind::Never)
        }

        if f->return_type != &null {
            return f->return_type->canonical
        }

        if f->body_kind != FnBodyKind::Expr {
            return self.dyn()->tu.builtin(BuiltinKind::Void)
        }

        if f->body_expr == &null {
            return self.dyn()->tu.builtin(BuiltinKind::Void)
        }

        if self.dyn()->tu.is_foreign(f) {
            // DAG order: its own TU typed it and wrote the slot. Null here means
            // it failed there, and that TU reported it.
            return if (f->body_expr->type_ != &null) => (f->body_expr->type_) else => &null
        }

        var st = self.dyn()->sc->rstate.decl_state(f)
        if st == ResolveState::Resolved {
            return if (f->return_type != &null) => (f->return_type->canonical)
                   else => f->body_expr->type_
        }

        if st == ResolveState::Errored {
            return &null
        }

        if st == ResolveState::InProgress {
            self.dyn()->sc->diag->report(
                DiagID::SC043E,
                f->range.start,
                f"cannot infer the return type of '{self.dyn()->tu.decl_name((unsafe (f as unsafe *Decl)))}': its body refers to itself; annotate the return type",
            ).first(f->range)->emit()
            f->poison()
            self.dyn()->sc->rstate.fail_decl(f)
            return &null
        }

        if !self.dyn()->sc->rstate.begin_decl(f, f->range) {
            self._inference_capped(unsafe (f as unsafe *Decl))
            return &null
        }

        self.push_fn_frame(f, &null)
        var saved_unsafe = self.dyn()->unsafe_depth
        self.dyn()->unsafe_depth = 0
        var t = self.dyn()->type_of(f->body_expr, &null)
        self.dyn()->unsafe_depth = saved_unsafe
        self.pop_frame()

        var ok = t != &null && !f->body_expr->is_poisoned()
        if ok { // inferred slot := canonical.
            f->return_type = canon_unqual(t)
        }

        self.dyn()->sc->rstate.finish_decl(f, ok || !f->body_expr->is_poisoned())
        return t
    }

    /// The demand to infer \p d met a full resolution stack (begin_decl's
    /// only refusal once Unresolved is tested). Returning null quietly here
    /// left every declaration that waited on \p d untyped with no error at
    /// all, and the program accepted. Failed, so the chain above it stays
    /// quiet behind this one report.
    priv fn _inference_capped(self, d: unsafe *Decl) {
        var nm  = self.dyn()->tu.decl_name(d)
        var cap = self.dyn()->sc->rstate.max_depth()
        self.dyn()->sc->diag->report(
            DiagID::SC001E,
            d->range.start,
            f"inferring the type of '{nm}' exceeded the nested scope limit ({cap})",
        ).first(d->range)->fix(
            f"write the type of '{nm}' out, or raise the limit with --cmax-scope-depth",
        )->emit()
        d->poison()
        self.dyn()->sc->rstate.fail_decl(d)
    }

    /// A variable's canonical, inferring a file-scope `var x = e` on demand
    /// when a use precedes its declaration in walk order.
    fn var_type(self, v: unsafe *VariableDecl) -> unsafe *Type {
        if v == &null {
            return &null
        }

        if v->type_ != &null {
            if v->type_->canonical == &null {
                return self.resolve_typeof_type(v->type_)
            }

            return v->type_->canonical
        }

        if v->init == &null {
            return &null
        }

        if self.dyn()->tu.is_foreign(v) {
            return v->init->type_
        }

        var st = self.dyn()->sc->rstate.decl_state(v)
        if st == ResolveState::Errored {
            return &null
        }

        if st == ResolveState::InProgress {
            self.dyn()->sc->diag->report(
                DiagID::SC043E,
                v->range.start,
                f"cannot infer the type of '{self.dyn()->tu.decl_name((unsafe (v as unsafe *Decl)))}': its initializer refers to itself",
            ).first(v->range)->emit()
            v->poison()
            self.dyn()->sc->rstate.fail_decl(v)
            return &null
        }

        if st == ResolveState::Resolved {
            return if (v->type_ != &null) => (v->type_->canonical) else => &null
        }

        if !self.dyn()->sc->rstate.begin_decl(v, v->range) {
            self._inference_capped(unsafe (v as unsafe *Decl))
            return &null
        }

        if !self._shorthand_has_source(v) {
            self.dyn()->sc->rstate.finish_decl(v, false)
            return &null
        }

        // Typed on demand from wherever the use is: the initializer must
        // not see that body's nullness facts.
        self.dyn()->flow.enter()
        var t = self.dyn()->type_of(v->init, &null)
        self.dyn()->flow.leave()
        if t == &null {
            self._reject_type_value(v)
        }

        self.dyn()->mark_list_storage(v->init)
        self._reject_array_copy(v, t)
        if t != &null {
            v->type_ = self._shorthand_type(v, t)
        }

        self.dyn()->sc->rstate.finish_decl(v, t != &null)
        return if (t != &null && v->nullable_shorthand) => (v->type_) else => t
    }

    /// A written `typeof e`: the type of \p e as `var y = e` would
    /// infer it (a copy: top-level cv and a C++ reference dropped), with the
    /// cv written on the typeof itself. T cannot do this -- it runs before
    /// any expression has a type -- so the node leaves T with no canonical
    /// and is filled here, where the declaration it types is typed (the
    /// walk, or a use that demands the variable first). Only a variable's
    /// whole declared type comes here; anywhere else is _check_typeof_types.
    /// \return the canonical, or null (reported, poisoned).
    fn resolve_typeof_type(self, t: unsafe *Type) -> unsafe *Type {
        if t == &null {
            return &null
        }

        if t->canonical != &null {
            return t->canonical
        }

        if t->is_poisoned() || !isa<TypeOfType>(t) {
            return &null
        }

        var unsafe *tt = cast<TypeOfType>(t)
        var        st  = self.dyn()->sc->rstate.type_state(t)
        if st == ResolveState::InProgress {
            // `var x: typeof x`: the operand needs the type it is to name.
            self.dyn()->sc->diag->report(
                DiagID::SC043E,
                t->range.start,
                "cannot take 'typeof' of an expression whose type depends on this declaration's own type",
            ).first(t->range)->emit()
            t->poison()
            return &null
        }

        if tt->expr == &null {
            t->poison()
            return &null
        }

        self.dyn()->sc->rstate.set_type_state(t, ResolveState::InProgress)
        // The operand is never evaluated, and its type is the declared one:
        // no nullness fact of the surrounding body narrows it.
        self.dyn()->flow.enter()
        var et = self.dyn()->type_of(tt->expr, &null)
        self.dyn()->flow.leave()
        if t->is_poisoned() {
            self.dyn()->sc->rstate.set_type_state(t, ResolveState::Errored)
            return &null
        }

        if et == &null || tt->expr->is_poisoned() {
            if !tt->expr->is_poisoned() {
                self.dyn()->sc->diag->report(
                    DiagID::SC270E,
                    t->range.start,
                    "the type of this expression is not known until the generic is instantiated; 'typeof' of it is not supported yet, write the type out",
                ).first(t->range)->emit()
            }

            t->poison()
            self.dyn()->sc->rstate.set_type_state(t, ResolveState::Errored)
            return &null
        }

        var c     = self._cxx_referee(canon_unqual(et))
        var q: u8 = 0
        if t->is_const() {
            q = q | QUAL_CONST
        }

        if t->is_volatile() {
            q = q | QUAL_VOLATILE
        }

        if q != 0 {
            c = self.dyn()->sc->types->qualified(c, q)
        }

        t->canonical = c
        tt->resolved = c
        // T marked the node instantiation-dependent while its type was
        // unknown; a concrete answer is not, or a non-generic body would
        // carry a "dependent" declaration into template-only paths.
        if !(c->is_dependent() || c->is_instantiation_dependent()) {
            t->type_flags.clear(Type::TypeFlags::IsInstantiationDependent)
        }

        self.dyn()->sc->rstate.set_type_state(t, ResolveState::Resolved)
        return c
    }

    /// `var i = P` / `var info = typeof x`: an initializer that names a
    /// type (typeof as a value is a TypeInfo) types to nothing
    /// by design, so the variable would reach codegen with no type.
    /// ExprTyper::reject_type_value reports it. \return reported.
    priv fn _reject_type_value(self, v: unsafe *VariableDecl) -> bool {
        if v == &null || v->init == &null || v->init->is_poisoned() {
            return false
        }

        if !self.dyn()->reject_type_value(v->init) {
            return false
        }

        v->poison()
        return true
    }

    /// The inferred slot of `var g = f` (a named function) or `var g = fn
    /// (...) {...}` (a closure that captures nothing): the `fn` value, not
    /// the raw `unsafe fn` the expression is typed as (ExprTyper::
    /// fn_pointer_type, ControlTyping::type_closure). Nobody wrote `unsafe`,
    /// and `g = <a capturing closure>` later must still be legal. A value
    /// that IS raw by its declaration (a C struct's callback field, an
    /// `unsafe fn` variable) keeps its type.
    priv fn _fn_value_decay(self, init: *Expr, t: unsafe *Type) -> unsafe *Type {
        var unsafe *c = canon_unqual(t)
        if c == &null || (!isa<FunctionPointerType>(c)) || !cast<FunctionPointerType>(c)->is_raw {
            return t
        }

        var e        = self.dyn()->tu.strip_parens(init)
        var names_fn = isa<ClosureExpr>(e)
        var ni       = dyn_cast<NamedIdentExpr>(e)
        if ni != &null && ni->resolved_decl != &null && isa<FunctionDecl>(ni->resolved_decl) {
            names_fn = true
        }

        var ch = dyn_cast<ChainExpr>(e)
        if ch != &null && ch->steps.size() > 0 {
            var last = ch->steps.get(ch->steps.size() - 1)
            if last->resolved_decl != &null && isa<FunctionDecl>(last->resolved_decl) {
                names_fn = true
            }
        }

        if !names_fn {
            return t
        }

        return self.dyn()->sc->types->fn_with_raw(c, false)
    }

    /// The inferred slot of `var x = e` / `var x? = e`. The shorthand wraps
    /// ONE level and never a second: `typeof(e)` is already the nullable
    /// when `e` is one (`var b? = find()` with `find() -> i32?` is `i32?`,
    /// not `(i32?)?`), because the shorthand says "this may be null", not
    /// "add a level". A deliberate `(T?)?` is still writable as a type.
    priv fn _shorthand_type(self, v: *VariableDecl, t: unsafe *Type) -> unsafe *Type {
        var unsafe *c = canon_unqual(t)
        if v->pointer_depth > 0 {
            self._check_pointer_shorthand(v, self._cxx_referee(c))
        }

        // A copy, as `typeof e` already reads it and as C++'s `auto` does:
        // `var c = v.at(i)` is the value `v.at(i)` refers to, never the
        // C++ reference (`unsafe *DirEntry&` from an unordered_map's
        // `op []` failed to unify with a plain `unsafe *DirEntry` arm).
        if !v->nullable_shorthand {
            return self._cxx_referee(c)
        }

        // `var *p? = ptrs[0]` of a `vector<*Node?>`: the `?` is about the
        // value the reference refers to, and a nullable reference is no
        // type at all, so the slot is the referee's nullable -- `*Node?`,
        // already one, not `(*Node?&)?`.
        return self._nullable_once(self._cxx_referee(c))
    }

    /// \p c, or what it refers to when it is a C++ reference: the stars of
    /// `var *p = ptrs.at(0)` state the pointer `ptrs.at(0)` refers to
    /// (`*Node&`), as for any other read of a reference.
    priv fn _cxx_referee(self, c: unsafe *Type) -> unsafe *Type {
        if c == &null {
            return c
        }

        if isa<CXXLValueRefType>(c) {
            return canon_unqual(cast<CXXLValueRefType>(c)->referee)
        }

        if isa<CXXRValueRefType>(c) {
            return canon_unqual(cast<CXXRValueRefType>(c)->referee)
        }

        return c
    }

    /// `var *y = e` (Compiler/Spec/Nullables.md#declaration-shorthands): the stars state the pointer depth of
    /// `e`'s type, and `unsafe` its outermost pointer's safety. A marker,
    /// never a conversion: `y` is `typeof(e)` whatever is written, and a
    /// wrong marker is an error with a fix-it but does NOT poison `y`, so
    /// its uses type as they would without the stars and nothing cascades.
    ///
    /// Dependent types are decided on the type as written, like `var x? =
    /// t` (1.6): `p: **T` has depth 2 and `var *q = p` is wrong even though
    /// no `T` makes it right. What is NOT decidable is a pointer prefix that
    /// ends in an opaque parameter: `var **q = p` with `p: *T` is right for
    /// `T = *U` and wrong for `T = i32`. Such a decl is accepted when it has
    /// at least the visible stars, and nothing re-checks it per instance
    /// (bodies are typed once, on the dependent type): deferred means
    /// unchecked.
    priv fn _check_pointer_shorthand(self, v: *VariableDecl, c: unsafe *Type) {
        if c == &null {
            return
        }

        var nm    = self.dyn()->tu.decl_name(v)
        var wrote = pointer_shorthand_spelling(v->pointer_depth, v->pointer_unsafe)

        // `var *y = e` with `e: (*T)?`: the value may be null and nothing
        // on the name says so. The `?` is what is missing, not a star.
        var unsafe *base = c
        var        inner = self.dyn()->tu.nullable_inner(c)
        if inner != &null {
            base = canon_unqual(inner)
        }

        var shape        = self.dyn()->tu.pointer_shape(base)
        var depth        = shape.depth
        var outer_unsafe = shape.outer_unsafe
        var leaf         = shape.leaf
        var opaque       = leaf != &null && self._is_opaque_dependent(leaf)

        var depth_ok = v->pointer_depth == depth || opaque && v->pointer_depth > depth
        if inner != &null && !v->nullable_shorthand {
            // The `?` and the stars are ONE fix when both are wrong: `var
            // unsafe *x = <*T?>` wants `*x?`. Two separate fix-its, the `?`
            // one restating the written `unsafe *`, left a tool that applies
            // only the first with a nullable RAW pointer.
            var stars_ok = depth == 0 || depth_ok && v->pointer_unsafe == outer_unsafe
            var fixd     = if (depth_ok) => (v->pointer_depth) else => depth
            var want0 = if (stars_ok) => (wrote)
                        else => pointer_shorthand_spelling(fixd, outer_unsafe)
            var b = self.dyn()->sc->diag->report(
                DiagID::SC266E,
                v->name.range.start,
                f"'{wrote}{nm}' is initialized with a nullable '{self.dyn()->tu.str(c)}'; write '{want0}{nm}?' so the declaration says it may be null",
            )

            b.first(v->name.range)
            b.second(v->init->range, f"this has type '{self.dyn()->tu.str(c)}'")
            if !stars_ok {
                b.fix(v->pointer_range, want0, f"write '{want0}'")
            }

            b.insert(v->name.range.end, "?", "mark the binding nullable")
            b.emit()
            if !stars_ok {
                return
            }
        }

        if depth == 0 && opaque { // `var *y = t`, `t: T`: undecidable here.
            return
        }

        if depth == 0 {
            var b = self.dyn()->sc->diag->report(
                DiagID::SC266E,
                v->pointer_range.start,
                f"'{wrote}{nm}' declares a pointer, but its initializer has type '{self.dyn()->tu.str(c)}', which is not one",
            )

            b.first(v->pointer_range)
            b.second(v->init->range, f"this has type '{self.dyn()->tu.str(c)}'")
            b.remove(v->pointer_range, "remove the shorthand")
            b.emit()
            return
        }

        if depth_ok && v->pointer_unsafe == outer_unsafe {
            return
        }

        // One fix-it rewrites both the count and the safety: what the
        // initializer's type spells (the visible stars when it is opaque).
        var want_depth        = if (depth_ok) => (v->pointer_depth) else => depth
        var want              = pointer_shorthand_spelling(want_depth, outer_unsafe)
        var msg:       string = ""
        if !depth_ok {
            msg = f"'{wrote}{nm}' states a pointer of depth {v->pointer_depth}, but its initializer is '{self.dyn()->tu.str(c)}', a pointer of depth {depth}; write '{want}{nm}'"
        } else if outer_unsafe {
            msg = f"'{wrote}{nm}' declares a safe pointer, but its initializer is the unsafe pointer '{self.dyn()->tu.str(c)}'; write '{want}{nm}'"
        } else {
            msg = f"'{wrote}{nm}' declares an unsafe pointer, but its initializer is the safe pointer '{self.dyn()->tu.str(c)}'; write '{want}{nm}'"
        }

        var b = self.dyn()->sc->diag->report(DiagID::SC266E, v->pointer_range.start, msg)
        b.first(v->pointer_range)
        b.second(v->init->range, f"this has type '{self.dyn()->tu.str(c)}'")
        b.fix(v->pointer_range, want, f"write '{want}'")
        b.emit()
    }

    /// A dependent type with no visible shape: a generic parameter (or a
    /// type computed from one) that some argument could make a pointer.
    /// A dependent record, tuple, array or function pointer is never one.
    priv fn _is_opaque_dependent(self, t: unsafe *Type) -> bool {
        if t == &null || !t->is_dependent() {
            return false
        }

        if isa<RecordType>(t) || isa<TupleType>(t) || isa<FixedArrayType>(t) {
            return false
        }

        if isa<VectorType>(t) || isa<MapType>(t) || isa<SetType>(t) {
            return false
        }

        if isa<FunctionPointerType>(t) || isa<NullableType>(t) {
            return false
        }

        return true
    }

    /// `T` -> `T?`, `T?` -> `T?`: what every `?` shorthand (declaration or
    /// binder) makes of the type it infers.
    priv fn _nullable_once(self, c: unsafe *Type) -> unsafe *Type {
        if c == &null || self.dyn()->tu.nullable_inner(c) != &null {
            return c
        }

        return self.dyn()->sc->types->nullable(c)
    }

    /// `var x? = null` (or `&null`): the shorthand infers the payload from
    /// the initializer, and a null literal has none. Caught before typing
    /// the literal so the error names the shorthand, not the generic
    /// "annotate the target" SC076E that `type_null_literal` would give;
    /// same code, it is the same mistake (nothing to infer from).
    priv fn _shorthand_has_source(self, v: unsafe *VariableDecl) -> bool {
        if !v->nullable_shorthand || v->init == &null {
            return true
        }

        var e = self.dyn()->tu.strip_parens(v->init)
        if e == &null || !isa<NullLiteralExpr>(e) {
            return true
        }

        var nm  = self.dyn()->tu.decl_name(v)
        var lit = if (cast<NullLiteralExpr>(e)->is_ref) => ("&null") else => "null"
        var b = self.dyn()->sc->diag->report(
            DiagID::SC076E,
            v->init->range.start,
            f"nothing to infer the nullable's type from: '{nm}?' takes its type from the initializer, and '{lit}' has none",
        )

        b.first(v->init->range)
        b.second(v->range, f"declare the type instead: 'var {nm}: T? = null'")
        b.emit()
        v->poison()
        return false
    }

    priv fn _reject_array_return(self, f: unsafe *FunctionDecl, t: unsafe *Type) {
        var unsafe *c = canon_unqual(t)
        if c == &null || !isa<FixedArrayType>(c) {
            return
        }

        self.dyn()->sc->diag->report(
            DiagID::SC044E,
            f->range.start,
            f"'{self.dyn()->tu.decl_name((unsafe (f as unsafe *Decl)))}' returns an array; an array is not returned by value, return '[T]' or fill an {LangAttrs::quoted(LangAttrs::param_inout())} parameter",
        ).first(f->name.range)->emit()
    }

    /// An array is initialized from a list literal and from nothing else
    /// (LiteralTyping::reject_array_copy, shared with a field initializer).
    priv fn _reject_array_copy(self, v: unsafe *VariableDecl, t: unsafe *Type) {
        self.dyn()->reject_array_copy(v->init, t)
    }

    /// # traversal overrides (scope)

    fn traverse_function_decl(self, n: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        if n == &null {
            return n
        }

        if n->is_poisoned() {
            return n
        }

        // signature pieces first: defaults against their param types. A
        // default may not read another parameter or `self`, and may not be a
        // slice literal (its thunk would return a view of a dead array).
        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = n->params[i]
            if p == &null || p->default_val == &null {
                continue
            }

            var unsafe *pt = if (p->type_ != &null) => (p->type_->canonical) else => &null
            self.dyn()->push_null_target(p->default_val, p->type_, p)
            self.dyn()->type_of(p->default_val, pt)
            self.dyn()->pop_null_target()
            if self.dyn()->reject_slice_literal(p->default_val, "used as a default argument") {
                continue
            }

            if pt != &null {
                self.dyn()->check_convertible(p->default_val, pt)
            }

            var scan = DefaultRefScan()
            scan.fn_decl = n
            scan.dispatch_expr(p->default_val)
            if scan.hit != &null {
                var unsafe *rp = cast<ParamDecl>(scan.hit->resolved_decl)
                var what = if (rp->is_self) => ("'self'")
                           else => f"parameter '{self.dyn()->tu.param_name(rp)}'"
                self.dyn()->fail(
                    scan.hit,
                    DiagID::SC106E,
                    f"a default argument cannot refer to {what}; a default is evaluated with no access to the call's other arguments",
                )
            }
        }

        // `[T; N]` is a C array: by value it would decay to a pointer and
        // pass by reference. `const` and `@inout` say what is meant.
        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = n->params[i]
            if p == &null || p->is_self || p->type_ == &null {
                continue
            }

            var unsafe *pc = canon_unqual(p->type_->canonical)
            if pc == &null || !isa<FixedArrayType>(pc) {
                continue
            }

            if p->is_const || p->mode != ParamMode::Value {
                continue
            }

            self.dyn()->sc->diag->report(
                DiagID::SC045E,
                p->range.start,
                f"parameter '{self.dyn()->tu.param_name(p)}' takes an array by value; write 'const', {LangAttrs::quoted(LangAttrs::param_inout())}, or take a slice",
            ).first(p->range)->emit()
        }

        self._stamp_no_unwind(n)

        // The generator fact, before anything reads it: the body's `yield`s
        // and `return`s below, then ReturnPathCheck and EmitIR. The WRITTEN
        // `-> yield T` decides, not the canonical Yield<T> (see
        // TypeUtil::is_generator_return).
        n->is_generator = self.dyn()->tu.is_generator_return(n->return_type)
        n->has_yield    = false
        if n->is_generator {
            self._check_generator_kind(n)
        }

        if n->requires_clause != &null {
            self.dyn()->type_of(n->requires_clause, self.dyn()->tu.builtin(BuiltinKind::Bool))
        }

        if n->where_clause != &null {
            self.dyn()->require_bool(n->where_clause, "a 'where' clause")
        }

        var declared: unsafe *Type = &null
        if n->return_type != &null {
            declared = n->return_type->canonical
        }

        if n->is_noreturn {
            declared = self.dyn()->tu.builtin(BuiltinKind::Never)
        }

        if n->return_type == &null && !n->is_noreturn && n->body_kind != FnBodyKind::Expr {
            declared = self.dyn()->tu.builtin(BuiltinKind::Void)
        }

        // An expression body abbreviates `{ return e }` (ExprBodyDesugar), so a
        // written return type types it exactly as that `return` would. Only
        // an unwritten one goes through the demand path, which owns the
        // inference slot; routing a declared one there too would make a
        // recursive call in the body read its own InProgress state (SC043E).
        if n->body_kind == FnBodyKind::Expr {
            if declared == &null {
                self.fn_return_type(n)
                if n->return_type != &null {
                    self._reject_array_return(n, n->return_type->canonical)
                }

                return n
            }

            self._reject_array_return(n, declared)
            if n->body_expr == &null {
                return n
            }

            self.push_fn_frame(n, declared)
            var saved_unsafe_e = self.dyn()->unsafe_depth
            self.dyn()->unsafe_depth = 0
            var unsafe *want = self.cur_frame()->declared
            var        bt    = self.dyn()->type_of(n->body_expr, want)
            self.dyn()->reject_slice_literal(n->body_expr, "returned from a function")
            if want != &null && self.dyn()->tu.is_void(want) {
                // desugars to `return e;` in a void function: legal C++ only
                // for a void (or never-returning) `e`.
                if bt != &null && !self.dyn()->tu.is_void(bt) && !self.dyn()->tu.is_never(bt) {
                    self.dyn()->sc->diag->report(
                        DiagID::SC050E,
                        n->body_expr->range.start,
                        f"an expression body of type '{self.dyn()->tu.str(bt)}' in a function returning 'void'",
                    ).first(n->body_expr->range)->emit()
                }
            } else if want != &null {
                self.dyn()->check_convertible(n->body_expr, want)
            }

            self.dyn()->unsafe_depth = saved_unsafe_e
            self.pop_frame()
            return n
        }

        self._reject_array_return(n, declared)

        self.push_fn_frame(n, declared)
        var saved_unsafe = self.dyn()->unsafe_depth
        self.dyn()->unsafe_depth = 0
        if n->body_block != &null {
            self.dyn()->dispatch_stmt(n->body_block)
        }

        self.dyn()->unsafe_depth = saved_unsafe
        self.pop_frame()
        return n
    }

    /// Whether the function is spelled `noexcept` (FunctionDecl::no_unwind),
    /// decided once for the whole redeclaration chain, because C++ requires
    /// every declaration of a function to agree and an attribute may be
    /// written on only one of them:
    ///   - `@no_unwind` on any link: noexcept, even under -funwind;
    ///   - else `@unwind` on any link, or -funwind: not noexcept, so a C++
    ///     exception from a callee passes through this frame;
    ///   - else noexcept: a C++ exception reaching the frame terminates.
    /// A function with ffi linkage, or one imported from a header, is never
    /// stamped: it is C/C++'s own declaration, whose exception spec its
    /// header already states. Both attributes on one function is SC001E.
    /// Names probed, never interned: a name this file never spelled is on
    /// no decl.
    priv fn _stamp_no_unwind(self, n: unsafe *FunctionDecl) {
        var unsafe *head = n->first_decl()
        if n->has_ffi_linkage() || n->clang_decl != &null {
            return
        }

        var k_no = self.dyn()->sc->imm_table()->find_ident(LangAttrs::no_unwind())
        var k_un = self.dyn()->sc->imm_table()->find_ident(LangAttrs::unwind())
        var        no_at: unsafe *FunctionDecl = &null
        var        un_at: unsafe *FunctionDecl = &null
        var unsafe *cur                        = head
        while true {
            if k_no != u32::MAX && cur->has_attribute_named(k_no) && no_at == &null {
                no_at = cur
            }

            if k_un != u32::MAX && cur->has_attribute_named(k_un) && un_at == &null {
                un_at = cur
            }

            cur = cur->next_in_chain()
            if cur == head {
                break
            }
        }

        // Reported once, from the link that carries `@unwind`.
        if no_at != &null && un_at == n {
            var nm = self.dyn()->tu.decl_name(n)
            var b = self.dyn()->sc->diag->report(
                DiagID::SC267E,
                n->range.start,
                f"'{nm}' is marked both {LangAttrs::quoted(LangAttrs::unwind())} and {LangAttrs::quoted(LangAttrs::no_unwind())}",
            )

            b.first(n->range)
            b.note(
                DiagCode(DiagID::SC267N),
                no_at->range.start,
                LangAttrs::quoted(LangAttrs::no_unwind()) + " is here; it wins: the function is 'noexcept'",
            )->first(no_at->range)
            b.emit()
        }

        var spell = no_at != &null || un_at == &null && !self.dyn()->sc->opts.unwind_all
        cur = head
        while true {
            cur->no_unwind = spell
            cur            = cur->next_in_chain()
            if cur == head {
                break
            }
        }
    }

    /// The functions that cannot be generators, each for a reason C++ makes
    /// fatal or Kairo makes meaningless. One error, at the name.
    priv fn _check_generator_kind(self, n: unsafe *FunctionDecl) {
        var why = ""
        if n->is_operator && n->op_token.size() > 0 && n->op_token[0].kind == TokenKind::KwFinally {
            why = "a destructor cannot be a generator; it runs to completion when the object dies"
        } else if self._is_ctor(n) {
            why = "a constructor cannot be a generator; it returns the object it builds, not a sequence"
        } else if self._is_main(n) {
            why = "'main' cannot be a generator; it returns the process's exit status"
        } else if n->ffi_c_variadic {
            why = "a C-variadic function cannot be a generator; its '...' arguments do not outlive the call"
        } else if n->is_noreturn {
            why = "a function returning '!' cannot be a generator; a generator ends"
        }

        if why.size() == 0 {
            return
        }

        var at = if (n->is_operator) => (n->range) else => n->name.range
        self.dyn()->sc->diag->report(DiagID::SC112E, at.start, why).first(at)->emit()
    }

    /// A method named after the type it is declared in. Operators have no
    /// name token to compare.
    priv fn _is_ctor(self, f: unsafe *FunctionDecl) -> bool {
        if f->is_operator || !f->is_method() {
            return false
        }

        var unsafe *dc = f->semantic_dc
        if dc == &null || !dc->is_type_scope() || dc->dc_owner == &null {
            return false
        }

        return self.dyn()->tu.decl_name(f) == self.dyn()->tu.decl_name(dc->dc_owner)
    }

    /// A free function named `main` outside any type. Whether this TU is the
    /// entry is codegen's question; a generator `main` is wrong in any TU.
    priv fn _is_main(self, f: unsafe *FunctionDecl) -> bool {
        if f->is_operator || f->is_method() {
            return false
        }

        var unsafe *dc = f->semantic_dc
        if dc != &null && dc->is_type_scope() {
            return false
        }

        return self.dyn()->tu.decl_name(f) == entry_point_name()
    }

    fn traverse_field_decl(self, n: unsafe *FieldDecl) -> unsafe *FieldDecl {
        if n == &null {
            return n
        }

        if n->init != &null {
            var unsafe *ft = if (n->type_ != &null) => (n->type_->canonical) else => &null
            self.dyn()->flow.enter() // a default runs in no body's state.
            self.dyn()->push_null_target(n->init, n->type_, n)
            self.dyn()->type_of(n->init, ft)
            self.dyn()->pop_null_target()
            self.dyn()->reject_slice_literal(n->init, "used as a field default")
            // An array field is initialized from a list literal, as a `var`
            // is (collections.mdx: an array is not copyable).
            var copied = ft != &null && self.dyn()->reject_array_copy(n->init, ft)
            if ft != &null && !copied {
                self.dyn()->check_convertible(n->init, ft)
            }

            self.dyn()->flow.leave()
        }

        return n
    }

    fn traverse_enum_variant_decl(self, n: unsafe *EnumVariantDecl) -> unsafe *EnumVariantDecl {
        if n == &null {
            return n
        }

        var unsafe *edc = n->semantic_dc
        var unsafe *ed = if (edc != &null) => (dyn_cast<EnumDecl>(edc->owner_decl())) else => &null
        var under: unsafe *Type = self.dyn()->tu.builtin(BuiltinKind::U32)
        if ed != &null && ed->underlying != &null && ed->underlying->canonical != &null {
            under = ed->underlying->canonical
        }

        var typed_ok = true
        if n->discriminant != &null {
            // An earlier variant named here is its integer value, not an enum
            // object; see ExprTyper::discr_enum.
            var saved = self.dyn()->discr_enum
            self.dyn()->discr_enum = if (ed != &null) => (NameLookup::representative(ed))
                                     else => &null
            self.dyn()->type_of(n->discriminant, under)
            typed_ok               = self.dyn()->check_convertible(n->discriminant, under)
            self.dyn()->discr_enum = saved
        }

        self._enum_variant_value(n, ed, under, typed_ok)
        for var i: usize = 0; i < n->payload.size(); ++i {
            self.traverse_field_decl(n->payload[i])
        }

        return n
    }

    /// Write EnumVariantDecl::value (this is its one writer): the
    /// discriminant's value, else the previous variant's plus one, else 0.
    /// The RAV visits `variants` in order, so the previous variant's slot,
    /// and every slot a discriminant may name, is already written. An
    /// imported C++ enum is clang's to number and is left alone.
    priv fn _enum_variant_value(self,
                                n:        unsafe *EnumVariantDecl,
                                ed:       unsafe *EnumDecl,
                                under:    unsafe *Type,
                                typed_ok: bool) {
        n->value = IntConst{}
        if ed != &null && ed->is_imported() {
            return
        }

        var ce  = ConstEval(self.dyn()->sc)
        var pos = (n->index as usize)
        if ed != &null {
            for var i: usize = 0; i < ed->variants.size(); ++i {
                if ed->variants[i] == n {
                    pos = i
                    break
                }
            }
        }

        if n->discriminant != &null {
            // X has already said what is wrong with a discriminant that
            // did not type or convert (SC075E for `256` in a u8 enum).
            if !typed_ok || n->discriminant->is_poisoned() {
                return
            }

            var c = ce.eval_discriminant(n->discriminant, ed, pos)
            if c.ok && ce.fits(c, under) {
                n->value = c
                self._reject_duplicate_value(n, ed, pos)
                return
            }

            if !c.ok && ce.quiet() {
                return
            }

            if !c.ok {
                var unsafe *at = if (ce.bad != &null) => (ce.bad) else => n->discriminant
                var why = if (ce.bad_why.size() > 0) => (ce.bad_why) else => "it is not a constant"
                var b = self.dyn()->sc->diag->report(
                    DiagID::SC128E,
                    at->range.start,
                    f"an enum discriminant must be an integer constant that fits '{self.dyn()->tu.str(under)}'; this one does not evaluate: {why}",
                )

                b.first(at->range)
                if ce.bad_decl != &null {
                    b.note(
                        ce.bad_decl->range.start,
                        named_declared_here(self.dyn()->tu.decl_name(ce.bad_decl)),
                    )
                }

                b.emit()
                return
            }

            self._report_value_misfit(ed, under, n->discriminant->range, f"it is {ce.str(c)}")
            return
        }

        if pos == 0 {
            n->value = ce.make(false, 0)
            return
        }

        var unsafe *prev = if (ed != &null && pos < ed->variants.size()) => (ed->variants[pos - 1])
                           else => &null
        if prev == &null || !prev->value.ok { // the previous one failed, and said so.
            return
        }

        var c = ce.add(prev->value, ce.make(false, 1))
        if ce.fits(c, under) {
            n->value = c
            self._reject_duplicate_value(n, ed, pos)
            return
        }

        // C++ rejects the enumerator too; say it here, where the cause is.
        self._report_value_misfit(
            ed,
            under,
            n->name.range,
            f"'{self.dyn()->tu.decl_name((unsafe (n as unsafe *Decl)))}' is one past '{self.dyn()->tu.decl_name((unsafe (prev as unsafe *Decl)))}', so it is {ce.str(c)}",
        )
    }

    /// SC130E when \p n, just given its value, repeats the value of a
    /// variant above it. A closed-enum match switches on the enumerators, so
    /// two with one value would be two case labels with one value, which
    /// C++ rejects in the emitted switch, and no arm could tell the two
    /// apart anyway. How either value came about does not matter: written,
    /// computed, or one past the previous. Only the variants above are
    /// compared, so each pair is reported once, at the later one. A variant
    /// whose value failed has no ok slot and takes no part; its error is
    /// already out. An ADT is not checked: its match switches on the tag,
    /// which is the variant's position (MatchLowering), never its value.
    priv fn _reject_duplicate_value(self,
                                    n:   unsafe *EnumVariantDecl,
                                    ed:  unsafe *EnumDecl,
                                    pos: usize) {
        if ed == &null || ed->is_adt || !n->value.ok {
            return
        }

        var lim = if (pos < ed->variants.size()) => (pos) else => ed->variants.size()
        for var i: usize = 0; i < lim; ++i {
            var unsafe *a = ed->variants[i]
            if a == &null || a == n || !a->value.ok || a->value.overflow {
                continue
            }

            if a->value.neg != n->value.neg || a->value.mag != n->value.mag {
                continue
            }

            var ce = ConstEval(self.dyn()->sc)
            var an = self.dyn()->tu.decl_name(a)
            var b = self.dyn()->sc->diag->report(
                DiagID::SC130E,
                n->name.range.start,
                f"'{self.dyn()->tu.decl_name((unsafe (n as unsafe *Decl)))}' has the same value as '{an}' ({ce.str(n->value)})",
            )

            b.first(n->name.range)
            b.note(DiagCode(DiagID::SC130N), a->name.range.start, named_declared_here(an))
            b.emit()
            return
        }
    }

    /// SC128E for a value outside the underlying type, with a note on
    /// where that type comes from.
    priv fn _report_value_misfit(self,
                                 ed:         unsafe *EnumDecl,
                                 under:      unsafe *Type,
                                 at:         SourceRange,
                                 const what: string) {
        var b = self.dyn()->sc->diag->report(
            DiagID::SC128E,
            at.start,
            f"an enum discriminant must be an integer constant that fits '{self.dyn()->tu.str(under)}'; {what}, which does not fit",
        )

        b.first(at)
        if ed != &null && ed->underlying != &null && ed->underlying->range.is_valid() {
            b.note(ed->underlying->range.start, "the underlying type is declared here")
        } else if ed != &null {
            b.note(
                ed->name.range.start,
                f"'{self.dyn()->tu.decl_name((unsafe (ed as unsafe *Decl)))}' has the default underlying type 'u32'; name a wider one with 'derives'",
            )
        }

        b.emit()
    }

    /// End \p n's resolution the way it began: with its own frame, or (at the
    /// depth cap) as a bare outcome.
    priv fn _release_local(self, n: unsafe *VariableDecl, framed: bool, ok: bool) {
        if framed {
            self.dyn()->sc->rstate.finish_decl(n, ok)
        } else {
            self.dyn()->sc->rstate.settle_decl(n, ok)
        }
    }

    fn traverse_variable_decl(self, n: unsafe *VariableDecl) -> unsafe *VariableDecl {
        if n == &null {
            return n
        }

        if n->is_poisoned() {
            return n
        }

        var declared: unsafe *Type = &null
        if n->type_ != &null {
            if n->type_->canonical == &null {
                self.resolve_typeof_type(n->type_)
            }

            if n->type_->is_poisoned() {
                if n->init != &null {
                    self.dyn()->type_of(n->init, &null)
                }

                return n
            }

            declared = n->type_->canonical
        }

        if n->init == &null {
            if n->type_ == &null {
                self.dyn()->sc->diag->report(
                    DiagID::SC046E,
                    n->range.start,
                    f"'{self.dyn()->tu.decl_name((unsafe (n as unsafe *Decl)))}' has neither a type nor an initializer",
                ).first(n->range)->emit()
                n->poison()
            }

            self.dyn()->flow.define(n) // `var x: T?` starts null.
            return n
        }

        var st = self.dyn()->sc->rstate.decl_state(n)
        if st != ResolveState::Unresolved { // demand-typed already.
            return n
        }

        // Refused only at the depth cap (Unresolved is tested above): the
        // walk types the declaration anyway, it needs no frame to, but then
        // it owns none to pop.
        var framed = self.dyn()->sc->rstate.begin_decl(n, n->range)
        if !self._shorthand_has_source(n) {
            self._release_local(n, framed, false)
            return n
        }

        self.dyn()->push_null_target(n->init, n->type_, n)
        var t = self.dyn()->type_of(n->init, declared)
        self.dyn()->pop_null_target()
        self.dyn()->mark_list_storage(n->init)
        self._reject_array_copy(n, if (declared != &null) => (declared) else => t)
        var ok = true
        if declared != &null {
            ok = self.dyn()->check_convertible(n->init, declared)
        } else if t != &null {
            if self.dyn()->tu.is_void(t) {
                self.dyn()->sc->diag->report(
                    DiagID::SC047E,
                    n->range.start,
                    f"'{self.dyn()->tu.decl_name((unsafe (n as unsafe *Decl)))}' is initialized with an expression of type 'void'",
                ).first(n->range)->emit()
                n->poison()
                ok = false
            } else {
                n->type_ = self._shorthand_type(n, self._fn_value_decay(n->init, t)) // inferred slot := the value's type (a copy has no cv), `?` applied.
            }
        } else if self._reject_type_value(n) {
            ok = false
        } else if n->init->is_poisoned() {
            ok = false
        }

        self._release_local(n, framed, ok)
        if ok { // the value SETS the state (Compiler/Spec/Nullables.md#definitions-and-conditions).
            self.dyn()->flow.define(n)
        }

        return n
    }

    /// # statements

    fn traverse_expression_stmt(self,
                                n: unsafe *Statements::ExpressionStmt) -> unsafe *Statements::ExpressionStmt {
        if n == &null || n->expr == &null {
            return n
        }

        var t = self.dyn()->type_of(n->expr, &null)
        if t != &null && self.dyn()->tu.is_never(t) { // a `-> !` call ends the path.
            self.dyn()->flow.diverge()
        }

        // An attributed statement (`@note` NL `p`) was written to be there.
        if t != &null && !n->has_attribute() && self._discards_pure_value(n->expr) {
            // `x = a` NEWLINE `+ b` is two statements (a newline ends one),
            // the second a value thrown away: a silent miscompile of the
            // continuation it looks like, as C++'s -Wunused-value.
            var b = self.dyn()->sc->diag->report(
                DiagID::SC268W,
                n->expr->range.start,
                "expression result unused; the statement has no effect",
            )

            b.first(n->expr->range)
            b.note(
                n->expr->range.start,
                "a newline ends a statement: an operator that continues the line above belongs at the end of that line",
            )

            b.emit()
        }

        return n
    }

    /// \p e computes a value and does nothing else: a literal, a bare name,
    /// or a BUILTIN unary / binary operator (not `++`/`--`, not a user `op`,
    /// which may act, and not `&&` / `||` / `??`, which are control flow).
    priv fn _discards_pure_value(self, e_in: unsafe *Expr) -> bool {
        var e = self.dyn()->tu.strip_parens(e_in)
        if e == &null || e->is_poisoned() || e->is_instantiation_dependent() {
            return false
        }

        if e->range.start.is_invalid() { // synthesized, not written.
            return false
        }

        var k = e->kind
        if k == ExprKind::IntegerLiteralExpr
            || k == ExprKind::FloatingLiteralExpr
            || k == ExprKind::StringLiteralExpr
            || k == ExprKind::CharacterLiteralExpr
            || k == ExprKind::BooleanLiteralExpr
            || k == ExprKind::NullLiteralExpr
            || k == ExprKind::NamedIdentExpr {
            return true
        }

        if k == ExprKind::UnaryOperatorExpr {
            var u = cast<UnaryOperatorExpr>(e)
            if u->is_mode_marker || u->resolved_op != &null {
                return false
            }

            var uk = u->op_token.kind
            if uk == TokenKind::OpPlusPlus || uk == TokenKind::OpMinusMinus {
                return false
            }

            return u->fix == UnaryOperatorExpr::Fix::Prefix
        }

        if k == ExprKind::BinaryOperatorExpr {
            var bo = cast<BinaryOperatorExpr>(e)
            if bo->resolved_op != &null {
                return false
            }

            var bk = bo->op_token.kind
            if bk == TokenKind::OpAmpAmp
                || bk == TokenKind::OpPipePipe
                || bk == TokenKind::OpQuestionQuestion {
                return false
            }

            return true
        }

        return false
    }

    fn traverse_return_stmt(self,
                            n: unsafe *Statements::ReturnStmt) -> unsafe *Statements::ReturnStmt {
        if n == &null {
            return n
        }

        self._type_return(n)
        self.dyn()->flow.diverge()
        return n
    }

    fn traverse_break_stmt(self,
                           n: unsafe *Statements::BreakStmt) -> unsafe *Statements::BreakStmt {
        if n == &null {
            return n
        }

        self.dyn()->flow.on_break(
            if (n->has_label) => (self.dyn()->sc->ctx->get_spelling(n->label)) else => "",
        )

        return n
    }

    fn traverse_continue_stmt(self,
                              n: unsafe *Statements::ContinueStmt) -> unsafe *Statements::ContinueStmt {
        if n == &null {
            return n
        }

        // The loop's head already assumes whatever the back edge brings.
        self.dyn()->flow.diverge()
        return n
    }

    priv fn _type_return(self,
                         n: unsafe *Statements::ReturnStmt) -> unsafe *Statements::ReturnStmt {
        var unsafe *fr = self.cur_frame()
        if fr == &null {
            if n->value != &null {
                self.dyn()->type_of(n->value, &null)
            }

            return n
        }

        // A generator's `-> yield T` types what it YIELDS. A bare `return`
        // ends the sequence early (functions.md); a value has nowhere to go.
        if fr->is_generator {
            if n->value == &null {
                fr->saw_bare_return = true
                return n
            }

            self.dyn()->type_of(n->value, &null)
            self.dyn()->sc->diag->report(
                DiagID::SC269E,
                n->range.start,
                "a generator ends with 'return' and yields its values; it has no return value",
            ).first(n->range)->emit()
            return n
        }

        if n->value == &null {
            fr->saw_bare_return = true
            if fr->declared != &null
                && !self.dyn()->tu.is_void(fr->declared)
                && !self.dyn()->tu.is_never(fr->declared) {
                self.dyn()->sc->diag->report(
                    DiagID::SC048E,
                    n->range.start,
                    f"'return' with no value in a function returning '{self.dyn()->tu.str(fr->declared)}'",
                ).first(n->range)->emit()
            }

            return n
        }

        fr->saw_return_value = true
        var rw: unsafe *Type = if (fr->fn_decl != &null) => (fr->fn_decl->return_type) else => &null
        self.dyn()->push_null_target(n->value, rw, fr->fn_decl)
        var t = self.dyn()->type_of(n->value, fr->declared)
        self.dyn()->pop_null_target()
        // Re-read: typing a closure in the value pushes its frame, and a
        // `frames` that grew moved this one. The old pointer read freed
        // memory (an inferred return wrote to it), harmless only while
        // nothing reused the block.
        fr = self.cur_frame()
        self.dyn()->reject_slice_literal(n->value, "returned from a function")
        if fr->declared != &null {
            if self.dyn()->tu.is_never(fr->declared) {
                self.dyn()->sc->diag->report(
                    DiagID::SC049E,
                    n->range.start,
                    "a function returning '!' cannot return",
                ).first(n->range)->emit()
                return n
            }

            if self.dyn()->tu.is_void(fr->declared) {
                if t != &null && !self.dyn()->tu.is_void(t) {
                    self.dyn()->sc->diag->report(
                        DiagID::SC050E,
                        n->range.start,
                        f"'return' with a value of type '{self.dyn()->tu.str(t)}' in a function returning 'void'",
                    ).first(n->range)->emit()
                }

                return n
            }

            self.dyn()->check_convertible(n->value, fr->declared)
            return n
        }

        // inferring
        if t == &null {
            self.dyn()->reject_type_value(n->value)
            return n
        }

        var j = self.dyn()->conv.join(fr->inferred, t)
        if j == &null {
            self.dyn()->sc->diag->report(
                DiagID::SC039E,
                n->range.start,
                f"this 'return' has type '{self.dyn()->tu.str(t)}', which does not unify with an earlier return of type '{self.dyn()->tu.str(fr->inferred)}'",
            ).first(n->range)->emit()
            return n
        }

        fr->inferred = j
        return n
    }

    /// The branches start from the condition's true and false sets, and
    /// the code after from their join; a branch that diverges contributes
    /// nothing (Compiler/Spec/Nullables.md#definitions-and-conditions).
    fn traverse_conditional_stmt(self,
                                 n: unsafe *Statements::ConditionalStmt) -> unsafe *Statements::ConditionalStmt {
        if n == &null {
            return n
        }

        if n->cond != &null {
            self.dyn()->require_bool(n->cond, "the 'if' condition")
        }

        // An `eval if` over `typeof T == U` (Compiler/Spec/Eval.md "Type-based branching"):
        // the unselected branches are not type-checked. Decided here (0/1),
        // the untaken branch is dropped from the tree, so no later pass and
        // no C++ compile sees code that is invalid for these types. Decided
        // only per instance (2: a generic parameter), every branch is typed
        // with its diagnostics dropped -- the tree still gets its terminal
        // states -- and `if constexpr (__is_same(T, U))` lets C++ check the
        // one branch each instance takes.
        var sel = if (n->is_eval) => (self._type_cmp_truth(n->cond)) else => -1
        if sel == 1 {
            n->else_      = &null
            n->eval_taken = Statements::EvalTaken::Then
        }

        if sel == 0 && n->then_ != &null {
            n->then_      = Statements::CompoundStmt::create(self.dyn()->sc->ctx, n->then_->range)
            n->eval_taken = Statements::EvalTaken::Else
        }

        if sel == 2 {
            self.dyn()->sc->diag->push_suppress()
        }

        var c = self.dyn()->flow.cond_of(n->cond)
        self.dyn()->flow.env = c.t
        if n->then_ != &null {
            self.dyn()->dispatch_stmt(n->then_)
        }

        if sel == 2 {
            self.dyn()->sc->diag->pop_suppress()
        }

        var then_env = self.dyn()->flow.env
        self.dyn()->flow.env = c.f
        // An else-if link is a ConditionalStmt of its own, decided when it
        // is dispatched; a final `else` here is the dependent chain's.
        var sup_else = sel == 2 && n->else_ != &null && !isa<Statements::ConditionalStmt>(n->else_)
        if sup_else {
            self.dyn()->sc->diag->push_suppress()
        }

        if n->else_ != &null {
            self.dyn()->dispatch_stmt(n->else_)
        }

        if sup_else {
            self.dyn()->sc->diag->pop_suppress()
        }

        var else_env = self.dyn()->flow.env
        self.dyn()->flow.env = self.dyn()->flow.join(&then_env, &else_env)
        return n
    }

    /// \p e, an `eval if` condition built of `typeof T == U` comparisons
    /// (OperatorTyping wrote type_cmp_lhs/rhs), `!`, `&&`, `||`, parentheses
    /// and bool literals: 1 / 0 when it is decided here, 2 when it depends
    /// on a generic parameter, -1 when it is not such a condition (it stays
    /// an ordinary `eval if`).
    priv fn _type_cmp_truth(self, e0: unsafe *Expr) -> i32 {
        var e = self.dyn()->tu.strip_parens(e0)
        if e == &null || e->is_poisoned() {
            return -1
        }

        if isa<BooleanLiteralExpr>(e) {
            return if (cast<BooleanLiteralExpr>(e)->value) => (1) else => 0
        }

        var u = dyn_cast<UnaryOperatorExpr>(e)
        if u != &null
            && u->is_prefix()
            && (u->op_token.kind == TokenKind::OpExclaim || u->op_token.kind == TokenKind::KwNot) {
            var v = self._type_cmp_truth(u->operand)
            if v == 0 || v == 1 {
                return 1 - v
            }

            return v
        }

        var b = dyn_cast<BinaryOperatorExpr>(e)
        if b == &null {
            return -1
        }

        if b->type_cmp_lhs != &null {
            if b->type_cmp_lhs->is_dependent() || b->type_cmp_rhs->is_dependent() {
                return 2
            }

            var same = b->type_cmp_lhs == b->type_cmp_rhs
            if b->op_token.kind != TokenKind::OpEqualEqual {
                same = !same
            }

            return if (same) => (1) else => 0
        }

        var k      = b->op_token.kind
        var is_and = k == TokenKind::OpAmpAmp || k == TokenKind::KwAnd
        var is_or  = k == TokenKind::OpPipePipe || k == TokenKind::KwOr
        if !is_and && !is_or {
            return -1
        }

        var l = self._type_cmp_truth(b->lhs)
        var r = self._type_cmp_truth(b->rhs)
        if l == -1 || r == -1 {
            return -1
        }

        // A decided side settles it when it is the absorbing value.
        if is_and && (l == 0 || r == 0) {
            return 0
        }

        if is_or && (l == 1 || r == 1) {
            return 1
        }

        if l == 2 || r == 2 {
            return 2
        }

        return if (is_and) => (1) else => 0
    }

    /// `outer: while ...`: the loop's `break outer` joins into it, not into
    /// whichever loop is innermost (Compiler/Spec/Nullables.md#loops).
    fn traverse_labeled_stmt(self,
                             n: unsafe *Statements::LabeledStmt) -> unsafe *Statements::LabeledStmt {
        if n == &null {
            return n
        }

        self.dyn()->flow.label_next(self.dyn()->sc->ctx->get_spelling(n->label))
        if n->inner != &null {
            self.dyn()->dispatch_stmt(n->inner)
        }

        self.dyn()->flow.label_next("")
        return n
    }

    /// The head holds what every back edge brings (NullnessFlow::
    /// loop_enter); the condition, typed there, narrows the body; after the
    /// loop, its false set joined with each `break`.
    fn traverse_while_loop_stmt(self,
                                n: unsafe *Statements::WhileLoopStmt) -> unsafe *Statements::WhileLoopStmt {
        if n == &null {
            return n
        }

        self.dyn()->flow.loop_enter(n->body, &null)
        if n->cond != &null {
            self.dyn()->require_bool(n->cond, "the 'while' condition")
        }

        var c = self.dyn()->flow.cond_of(n->cond)
        self.dyn()->flow.env = c.t
        if n->body != &null {
            self.dyn()->dispatch_stmt(n->body)
        }

        var brk = self.dyn()->flow.loop_leave()
        self.dyn()->flow.env = self.dyn()->flow.join(&c.f, &brk)
        return n
    }

    /// `loop { }`: left only by a `break` (or not at all).
    fn traverse_loop_stmt(self, n: unsafe *Statements::LoopStmt) -> unsafe *Statements::LoopStmt {
        if n == &null {
            return n
        }

        self.dyn()->flow.loop_enter(n->body, &null)
        if n->body != &null {
            self.dyn()->dispatch_stmt(n->body)
        }

        self.dyn()->flow.env = self.dyn()->flow.loop_leave()
        return n
    }

    fn traverse_indexed_for_stmt(self,
                                 n: unsafe *Statements::IndexedForStmt) -> unsafe *Statements::IndexedForStmt {
        if n == &null {
            return n
        }

        if n->init != &null {
            self.dyn()->dispatch_stmt(n->init)
        }

        self.dyn()->flow.loop_enter(n->body, n->update)
        var head = self.dyn()->flow.env
        if n->cond != &null {
            self.dyn()->require_bool(n->cond, "the loop condition")
        }

        var c = self.dyn()->flow.cond_of(n->cond)
        // The update runs after the body or a `continue`: the head's state
        // (which already assumes the body's assignments) covers both.
        self.dyn()->flow.env = head
        if n->update != &null {
            self.dyn()->type_of(n->update, &null)
        }

        self.dyn()->flow.env = c.t
        if n->body != &null {
            self.dyn()->dispatch_stmt(n->body)
        }

        var brk = self.dyn()->flow.loop_leave()
        self.dyn()->flow.env = self.dyn()->flow.join(&c.f, &brk)
        return n
    }

    /// The element type an iterable yields, or null (diagnosed). With \p rf,
    /// also records on the loop how IterLowering walks it.
    fn iter_elem_type(self,
                      at: unsafe *Expr,
                      t:  unsafe *Type,
                      rf: unsafe *Statements::RangedForStmt = &null) -> unsafe *Type {
        if t == &null {
            return &null
        }

        var kind                        = Statements::IterKind::None
        var _op:  unsafe *Decl          = &null
        var inst: unsafe *InstanceEntry = &null
        var unsafe *elem = self._iter_classify(at, t, unsafe &kind, unsafe &_op, unsafe &inst, rf)
        if rf != &null && elem != &null {
            rf->iter_kind = kind
            rf->iter_op   = _op
            rf->iter_inst = inst
            rf->iter_elem = canon_unqual(elem)
        }

        return elem
    }

    /// `fn op in (self) -> yield T` on \p t: the element type it yields, with
    /// \p kind / \p _op / \p inst set to the call, or null when \p t
    /// declares none. The iteration form takes `self` only; `op in (self, x)`
    /// is containment and is never picked here.
    priv fn _iter_own_op(self,
                         at:   unsafe *Expr,
                         t:    unsafe *Type,
                         kind: unsafe *Statements::IterKind,
                         _op:  unsafe *(unsafe *Decl),
                         inst: unsafe *(unsafe *InstanceEntry)) -> unsafe *Type {
        var cands = cxx::std::vector<unsafe *Decl>()
        self.dyn()->ml.lookup(
            self.dyn()->tu.strip_nullable(t),
            DeclName::op_name(TokenKind::KwIn, TokenKind::TkUnknown),
            &cands,
        )

        // Every iteration form first, then one resolution among them on the
        // iterable's own cv: a const one picks `op in (const self)`, and
        // with only `op in (self)` the loop is SC063E here ("'op in' is not
        // const"), where before the const was dropped and clang found it in
        // the generated C++ (P950, `for x in m` with `const m: {K: V}`).
        var forms = cxx::std::vector<unsafe *Decl>()
        var yelem = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < cands.size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>(cands[i])
            if f == &null {
                continue
            }

            var extra: usize = 0
            for var p: usize = 0; p < f->params.size(); ++p {
                if f->params[p] != &null && !f->params[p]->is_self {
                    extra += 1
                }
            }

            if extra != 0 {
                continue
            }

            var unsafe *rt = self.fn_return_type(f)
            if rt == &null {
                continue
            }

            rt = self.dyn()->ded_scratch()->member_through(t, rt)
            if !self.dyn()->tu.is_lang(rt, WellKnownType::Yield) {
                continue
            }

            var args = self.dyn()->tu.record_args(rt)
            if args.size() == 0 {
                continue
            }

            forms.push_back(cands[i])
            yelem.push_back(args[0])
        }

        if forms.size() == 0 {
            return &null
        }

        // The winner is resolved once more for its instance and its result
        // through the receiver: a generic one -- an extension's on `[T]`
        // above all, the form a builtin's iteration takes -- is called with
        // X's arguments, never clang's (ExtensionLowering refuses it without
        // them), and its `T` is the extension's, which member_through does
        // not reach.
        var none = cxx::std::vector<ArgInfo>()
        var recv = canon_unqual(self.dyn()->tu.strip_nullable(t))
        var qrecv = recv
        if self._const_iterable(t) {
            qrecv = self.dyn()->sc->types->qualified(recv, QUAL_CONST)
        }

        var r = self.dyn()->ovl.resolve(&forms, &none, true, at->range, "op in", qrecv)
        if r.outcome == OvlOutcome::NoViable {
            at->poison() // reported; the shapes below must not iterate it anyway.
            return &null
        }

        var pick: usize = 0
        if r.outcome == OvlOutcome::Selected {
            for var i: usize = 0; i < forms.size(); ++i {
                if forms[i] == unsafe (r.decl as unsafe *Decl) {
                    pick = i
                }
            }
        }

        var unsafe *elem = yelem[pick]
        if r.outcome == OvlOutcome::Selected {
            r.ded.bind_from_record(recv)
            var srt = self.dyn()->call_result_type(r.decl, &r)
            *inst = r.instance
            if srt != &null && self.dyn()->tu.is_lang(srt, WellKnownType::Yield) {
                var sargs = self.dyn()->tu.record_args(srt)
                if sargs.size() > 0 {
                    elem = sargs[0]
                }
            }
        }

        *kind = Statements::IterKind::User
        *_op  = forms[pick]
        return elem
    }

    /// The iterable is const to its `op in`: a const binding, a `const`
    /// parameter, a field reached through `const self`, a `const T&`.
    priv fn _const_iterable(self, t: unsafe *Type) -> bool {
        var unsafe *o = t
        if o != &null && isa<CXXLValueRefType>(o) {
            o = cast<CXXLValueRefType>(o)->referee
        } else if o != &null && isa<CXXRValueRefType>(o) {
            o = cast<CXXRValueRefType>(o)->referee
        }

        return o != &null && self.dyn()->tu.has_const(o)
    }

    priv fn _iter_classify(self,
                           at:   unsafe *Expr,
                           t:    unsafe *Type,
                           kind: unsafe *Statements::IterKind,
                           _op:  unsafe *(unsafe *Decl),
                           inst: unsafe *(unsafe *InstanceEntry),
                           rf:   unsafe *Statements::RangedForStmt) -> unsafe *Type {
        var arr = self.dyn()->tu.element_of(t)
        if arr != &null {
            *kind = Statements::IterKind::Array
            return arr
        }

        // A record's own `op in` wins, the builtin containers' included: the
        // shapes below are only what a lang record that declares no
        // iteration form falls back to, so Lib/builtin can give `[T]` or
        // `string` a real `op in` without a compiler change and without the
        // gate in FeatureGateCheck (SC116E) refusing it. Asked only of a
        // record: an array (above), a pointer or a builtin has no members.
        if self.dyn()->tu.record_decl(self.dyn()->tu.strip_nullable(t)) != &null {
            var was = at->is_poisoned()
            var unsafe *own = self._iter_own_op(at, t, kind, _op, inst)
            if own != &null {
                return own
            }

            if (!was) && at->is_poisoned() { // its only `op in` refused the receiver: reported.
                return &null
            }
        }

        if self.dyn()->tu.is_slice(t) {
            *kind = Statements::IterKind::Slice
            return self.dyn()->tu.container_elem(t)
        }

        if self.dyn()->tu.is_vector_like(t) {
            *kind = Statements::IterKind::Vector
            return self.dyn()->tu.container_elem(t)
        }

        if self.dyn()->tu.is_set_like(t) {
            *kind = Statements::IterKind::Set
            return self.dyn()->tu.container_elem(t)
        }

        var k: unsafe *Type = &null
        var v: unsafe *Type = &null
        if self.dyn()->tu.map_key_value(t, unsafe &k, unsafe &v) {
            *kind = Statements::IterKind::Map
            var e = cxx::std::vector<unsafe *Type>()
            e.push_back(k)
            e.push_back(v)
            return self.dyn()->tu.tuple_of(unsafe &e)
        }

        if self.dyn()->tu.is_string(t) {
            *kind = Statements::IterKind::String
            return self.dyn()->tu.builtin(BuiltinKind::Char)
        }

        if self.dyn()->tu.is_lang(t, WellKnownType::Range) {
            var r = dyn_cast<RangeExpr>(self.dyn()->tu.strip_parens(at))
            if r != &null {
                if r->begin == &null || r->end == &null {
                    self.dyn()->fail(
                        at,
                        DiagID::SC095E,
                        "an open range cannot be iterated; give it both bounds",
                    )

                    return &null
                }

                *kind = Statements::IterKind::RangeLit
            } else {
                *kind = Statements::IterKind::RangeValue
            }

            var args = self.dyn()->tu.record_args(t)
            return if (args.size() > 0) => (args[0])
                   else => self.dyn()->tu.builtin(BuiltinKind::I32)
        }

        // A Yield<T> value is a generator already -- a call of a `-> yield T`
        // function, or a variable holding one -- so the loop drives it with
        // no `op in` to call (IterLowering::_user reads the null op).
        if self.dyn()->tu.is_lang(t, WellKnownType::Yield) {
            var yargs = self.dyn()->tu.record_args(t)
            if yargs.size() > 0 {
                *kind = Statements::IterKind::User
                *_op  = &null
                return yargs[0]
            }
        }

        var        cxx_ok = false
        var unsafe *ce    = self._cxx_range(at, t, rf, unsafe &cxx_ok)
        if cxx_ok {
            *kind = Statements::IterKind::Cxx
            return ce
        }

        if rf != &null && (rf->cxx_dependent || at->is_poisoned()) { // left to C++, or _dependent_for_shape reported.
            return &null
        }

        if ce == &null && at->is_poisoned() { // the protocol applied and failed: reported.
            return &null
        }

        // A Kairo type has one iteration protocol, so its message names one.
        var how = "no 'op in (self) -> yield T'"
        if self._is_cxx_record(t) {
            how = "no 'op in (self) -> yield T' and no 'begin()'/'end()'"
        }

        self.dyn()->fail(
            at,
            DiagID::SC095E,
            f"'{self.dyn()->tu.str(t)}' is not iterable; it has {how}",
        )

        return &null
    }

    /// ## C++'s range protocol

    /// [stmt.ranged]/1 for a class: a member named `begin` or `end` makes the
    /// loop `r.begin()` / `r.end()`; with neither, `begin(r)` / `end(r)` by
    /// argument-dependent lookup. X does what a C++ compiler does there:
    /// resolves both calls on the range's own cv (a const vector's `begin()
    /// const` returns a const_iterator), mints `__it` / `__end`, and types
    /// `__it != __end`, `*__it` and `++__it` over them, so every overload --
    /// a free operator template, C++20's `!=` from `==` -- is resolved the
    /// way any expression's is. The element is `*__it` read as a value; `*x`
    /// binds its address.
    ///
    /// Imported C++ records only. A Kairo type has exactly one way to be
    /// iterable, `op in (self) -> yield T`: a second protocol would need a
    /// precedence rule when a class has both, would silently reroute a class
    /// that defines begin()/end() only for its C++ callers, and would put
    /// iterator records and pointer steps outside `op in` where Tether does
    /// not follow them. A Kairo class's begin()/end() are ordinary methods.
    ///
    /// \p ok: the protocol applied and every piece typed. Not applying (a
    /// Kairo type, or no begin or end anywhere) reports nothing, so the
    /// caller's SC095E speaks; applying and failing reports, and poisons \p at.
    priv fn _cxx_range(self,
                       at: unsafe *Expr,
                       t:  unsafe *Type,
                       rf: unsafe *Statements::RangedForStmt,
                       ok: unsafe *bool) -> unsafe *Type {
        *ok = false
        // The object, cv kept: a const range must pick `begin() const`, so
        // only a reference is looked through (peel_ref would drop the const).
        var unsafe *obj = t
        if isa<CXXLValueRefType>(obj) {
            obj = cast<CXXLValueRefType>(obj)->referee
        } else if isa<CXXRValueRefType>(obj) {
            obj = cast<CXXRValueRefType>(obj)->referee
        }

        if !self._is_cxx_record(obj) {
            return &null
        }

        // An instance over the generic's own parameter (`vector<T>`): a
        // member call on it is left to C++ per instance (untyped), so
        // begin()/end()/`*it` have no type here and the loop is C++'s own
        // range-for (P476: it was poisoned with no diagnostic, then an ICE).
        var unsafe *oc = canon_unqual(obj)
        if rf != &null && oc != &null && (oc->is_dependent() || oc->is_instantiation_dependent()) {
            if self._dependent_for_shape(rf) {
                rf->cxx_dependent = true
            }

            return &null
        }

        var mb = cxx::std::vector<unsafe *Decl>()
        var me = cxx::std::vector<unsafe *Decl>()
        var kb = LowerTargets::cxx_range_begin()
        var ke = LowerTargets::cxx_range_end()
        var nb = self._cxx_name(kb)
        var ne = self._cxx_name(ke)
        self.dyn()->ml.lookup(obj, nb, &mb)
        self.dyn()->ml.lookup(obj, ne, &me)
        // A hidden friend `friend It begin(R&)` sits in the class's table but
        // is no member ([stmt.ranged] asks for a MEMBER named begin): it is
        // one of the free candidates, which ADL alone would never reach.
        var hb = cxx::std::vector<unsafe *Decl>()
        var he = cxx::std::vector<unsafe *Decl>()
        self._split_friends(&mb, &hb)
        self._split_friends(&me, &he)

        var bt:  unsafe *Type          = &null
        var et:  unsafe *Type          = &null
        var bf:  unsafe *FunctionDecl  = &null
        var ef:  unsafe *FunctionDecl  = &null
        var bi:  unsafe *InstanceEntry = &null
        var ei:  unsafe *InstanceEntry = &null
        var free                       = false
        if mb.size() > 0 || me.size() > 0 {
            // Members, both or neither: one alone is not a fallback to the
            // free pair ([stmt.ranged]/1.2), it is an error.
            if mb.size() == 0 || me.size() == 0 {
                var have = kb
                var miss = ke
                if mb.size() == 0 {
                    have = ke
                    miss = kb
                }

                self.dyn()->fail(
                    at,
                    DiagID::SC095E,
                    f"'{self.dyn()->tu.str(t)}' has a member '{have}' but no '{miss}'; a C++ range needs both",
                )

                return &null
            }

            bf = self._cxx_member(at, obj, unsafe &mb, kb, unsafe &bt, unsafe &bi)
            ef = self._cxx_member(at, obj, unsafe &me, ke, unsafe &et, unsafe &ei)
        } else {
            var scopes = cxx::std::vector<unsafe *DeclContext>()
            self.dyn()->ml.associated_scopes(obj, &scopes)
            var fb = hb
            var fe = he
            self.dyn()->ml.adl_candidates(&scopes, nb, kb, &hb, &fb)
            self.dyn()->ml.adl_candidates(&scopes, ne, ke, &he, &fe)
            if fb.size() == 0 && fe.size() == 0 {
                return &null
            }

            // A `begin` that cannot take this range is some other type's:
            // ADL reaches every free `begin` in the namespace. Not iterable,
            // not a failed call.
            var probe = cxx::std::vector<ArgInfo>()
            probe.push_back(self.dyn()->arg_info(at))
            var nofree = cxx::std::vector<unsafe *Decl>()
            if !self.dyn()->ovl.any_viable(&nofree, &probe, false, &fb, &probe) {
                return &null
            }

            if fb.size() == 0 || fe.size() == 0 {
                var have = kb
                var miss = ke
                if fb.size() == 0 {
                    have = ke
                    miss = kb
                }

                self.dyn()->fail(
                    at,
                    DiagID::SC095E,
                    f"'{self.dyn()->tu.str(t)}' has a free '{have}' but no '{miss}'; a C++ range needs both",
                )

                return &null
            }

            free = true
            bf   = self._cxx_free(at, unsafe &fb, kb, unsafe &bt, unsafe &bi)
            ef   = self._cxx_free(at, unsafe &fe, ke, unsafe &et, unsafe &ei)
        }

        if bf == &null || ef == &null {
            self.dyn()->poison_only(at)
            return &null
        }

        var        synth = LowerSynth(self.dyn()->sc)
        var        r     = at->range
        var unsafe *it   = synth.local(r, "it", bt, &null)
        var unsafe *end  = synth.local(r, "end", et, &null)

        var ctx = self.dyn()->sc->ctx
        var cond = (unsafe (BinaryOperatorExpr::create(ctx, r,
                       synth.use_of(it, r, Expr::ValueCategory::LValue),
                       synth.use_of(end, r, Expr::ValueCategory::LValue),
                       synth.punct(r, TokenKind::OpExclaimEqual)) as unsafe *Expr))
        var deref = (unsafe (UnaryOperatorExpr::create(ctx, r,
                       synth.use_of(it, r, Expr::ValueCategory::LValue),
                       synth.punct(r, TokenKind::OpStar), UnaryOperatorExpr::Fix::Prefix) as unsafe *Expr))
        var next = (unsafe (UnaryOperatorExpr::create(ctx, r,
                       synth.use_of(it, r, Expr::ValueCategory::LValue),
                       synth.punct(r, TokenKind::OpPlusPlus), UnaryOperatorExpr::Fix::Prefix) as unsafe *Expr))

        self.dyn()->require_bool(cond, "a C++ range's 'begin() != end()'")
        var elem = self.dyn()->type_of(deref, &null)
        // A pointer iterator (std::array, span, a C array member) steps by
        // C++'s builtin `++`. Kairo has no `++` on pointers for user code, and
        // this one is the loop's own step over [begin, end), so it is minted
        // typed rather than offered to the operator table.
        if isa<PointerType>(canon_unqual(bt)) {
            next->type_          = bt
            next->value_category = Expr::ValueCategory::LValue
        } else {
            self.dyn()->type_of(next, &null)
        }

        if cond->is_poisoned() || deref->is_poisoned() || next->is_poisoned() || elem == &null {
            self.dyn()->poison_only(at)
            return &null
        }

        if rf != &null {
            rf->cxx_begin_fn   = unsafe (bf as unsafe *Decl)
            rf->cxx_end_fn     = unsafe (ef as unsafe *Decl)
            rf->cxx_free       = free
            rf->cxx_begin_inst = bi
            rf->cxx_end_inst   = ei
            rf->cxx_it         = it
            rf->cxx_end        = end
            rf->cxx_cond       = cond
            rf->cxx_deref      = deref
            rf->cxx_next       = next
        }

        *ok = true
        return self.dyn()->tu.as_value(elem)
    }

    /// The binders a C++ range-for over a dependent range can spell: one
    /// name (a copy, `auto x`), one `*x` (the element's address) or `_`, or
    /// plain names destructured (`auto [a, b]`). Anything else is reported
    /// here, the iterable poisoned.
    priv fn _dependent_for_shape(self, rf: unsafe *Statements::RangedForStmt) -> bool {
        var n = rf->bindings.size()
        for var i: usize = 0; i < n; ++i {
            var unsafe *b = rf->bindings.get(i)
            var plain = b->type_ == &null && b->shorthand.empty()
            var ptr   = n == 1
                && b->type_ == &null
                && b->shorthand.has(Statements::BindingShorthand::Pointer)
                && (!b->shorthand.has(Statements::BindingShorthand::Nullable))
            if (!plain) && (!ptr) && (!b->is_discard) {
                self.dyn()->sc->diag->report(
                    DiagID::SC001E,
                    b->range.start,
                    "a loop over a C++ range that depends on a type parameter binds a name, '*name' or '_' (no type, no '?', '*' only on a single binder)",
                ).first(b->range)->emit()
                self.dyn()->poison_only(rf->iterable)
                return false
            }
        }

        return true
    }

    /// A record imported from a C++ header, or an instance of an imported
    /// template (only its primary carries the import stamp).
    priv fn _is_cxx_record(self, t: unsafe *Type) -> bool {
        var unsafe *c = t
        if c != &null && isa<CXXLValueRefType>(c) {
            c = cast<CXXLValueRefType>(c)->referee
        } else if c != &null && isa<CXXRValueRefType>(c) {
            c = cast<CXXRValueRefType>(c)->referee
        }

        var d = self.dyn()->tu.record_decl(c)
        if d == &null {
            return false
        }

        if decl_is_imported(d) {
            return true
        }

        return decl_is_instance(d) && decl_is_imported(decl_instantiated_from(d))
    }

    /// Move the non-methods member lookup found (hidden friends) to \p frees.
    priv fn _split_friends(self,
                           @inout found: cxx::std::vector<unsafe *Decl>,
                           @inout frees: cxx::std::vector<unsafe *Decl>) {
        var keep = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < found.size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>((found)[i])
            if f != &null && !f->is_method() {
                frees.push_back((found)[i])
                continue
            }

            keep.push_back((found)[i])
        }

        (found) = keep
    }

    /// This TU's DeclName for the identifier \p s.
    priv fn _cxx_name(self, const s: string) -> DeclName {
        return DeclName::ident(self.dyn()->sc->imm_table()->intern_ident_copy(s))
    }

    /// `obj.<name>()` resolved on \p obj's cv: the method, its result type
    /// read as the value the hidden local holds, and the instance.
    priv fn _cxx_member(self,
                        at:         unsafe *Expr,
                        obj:        unsafe *Type,
                        cands:      unsafe *cxx::std::vector<unsafe *Decl>,
                        const name: string,
                        ty:         unsafe *(unsafe *Type),
                        inst:       unsafe *(unsafe *InstanceEntry)) -> unsafe *FunctionDecl {
        var args = cxx::std::vector<ArgInfo>()
        var r    = self.dyn()->ovl.resolve(cands, &args, true, at->range, name, obj)
        if r.outcome != OvlOutcome::Selected {
            return &null
        }

        r.ded.bind_from_record(canon_unqual(obj))
        var rt = self.dyn()->call_result_type(r.decl, &r)
        if rt == &null {
            return &null
        }

        *ty   = canon_unqual(self.dyn()->tu.as_value(rt))
        *inst = r.instance
        return r.decl
    }

    /// `<name>(r)` among the ADL candidates \p cands, the range as its one
    /// argument.
    priv fn _cxx_free(self,
                      at:         unsafe *Expr,
                      cands:      unsafe *cxx::std::vector<unsafe *Decl>,
                      const name: string,
                      ty:         unsafe *(unsafe *Type),
                      inst:       unsafe *(unsafe *InstanceEntry)) -> unsafe *FunctionDecl {
        var args = cxx::std::vector<ArgInfo>()
        args.push_back(self.dyn()->arg_info(at))
        var r = self.dyn()->ovl.resolve(cands, &args, false, at->range, name)
        if r.outcome != OvlOutcome::Selected {
            return &null
        }

        var rt = self.dyn()->call_result_type(r.decl, &r)
        if rt == &null {
            return &null
        }

        *ty   = canon_unqual(self.dyn()->tu.as_value(rt))
        *inst = r.instance
        return r.decl
    }

    /// Apply binding shorthands and write the binder's type.
    priv fn _bind_one(self, b: unsafe *Statements::Binding, t: unsafe *Type, const_elem: bool = false) {
        if b == &null || b->is_discard || b->decl == &null {
            return
        }

        var unsafe *vd = dyn_cast<VariableDecl>(b->decl)
        if vd == &null {
            return
        }

        if b->type_ != &null && b->type_->canonical != &null {
            vd->type_ = canon_unqual(b->type_->canonical)
            if t != &null && !self.dyn()->conv.convertible(t, vd->type_->canonical) {
                self.dyn()->sc->diag->report(
                    DiagID::SC041E,
                    b->range.start,
                    f"binding annotated '{self.dyn()->tu.str(vd->type_->canonical)}' cannot take a value of type '{self.dyn()->tu.str(t)}'",
                ).first(b->range)->emit()
                vd->poison()
            }

            return
        }

        if t == &null {
            return
        }

        var unsafe *shaped = canon_unqual(t)
        if b->shorthand.has(Statements::BindingShorthand::Pointer) {
            // An element reached through a `const T&` (a std::set's iterator)
            // is not writable: the binder points at a `const T`, or C++
            // refuses the `const T*` into a `T*` (P474).
            if const_elem {
                shaped = self.dyn()->sc->types->qualified(shaped, QUAL_CONST)
            }

            shaped = self.dyn()->sc->types->pointer(
                shaped,
                b->shorthand.has(Statements::BindingShorthand::Unsafe),
            )
        }

        if b->shorthand.has(Statements::BindingShorthand::Nullable) {
            shaped = self._nullable_once(shaped)
        }

        vd->type_ = shaped
    }

    priv fn _bind_list(self,
                       list:       *FrozenList<Statements::Binding>,
                       t:          unsafe *Type,
                       at:         *Expr,
                       const_elem: bool = false) {
        if list->size() == 1 {
            self._bind_one(list->get(0), t, const_elem)
            return
        }

        var unsafe *tu_  = canon_unqual(t)
        var        have  = tu_ != &null && self.dyn()->tu.is_tuple(tu_)
        var        elems = self.dyn()->tu.tuple_elems(tu_)
        if have && elems.size() != list->size() {
            self.dyn()->fail(
                at,
                DiagID::SC042E,
                f"{list->size()} binding(s) but '{self.dyn()->tu.str(t)}' has {elems.size()} element(s)",
            )

            have = false
        }

        if tu_ != &null && !self.dyn()->tu.is_tuple(tu_) {
            self.dyn()->fail(
                at,
                DiagID::SC096E,
                f"cannot destructure '{self.dyn()->tu.str(t)}' into {list->size()} bindings",
            )
        }

        // Each binder of the tuple points into the same const element:
        // `for (k, *v) in xs` over a const owner is `*const V` too (P950).
        for var i: usize = 0; i < list->size(); ++i {
            self._bind_one(list->get(i), if (have) => (elems[i]) else => &null, const_elem)
        }
    }

    fn traverse_ranged_for_stmt(self,
                                n: unsafe *Statements::RangedForStmt) -> unsafe *Statements::RangedForStmt {
        if n == &null {
            return n
        }

        var it   = self.dyn()->type_of(n->iterable, &null)
        var elem = if (it != &null) => (self.iter_elem_type(n->iterable, it, n)) else => &null
        // `for x in xs` over a type pack: one copy of the body per element,
        // each with its own type, so `x` is typed as the pack (dependent,
        // like any generic body) and C++ unrolls it (EmitIR::_pack_for).
        var unsafe *pk = self._type_pack_ref(n->iterable)
        if pk != &null && !n->is_eval {
            n->iter_kind = Statements::IterKind::Pack
            n->iter_elem = canon_unqual(pk->type_->canonical)
            elem         = n->iter_elem
        }

        self._by_value_abstract(n, elem)
        self._bind_list(
            &n->bindings,
            elem,
            n->iterable,
            self._cxx_yields_const(n) || self._const_owner_iter(n, it),
        )
        // No condition refines it; it may run zero times, so after it is
        // the head's state joined with each `break`.
        self.dyn()->flow.loop_enter(n->body, &null)
        var head = self.dyn()->flow.env
        if n->body != &null {
            self.dyn()->dispatch_stmt(n->body)
        }

        var brk = self.dyn()->flow.loop_leave()
        self.dyn()->flow.env = self.dyn()->flow.join(&head, &brk)
        return n
    }

    /// A C++ range whose `*it` is a reference to const (std::set, a
    /// const_iterator): what `for *x` may point at is read-only. The
    /// element type itself is kept unqualified (canonicals carry no quals),
    /// so the constness is read off the loop's own `*it` here.
    priv fn _cxx_yields_const(self, n: unsafe *Statements::RangedForStmt) -> bool {
        if n->iter_kind != Statements::IterKind::Cxx || n->cxx_deref == &null {
            return false
        }

        var unsafe *d = n->cxx_deref->type_
        if d == &null {
            return false
        }

        if isa<CXXLValueRefType>(d) {
            d = cast<CXXLValueRefType>(d)->referee
        } else if isa<CXXRValueRefType>(d) {
            d = cast<CXXRValueRefType>(d)->referee
        } else {
            // A prvalue element is copied into a loop temporary; that copy
            // is the binder's to point at, mutable.
            return false
        }

        return self.dyn()->tu.has_const(d)
    }

    /// A const array or vector owns its elements, so what `for *x` points
    /// at through one is const, as `&a[i]` is (P921). The builtin vector
    /// iterates through its own `op in (const self)` (IterKind::User), which
    /// says nothing about the element's const: without this a `for *e` over
    /// a const `[T]` wrote the elements and compiled. A slice is a view over
    /// storage it does not own and keeps its elements' own const.
    priv fn _const_owner_iter(self, n: unsafe *Statements::RangedForStmt, it: unsafe *Type) -> bool {
        if it == &null {
            return false
        }

        var unsafe *o = it
        if isa<CXXLValueRefType>(o) {
            o = cast<CXXLValueRefType>(o)->referee
        } else if isa<CXXRValueRefType>(o) {
            o = cast<CXXRValueRefType>(o)->referee
        }

        if !self.dyn()->tu.has_const(o) {
            return false
        }

        return n->iter_kind == Statements::IterKind::Array
            || n->iter_kind == Statements::IterKind::Vector
            || self.dyn()->tu.is_vector_like(canon_unqual(o))
    }

    /// `for h in *arr` over a C++ range whose element is an abstract class
    /// (toml::array yields toml::node): `h` binds a COPY, which C++ cannot
    /// make, and the failure would surface as clang's "variable type is an
    /// abstract class" in emitted code (P833). Said here, at the binding,
    /// with the `for *h` that iterates by pointer.
    priv fn _by_value_abstract(self, n: unsafe *Statements::RangedForStmt, elem: unsafe *Type) {
        if elem == &null || n->iter_kind != Statements::IterKind::Cxx || n->bindings.size() != 1 {
            return
        }

        var unsafe *b = n->bindings.get(0)
        if b == &null || b->is_discard || b->name == &null || b->type_ != &null {
            return
        }

        if b->shorthand.has(Statements::BindingShorthand::Pointer) {
            return
        }

        var unsafe *cd = dyn_cast<ClassDecl>(self.dyn()->tu.record_decl(canon_unqual(elem)))
        if cd == &null || (!cd->is_abstract) {
            return
        }

        var bn = self.dyn()->sc->ctx->get_spelling(b->name->name)
        var tn = self.dyn()->tu.str(elem)
        var d  = self.dyn()->sc->diag->report(
            DiagID::SC001E,
            b->range.start,
            f"cannot bind '{bn}' by value: '{tn}' is abstract; iterate by pointer",
        )

        d.first(b->range)
        d.note(cd->name.range.start, f"'{tn}' is declared abstract here")
        d.insert(b->range.start, "*", "bind a pointer to each element")
        d.emit()
        if b->decl != &null {
            b->decl->poison()
        }
    }

    /// \p e names a type pack parameter (`xs` of `...xs: T`), or null.
    priv fn _type_pack_ref(self, e: unsafe *Expr) -> unsafe *ParamDecl {
        var u = self.dyn()->tu.strip_parens(e)
        if u == &null || !isa<NamedIdentExpr>(u) {
            return &null
        }

        var p = dyn_cast<ParamDecl>(cast<NamedIdentExpr>(u)->resolved_decl)
        return if (param_is_type_pack(p)) => (p) else => &null
    }

    fn traverse_destructuring_decl_stmt(self,
                                        n: unsafe *Statements::DestructuringDeclStmt) -> unsafe *Statements::DestructuringDeclStmt {
        if n == &null {
            return n
        }

        var t = self.dyn()->type_of(n->value, &null)
        if n->kind_ == Statements::DestructureKind::Tuple {
            self._bind_list(&n->bindings, t, n->value)
            return n
        }

        // struct destructure: by field name.
        var d = self.dyn()->tu.record_decl(self.dyn()->tu.strip_nullable(t))
        if t != &null && d == &null {
            self.dyn()->fail(
                n->value,
                DiagID::SC096E,
                f"cannot destructure '{self.dyn()->tu.str(t)}' by field name",
            )

            return n
        }

        var dc = if (d != &null) => (NameLookup::context_of(self.dyn()->sc->body_of(d)))
                 else => &null
        for var i: usize = 0; i < n->bindings.size(); ++i {
            var unsafe *b = n->bindings.get(i)
            if b == &null || b->is_discard || b->name == &null {
                continue
            }

            var ft: unsafe *Type = &null
            if dc != &null {
                var spelled = self.dyn()->sc->ctx->get_spelling(b->name->name)
                var imm     = self.dyn()->sc->ctx->get_ident_imm(b->name->name)
                var cell    = self.dyn()->sc->lookup.in_context(dc, DeclName::ident(imm), spelled)
                var fd      = if (cell.found()) => (dyn_cast<FieldDecl>(cell.first())) else => &null
                if fd == &null {
                    self.dyn()->sc->diag->report(
                        DiagID::SC040E,
                        b->range.start,
                        f"'{self.dyn()->tu.decl_name(d)}' has no field named '{spelled}'",
                    ).first(b->range)->emit()
                    continue
                }

                if fd->type_ != &null {
                    ft = self.dyn()->ded_scratch()->member_through(t, fd->type_->canonical)
                }
            }

            self._bind_one(b, ft)
        }

        return n
    }

    fn traverse_context_binding_stmt(self,
                                     n: unsafe *Statements::ContextBindingStmt) -> unsafe *Statements::ContextBindingStmt {
        if n == &null {
            return n
        }

        var t = self.dyn()->type_of(n->value, &null)
        // enter/exit protocol lowering is a lang-item question; the binder
        // takes the value's type until ContextLowering says otherwise.
        self._bind_list(&n->bindings, t, n->value)
        if n->body != &null {
            self.dyn()->dispatch_stmt(n->body)
        }

        return n
    }

    /// Each arm starts from the state before the match, refined by what its
    /// pattern proves (Compiler/Spec/Nullables.md#match: on a `T?`, `case null` sees the
    /// place Null and every later arm NonNull) and by its guard's true set.
    /// After it, the join of the arms' ends, a diverging arm excluded: the
    /// state before the match is not joined in, since a match is exhaustive
    /// (a non-exhaustive one is SC120E), so no path skips every arm.
    fn traverse_match_stmt(self,
                           n: unsafe *Statements::MatchStmt) -> unsafe *Statements::MatchStmt {
        if n == &null {
            return n
        }

        var st = self.dyn()->type_of(n->scrutinee, &null)
        st = self.dyn()->match_infer_column(n->scrutinee, &n->cases, st)
        var entry = self.dyn()->flow.env
        n->null_arm = self.dyn()->match_null_first(n->scrutinee, &n->cases, st, n->range, true)
        var bad_null = self.dyn()->match_null_missed(n->null_arm, st)
        var acc      = self.dyn()->flow.dead_env()
        for var i: usize = 0; i < n->cases.size(); ++i {
            var unsafe *mc = n->cases.get(i)
            var col = self.dyn()->match_arm_enter(n->null_arm, n->scrutinee, mc, i, st, &entry)
            for var j: usize = 0; j < mc->patterns.size(); ++j {
                self.dyn()->type_pattern(mc->patterns[j], col)
            }

            self.dyn()->match_guard(mc)
            if mc->body != &null {
                self.dyn()->dispatch_stmt(mc->body)
            }

            if mc->expression != &null {
                self.dyn()->type_of(mc->expression, &null)
            }

            var end = self.dyn()->flow.env
            acc = self.dyn()->flow.join(&acc, &end)
        }

        if n->cases.size() == 0 {
            acc = entry
        }

        self.dyn()->flow.env = acc
        if bad_null {
            n->scrutinee->poison()
        }

        return n
    }

    /// A `catch` arm starts from the state before the `try` with whatever
    /// the body assigns assumed (it may throw anywhere); after the
    /// statement, the body's end joined with every arm's.
    fn traverse_try_catch_stmt(self,
                               n: unsafe *Statements::TryCatchStmt) -> unsafe *Statements::TryCatchStmt {
        if n == &null {
            return n
        }

        var entry = self.dyn()->flow.env
        if n->try_body != &null {
            self.dyn()->dispatch_stmt(n->try_body)
        }

        var acc       = self.dyn()->flow.env
        var arm_entry = self.dyn()->flow.try_entry(&entry, n->try_body, &null)
        for var i: usize = 0; i < n->arms.size(); ++i {
            var unsafe *arm = n->arms.get(i)
            var unsafe *vd  = dyn_cast<VariableDecl>(arm->decl)
            if vd != &null && vd->type_ == &null {
                var ft: unsafe *Type = &null
                if arm->filter != &null && arm->filter->canonical != &null {
                    ft = arm->filter->canonical
                }

                if ft == &null {
                    var a = cxx::std::vector<*Type>()
                    ft = self.dyn()->tu.lang_record(WellKnownType::Panic, &a)
                }

                if ft != &null {
                    vd->type_ = canon_unqual(ft)
                }
            }

            self.dyn()->flow.env = arm_entry
            if arm->body != &null {
                self.dyn()->dispatch_stmt(arm->body)
            }

            var end = self.dyn()->flow.env
            acc = self.dyn()->flow.join(&acc, &end)
        }

        self.dyn()->flow.env = acc
        return n
    }

    fn traverse_unsafe_block_stmt(self,
                                  n: unsafe *Statements::UnsafeBlockStmt) -> unsafe *Statements::UnsafeBlockStmt {
        if n == &null {
            return n
        }

        self.dyn()->unsafe_depth += 1
        if n->body != &null {
            self.dyn()->dispatch_stmt(n->body)
        }

        self.dyn()->unsafe_depth -= 1
        return n
    }

    fn traverse_runtime_assert_stmt(self,
                                    n: unsafe *Statements::RuntimeAssertStmt) -> unsafe *Statements::RuntimeAssertStmt {
        if n == &null {
            return n
        }

        if n->condition != &null {
            self.dyn()->require_bool(n->condition, "an 'assert' condition")
        }

        if n->message != &null {
            self.dyn()->type_of(n->message, self.dyn()->tu.string_type())
        }

        return n
    }

    fn traverse_static_assert_stmt(self,
                                   n: unsafe *Statements::StaticAssertStmt) -> unsafe *Statements::StaticAssertStmt {
        if n == &null {
            return n
        }

        if n->condition != &null {
            self.dyn()->require_bool(n->condition, "a static assertion")
        }

        if n->message != &null {
            self.dyn()->type_of(n->message, self.dyn()->tu.string_type())
        }

        return n
    }

    fn traverse_panic_stmt(self,
                           n: unsafe *Statements::PanicStmt) -> unsafe *Statements::PanicStmt {
        if n == &null {
            return n
        }

        if n->payload != &null {
            self.dyn()->type_of(n->payload, &null)
        }

        self.dyn()->flow.diverge()
        return n
    }

    /// `yield e` types against the enclosing generator's element. Every
    /// other place a `yield` can sit is an error here, so EmitIR only ever
    /// meets one inside a function it knows is a generator.
    fn traverse_yield_stmt(self,
                           n: unsafe *Statements::YieldStmt) -> unsafe *Statements::YieldStmt {
        if n == &null {
            return n
        }

        var unsafe *fr = self.cur_frame()
        if fr == &null || fr->closure != &null || !fr->is_generator {
            if n->value != &null {
                self.dyn()->type_of(n->value, &null)
            }

            if fr == &null {
                self.dyn()->sc->diag->report(
                    DiagID::SC111E,
                    n->range.start,
                    "'yield' outside a function",
                ).first(n->range)->emit()
            } else if fr->closure != &null {
                // Lifts when closures are emitted at all; a closure frame has
                // no FunctionDecl to carry the generator fact yet.
                self.dyn()->sc->diag->report(
                    DiagID::SC111E,
                    n->range.start,
                    "a closure cannot yield yet",
                ).first(n->range)->emit()
            } else {
                var unsafe *f = fr->fn_decl
                var b = self.dyn()->sc->diag->report(
                    DiagID::SC111E,
                    n->range.start,
                    "'yield' in a function that does not return 'yield T'",
                )

                b.first(n->range)
                if f != &null && f->return_type != &null && f->return_type->range.is_valid() {
                    b.note(
                        f->return_type->range.start,
                        "declare the return type 'yield T' to make this a generator",
                    )->first(f->return_type->range)
                } else if f != &null && !f->is_operator {
                    b.note(
                        f->name.range.start,
                        "this function has no return type; declare '-> yield T' to make it a generator",
                    )->first(f->name.range)
                }

                b.emit()
            }

            return n
        }

        if fr->fn_decl != &null {
            fr->fn_decl->has_yield = true
        }

        if n->value == &null {
            return n
        }

        var unsafe *elem = fr->yield_elem
        self.dyn()->type_of(n->value, elem)
        // The backing array of `[1, 2]` as a slice dies at the suspension.
        if self.dyn()->reject_slice_literal(n->value, "yielded from a generator") {
            return n
        }

        if elem == &null {
            return n
        }

        // Either side dependent is the instance's question.
        var unsafe *vt = n->value->type_
        if elem->is_dependent() || vt != &null && vt->is_dependent() {
            return n
        }

        self.dyn()->check_convertible(n->value, elem)
        return n
    }
}
