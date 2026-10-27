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
///     The restriction table (eval.mdx, Restrictions), in an eval CONTEXT --
///     an `eval fn`'s body, an `eval` binding's or field's initializer:
///       - a call only of an `eval fn` / eval constructor / eval operator
///         (fix-it: `eval` on the callee, when it is the user's); this is
///         also what keeps IO out;
///       - no pointer types or operations (`&x`, `*p`, `->`, a pointer
///         parameter);
///       - no heap allocation (a vector, set or map value);
///       - no `await`, `spawn`, `thread`, `panic`;
///       - no mutable global, static or thread variable, and no non-eval
///         global at all (a `const` global is initialized at run time);
///         in an initializer outside an eval fn, no run-time local either;
///       - no local of a type with a user-written destructor;
///       - an `eval fn` has no `where` clause (eval.mdx: `requires` only).
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
    /// > 0 inside an eval CONTEXT (file header): an eval fn's body or an
    /// eval initializer. `_ctx_fn` > 0 when one of them is an eval fn's,
    /// where the function's own locals and parameters are compile-time too.
    priv var _ctx:    u32 = 0;
    priv var _ctx_fn: u32 = 0;

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
        var ev = n->is_eval() && (!n->is_implicit);
        if ev { self._check_eval_fn(n); self._ctx += 1; self._ctx_fn += 1; }
        var r = RecursiveASTVisitor::<EvalUsageChecking>::traverse_function_decl(n);
        if ev { self._ctx -= 1; self._ctx_fn -= 1; }
        self._ef_depth = sd;
        self._fns.pop_back();
        return r;
    }

    /// An `eval` binding's initializer is an eval context.
    fn traverse_variable_decl(self, n: *VariableDecl) -> *VariableDecl {
        if n->is_eval() && (n->init != &null) {
            self._ctx += 1;
            var r = RecursiveASTVisitor::<EvalUsageChecking>::traverse_variable_decl(n);
            self._ctx -= 1;
            return r;
        }
        if self._ctx_fn > 0 { self._check_local(n); }
        return RecursiveASTVisitor::<EvalUsageChecking>::traverse_variable_decl(n);
    }

    fn traverse_field_decl(self, n: *FieldDecl) -> *FieldDecl {
        if n->is_eval() && (n->init != &null) {
            self._ctx += 1;
            var r = RecursiveASTVisitor::<EvalUsageChecking>::traverse_field_decl(n);
            self._ctx -= 1;
            return r;
        }
        return RecursiveASTVisitor::<EvalUsageChecking>::traverse_field_decl(n);
    }

    // === the restriction table ==============================================

    /// The signature of an eval fn: no `where`, no pointer parameter.
    priv fn _check_eval_fn(self, n: *FunctionDecl) {
        var nm = self.tu.decl_name(static_cast::<*Decl>(n));
        if n->where_clause != &null {
            var b = self.sc->diag->report(DiagID::SC001E, n->where_clause->range.start,
                f"an 'eval' function cannot have a 'where' clause; bound '{nm}' with 'requires\x27");
            b.first(n->where_clause->range);
            b.emit();
        }
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if (p == &null) || p->is_self || (p->type_ == &null) || (p->type_->canonical == &null) { continue; }
            if !isa::<PointerType>(canon_unqual(p->type_->canonical)) { continue; }
            var pn = self.sc->ctx->get_spelling(p->name);
            var b = self.sc->diag->report(DiagID::SC001E, p->range.start,
                f"an 'eval' function cannot take a pointer; '{pn}' is '{self.tu.str(p->type_->canonical)}\x27: there is no addressable memory at compile time");
            b.first(p->range);
            b.emit();
        }
    }

    /// A local of an eval fn: no pointer, no type with a destructor, no
    /// static / thread storage.
    priv fn _check_local(self, n: *VariableDecl) {
        var nm = self.sc->ctx->get_spelling(n->name);
        if n->is_static() || n->is_thread {
            self._err(n->name.range, f"an 'eval' function cannot declare a static or thread variable; '{nm}' outlives the evaluation");
            return;
        }
        if (n->type_ == &null) || (n->type_->canonical == &null) { return; }
        var c = canon_unqual(n->type_->canonical);
        if isa::<PointerType>(c) {
            self._err(n->name.range, f"an 'eval' function cannot hold a pointer; '{nm}' is '{self.tu.str(c)}\x27: there is no addressable memory at compile time");
            return;
        }
        var d = self.tu.record_decl(c);
        var dtor = self._user_dtor(d);
        if dtor != &null {
            var b = self.sc->diag->report(DiagID::SC001E, n->name.range.start,
                f"'{nm}' is a '{self.tu.str(c)}', whose destructor is not trivial; it cannot live in an 'eval' function");
            b.first(n->name.range);
            b.note(DiagID::SC001N, dtor->range.start, "the destructor is declared here").first(dtor->range);
            b.emit();
        }
    }

    /// \p d's user-written `op delete`, or null.
    priv fn _user_dtor(self, d: *Decl) -> *FunctionDecl {
        if d == &null { return &null; }
        var ms: *FrozenList::<*FunctionDecl> = &null;
        if isa::<ClassDecl>(d) { ms = &(cast::<ClassDecl>(d)->methods); }
        else if isa::<StructDecl>(d) { ms = &(cast::<StructDecl>(d)->methods); }
        if ms == &null { return &null; }
        for var i: usize = 0; i < ms->size(); ++i {
            var m = (*ms)[i];
            if (m == &null) || (!m->is_operator) || (m->op_token.size() == 0) { continue; }
            if m->op_token[0].kind != TokenKind::KwDelete { continue; }
            if m->body_kind == FnBodyKind::Default { continue; }
            return m;
        }
        return &null;
    }

    /// A call in an eval context: of an eval fn, an eval constructor, or a
    /// struct's implicit one.
    priv fn _check_ctx_call(self, n: *CallExpr) {
        var f = self._callee_fn(n);
        if f == &null { return; }      // a constructor no one wrote, or untyped: nothing to say.
        if f->is_eval() { return; }
        var nm  = self.tu.decl_name(static_cast::<*Decl>(f));
        var what = ("constructor") if (n->ctor_decl != &null) else ("function");
        var b = self.sc->diag->report(DiagID::SC001E, n->range.start,
            f"an eval context can call only 'eval' functions; '{nm}' is a {what} that is not 'eval\x27");
        b.first(n->range);
        b.note(DiagID::SC001N, f->range.start, f"'{nm}' is declared here").first(f->range);
        if (!self._foreign(static_cast::<*Decl>(f))) && (!f->is_implicit) && (f->body_kind == FnBodyKind::Block) {
            b.insert(f->range.start, "eval ", f"make '{nm}' an 'eval fn\x27");
        }
        b.emit();
    }

    /// A name in an eval context: a compile-time value (_eval_decl), or,
    /// in an eval fn, one of its locals or parameters.
    priv fn _check_ctx_name(self, e: *Expr, d: *Decl) {
        if d == &null { return; }
        if self._eval_decl(d) { return; }
        if isa::<ParamDecl>(d) { return; }        // a parameter of the eval fn (else not in an eval context).
        var vd = dyn_cast::<VariableDecl>(d);
        var fd = dyn_cast::<FieldDecl>(d);
        if (vd == &null) && (fd == &null) { return; }
        var global = (fd != &null) && fd->is_static();
        if vd != &null { global = self._is_global(vd); }
        if (!global) && (self._ctx_fn > 0) { return; }   // the eval fn's own local.
        if (fd != &null) && (!global) { return; }        // a member through `self` of an eval method.
        var nm = self.tu.decl_name(d);
        var why = ("a run-time local") if (!global) else ("a global, static or thread variable that is not 'eval\x27");
        var b = self.sc->diag->report(DiagID::SC001E, e->range.start,
            f"an eval context reads only compile-time values; '{nm}' is {why}");
        b.first(e->range);
        b.note(DiagID::SC001N, d->range.start, f"'{nm}' is declared here").first(d->range);
        if (vd != &null) && (vd->storage == StorageClass::Const) && (!vd->const_binding) && vd->storage_kw.is_valid() && global {
            b.fix(vd->storage_kw, "eval", f"declare '{nm}' as 'eval\x27");
        }
        b.emit();
    }

    priv fn _is_global(self, vd: *VariableDecl) -> bool {
        if vd->is_static() || vd->is_thread { return true; }
        var dc = reinterpret_cast::<*DeclContext>(vd->semantic_dc);
        if dc == &null { return false; }
        if dc->is_translation_unit() { return true; }
        var o = dc->owner_decl();
        return (o != &null) && isa::<ModuleDecl>(o);
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if self._ctx == 0 { return true; }
        self._check_ctx_name(static_cast::<*Expr>(n), n->resolved_decl);
        return true;
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if self._ctx == 0 { return true; }
        var k = n->op_token.kind;
        if (n->resolved_op == &null) && ((k == TokenKind::OpAmp) || (k == TokenKind::OpStar)) {
            self._err(n->range, "an eval context cannot take an address or dereference a pointer; there is no addressable memory at compile time");
            return true;
        }
        if (n->resolved_op != &null) && isa::<FunctionDecl>(n->resolved_op) && (!cast::<FunctionDecl>(n->resolved_op)->is_eval()) {
            self._op_not_eval(n->range, cast::<FunctionDecl>(n->resolved_op));
        }
        return true;
    }

    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        if self._ctx == 0 { return true; }
        if (n->resolved_op != &null) && isa::<FunctionDecl>(n->resolved_op) && (!cast::<FunctionDecl>(n->resolved_op)->is_eval()) {
            self._op_not_eval(n->range, cast::<FunctionDecl>(n->resolved_op));
        }
        return true;
    }

    priv fn _op_not_eval(self, at: SourceRange, f: *FunctionDecl) {
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            "an eval context can use only 'eval' operators; this one is not 'eval\x27");
        b.first(at);
        b.note(DiagID::SC001N, f->range.start, "the operator is declared here").first(f->range);
        if !self._foreign(static_cast::<*Decl>(f)) { b.insert(f->range.start, "eval ", "make it 'eval\x27"); }
        b.emit();
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        if self._ctx == 0 { return true; }
        for var i: usize = 0; i < n->steps.size(); ++i {
            var st = n->steps.get(i);
            if (st->access_kind == ChainExpr::AccessKind::Arrow) || (st->access_kind == ChainExpr::AccessKind::QuestionArrow) {
                self._err(n->range, "an eval context cannot follow a pointer ('->'); there is no addressable memory at compile time");
                return true;
            }
        }
        var d: *Decl = &null;
        if n->steps.size() > 0 {
            var st = n->steps.get(n->steps.size() - 1);
            d = st->resolved_decl;
        }
        if (d != &null) && (isa::<VariableDecl>(d) || (isa::<FieldDecl>(d) && cast::<FieldDecl>(d)->is_static())) {
            self._check_ctx_name(static_cast::<*Expr>(n), d);
        }
        return true;
    }

    fn visit_expr(self, e: *Expr) -> bool {
        if (self._ctx == 0) || (e->type_ == &null) { return true; }
        var t = e->type_;
        if self.tu.is_vector_like(t) || self.tu.is_set_like(t) || self.tu.is_map_like(t) {
            self._err(e->range, f"an eval context cannot allocate; a '{self.tu.str(t)}' needs the heap, which compile time does not have");
            return false;
        }
        return true;
    }

    fn visit_await_expr(self, n: *AwaitExpr) -> bool {
        if self._ctx > 0 { self._err(n->range, "an eval context cannot 'await'; there is no scheduler at compile time"); }
        return true;
    }

    fn visit_spawn_expr(self, n: *SpawnExpr) -> bool {
        if self._ctx > 0 { self._err(n->range, "an eval context cannot 'spawn'; there is no scheduler at compile time"); }
        return true;
    }

    fn visit_panic_stmt(self, n: *PanicStmt) -> bool {
        if self._ctx > 0 { self._err(n->range, "an eval context cannot 'panic'; there is no error handler at compile time"); }
        return true;
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
        if self._ctx > 0 { self._check_ctx_call(n); }
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
        if (c->ctor_decl != &null) && isa::<FunctionDecl>(c->ctor_decl) { return cast::<FunctionDecl>(c->ctor_decl); }
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
