/// --- The Kairo Project ------------------ Sema/Check/EvalUsageChecking.k --- ///
///
///   \brief What an eval context may contain (EVAL.md §5, §6).
///
///   \detail
///     C++ computes every eval value (EVAL.md §0), so a mistake left to it is
///     a clang error on the emitted text. This pass reports the ones Kairo
///     can name first, at the Kairo source.
///
///     `eval for`:
///       - iterates a range whose bounds are eval-able, an eval-able array
///         (an `eval` constant, a list literal of eval-able elements), or a
///         call of an eval generator (`eval fn g() -> yield T`). Anything
///         else is an error; a non-eval generator gets a fix-it adding
///         `eval` to it.
///       - has one binding, no label, and no C-style form;
///       - may `return` a value only of a type the expansion's return slot
///         can default-construct (a scalar, pointer or enum).
///       Inside an `eval fn` an `eval for` is an ordinary loop (IterLowering;
///       the function already runs at compile time), so none of this
///       applies there.
///     An eval generator is called only as an `eval for`'s iterable: it
///     returns a compile-time buffer, not a Yield<T>.
///     A function-body `eval if` EvalIfFolding could not fold is C++ `if
///     constexpr`: its condition must still be eval-able.
///
///     Eval-able: literals; `sizeof` / `alignof` / `typeof`; builtin
///     operators and casts over eval-able operands; an `eval` variable or
///     field; a generic value parameter; an enclosing `eval for`'s binding
///     (a constant in each copy); a call of an `eval fn` with eval-able
///     arguments.
///
///   Phase: CHECKS (after X: reads callee bindings and iter_kind)
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
import Sema::Type::TypeUtil::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Types::*;
import AST::Kind::StmtKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

/// The first `return` with a value in a statement, not counting closures'.
class ReturnFinder derives RecursiveASTVisitor::<ReturnFinder> {
    pub var found: *ReturnStmt = &null;
    fn ReturnFinder(self) { }
    fn visit_return_stmt(self, n: *ReturnStmt) -> bool {
        if (self.found == &null) && (n->value != &null) { self.found = n; }
        return true;
    }
    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr { return n; }
}

class EvalUsageChecking derives RecursiveASTVisitor::<EvalUsageChecking> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;

    /// The function whose body is walked (innermost), or null.
    priv var _fns: vec::<*FunctionDecl>;
    /// Bindings of the `eval for`s around the walk: constants in each copy.
    priv var _ef_binds: vec::<*Decl>;
    /// The iterables of those `eval for`s: the one place an eval generator
    /// may be called.
    priv var _ef_iters: vec::<*Expr>;
    /// `eval for` bodies around the walk (outside an eval fn).
    priv var _ef_depth: u32 = 0;

    fn EvalUsageChecking(self, sc: *SemaContext) {
        self.sc = sc;
        self.tu = TypeUtil(sc);
    }

    fn run(self) {
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl { self.dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dispatch_expr(item.as_expr()); }
                default { 0; }
            }
        }
    }

    // === scopes =============================================================

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        self._fns.push_back(n);
        var sd = self._ef_depth;
        self._ef_depth = 0;
        var r = RecursiveASTVisitor::<EvalUsageChecking>::traverse_function_decl(n);
        self._ef_depth = sd;
        self._fns.pop_back();
        return r;
    }

    priv fn _in_eval_fn(self) -> bool {
        return (self._fns.size() > 0) && self._fns[self._fns.size() - 1]->is_eval();
    }

    // === eval for ===========================================================

    fn traverse_ranged_for_stmt(self, n: *RangedForStmt) -> *RangedForStmt {
        if (!n->is_eval) || self._in_eval_fn() {
            return RecursiveASTVisitor::<EvalUsageChecking>::traverse_ranged_for_stmt(n);
        }
        self._check_eval_for(n);
        if n->iterable != &null {
            self._ef_iters.push_back(n->iterable);
            n->iterable = self.dyn()->dispatch_expr(n->iterable);
            self._ef_iters.pop_back();
        }
        var pushed = false;
        if (n->bindings.size() == 1) && (n->bindings[0].decl != &null) {
            self._ef_binds.push_back(n->bindings[0].decl);
            pushed = true;
        }
        self._ef_depth += 1;
        n->body = self.dyn()->traverse_block(n->body);
        self._ef_depth -= 1;
        if pushed { self._ef_binds.pop_back(); }
        return n;
    }

    fn visit_indexed_for_stmt(self, n: *IndexedForStmt) -> bool {
        if (!n->is_eval) || self._in_eval_fn() { return true; }
        var b = self.sc->diag->report(DiagID::SC001E, n->range.start,
            "an 'eval for' iterates a range, an eval array or an eval generator; the C-style form is not one: write 'eval for i in lo..hi\x27");
        b.first(SourceRange::from_bounds(n->range.start, u32(8)));
        b.emit();
        return true;
    }

    fn visit_labeled_stmt(self, n: *LabeledStmt) -> bool {
        var rf = dyn_cast::<RangedForStmt>(n->inner);
        if (rf == &null) || (!rf->is_eval) || self._in_eval_fn() { return true; }
        var b = self.sc->diag->report(DiagID::SC116E, n->range.start, "a labeled 'eval for' is not yet supported");
        b.first(n->range);
        b.emit();
        return true;
    }

    priv fn _check_eval_for(self, n: *RangedForStmt) {
        if n->bindings.size() != 1 {
            self._err(n->range, "an 'eval for' binds one name; destructure inside the body");
            return;
        }
        self._check_return_slot(n);
        var it = n->iterable;
        if (it == &null) || it->is_poisoned() || (it->type_ == &null) { return; }
        var e = self.tu.strip_parens(it);

        if isa::<RangeExpr>(e) {
            var r = cast::<RangeExpr>(e);
            if (r->begin == &null) || (r->end == &null) {
                self._err(e->range, "an 'eval for' over a range needs both bounds");
                return;
            }
            self._need_eval(r->begin, "the lower bound of an 'eval for' range");
            self._need_eval(r->end, "the upper bound of an 'eval for' range");
            return;
        }

        // An eval generator: a call of an `eval fn ... -> yield T`.
        var call = dyn_cast::<CallExpr>(e);
        if call != &null {
            var f = self._callee_fn(call);
            if (f != &null) && f->is_generator {
                if !f->is_eval() {
                    var nm = self.tu.decl_name(static_cast::<*Decl>(f));
                    var b = self.sc->diag->report(DiagID::SC001E, e->range.start,
                        f"an 'eval for' iterates an eval generator; '{nm}' is not 'eval\x27");
                    b.first(e->range);
                    b.note(DiagID::SC001N, f->range.start, f"'{nm}' is declared here").first(f->name.range);
                    if !self._foreign(static_cast::<*Decl>(f)) {
                        b.insert(f->range.start, "eval ", f"make '{nm}' an 'eval fn\x27");
                    }
                    b.emit();
                    return;
                }
                for var i: usize = 0; i < call->args.size(); ++i {
                    self._need_eval(call->args[i], "an argument of an 'eval for' generator");
                }
                return;
            }
        }

        // An array: an eval constant, or a list literal of eval-able elements.
        var at = canon_unqual(it->type_);
        if (at != &null) && isa::<FixedArrayType>(at) && (!cast::<FixedArrayType>(at)->is_incomplete) {
            if isa::<ListLiteralExpr>(e) {
                var ll = cast::<ListLiteralExpr>(e);
                for var i: usize = 0; i < ll->elements.size(); ++i {
                    self._need_eval(ll->elements[i], "an element of an 'eval for' array");
                }
                return;
            }
            if self._eval_able(e) { return; }
        }

        var b = self.sc->diag->report(DiagID::SC001E, e->range.start,
            f"an 'eval for' iterates a range with eval bounds, an eval array or an eval generator; this is '{self.tu.str(it->type_)}\x27");
        b.first(e->range);
        var pv = self._plain_var(e);
        if pv != &null {
            var pn = self.sc->ctx->get_spelling(pv->name);
            b.note(DiagID::SC001N, pv->name.range.start, f"'{pn}' is declared here, not as 'eval\x27").first(pv->name.range);
        }
        b.emit();
    }

    /// A `return` with a value inside an `eval for` goes through a slot the
    /// expansion default-constructs (EmitIR::_eval_for).
    priv fn _check_return_slot(self, n: *RangedForStmt) {
        if self._fns.size() == 0 { return; }
        var f = self._fns[self._fns.size() - 1];
        if (f->return_type == &null) || (f->return_type->canonical == &null) { return; }
        var c = canon_unqual(f->return_type->canonical);
        if (c == &null) || isa::<BuiltinType>(c) || isa::<PointerType>(c) || isa::<GenericParamType>(c) { return; }
        var rd = (cast::<RecordType>(c)->decl) if (isa::<RecordType>(c)) else (&null);
        if (rd != &null) && isa::<EnumDecl>(rd) && (!cast::<EnumDecl>(rd)->is_adt) { return; }
        var rs = ReturnFinder();
        rs.dispatch_stmt(static_cast::<*Stmt>(n->body));
        if rs.found == &null { return; }
        var b = self.sc->diag->report(DiagID::SC116E, rs.found->range.start,
            f"returning a '{self.tu.str(c)}' from inside an 'eval for' is not yet supported; return it after the loop");
        b.first(rs.found->range);
        b.emit();
    }

    // === eval generators ====================================================

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        var f = self._callee_fn(n);
        if (f == &null) || (!f->is_eval()) || (!f->is_generator) { return true; }
        var e = static_cast::<*Expr>(n);
        for var i: usize = 0; i < self._ef_iters.size(); ++i {
            if self.tu.strip_parens(self._ef_iters[i]) == e { return true; }
        }
        var nm = self.tu.decl_name(static_cast::<*Decl>(f));
        var b = self.sc->diag->report(DiagID::SC001E, n->range.start,
            f"'{nm}' is an eval generator; it runs at compile time and can only be iterated by an 'eval for\x27");
        b.first(n->range);
        b.note(DiagID::SC001N, f->range.start, f"'{nm}' is declared here").first(f->name.range);
        b.emit();
        return true;
    }

    // === eval if (a body's, left as `if constexpr`) ============================

    fn visit_conditional_stmt(self, n: *ConditionalStmt) -> bool {
        if (!n->is_eval) || self._in_eval_fn() { return true; }
        if (n->cond == &null) || n->cond->is_poisoned() { return true; }
        self._need_eval(n->cond, "the condition of an 'eval if\x27");
        return true;
    }

    // === eval-able ==========================================================

    /// \p e must be eval-able (file header); reported at its first part that
    /// is not, as \p what.
    priv fn _need_eval(self, e: *Expr, what: string) {
        if (e == &null) || e->is_poisoned() { return; }
        var bad = self._first_runtime(e);
        if bad == &null { return; }
        var b = self.sc->diag->report(DiagID::SC001E, bad->range.start,
            f"{what} must be evaluable at compile time; this is a run-time value");
        b.first(bad->range);
        var pv = self._plain_var(bad);
        if pv != &null {
            var pn = self.sc->ctx->get_spelling(pv->name);
            b.note(DiagID::SC001N, pv->name.range.start, f"'{pn}' is declared here, not as 'eval\x27").first(pv->name.range);
        }
        b.emit();
    }

    priv fn _eval_able(self, e: *Expr) -> bool { return self._first_runtime(e) == &null; }

    /// The first sub-expression of \p e0 that is not eval-able, or null.
    priv fn _first_runtime(self, e0: *Expr) -> *Expr {
        if e0 == &null { return &null; }
        var e = self.tu.strip_parens(e0);
        if e == &null { return &null; }
        if isa::<IntegerLiteralExpr>(e) || isa::<FloatingLiteralExpr>(e) || isa::<BooleanLiteralExpr>(e)
        || isa::<CharacterLiteralExpr>(e) || isa::<StringLiteralExpr>(e) || isa::<NullLiteralExpr>(e) { return &null; }
        if isa::<SizeOfExpr>(e) || isa::<AlignOfExpr>(e) || isa::<TypeOfExpr>(e) { return &null; }
        if isa::<UnaryOperatorExpr>(e) {
            var u = cast::<UnaryOperatorExpr>(e);
            if u->resolved_op != &null { return e; }
            var k = u->op_token.kind;
            if (k == TokenKind::OpAmp) || (k == TokenKind::OpStar) { return e; }   // pointers: no address at compile time.
            return self._first_runtime(u->operand);
        }
        if isa::<BinaryOperatorExpr>(e) {
            var b = cast::<BinaryOperatorExpr>(e);
            if b->resolved_op != &null { return e; }
            var l = self._first_runtime(b->lhs);
            if l != &null { return l; }
            return self._first_runtime(b->rhs);
        }
        if isa::<TypeCastExpr>(e) {
            var c = cast::<TypeCastExpr>(e);
            if (c->resolved_op != &null) || (c->resolved_ctor != &null) { return e; }
            return self._first_runtime(c->operand);
        }
        if isa::<ListLiteralExpr>(e) {
            var ll = cast::<ListLiteralExpr>(e);
            for var i: usize = 0; i < ll->elements.size(); ++i {
                var x = self._first_runtime(ll->elements[i]);
                if x != &null { return x; }
            }
            return &null;
        }
        if isa::<NamedIdentExpr>(e) { return (&null) if (self._eval_decl(cast::<NamedIdentExpr>(e)->resolved_decl)) else (e); }
        if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            if ch->steps.size() == 0 { return e; }
            var st = ch->steps.get(ch->steps.size() - 1);
            var d = (st->name->resolved_decl) if (st->name != &null) else (&null);
            if d == &null { d = st->resolved_decl; }
            return (&null) if (self._eval_decl(d)) else (e);
        }
        if isa::<CallExpr>(e) {
            var c = cast::<CallExpr>(e);
            var f = self._callee_fn(c);
            if (f == &null) || (!f->is_eval()) { return e; }
            for var i: usize = 0; i < c->args.size(); ++i {
                var x = self._first_runtime(c->args[i]);
                if x != &null { return x; }
            }
            return &null;
        }
        return e;
    }

    /// A name that is a compile-time constant here.
    priv fn _eval_decl(self, d: *Decl) -> bool {
        if d == &null { return false; }
        var vd = dyn_cast::<VariableDecl>(d);
        if vd != &null {
            if vd->is_eval() { return true; }
            for var i: usize = 0; i < self._ef_binds.size(); ++i { if self._ef_binds[i] == d { return true; } }
            return false;
        }
        var fd = dyn_cast::<FieldDecl>(d);
        if fd != &null { return fd->is_eval(); }
        var gp = dyn_cast::<GenericParamDecl>(d);
        if gp != &null { return gp->is_const_param; }
        if isa::<EnumVariantDecl>(d) { return true; }
        return false;
    }

    // === helpers ============================================================

    /// The function a call selected, or null.
    priv fn _callee_fn(self, c: *CallExpr) -> *FunctionDecl {
        var e = self.tu.strip_parens(c->callee);
        if e == &null { return &null; }
        var d: *Decl = &null;
        if isa::<NamedIdentExpr>(e) { d = cast::<NamedIdentExpr>(e)->resolved_decl; }
        else if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            if ch->steps.size() > 0 {
                var st = ch->steps.get(ch->steps.size() - 1);
                d = st->resolved_decl;
                if (d == &null) && (st->name != &null) { d = st->name->resolved_decl; }
            }
        }
        if (d == &null) && (c->ctor_decl != &null) { d = c->ctor_decl; }
        return dyn_cast::<FunctionDecl>(d);
    }

    priv fn _foreign(self, d: *Decl) -> bool { return self.tu.is_foreign(d); }

    /// The non-eval variable \p e names, for a note; null if none.
    priv fn _plain_var(self, e: *Expr) -> *VariableDecl {
        if (e == &null) || (!isa::<NamedIdentExpr>(e)) { return &null; }
        return dyn_cast::<VariableDecl>(cast::<NamedIdentExpr>(e)->resolved_decl);
    }

    priv fn _err(self, at: SourceRange, msg: string) {
        var b = self.sc->diag->report(DiagID::SC001E, at.start, msg);
        b.first(at);
        b.emit();
    }
}
