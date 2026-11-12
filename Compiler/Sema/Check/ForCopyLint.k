/// --- The Kairo Project -------------------- Sema/Check/ForCopyLint.k --- ///
///
///   \brief Warn when the loop variable of a by-value `for x in v` is written
///          and the write is never read: it could only have been meant for
///          the element (library/core/containers.mdx, `Vector.op in`).
///
///   \detail
///     `for x in v` binds a copy of each element; `for *x in v` binds a
///     pointer to it. The bug this catches is the one that looks right:
///
///         for p in points {
///             p.x = 0         // SC275W: writes to a copy of the element
///         }
///
///     A write is an assignment or compound assignment whose target is `x`
///     or a field path of it (`x.a.b`, every step a `.` to a field), or
///     `&x` passed to an `@inout` parameter. The lint fires on the FIRST
///     write when no read of `x` follows it in the body; the fix-it inserts
///     `*` before the binder.
///
///   \par What is NOT warned (precise rather than broad)
///     - A read of `x` anywhere after the first write: the copy is being
///       used as a scratch value. A method call on `x`, a subscript, a
///       `->` step and an argument all count as reads: Sema does not know
///       cheaply whether they mutate, and guessing would be the broad lint.
///     - A write inside a nested loop when that loop also reads `x`: the
///       read may be the next inner iteration's.
///     - `&x` that is not an `@inout` marker, or any mention of `x` inside
///       a closure: the copy escapes, and its later uses are not in order.
///     - `for *x`, a `const` binder, an element that is a pointer or a C++
///       reference, a dependent element type, an integer range (RangeLit /
///       RangeValue), a pack, an `eval for`.
///
///   The lint is SC275W (silenced by `-A SC275W` like any warning).
///
///   Phase: CHECK (after ExprTyper; reads resolved decls and binder types)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Base::{
    Decl,
    Expr,
}
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    FieldDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr,
    ClosureExpr,
    ParenExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    BindingShorthand, CompoundStmt, IndexedForStmt, IterKind, LoopStmt, RangedForStmt,
    WhileLoopStmt,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

/// The place \p e names is the binder \p d itself or a field path of it
/// (`d`, `d.a`, `d.a.b`, parentheses allowed). A `->`, a call, a subscript
/// or a static field leaves the copy: the write lands somewhere shared.
fn for_copy_place(e: unsafe *Expr, d: unsafe *Decl) -> bool {
    var unsafe *x = e
    while x != &null && isa<ParenExpr>(x) {
        x = dyn_cast<ParenExpr>(x)->inner
    }

    if x == &null {
        return false
    }

    var unsafe *ni = dyn_cast<NamedIdentExpr>(x)
    if ni != &null {
        return ni->resolved_decl == d
    }

    var unsafe *c = dyn_cast<ChainExpr>(x)
    if c == &null || c->steps.size() == 0 {
        return false
    }

    var unsafe *head = dyn_cast<NamedIdentExpr>(c->base)
    if head == &null || head->resolved_decl != d {
        return false
    }

    for var i: usize = 0; i < c->steps.size(); ++i {
        var unsafe *st = c->steps.get(i)
        if st->access_kind != ChainExpr::AccessKind::Dot {
            return false
        }

        if st->resolved_decl == &null || !isa<FieldDecl>(st->resolved_decl) {
            return false
        }

        if dyn_cast<FieldDecl>(st->resolved_decl)->is_static() {
            return false
        }
    }

    return true
}

/// \p e mentions \p d at its root (`&x.a` takes the copy's address too).
fn for_copy_rooted(e: unsafe *Expr, d: unsafe *Decl) -> bool {
    var unsafe *x = e
    while x != &null && isa<ParenExpr>(x) {
        x = dyn_cast<ParenExpr>(x)->inner
    }

    var unsafe *ni = dyn_cast<NamedIdentExpr>(x)
    if ni != &null {
        return ni->resolved_decl == d
    }

    var unsafe *c = dyn_cast<ChainExpr>(x)
    if c == &null {
        return false
    }

    var unsafe *head = dyn_cast<NamedIdentExpr>(c->base)
    return head != &null && head->resolved_decl == d
}

///
/// \class ForCopyScan
/// \brief One binder's uses in one loop body, in evaluation order: the RHS
///        of an assignment is walked before its target is recorded.
///
pub class ForCopyScan derives RecursiveASTVisitor<ForCopyScan> {
    pub var  target:      unsafe *Decl = &null
    pub var  first_write: SourceRange
    pub var  has_write:   bool         = false
    pub var  read_after:  bool         = false ///< a read after the first write.
    pub var  escaped:     bool         = false ///< a non-@inout `&x`, or `x` in a closure.
    pub var  inner_write: bool         = false ///< a write inside a nested loop.
    pub var  inner_read:  bool         = false ///< a read inside a nested loop.
    priv var _depth:      i32          = 0
    priv var _closure:    i32          = 0

    fn ForCopyScan(self, d: unsafe *Decl) {
        self.target = d
    }

    pub fn scan(self, body: unsafe *CompoundStmt) {
        self.dyn()->traverse_block(body)
    }

    priv fn _write(self, r: SourceRange) {
        if self._closure > 0 {
            self.escaped = true
            return
        }

        if !self.has_write {
            self.has_write   = true
            self.first_write = r
        }

        if self._depth > 0 {
            self.inner_write = true
        }
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if n->resolved_decl != self.target {
            return true
        }

        if self._closure > 0 {
            self.escaped = true
        }

        if self.has_write {
            self.read_after = true
        }

        if self._depth > 0 {
            self.inner_read = true
        }

        return true
    }

    fn traverse_assign_operator_expr(self, n: *AssignOperatorExpr) -> *AssignOperatorExpr {
        if !for_copy_place(n->lhs, self.target) {
            return RecursiveASTVisitor<ForCopyScan>::traverse_assign_operator_expr(
                self,
                n,
            )
        }

        // The value is computed first: `x.n = x.n + 1` reads, then writes.
        // The target itself is not a read, not even for `+=`: the old value
        // it reads feeds only the lost write.
        if n->rhs != &null {
            n->rhs = self.dyn()->dispatch_expr(n->rhs)
        }

        self._write(n->lhs->range)
        return n
    }

    fn traverse_unary_operator_expr(self, n: *UnaryOperatorExpr) -> *UnaryOperatorExpr {
        if n->op_token.kind == TokenKind::OpAmp && for_copy_rooted(n->operand, self.target) {
            if n->is_mode_marker && for_copy_place(n->operand, self.target) {
                self._write(n->operand->range)
                return n
            }

            self.escaped = true
        }

        return RecursiveASTVisitor<ForCopyScan>::traverse_unary_operator_expr(
            self,
            n,
        )
    }

    fn traverse_closure_expr(self, n: unsafe *ClosureExpr) -> unsafe *ClosureExpr {
        ++self._closure
        var unsafe *out = RecursiveASTVisitor<ForCopyScan>::traverse_closure_expr(
            self,
            n,
        )

        --self._closure
        return out
    }

    fn traverse_while_loop_stmt(self, n: *WhileLoopStmt) -> *WhileLoopStmt {
        ++self._depth
        var *out = RecursiveASTVisitor<ForCopyScan>::traverse_while_loop_stmt(
            self,
            n,
        )

        --self._depth
        return out
    }

    fn traverse_loop_stmt(self, n: *LoopStmt) -> *LoopStmt {
        ++self._depth
        var *out = RecursiveASTVisitor<ForCopyScan>::traverse_loop_stmt(self, n)
        --self._depth
        return out
    }

    fn traverse_ranged_for_stmt(self, n: unsafe *RangedForStmt) -> unsafe *RangedForStmt {
        ++self._depth
        var unsafe *out = RecursiveASTVisitor<ForCopyScan>::traverse_ranged_for_stmt(
            self,
            n,
        )

        --self._depth
        return out
    }

    fn traverse_indexed_for_stmt(self, n: *IndexedForStmt) -> *IndexedForStmt {
        ++self._depth
        var *out = RecursiveASTVisitor<ForCopyScan>::traverse_indexed_for_stmt(
            self,
            n,
        )

        --self._depth
        return out
    }
}

///
/// \class ForCopyLint
/// \brief The pass. Read-only: emits warnings, writes nothing to the AST.
///
pub class ForCopyLint derives RecursiveASTVisitor<ForCopyLint> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil

    fn ForCopyLint(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

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

    fn traverse_ranged_for_stmt(self, n: unsafe *RangedForStmt) -> unsafe *RangedForStmt {
        if n == &null {
            return n
        }

        var unsafe *out = RecursiveASTVisitor<ForCopyLint>::traverse_ranged_for_stmt(
            self,
            n,
        )

        self._check(n)
        return out
    }

    priv fn _by_value(self, iter: IterKind) -> bool {
        // An integer range yields fresh counters, and a pack unrolls one
        // binding per element: neither has an element to write back to.
        return iter == IterKind::Array
            || iter == IterKind::Slice
            || iter == IterKind::Vector
            || iter == IterKind::Set
            || iter == IterKind::Map
            || iter == IterKind::String
            || iter == IterKind::User
            || iter == IterKind::Cxx
    }

    priv fn _check(self, n: unsafe *RangedForStmt) {
        if n->is_eval || n->body == &null {
            return
        }

        if !self._by_value(n->iter_kind) {
            return
        }

        for var i: usize = 0; i < n->bindings.size(); ++i {
            var unsafe *b = n->bindings.get(i)
            if b->is_discard || b->is_const || b->name == &null || b->decl == &null {
                continue
            }

            if b->shorthand.has(BindingShorthand::Pointer) {
                continue
            }

            self._check_binder(n, b->decl, b->name->range)
        }
    }

    priv fn _check_binder(self,
                          n:    unsafe *RangedForStmt,
                          v:    unsafe *VariableDecl,
                          name: SourceRange) {
        if v->is_poisoned() || v->type_ == &null || !name.is_valid() {
            return
        }

        var unsafe *c = canon_unqual(v->type_->canonical)
        if c == &null || c->is_dependent() {
            return
        }

        // A C++ reference binder IS the element; a pointer element (or a
        // nullable one) writes through to shared data either way.
        if isa<CXXLValueRefType>(c) || isa<CXXRValueRefType>(c) {
            return
        }

        var unsafe *base  = c
        var unsafe *inner = self._tu.nullable_inner(c)
        if inner != &null {
            base = canon_unqual(inner)
        }

        if base == &null || self._tu.pointer_shape(base).depth > 0 {
            return
        }

        var unsafe *d   = unsafe (v as unsafe *Decl)
        var        scan = ForCopyScan(d)
        scan.scan(n->body)
        if !scan.has_write || scan.read_after || scan.escaped {
            return
        }

        if scan.inner_write && scan.inner_read {
            return
        }

        var nm = self.sc->ctx->get_spelling(name)
        var b = self.sc->diag->report(
            DiagID::SC275W,
            scan.first_write.start,
            "this writes to a copy of the element; the collection is not changed",
        )

        b.first(scan.first_write)
        b.note(
            DiagCode(DiagID::SC275N),
            name.start,
            f"'{nm}' is bound by value here; 'for *{nm}' binds a pointer to the element, and uses of '{nm}' then go through it",
        )

        b.insert(name.start, "*", f"bind '{nm}' to the element")
        b.emit()
    }
}
