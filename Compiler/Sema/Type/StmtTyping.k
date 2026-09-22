/// --- The Kairo Project ---------------------- Sema/Type/StmtTyping.k --- ///
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import Sema::Resolve::ResolutionState::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Patterns::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::StmtKind::*;
import Token::TokenKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Diagnostic::Registry::*;
import AST::ParamMode::*;

class TyperFrame {
    pub var fn_decl:  *FunctionDecl = &null;   ///< null for a closure.
    pub var closure:  *ClosureExpr  = &null;
    pub var declared: *Type = &null;           ///< return type, null = infer.
    pub var inferred: *Type = &null;           ///< join of `return e` seen so far.
    pub var saw_return_value: bool = false;
    pub var saw_bare_return:  bool = false;
    fn TyperFrame(self) { }
}

/// Derives the RAV rather than sitting beside it: these traverse_ methods are
/// OVERRIDES, and two sibling bases declaring the same name is an ambiguity in
/// the emitted C++, not an override. ExprTyper therefore reaches the visitor
/// through this mixin and does not derive it a second time.
class <T> StmtTyping derives RecursiveASTVisitor::<T> {
    priv inline fn dyn(self) -> *T { return static_cast::<*T>(&self); }

    // === frames =============================================================

    fn push_fn_frame(self, f: *FunctionDecl, declared: *Type) {
        var fr = TyperFrame{};
        fr.fn_decl  = f;
        fr.declared = declared;
        dyn()->frames.push_back(fr);
    }

    fn push_closure_frame(self, c: *ClosureExpr, declared: *Type) {
        var fr = TyperFrame{};
        fr.closure  = c;
        fr.declared = declared;
        dyn()->frames.push_back(fr);
    }

    fn pop_frame(self) {
        if !dyn()->frames.empty() { dyn()->frames.pop_back(); }
    }

    fn cur_frame(self) -> *TyperFrame {
        if dyn()->frames.empty() { return &null; }
        return &(dyn()->frames[dyn()->frames.size() - 1]);
    }

    fn frame_inferred_return(self) -> *Type {
        var fr = self.cur_frame();
        if fr == &null { return &null; }
        if (fr->inferred == &null) && (!fr->saw_return_value) { return dyn()->tu.builtin(BuiltinKind::Void); }
        return fr->inferred;
    }

    fn in_unsafe(self) -> bool {
        if dyn()->unsafe_depth > 0 { return true; }
        var fr = self.cur_frame();
        if (fr != &null) && (fr->fn_decl != &null) && fr->fn_decl->is_unsafe() { return true; }
        return false;
    }

    // === return type on demand ==============================================

    /// PRE: T ran. Declared -> canonical; `!` -> Never; expr-bodied without an
    /// annotation -> typed now under a cycle guard; a foreign one is read.
    fn fn_return_type(self, f: *FunctionDecl) -> *Type {
        if f == &null { return &null; }
        if f->is_noreturn { return dyn()->tu.builtin(BuiltinKind::Never); }
        if f->return_type != &null { return f->return_type->canonical; }
        if f->body_kind != FnBodyKind::Expr { return dyn()->tu.builtin(BuiltinKind::Void); }
        if f->body_expr == &null { return dyn()->tu.builtin(BuiltinKind::Void); }

        if dyn()->tu.is_foreign(static_cast::<*Decl>(f)) {
            // DAG order: its own TU typed it and wrote the slot. Null here means
            // it failed there, and that TU reported it.
            return (f->body_expr->type_) if (f->body_expr->type_ != &null) else (&null);
        }

        var st = dyn()->sc->rstate.decl_state(static_cast::<*Decl>(f));
        if st == ResolveState::Resolved { return (f->return_type->canonical) if (f->return_type != &null) else (f->body_expr->type_); }
        if st == ResolveState::Errored  { return &null; }
        if st == ResolveState::InProgress {
            dyn()->sc->diag->report(DiagID::SC001E, f->range.start,
                f"cannot infer the return type of '{dyn()->tu.decl_name(static_cast::<*Decl>(f))}': its body refers to itself; annotate the return type"
            ).first(f->range).emit();
            f->poison();
            dyn()->sc->rstate.set_decl_state(static_cast::<*Decl>(f), ResolveState::Errored);
            return &null;
        }
        if !dyn()->sc->rstate.begin_decl(static_cast::<*Decl>(f), f->range) { return &null; }

        self.push_fn_frame(f, &null);
        var saved_unsafe = dyn()->unsafe_depth;
        dyn()->unsafe_depth = 0;
        var t = dyn()->type_of(f->body_expr, &null);
        dyn()->unsafe_depth = saved_unsafe;
        self.pop_frame();

        var ok = (t != &null) && (!f->body_expr->is_poisoned());
        if ok { f->return_type = canon_unqual(t); }   // inferred slot := canonical.
        dyn()->sc->rstate.finish_decl(static_cast::<*Decl>(f), ok || (!f->body_expr->is_poisoned()));
        return t;
    }

    /// A variable's canonical, inferring a file-scope `var x = e` on demand
    /// when a use precedes its declaration in walk order.
    fn var_type(self, v: *VariableDecl) -> *Type {
        if v == &null { return &null; }
        if v->type_ != &null { return v->type_->canonical; }
        if v->init == &null { return &null; }
        if dyn()->tu.is_foreign(static_cast::<*Decl>(v)) { return v->init->type_; }
        var st = dyn()->sc->rstate.decl_state(static_cast::<*Decl>(v));
        if st == ResolveState::Errored { return &null; }
        if st == ResolveState::InProgress {
            dyn()->sc->diag->report(DiagID::SC001E, v->range.start,
                f"cannot infer the type of '{dyn()->tu.decl_name(static_cast::<*Decl>(v))}': its initializer refers to itself"
            ).first(v->range).emit();
            v->poison();
            dyn()->sc->rstate.set_decl_state(static_cast::<*Decl>(v), ResolveState::Errored);
            return &null;
        }
        if st == ResolveState::Resolved { return (v->type_->canonical) if (v->type_ != &null) else (&null); }
        if !dyn()->sc->rstate.begin_decl(static_cast::<*Decl>(v), v->range) { return &null; }
        var t = dyn()->type_of(v->init, &null);
        dyn()->mark_list_storage(v->init);
        self._reject_array_copy(v, t);
        if t != &null { v->type_ = canon_unqual(t); }
        dyn()->sc->rstate.finish_decl(static_cast::<*Decl>(v), t != &null);
        return t;
    }

    priv fn _reject_array_return(self, f: *FunctionDecl, t: *Type) {
        var c = canon_unqual(t);
        if (c == &null) || (!isa::<FixedArrayType>(c)) { return; }
        dyn()->sc->diag->report(DiagID::SC001E, f->range.start,
            f"'{dyn()->tu.decl_name(static_cast::<*Decl>(f))}' returns an array; an array is not returned by value, return '[T]' or fill an '@inout' parameter"
        ).first(f->name.range).emit();
    }

    /// An array is initialized from a list literal and from nothing else:
    /// copying one is not an initialization C++ has.
    priv fn _reject_array_copy(self, v: *VariableDecl, t: *Type) {
        var c = canon_unqual(t);
        if (c == &null) || (!isa::<FixedArrayType>(c)) { return; }
        var init = dyn()->tu.strip_parens(v->init);
        if (init == &null) || init->is_poisoned() || isa::<ListLiteralExpr>(init) { return; }
        dyn()->fail(init, "an array is not copyable; initialize it from a list literal, or view the source through a slice or a pointer");
    }

    // === traversal overrides (scope) ========================================

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        if n == &null { return n; }
        if n->is_poisoned() { return n; }

        // signature pieces first: defaults against their param types.
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if (p == &null) || (p->default_val == &null) { continue; }
            var pt = (p->type_->canonical) if (p->type_ != &null) else (&null);
            dyn()->type_of(p->default_val, pt);
            if pt != &null { dyn()->check_convertible(p->default_val, pt); }
        }
        // `[T; N]` is a C array: by value it would decay to a pointer and
        // pass by reference. `const` and `@inout` say what is meant.
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if (p == &null) || p->is_self || (p->type_ == &null) { continue; }
            var pc = canon_unqual(p->type_->canonical);
            if (pc == &null) || (!isa::<FixedArrayType>(pc)) { continue; }
            if p->is_const || (p->mode != ParamMode::Value) { continue; }
            dyn()->sc->diag->report(DiagID::SC001E, p->range.start,
                f"parameter '{dyn()->tu.param_name(p)}' takes an array by value; write 'const', '@inout', or take a slice"
            ).first(p->range).emit();
        }
        if n->requires_clause != &null { dyn()->type_of(n->requires_clause, dyn()->tu.builtin(BuiltinKind::Bool)); }
        if n->where_clause != &null    { dyn()->require_bool(n->where_clause, "a 'where' clause"); }

        var declared: *Type = &null;
        if n->return_type != &null { declared = n->return_type->canonical; }
        if n->is_noreturn { declared = dyn()->tu.builtin(BuiltinKind::Never); }
        if (n->return_type == &null) && (!n->is_noreturn) && (n->body_kind != FnBodyKind::Expr) {
            declared = dyn()->tu.builtin(BuiltinKind::Void);
        }

        if n->body_kind == FnBodyKind::Expr {
            self.fn_return_type(n);   // demand path owns the frame + slot write.
            if n->return_type != &null { self._reject_array_return(n, n->return_type->canonical); }
            return n;
        }
        self._reject_array_return(n, declared);

        self.push_fn_frame(n, declared);
        var saved_unsafe = dyn()->unsafe_depth;
        dyn()->unsafe_depth = 0;
        if n->body_block != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body_block)); }
        dyn()->unsafe_depth = saved_unsafe;
        self.pop_frame();
        return n;
    }

    fn traverse_field_decl(self, n: *FieldDecl) -> *FieldDecl {
        if n == &null { return n; }
        if n->init != &null {
            var ft = (n->type_->canonical) if (n->type_ != &null) else (&null);
            dyn()->type_of(n->init, ft);
            dyn()->reject_slice_literal(n->init, "used as a field default");
            if ft != &null { dyn()->check_convertible(n->init, ft); }
        }
        return n;
    }

    fn traverse_enum_variant_decl(self, n: *EnumVariantDecl) -> *EnumVariantDecl {
        if n == &null { return n; }
        if n->discriminant != &null {
            var edc = reinterpret_cast::<*DeclContext>(n->semantic_dc);
            var ed  = (dyn_cast::<EnumDecl>(edc->owner_decl())) if (edc != &null) else (&null);
            var under: *Type = dyn()->tu.builtin(BuiltinKind::U32);
            if (ed != &null) && (ed->underlying != &null) && (ed->underlying->canonical != &null) { under = ed->underlying->canonical; }
            dyn()->type_of(n->discriminant, under);
            dyn()->check_convertible(n->discriminant, under);
        }
        for var i: usize = 0; i < n->payload.size(); ++i { self.traverse_field_decl(n->payload[i]); }
        return n;
    }

    fn traverse_variable_decl(self, n: *VariableDecl) -> *VariableDecl {
        if n == &null { return n; }
        if n->is_poisoned() { return n; }
        var declared: *Type = &null;
        if n->type_ != &null {
            if n->type_->is_poisoned() { if n->init != &null { dyn()->type_of(n->init, &null); } return n; }
            declared = n->type_->canonical;
        }
        if n->init == &null {
            if (n->type_ == &null) {
                dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                    f"'{dyn()->tu.decl_name(static_cast::<*Decl>(n))}' has neither a type nor an initializer"
                ).first(n->range).emit();
                n->poison();
            }
            return n;
        }
        var st = dyn()->sc->rstate.decl_state(static_cast::<*Decl>(n));
        if st != ResolveState::Unresolved { return n; }   // demand-typed already.
        dyn()->sc->rstate.begin_decl(static_cast::<*Decl>(n), n->range);
        var t = dyn()->type_of(n->init, declared);
        dyn()->mark_list_storage(n->init);
        self._reject_array_copy(n, (declared) if (declared != &null) else (t));
        var ok = true;
        if declared != &null {
            ok = dyn()->check_convertible(n->init, declared);
        } else if t != &null {
            if dyn()->tu.is_void(t) {
                dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                    f"'{dyn()->tu.decl_name(static_cast::<*Decl>(n))}' is initialized with an expression of type 'void\x27"
                ).first(n->range).emit();
                n->poison(); ok = false;
            } else {
                n->type_ = canon_unqual(t);   // inferred slot := the value's type; a copy has no cv.
            }
        } else if n->init->is_poisoned() {
            ok = false;
        }
        dyn()->sc->rstate.finish_decl(static_cast::<*Decl>(n), ok);
        return n;
    }

    // === statements =========================================================

    fn traverse_expression_stmt(self, n: *ExpressionStmt) -> *ExpressionStmt {
        if (n == &null) || (n->expr == &null) { return n; }
        dyn()->type_of(n->expr, &null);
        return n;
    }

    fn traverse_return_stmt(self, n: *ReturnStmt) -> *ReturnStmt {
        if n == &null { return n; }
        var fr = self.cur_frame();
        if fr == &null {
            if n->value != &null { dyn()->type_of(n->value, &null); }
            return n;
        }
        if n->value == &null {
            fr->saw_bare_return = true;
            if (fr->declared != &null) && (!dyn()->tu.is_void(fr->declared)) && (!dyn()->tu.is_never(fr->declared)) {
                dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                    f"'return' with no value in a function returning '{dyn()->tu.str(fr->declared)}\x27"
                ).first(n->range).emit();
            }
            return n;
        }
        fr->saw_return_value = true;
        var t = dyn()->type_of(n->value, fr->declared);
        dyn()->reject_slice_literal(n->value, "returned from a function");
        if fr->declared != &null {
            if dyn()->tu.is_never(fr->declared) {
                dyn()->sc->diag->report(DiagID::SC001E, n->range.start, "a function returning '!' cannot return").first(n->range).emit();
                return n;
            }
            if dyn()->tu.is_void(fr->declared) {
                if (t != &null) && (!dyn()->tu.is_void(t)) {
                    dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                        f"'return' with a value of type '{dyn()->tu.str(t)}' in a function returning 'void\x27"
                    ).first(n->range).emit();
                }
                return n;
            }
            dyn()->check_convertible(n->value, fr->declared);
            return n;
        }
        // inferring
        if t == &null { return n; }
        var j = dyn()->conv.join(fr->inferred, t);
        if j == &null {
            dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                f"this 'return' has type '{dyn()->tu.str(t)}', which does not unify with an earlier return of type '{dyn()->tu.str(fr->inferred)}\x27"
            ).first(n->range).emit();
            return n;
        }
        fr->inferred = j;
        return n;
    }

    fn traverse_conditional_stmt(self, n: *ConditionalStmt) -> *ConditionalStmt {
        if n == &null { return n; }
        if n->cond != &null { dyn()->require_bool(n->cond, "the 'if' condition"); }
        if n->then_ != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->then_)); }
        if n->else_ != &null { dyn()->dispatch_stmt(n->else_); }
        return n;
    }

    fn traverse_while_loop_stmt(self, n: *WhileLoopStmt) -> *WhileLoopStmt {
        if n == &null { return n; }
        if n->cond != &null { dyn()->require_bool(n->cond, "the 'while' condition"); }
        if n->body != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body)); }
        return n;
    }

    fn traverse_indexed_for_stmt(self, n: *IndexedForStmt) -> *IndexedForStmt {
        if n == &null { return n; }
        if n->init   != &null { dyn()->dispatch_stmt(n->init); }
        if n->cond   != &null { dyn()->require_bool(n->cond, "the loop condition"); }
        if n->update != &null { dyn()->type_of(n->update, &null); }
        if n->body   != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body)); }
        return n;
    }

    /// The element type an iterable yields, or null (diagnosed).
    fn iter_elem_type(self, at: *Expr, t: *Type) -> *Type {
        if t == &null { return &null; }
        var elem = dyn()->tu.container_elem(t);
        if elem != &null { return elem; }
        var k: *Type = &null; var v: *Type = &null;
        if dyn()->tu.map_key_value(t, &k, &v) {
            var e = vec::<*Type>(); e.push_back(k); e.push_back(v);
            return dyn()->sc->types->tuple(&e);
        }
        if dyn()->tu.is_string(t) { return dyn()->tu.builtin(BuiltinKind::Char); }
        if dyn()->tu.is_lang(t, WellKnownType::Range) {
            var args = dyn()->tu.record_args(t);
            return (args[0]) if (args.size() > 0) else (dyn()->tu.builtin(BuiltinKind::I32));
        }
        // `fn op in (self) -> yield T` on a record
        var cands = vec::<*Decl>();
        dyn()->ml.lookup(dyn()->tu.strip_nullable(t), DeclName::op_name(TokenKind::KwIn, TokenKind::TkUnknown), &cands);
        for var i: usize = 0; i < cands.size(); ++i {
            var f = dyn_cast::<FunctionDecl>(cands[i]);
            if f == &null { continue; }
            var rt = self.fn_return_type(f);
            if rt == &null { continue; }
            rt = dyn()->ded_scratch()->member_through(t, rt);
            if dyn()->tu.is_lang(rt, WellKnownType::Yield) {
                var args = dyn()->tu.record_args(rt);
                if args.size() > 0 { return args[0]; }
            }
            return rt;
        }
        dyn()->fail(at, f"'{dyn()->tu.str(t)}' is not iterable; it has no 'op in\x27");
        return &null;
    }

    /// Apply binding shorthands and write the binder's type.
    priv fn _bind_one(self, b: *Binding, t: *Type) {
        if (b == &null) || b->is_discard || (b->decl == &null) { return; }
        var vd = dyn_cast::<VariableDecl>(b->decl);
        if vd == &null { return; }
        if (b->type_ != &null) && (b->type_->canonical != &null) {
            vd->type_ = canon_unqual(b->type_->canonical);
            if (t != &null) && (!dyn()->conv.convertible(t, vd->type_->canonical)) {
                dyn()->sc->diag->report(DiagID::SC001E, b->range.start,
                    f"binding annotated '{dyn()->tu.str(vd->type_->canonical)}' cannot take a value of type '{dyn()->tu.str(t)}\x27"
                ).first(b->range).emit();
                vd->poison();
            }
            return;
        }
        if t == &null { return; }
        var shaped = canon_unqual(t);
        var sh = static_cast::<u8>(b->shorthand);
        if (sh & static_cast::<u8>(BindingShorthand::Pointer)) != 0 {
            shaped = dyn()->sc->types->pointer(shaped, (sh & static_cast::<u8>(BindingShorthand::Unsafe)) != 0);
        }
        if (sh & static_cast::<u8>(BindingShorthand::Nullable)) != 0 {
            shaped = dyn()->sc->types->nullable(shaped);
        }
        vd->type_ = shaped;
    }

    priv fn _bind_list(self, list: *FrozenList::<Binding>, t: *Type, at: *Expr) {
        if list->size() == 1 { self._bind_one(list->get(0), t); return; }
        var tt: *TupleType = &null;
        var tu_ = canon_unqual(t);
        if (tu_ != &null) && isa::<TupleType>(tu_) { tt = cast::<TupleType>(tu_); }
        if (tt != &null) && (tt->elements.size() != list->size()) {
            dyn()->fail(at, f"{list->size()} binding(s) but '{dyn()->tu.str(t)}' has {tt->elements.size()} element(s)");
            tt = &null;
        }
        if (tt == &null) && (tu_ != &null) && (!isa::<TupleType>(tu_)) {
            dyn()->fail(at, f"cannot destructure '{dyn()->tu.str(t)}' into {list->size()} bindings");
        }
        for var i: usize = 0; i < list->size(); ++i {
            self._bind_one(list->get(i), (tt->elements[i]) if (tt != &null) else (&null));
        }
    }

    fn traverse_ranged_for_stmt(self, n: *RangedForStmt) -> *RangedForStmt {
        if n == &null { return n; }
        var it = dyn()->type_of(n->iterable, &null);
        var elem = (self.iter_elem_type(n->iterable, it)) if (it != &null) else (&null);
        self._bind_list(&(n->bindings), elem, n->iterable);
        if n->body != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body)); }
        return n;
    }

    fn traverse_destructuring_decl_stmt(self, n: *DestructuringDeclStmt) -> *DestructuringDeclStmt {
        if n == &null { return n; }
        var t = dyn()->type_of(n->value, &null);
        if n->kind_ == DestructureKind::Tuple {
            self._bind_list(&(n->bindings), t, n->value);
            return n;
        }
        // struct destructure: by field name.
        var d = dyn()->tu.record_decl(dyn()->tu.strip_nullable(t));
        if (t != &null) && (d == &null) { dyn()->fail(n->value, f"cannot destructure '{dyn()->tu.str(t)}' by field name"); return n; }
        var dc = (NameLookup::context_of(dyn()->tu.pattern_of(d))) if (d != &null) else (&null);
        for var i: usize = 0; i < n->bindings.size(); ++i {
            var b = n->bindings.get(i);
            if (b == &null) || b->is_discard || (b->name == &null) { continue; }
            var ft: *Type = &null;
            if dc != &null {
                var spelled = dyn()->sc->ctx->get_spelling(b->name->name);
                var imm = dyn()->sc->ctx->get_ident_imm(b->name->name);
                var cell = dyn()->sc->lookup.in_context(dc, DeclName::ident(imm), spelled);
                var fd = (dyn_cast::<FieldDecl>(cell.first())) if (cell.found()) else (&null);
                if fd == &null {
                    dyn()->sc->diag->report(DiagID::SC001E, b->range.start,
                        f"'{dyn()->tu.decl_name(d)}' has no field named '{spelled}\x27"
                    ).first(b->range).emit();
                    continue;
                }
                if fd->type_ != &null { ft = dyn()->ded_scratch()->member_through(t, fd->type_->canonical); }
            }
            self._bind_one(b, ft);
        }
        return n;
    }

    fn traverse_context_binding_stmt(self, n: *ContextBindingStmt) -> *ContextBindingStmt {
        if n == &null { return n; }
        var t = dyn()->type_of(n->value, &null);
        // enter/exit protocol lowering is a lang-item question; the binder
        // takes the value's type until ContextLowering says otherwise.
        self._bind_list(&(n->bindings), t, n->value);
        if n->body != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body)); }
        return n;
    }

    fn traverse_match_stmt(self, n: *MatchStmt) -> *MatchStmt {
        if n == &null { return n; }
        var st = dyn()->type_of(n->scrutinee, &null);
        for var i: usize = 0; i < n->cases.size(); ++i {
            var mc = n->cases.get(i);
            for var j: usize = 0; j < mc->patterns.size(); ++j { dyn()->type_pattern(mc->patterns[j], st); }
            if mc->guard != &null { dyn()->require_bool(mc->guard, "a 'where' guard"); }
            if mc->body  != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(mc->body)); }
            if mc->expression != &null { dyn()->type_of(mc->expression, &null); }
        }
        return n;
    }

    fn traverse_try_catch_stmt(self, n: *TryCatchStmt) -> *TryCatchStmt {
        if n == &null { return n; }
        if n->try_body != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->try_body)); }
        for var i: usize = 0; i < n->arms.size(); ++i {
            var arm = n->arms.get(i);
            var vd = dyn_cast::<VariableDecl>(arm->decl);
            if (vd != &null) && (vd->type_ == &null) {
                var ft: *Type = &null;
                if (arm->filter != &null) && (arm->filter->canonical != &null) { ft = arm->filter->canonical; }
                if ft == &null { var a = vec::<*Type>(); ft = dyn()->tu.lang_record(WellKnownType::Panic, &a); }
                if ft != &null { vd->type_ = canon_unqual(ft); }
            }
            if arm->body != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(arm->body)); }
        }
        return n;
    }

    fn traverse_unsafe_block_stmt(self, n: *UnsafeBlockStmt) -> *UnsafeBlockStmt {
        if n == &null { return n; }
        dyn()->unsafe_depth += 1;
        if n->body != &null { dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body)); }
        dyn()->unsafe_depth -= 1;
        return n;
    }

    fn traverse_runtime_assert_stmt(self, n: *RuntimeAssertStmt) -> *RuntimeAssertStmt {
        if n == &null { return n; }
        if n->condition != &null { dyn()->require_bool(n->condition, "an 'assert' condition"); }
        if n->message   != &null { dyn()->type_of(n->message, dyn()->tu.string_type()); }
        return n;
    }

    fn traverse_static_assert_stmt(self, n: *StaticAssertStmt) -> *StaticAssertStmt {
        if n == &null { return n; }
        if n->condition != &null { dyn()->require_bool(n->condition, "a static assertion"); }
        if n->message   != &null { dyn()->type_of(n->message, dyn()->tu.string_type()); }
        return n;
    }

    fn traverse_panic_stmt(self, n: *PanicStmt) -> *PanicStmt {
        if n == &null { return n; }
        if n->payload != &null { dyn()->type_of(n->payload, &null); }
        return n;
    }

    fn traverse_yield_stmt(self, n: *YieldStmt) -> *YieldStmt {
        if n == &null { return n; }
        // The yielded type is the enclosing fn's `yield T`; that check is
        // YieldLowering's once the return-type qualifier is modelled.
        if n->value != &null { dyn()->type_of(n->value, &null); }
        return n;
    }
}