/// --- The Kairo Project ------------------- Sema/Type/ControlTyping.k --- ///
///
///   \brief Every expression kind that is neither an operator, a call, a
///          member access, a cast nor a literal: value-producing control
///          flow, closures, initializers, and the keyword unaries that
///          desugar through lang items.
///
///   \detail
///     Branch joins (if / match / try) use Conversion::join: identical or
///     one-way-W or Never on one side; anything else is an error at the arm
///     that broke it, naming both types.
///
///     A closure is typed as its function-pointer canonical. Parameters must
///     be annotated (the docs say so); the return type is declared or inferred
///     from the body through the same frame machinery a function uses.
///
///     Lang-item desugars (`a..b` -> Range, `await` -> Future<T>, `spawn`)
///     are typed against the lang record and error when the item is unbound
///     -- that is the "error at USE" the SemaContext header promises.
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
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::OverloadResolution::*;
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
import AST::Kind::ExprKind::*;
import AST::Kind::PatternKind::*;
import Diagnostic::Registry::*;
import AST::ParamMode::*;

class <T> ControlTyping {
    priv inline fn dyn(self) -> *T { return static_cast::<*T>(&self); }

    // === joins ==============================================================

    /// Join \p t into \p acc; on failure diagnose at \p at and return false.
    priv fn _join_into(self, acc: *(*Type), t: *Type, at: *Expr, what: string) -> bool {
        if t == &null { return true; }   // unknown/poisoned arm: nothing to join, already reported.
        var j = dyn()->conv.join(*acc, t);
        if j == &null {
            dyn()->sc->diag->report(DiagID::SC001E, at->range.start,
                f"{what} has type '{dyn()->tu.str(t)}', which does not unify with the earlier '{dyn()->tu.str(*acc)}\x27"
            ).first(at->range)
             .note(at->range.start, "every branch of a value-producing construct must convert to one type")
             .emit();
            return false;
        }
        (*acc) = j;
        return true;
    }

    fn require_bool(self, e: *Expr, what: string) -> bool {
        var t = dyn()->type_of(e, dyn()->tu.builtin(BuiltinKind::Bool));
        if t == &null { return !e->is_poisoned(); }
        if dyn()->tu.is_bool(t) { return true; }
        dyn()->fail(e, f"{what} must be 'bool', not '{dyn()->tu.str(t)}\x27");
        return false;
    }

    // === if / match / try as expressions ====================================

    fn type_if_expr(self, n: *IfExpr, expected: *Type) -> *Type {
        self.require_bool(n->condition, "the 'if' condition");
        var acc: *Type = &null;
        var ok = true;
        var t = dyn()->type_of(n->then_expr, expected);
        ok = self._join_into(&acc, t, n->then_expr, "the 'if' branch") && ok;
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            var arm = n->else_ifs.get(i);
            self.require_bool(arm->condition, "the 'else if' condition");
            var at = dyn()->type_of(arm->body, (expected) if (expected != &null) else (acc));
            ok = self._join_into(&acc, at, arm->body, "this 'else if' branch") && ok;
        }
        var et = dyn()->type_of(n->else_expr, (expected) if (expected != &null) else (acc));
        ok = self._join_into(&acc, et, n->else_expr, "the 'else' branch") && ok;
        if !ok { dyn()->poison_only(n); return &null; }
        if acc == &null { dyn()->mark_unknown(n); return &null; }
        // every branch must actually convert to the join.
        dyn()->check_convertible(n->then_expr, acc);
        for var i: usize = 0; i < n->else_ifs.size(); ++i { dyn()->check_convertible(n->else_ifs.get(i)->body, acc); }
        dyn()->check_convertible(n->else_expr, acc);
        return acc;
    }

    fn type_match_expr(self, n: *MatchExpr, expected: *Type) -> *Type {
        var st = dyn()->type_of(n->scrutinee, &null);
        var acc: *Type = &null;
        var ok = true;
        for var i: usize = 0; i < n->cases.size(); ++i {
            var mc = n->cases.get(i);
            for var j: usize = 0; j < mc->patterns.size(); ++j { dyn()->type_pattern(mc->patterns[j], st); }
            if mc->guard != &null { self.require_bool(mc->guard, "a 'where' guard"); }
            if mc->expression != &null {
                var t = dyn()->type_of(mc->expression, (expected) if (expected != &null) else (acc));
                ok = self._join_into(&acc, t, mc->expression, "this 'case' value") && ok;
            } else if mc->body != &null {
                dyn()->dispatch_stmt(static_cast::<*Stmt>(mc->body));
            }
        }
        if !ok { dyn()->poison_only(n); return &null; }
        if acc == &null { dyn()->mark_unknown(n); return &null; }
        for var i: usize = 0; i < n->cases.size(); ++i {
            var mc = n->cases.get(i);
            if mc->expression != &null { dyn()->check_convertible(mc->expression, acc); }
        }
        return acc;
    }

    fn type_try_expr(self, n: *TryCatchExpr, expected: *Type) -> *Type {
        var acc: *Type = &null;
        var ok = true;
        var t = dyn()->type_of(n->try_expr, expected);
        ok = self._join_into(&acc, t, n->try_expr, "the 'try' value") && ok;
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            var arm = n->catch_arms.get(i);
            if arm->decl != &null {
                var vd = dyn_cast::<VariableDecl>(arm->decl);
                if (vd != &null) && (vd->type_ == &null) {
                    var ft: *Type = &null;
                    if (arm->filter != &null) && (arm->filter->canonical != &null) { ft = arm->filter->canonical; }
                    if ft == &null {
                        var a = vec::<*Type>();
                        ft = dyn()->tu.lang_record(WellKnownType::Panic, &a);
                    }
                    if ft != &null { vd->type_ = canon_unqual(ft); }
                }
            }
            var at = dyn()->type_of(arm->body, (expected) if (expected != &null) else (acc));
            ok = self._join_into(&acc, at, arm->body, "this 'catch' value") && ok;
        }
        if !ok { dyn()->poison_only(n); return &null; }
        if acc == &null { dyn()->mark_unknown(n); return &null; }
        dyn()->check_convertible(n->try_expr, acc);
        for var i: usize = 0; i < n->catch_arms.size(); ++i { dyn()->check_convertible(n->catch_arms.get(i)->body, acc); }
        return acc;
    }

    // === ranges, async ======================================================

    fn type_range(self, n: *RangeExpr, expected: *Type) -> *Type {
        var bt: *Type = &null; var et: *Type = &null;
        var b_lit = (n->begin != &null) && dyn()->is_untyped_literal(n->begin);
        var e_lit = (n->end   != &null) && dyn()->is_untyped_literal(n->end);
        if b_lit && (!e_lit) {
            if n->end != &null { et = dyn()->type_of(n->end, &null); }
            bt = dyn()->type_of(n->begin, et);
        } else {
            if n->begin != &null { bt = dyn()->type_of(n->begin, &null); }
            if n->end   != &null { et = dyn()->type_of(n->end, bt); }
        }
        if ((n->begin != &null) && dyn()->propagate(n, n->begin)) || ((n->end != &null) && dyn()->propagate(n, n->end)) { return &null; }
        var elem = (bt) if (bt != &null) else (et);
        if (bt != &null) && (et != &null) {
            elem = dyn()->unify_operands(bt, et);
            if elem == &null {
                dyn()->fail(n, f"range bounds '{dyn()->tu.str(bt)}' and '{dyn()->tu.str(et)}' do not unify");
                return &null;
            }
        }
        if elem == &null { elem = dyn()->tu.builtin(BuiltinKind::I32); }   // `..`: unbounded, integer by convention.
        if !dyn()->tu.is_integer(elem) {
            dyn()->fail(n, f"range bounds must be integers, not '{dyn()->tu.str(elem)}\x27");
            return &null;
        }
        var a = vec::<*Type>(); a.push_back(elem);
        var r = dyn()->tu.lang_record(WellKnownType::Range, &a);
        if r == &null { dyn()->missing_lang_item(n, "Range"); return &null; }
        return r;
    }

    fn type_await(self, n: *AwaitExpr, expected: *Type) -> *Type {
        var ot = dyn()->type_of(n->operand, &null);
        if dyn()->propagate(n, n->operand) { return &null; }
        if ot == &null { return &null; }
        if !dyn()->tu.is_lang(ot, WellKnownType::Future) {
            if dyn()->sc->well_known->get(WellKnownType::Future) == &null { dyn()->missing_lang_item(n, "Future"); return &null; }
            dyn()->fail(n, f"'await' requires a 'Future', not '{dyn()->tu.str(ot)}\x27");
            return &null;
        }
        var args = dyn()->tu.record_args(ot);
        if args.size() == 0 { return dyn()->tu.builtin(BuiltinKind::Void); }
        return args[0];
    }

    fn type_spawn(self, n: *Expr, operand: *Expr, expected: *Type) -> *Type {
        var ot = dyn()->type_of(operand, &null);
        if dyn()->propagate(n, operand) { return &null; }
        if ot == &null { return &null; }
        var a = vec::<*Type>(); a.push_back(ot);
        var f = dyn()->tu.lang_record(WellKnownType::Future, &a);
        if f == &null { dyn()->missing_lang_item(n, "Future"); return &null; }
        return f;
    }

    // === closures ===========================================================

    fn type_closure(self, n: *ClosureExpr, expected: *Type) -> *Type {
        // parameter types are required; the frame gives `return` its target.
        // Modes ride parallel: a closure's type IS the fn-pointer canonical,
        // so a mode not collected here does not exist for closures.
        var params = vec::<*Type>();
        var modes  = vec::<ParamMode>();
        var ok = true;
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if p == &null { continue; }
            if (p->type_ == &null) || (p->type_->canonical == &null) {
                if (p->type_ != &null) && p->type_->is_dependent() { dyn()->mark_unknown(n); }
                else { dyn()->fail(n, f"closure parameter '{dyn()->tu.param_name(p)}' needs a type annotation"); }
                ok = false;
                continue;
            }
            // a function type has no top-level cv on its parameters ([dcl.fct]/5)
            params.push_back(canon_unqual(p->type_->canonical));
            modes.push_back(p->mode);
            if p->default_val != &null { dyn()->type_of(p->default_val, p->type_->canonical); dyn()->check_convertible(p->default_val, p->type_->canonical); }
        }
        for var i: usize = 0; i < n->captures.size(); ++i {
            var c = n->captures.get(i);
            if c->name != &null { dyn()->type_of(static_cast::<*Expr>(c->name), &null); }
        }

        var declared: *Type = &null;
        if n->return_type != &null { declared = n->return_type->canonical; }
        if n->is_noreturn { declared = dyn()->tu.builtin(BuiltinKind::Never); }

        dyn()->push_closure_frame(n, declared);
        var inferred: *Type = &null;
        if n->body_expr != &null {
            var bt = dyn()->type_of(n->body_expr, declared);
            if declared != &null { dyn()->check_convertible(n->body_expr, declared); }
            else { inferred = bt; }
        } else if n->body_block != &null {
            dyn()->dispatch_stmt(static_cast::<*Stmt>(n->body_block));
            inferred = dyn()->frame_inferred_return();
        }
        dyn()->pop_frame();
        if !ok { return &null; }

        var ret = declared;
        if ret == &null {
            ret = (canon_unqual(inferred)) if (inferred != &null) else (dyn()->tu.builtin(BuiltinKind::Void));
            if n->return_type == &null { n->return_type = ret; }   // inferred slot := canonical (self-canonical).
        }
        if (n->body_expr != &null) && (n->body_expr->type_ == &null) && (!n->body_expr->is_poisoned()) {
            dyn()->mark_unknown(n);
            return &null;
        }
        return dyn()->sc->types->func(&params, &modes, canon_unqual(ret));
    }

    // === initializers =======================================================

    /// `Point { x: 1, y: 2 }`
    fn type_named_init(self, n: *NamedInitializerExpr, expected: *Type) -> *Type {
        var rec = dyn()->denoted_type(n->type_expr);
        if rec == &null {
            dyn()->type_of(n->type_expr, &null);
            if n->type_expr->is_poisoned() { dyn()->poison_only(n); return &null; }
            dyn()->fail(n, "initializer head does not name a type");
            return &null;
        }
        return self._init_fields(static_cast::<*Expr>(n), rec, n->fields);
    }

    /// `{ .x: 1, .y: 2 }` -- the type comes from context.
    fn type_anon_init(self, n: *AnonInitializerExpr, expected: *Type) -> *Type {
        var rec = dyn()->tu.strip_nullable(expected);
        if (rec == &null) || (dyn()->tu.record_decl(rec) == &null) {
            for var i: usize = 0; i < n->fields.size(); ++i { dyn()->type_of(n->fields.get(i)->value, &null); }
            dyn()->fail(n, "cannot infer the type of an anonymous initializer here; name the type or annotate the target");
            return &null;
        }
        return self._init_fields(static_cast::<*Expr>(n), rec, n->fields);
    }

    priv fn _init_fields(self, n: *Expr, rec: *Type, fields: FrozenList::<InitField>) -> *Type {
        var d = dyn()->tu.record_decl(rec);
        if d == &null { dyn()->fail(n, f"'{dyn()->tu.str(rec)}' is not an aggregate"); return &null; }
        if rec->is_dependent() {
            for var i: usize = 0; i < fields.size(); ++i { dyn()->type_of(fields.get(i)->value, &null); }
            dyn()->mark_unknown(n);
            return &null;
        }
        var body = dyn()->tu.pattern_of(d);
        var dc   = NameLookup::context_of(body);
        var ok   = true;
        for var i: usize = 0; i < fields.size(); ++i {
            var f = fields.get(i);
            var spelled = dyn()->sc->ctx->get_spelling(f->name);
            var imm = dyn()->sc->ctx->get_ident_imm(f->name);
            var cell = dyn()->sc->lookup.in_context(dc, DeclName::ident(imm), spelled);
            var fd: *FieldDecl = &null;
            if cell.found() { fd = dyn_cast::<FieldDecl>(cell.first()); }
            if fd == &null {
                dyn()->type_of(f->value, &null);
                dyn()->sc->diag->report(DiagID::SC001E, f->range.start,
                    f"'{dyn()->tu.decl_name(d)}' has no field named '{spelled}\x27"
                ).first(f->range).emit();
                ok = false;
                continue;
            }
            var ft = (fd->type_->canonical) if (fd->type_ != &null) else (&null);
            if ft != &null { ft = dyn()->ded_scratch()->member_through(rec, ft); }
            dyn()->type_of(f->value, ft);
            if (ft != &null) && (!dyn()->check_convertible(f->value, ft)) { ok = false; }
        }
        if !ok { dyn()->poison_only(n); return &null; }
        return rec;
    }

    // === keyword expressions ================================================

    fn type_sizeof(self, n: *SizeOfExpr, expected: *Type) -> *Type {
        if (n->type_arg != &null) && n->type_arg->is_poisoned() { dyn()->poison_only(n); return &null; }
        return dyn()->tu.builtin(BuiltinKind::USize);
    }

    fn type_alignof(self, n: *AlignOfExpr, expected: *Type) -> *Type {
        if (n->type_arg != &null) && n->type_arg->is_poisoned() { dyn()->poison_only(n); return &null; }
        return dyn()->tu.builtin(BuiltinKind::USize);
    }

    /// `typeof x` in expression position yields a TypeInfo value; the docs
    /// route that through the reflection library. Until it exists the
    /// operand is typed, `resolved_type` is written, and the expression is
    /// a type-denoting head (usable as `typeof(x)::Foo` or a ctor).
    fn type_typeof(self, n: *TypeOfExpr, expected: *Type) -> *Type {
        var t = dyn()->type_of(n->operand, &null);
        if dyn()->propagate(n, n->operand) { return &null; }
        if t == &null { return &null; }
        n->resolved_type = t;
        dyn()->note_type_expr(static_cast::<*Expr>(n), t);
        return &null;
    }

    fn type_eval(self, n: *EvalExpr, expected: *Type) -> *Type {
        var t = dyn()->type_of(n->operand, expected);
        if dyn()->propagate(n, n->operand) { return &null; }
        return t;
    }

    fn type_unsafe(self, n: *UnsafeExpr, expected: *Type) -> *Type {
        dyn()->unsafe_depth += 1;
        var t = dyn()->type_of(n->operand, expected);
        dyn()->unsafe_depth -= 1;
        if dyn()->propagate(n, n->operand) { return &null; }
        return t;
    }

    fn type_delete(self, n: *DeleteExpr, expected: *Type) -> *Type {
        var t = dyn()->type_of(n->operand, &null);
        if dyn()->propagate(n, n->operand) { return &null; }
        if (t != &null) && (dyn()->tu.pointee(dyn()->tu.strip_nullable(t)) == &null) {
            dyn()->fail(n, f"'delete' requires a pointer, not '{dyn()->tu.str(t)}\x27");
            return &null;
        }
        return dyn()->tu.builtin(BuiltinKind::Void);
    }

    fn type_constraint(self, n: *Expr, expected: *Type) -> *Type {
        // `T impl I` / `T derives B` in a requires clause: bool at compile time.
        // The operands are types (already T-resolved) or a lhs expr naming one.
        if isa::<ConstraintExpr>(n) {
            var c = cast::<ConstraintExpr>(n);
            if c->lhs != &null { dyn()->type_of(c->lhs, &null); }
        }
        return dyn()->tu.builtin(BuiltinKind::Bool);
    }

    // === patterns (the binder-typing half; exhaustiveness/ctor heads are PatternChecking's) ==

    fn type_pattern(self, p: *Pattern, scrutinee: *Type) {
        if p == &null { return; }
        if p->is_poisoned() { return; }
        if (scrutinee != &null) && (p->type_ == &null) { p->type_ = canon_unqual(scrutinee); }
        switch p->kind {
            case PatternKind::BindingPattern {
                var b = cast::<BindingPattern>(p);
                var vd = dyn_cast::<VariableDecl>(b->decl);
                if vd == &null { return; }
                if (b->type_ != &null) && (b->type_->canonical != &null) {
                    vd->type_ = canon_unqual(b->type_->canonical);
                    if (scrutinee != &null) && (!dyn()->conv.convertible(scrutinee, b->type_->canonical)) {
                        dyn()->sc->diag->report(DiagID::SC001E, p->range.start,
                            f"pattern type '{dyn()->tu.str(b->type_->canonical)}' does not match the scrutinee type '{dyn()->tu.str(scrutinee)}\x27"
                        ).first(p->range).emit();
                        p->poison();
                    }
                } else if (vd->type_ == &null) && (scrutinee != &null) {
                    vd->type_ = canon_unqual(scrutinee);
                }
            }
            case PatternKind::LiteralPattern {
                var l = cast::<LiteralPattern>(p);
                if l->value != &null {
                    dyn()->type_of(l->value, scrutinee);
                    if scrutinee != &null { dyn()->check_convertible(l->value, scrutinee); }
                }
            }
            case PatternKind::RangePattern {
                var r = cast::<RangePattern>(p);
                if r->lo != &null { dyn()->type_of(r->lo, scrutinee); if scrutinee != &null { dyn()->check_convertible(r->lo, scrutinee); } }
                if r->hi != &null { dyn()->type_of(r->hi, scrutinee); if scrutinee != &null { dyn()->check_convertible(r->hi, scrutinee); } }
            }
            case PatternKind::TupleDestructurePattern {
                var tp = cast::<TupleDestructurePattern>(p);
                var tt: *TupleType = &null;
                var su = canon_unqual(scrutinee);
                if (su != &null) && isa::<TupleType>(su) { tt = cast::<TupleType>(su); }
                if (tt != &null) && (tt->elements.size() != tp->elements.size()) {
                    dyn()->sc->diag->report(DiagID::SC001E, p->range.start,
                        f"tuple pattern has {tp->elements.size()} element(s) but '{dyn()->tu.str(scrutinee)}' has {tt->elements.size()}"
                    ).first(p->range).emit();
                    p->poison();
                    tt = &null;
                }
                for var i: usize = 0; i < tp->elements.size(); ++i {
                    self.type_pattern(tp->elements[i], (tt->elements[i]) if (tt != &null) else (&null));
                }
            }
            case PatternKind::AlternationPattern {
                var a = cast::<AlternationPattern>(p);
                for var i: usize = 0; i < a->alternatives.size(); ++i { self.type_pattern(a->alternatives[i], scrutinee); }
            }
            case PatternKind::SlicePattern {
                var s = cast::<SlicePattern>(p);
                var elem = dyn()->tu.container_elem(scrutinee);
                for var i: usize = 0; i < s->prefix.size(); ++i { self.type_pattern(s->prefix[i], elem); }
                for var i: usize = 0; i < s->suffix.size(); ++i { self.type_pattern(s->suffix[i], elem); }
                if s->rest_binding != &null { self.type_pattern(s->rest_binding, scrutinee); }
            }
            case PatternKind::ConstructorPattern {
                // Head + payload binding is PatternChecking's (needs variant
                // payload shapes); subpatterns are typed as unknown so binders
                // still get a decl to hang on.
                var c = cast::<ConstructorPattern>(p);
                for var i: usize = 0; i < c->subpatterns.size(); ++i { self.type_pattern(c->subpatterns[i], &null); }
            }
            case PatternKind::UnresolvedConstructorPattern {
                var c = cast::<UnresolvedConstructorPattern>(p);
                for var i: usize = 0; i < c->subpatterns.size(); ++i { self.type_pattern(c->subpatterns[i], &null); }
            }
            default { 0; }
        }
    }
}