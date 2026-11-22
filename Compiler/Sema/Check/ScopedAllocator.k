/// --- The Kairo Project ----------------- Sema/Check/ScopedAllocator.k --- ///
///
/// The rules of `@set_scoped_allocator(A)` on the nodes it may stand on;
/// AttributeCheck calls in for each use and reports every other position as
/// a misplaced attribute (SC143E).
///
///   \detail
///     ScopedAllocatorExpand rewrote every use it could (a guard prepended to
///     the body or block) and left the rest alone. This is where the rest is
///     reported, after the fold of `eval if`, so an untaken branch reports
///     nothing:
///
///       - arguments other than one type (none, several, a keyword
///         argument, an expression that names no type): SC366E;
///       - a function with no body (a declaration, `= default`, an interface
///         requirement, an ffi function), or with an expression body and no
///         written return type: SC366E, the scope has no block to open in;
///       - an `extend`: SC366E, with a note at the extended type's own
///         declaration, where the attribute belongs, and a fix-it that
///         removes it;
///       - a second use with a type on one class or struct: SC366E, with a
///         note at the first, which names the one arena an object owns,
///         and a fix-it that removes the second.
///
///     The methods of a class or struct with the attribute are
///     ScopedArenaMethods' to judge (Sema/Expand/ScopedArena.k): it reports
///     the methods it cannot give the arena's guard.
///
///     A `yield` inside a function or block that carries the attribute is
///     SC367E, with a note at the attribute. A generator is a C++ coroutine
///     with no hook on suspend and resume, and the thread's scope stack
///     closes in LIFO order: a scope open across a suspension would stay in
///     effect for the caller, which could then close a scope of its own out
///     of order. Lexical only: a closure or a function declared inside does
///     not count, and a nested block that carries the attribute reports its
///     own `yield`s, so each is reported once, against the innermost scope.
///     A generator CALLED inside a scope is accepted: its body allocates
///     from whichever scope is open on the thread when it is resumed.
///
///   Phase: CHECKS (from AttributeCheck::run, before ExprTyper)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::LangItems::LangAttrs
import AST::Mixin::Annotation::AnnotationEntry
import AST::Node::Base::{
    Decl,
    Stmt,
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
    ClassDecl, EnumDecl, ExtensionDecl, FnBodyKind, FunctionDecl, StructDecl, UnionDecl,
}
import AST::Node::Expressions::{
    ClosureExpr,
    NamedArgExpr,
}
import AST::Node::Statements::{
    CompoundStmt,
    YieldStmt,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Expand::ScopedAllocator::ScopedAllocatorExpand
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil

pub class ScopedAllocatorCheck {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil

    fn ScopedAllocatorCheck(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
    }

    /// `d` may carry the attribute here: a function, a class or struct, or
    /// an `extend` (to be told it cannot). Any other declaration is a
    /// misplaced attribute, AttributeCheck's to report.
    pub static fn decl_target(d: unsafe *Decl) -> bool {
        return isa<FunctionDecl>(d)
            || isa<ClassDecl>(d)
            || isa<StructDecl>(d)
            || isa<ExtensionDecl>(d)
    }

    /// Why AttributeCheck's SC143E says the attribute is misplaced.
    pub static fn where_it_applies() -> string {
        return "applies only to a function, a block, or a class or struct"
    }

    /// Attribute `e` on declaration `d`, a decl_target.
    pub fn check_decl(self, d: unsafe *Decl, e: unsafe *AnnotationEntry) {
        if isa<ExtensionDecl>(d) {
            self._on_extend(cast<ExtensionDecl>(d), e)
            return
        }

        if isa<ClassDecl>(d) || isa<StructDecl>(d) {
            if self._check_args(e) {
                self._second_on_record(d, e)
            }

            return
        }

        var unsafe *fd = dyn_cast<FunctionDecl>(d)
        if fd == &null {
            return
        }

        var args_ok = self._check_args(e)
        if !ScopedAllocatorExpand::has_scope_body(fd) {
            self._no_body(fd, e)
            return
        }

        if args_ok && self._innermost(d, e) && fd->body_block != &null {
            self._scan_yields(unsafe (fd->body_block as unsafe *Stmt), e)
        }
    }

    /// Attribute `e` on the block statement `s`.
    pub fn check_block(self, s: unsafe *CompoundStmt, e: unsafe *AnnotationEntry) {
        var args_ok = self._check_args(e)
        if !args_ok {
            return
        }

        // One scan per block, against its innermost attribute.
        var last: unsafe *AnnotationEntry = &null
        for var i: usize = 0; i < s->annotations.size(); ++i {
            var unsafe *a = s->annotations.get(i)
            if ScopedAllocatorExpand::is_attr(self.sc, a) {
                last = a
            }
        }

        if last == e {
            self._scan_yields(unsafe (s as unsafe *Stmt), e)
        }
    }

    /// `e` is the last `@set_scoped_allocator` written on `d`.
    priv fn _innermost(self, d: unsafe *Decl, e: unsafe *AnnotationEntry) -> bool {
        var last: unsafe *AnnotationEntry = &null
        for var i: usize = 0; i < d->annotations.size(); ++i {
            var unsafe *a = d->annotations.get(i)
            if ScopedAllocatorExpand::is_attr(self.sc, a) {
                last = a
            }
        }

        return last == e
    }

    /// # the arguments

    /// SC366E unless the attribute has one argument, a type. True when it
    /// has.
    priv fn _check_args(self, e: unsafe *AnnotationEntry) -> bool {
        if ScopedAllocatorExpand::allocator_type(self.sc, e) != &null {
            return true
        }

        var at  = LangAttrs::at(LangAttrs::set_scoped_allocator())
        var why = "its argument must be a type"
        if e->args.size() == 0 {
            why = "it has none"
        } else if e->args.size() > 1 {
            why = f"it has {e->args.size()}"
        } else if isa<NamedArgExpr>(e->args[0]) {
            why = "a keyword argument names nothing it takes"
        }

        var b = self.sc->diag->report(
            DiagID::SC366E,
            e->range.start,
            LangAttrs::quoted(
                LangAttrs::set_scoped_allocator(),
            ) + f" takes one argument, the allocator type: '{at}(A)'; {why}",
        )

        b.first(e->range)
        b.emit()
        return false
    }

    /// # the positions

    priv fn _no_body(self, fd: unsafe *FunctionDecl, e: unsafe *AnnotationEntry) {
        var an = LangAttrs::quoted(LangAttrs::set_scoped_allocator())
        var msg = an.copy() + " needs a function body to open the scope in; this function has none"
        if fd->body_kind == FnBodyKind::Expr {
            msg = an.copy() + " on a function with an expression body needs the return type written ('-> T'): the scope opens in a block body, which does not infer one"
        }

        var b = self.sc->diag->report(
            DiagID::SC366E,
            e->range.start,
            msg.copy(),
        )

        b.first(e->range)
        if fd->body_kind != FnBodyKind::Expr {
            b.remove(e->range, "remove " + an)
        }

        b.emit()
    }

    /// SC366E when `e` is not the use that gives record `d` its arena
    /// (ScopedAllocatorExpand::record_attr): an object owns one.
    priv fn _second_on_record(self, d: unsafe *Decl, e: unsafe *AnnotationEntry) {
        var unsafe *first = ScopedAllocatorExpand::record_attr(self.sc, d)
        if first == &null || first == e {
            return
        }

        var an = LangAttrs::quoted(LangAttrs::set_scoped_allocator())
        var nm = self._tu.decl_name(d)
        var b = self.sc->diag->report(
            DiagID::SC366E,
            e->range.start,
            an.copy() + f" is written twice on '{nm}': an object owns one arena",
        )

        b.first(e->range)
        b.note(
            DiagCode(DiagID::SC366N),
            first->range.start,
            "this one names the arena's allocator",
        )->child_first(first->range)
        b.remove(e->range, "remove the second " + an)
        b.emit()
    }

    priv fn _on_extend(self, ext: unsafe *ExtensionDecl, e: unsafe *AnnotationEntry) {
        var an = LangAttrs::quoted(LangAttrs::set_scoped_allocator())
        var b = self.sc->diag->report(
            DiagID::SC366E,
            e->range.start,
            an.copy() + " cannot be written on an 'extend'; write it on the type's own declaration",
        )

        b.first(e->range)
        var unsafe *rd = self._extended(ext)
        if rd != &null {
            var nm = self._tu.decl_name(rd)
            b.note(
                DiagCode(DiagID::SC366N),
                rd->range.start,
                f"'{nm}' is declared here",
            )->child_first(self._name_range(rd))
        }

        b.remove(e->range, "remove " + an)
        b.emit()
    }

    /// The record an `extend` extends, its pattern for a generic one; null
    /// when the target is no record (or did not resolve).
    priv fn _extended(self, ext: unsafe *ExtensionDecl) -> unsafe *Decl {
        if ext->target == &null || ext->target->canonical == &null {
            return &null
        }

        var unsafe *rt = dyn_cast<RecordType>(
            canon_unqual(ext->target->canonical),
        )

        if rt == &null || rt->decl == &null {
            return &null
        }

        return self._tu.pattern_of(rt->decl)
    }

    priv fn _name_range(self, d: unsafe *Decl) -> SourceRange {
        if isa<ClassDecl>(d) {
            return cast<ClassDecl>(d)->name.range
        }

        if isa<StructDecl>(d) {
            return cast<StructDecl>(d)->name.range
        }

        if isa<EnumDecl>(d) {
            return cast<EnumDecl>(d)->name.range
        }

        if isa<UnionDecl>(d) {
            return cast<UnionDecl>(d)->name.range
        }

        return SourceRange::from_bounds(d->range.start, 1 as u32)
    }

    /// # yield

    priv fn _scan_yields(self, root: unsafe *Stmt, e: unsafe *AnnotationEntry) {
        var scan = ScopedYieldScan(self.sc, root, e->range)
        scan.dispatch_stmt(root)
    }
}

/// The `yield`s lexically inside one scope (ScopedAllocatorCheck's file
/// header): not into a closure, a nested function declaration, or a nested
/// block that opens a scope of its own. Each is SC367E with a note at
/// `attr`, the attribute that opens the scope; `found` counts them.
pub class ScopedYieldScan derives RecursiveASTVisitor<ScopedYieldScan> {
    pub var  sc:    unsafe *SemaContext
    pub var  found: usize               = 0
    priv var _root: unsafe *Stmt
    priv var _attr: SourceRange

    fn ScopedYieldScan(self, sc: unsafe *SemaContext, root: unsafe *Stmt, attr: SourceRange) {
        self.sc    = sc
        self._root = root
        self._attr = attr
    }

    fn visit_closure_expr(self, n: *ClosureExpr) -> bool {
        return false
    }

    fn visit_decl(self, n: *Decl) -> bool {
        return !isa<FunctionDecl>(n)
    }

    fn visit_compound_stmt(self, n: *CompoundStmt) -> bool {
        var unsafe *s = unsafe (n as unsafe *Stmt)
        return s == self._root || !ScopedAllocatorExpand::has_attr(self.sc, s)
    }

    fn visit_yield_stmt(self, n: *YieldStmt) -> bool {
        var at = SourceRange::from_bounds(n->range.start, 5 as u32)
        var b = self.sc->diag->report(
            DiagID::SC367E,
            at.start,
            "a 'yield' inside a " + LangAttrs::quoted(
                LangAttrs::set_scoped_allocator(),
            ) + " scope: the generator would suspend with the scope still open on the thread",
        )

        b.first(at)
        b.note(
            DiagCode(DiagID::SC367N),
            self._attr.start,
            "the scope opens here",
        )->child_first(self._attr)
        b.emit()
        self.found += 1
        return true
    }
}
