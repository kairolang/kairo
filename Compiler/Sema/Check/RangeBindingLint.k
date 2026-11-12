/// --- The Kairo Project ---------------- Sema/Check/RangeBindingLint.k --- ///
///
///   \brief Warn when `var t = a[i..j]` binds a split subscript's place form
///          and nothing in the scope writes through `t` (SC281W).
///
///   \detail
///     A type that declares `op []=` splits its subscript: `op []` is
///     the read form, `op []=` the place form. A `var` sub-range binding on a
///     mutable container takes the place form (StmtTyping::
///     _mark_range_binding), so `t` is a view that may be written through.
///     When nothing writes through it, the place form was not needed and may
///     have done work a read does not (a map inserts, a view marks its owner
///     changed); `const t = a[i..j]` binds the read form, and the fix-it
///     writes that:
///
///         var t = b[0..2]      // 't' is bound to the place form of ...
///         print(t[0])
///
///   \par What counts as a read
///     A whitelist, as ParamPassInference's: each reference to `t` must be
///     the base of a subscript the typer marked a read (SubscriptExpr::
///     place_ctx is SUB_READ, so no write, `&`, `@inout`, `for *` or written
///     member reached it), or the receiver of a `const self` (or static)
///     method. Anything else -- passing `t` on, copying it, returning it, a
///     `for` over it, a use the walk does not know -- keeps the binding as
///     written, with no warning.
///
///   \par What is not warned
///     `const` and `eval` bindings, a binding whose initializer did not take
///     an `op []=` (a type with no `op []=`, a const container, a range of
///     an array), implicit decls, and the builtin library (its files are not
///     the user's to edit).
///
///   Phase: CHECK (after ExprTyper: reads place_ctx and resolved_op).
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
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"

import AST::Node::Base::Expr
import AST::Node::Casting::{
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    FunctionDecl,
    StorageClass,
    VariableDecl,
}
import AST::Node::Expressions::{
    CallExpr,
    ParenExpr,
    RangeExpr,
    SubscriptExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::OperatorFacts::OperatorFacts
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::MemberTyping::{
    SUB_BIND,
    SUB_READ,
}

/// One candidate binding and what its references were.
pub struct RangeBindCand {
    pub var decl: unsafe *VariableDecl = &null
    pub var refs: usize                = 0     ///< references seen.
    pub var oks:  usize                = 0     ///< references approved as reads.
}

///
/// \class RangeBindingLint
/// \brief The pass. Read-only: emits SC281W, writes nothing to the AST.
///
pub class RangeBindingLint derives RecursiveASTVisitor<RangeBindingLint> {
    pub var  sc:    unsafe *SemaContext
    priv var _cand: cxx::std::vector<RangeBindCand>
    /// VariableDecl -> its index in _cand, plus one.
    priv var _index: llvm::DenseMap<u64, u64>
    /// The references an approving node has claimed: one approval each.
    priv var _approved: llvm::DenseSet<u64>

    fn RangeBindingLint(self, sc: unsafe *SemaContext) {
        self.sc = sc
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        if self.sc->g != &null && self.sc->g->is_builtin_fid(self.sc->ctx->fid) {
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

        for var i: usize = 0; i < self._cand.size(); ++i {
            if self._cand[i].refs == self._cand[i].oks {
                self._warn(self._cand[i].decl)
            }
        }
    }

    priv fn _strip(self, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = dyn_cast<ParenExpr>(x)->inner
        }

        return x
    }

    /// \p e names a candidate: its slot, plus one, or 0.
    priv fn _cand_of(self, e: unsafe *Expr) -> u64 {
        var unsafe *ni = dyn_cast<NamedIdentExpr>(self._strip(e))
        if ni == &null || ni->resolved_decl == &null {
            return 0
        }

        var it = self._index.find(ni->resolved_decl as usize as u64)
        if it == self._index.end() {
            return 0
        }

        return it->second
    }

    /// The reference \p e (a candidate's name) is a read.
    priv fn _approve(self, e: unsafe *Expr) {
        var slot = self._cand_of(e)
        if slot == 0 {
            return
        }

        var unsafe *ni = self._strip(e)
        var        key = ni as usize as u64
        if self._approved.count(key) != 0 {
            return
        }

        self._approved.insert(key)
        self._cand[(slot - 1) as usize].oks += 1
    }

    /// Registered before its scope's later statements are walked: the RAV
    /// visits a block's statements in order.
    fn visit_variable_decl(self, v: *VariableDecl) -> bool {
        if v->is_poisoned()
            || v->is_implicit
            || v->storage != StorageClass::Var
            || v->init == &null {
            return true
        }

        var unsafe *s = dyn_cast<SubscriptExpr>(self._strip(v->init))
        if s == &null || s->place_ctx != SUB_BIND || s->resolved_op == &null {
            return true
        }

        if s->index == &null || !isa<RangeExpr>(self._strip(s->index)) {
            return true
        }

        var unsafe *f = dyn_cast<FunctionDecl>(s->resolved_op)
        if f == &null || !OperatorFacts::is_subscript_set(f) {
            return true
        }

        var c = RangeBindCand{}
        c.decl = unsafe (v as unsafe *VariableDecl)
        self._cand.push_back(c)
        self._index[v as usize as u64] = self._cand.size() as u64
        return true
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if n->resolved_decl == &null {
            return true
        }

        var it = self._index.find(n->resolved_decl as usize as u64)
        if it != self._index.end() {
            self._cand[(it->second - 1) as usize].refs += 1
        }

        return true
    }

    /// `t[k]` read: the typer left the use unmarked (SUB_READ).
    fn visit_subscript_expr(self, n: *SubscriptExpr) -> bool {
        if n->place_ctx == SUB_READ {
            self._approve(n->base)
        }

        return true
    }

    /// `t.m()` with `m` taking `const self`, or a static.
    fn visit_call_expr(self, n: *CallExpr) -> bool {
        var unsafe *ce = dyn_cast<ChainExpr>(self._strip(n->callee))
        if ce == &null || ce->base == &null || ce->steps.size() != 1 {
            return true
        }

        var unsafe *st = ce->steps.get(0)
        var unsafe *f = if (st->resolved_decl != &null) => (dyn_cast<FunctionDecl>(
                            st->resolved_decl,
                        ))
                        else => &null
        if f == &null {
            return true
        }

        if !f->is_method() || f->is_const() {
            self._approve(ce->base)
        }

        return true
    }

    priv fn _warn(self, v: unsafe *VariableDecl) {
        if !v->name.range.is_valid() {
            return
        }

        var nm = self.sc->ctx->get_spelling(v->name)
        var b = self.sc->diag->report(
            DiagID::SC281W,
            v->name.range.start,
            f"'{nm}' binds the place form ('op []=') of its sub-range but is never written through; declare it 'const' to bind the read form",
        )

        b.first(v->name.range)
        b.second(v->init->range, "this calls 'op []='")
        if v->storage_kw.is_valid() {
            b.fix(v->storage_kw, "const", f"make '{nm}' const")
        }

        b.emit()
    }
}
