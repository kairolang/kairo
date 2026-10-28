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
///     An enum variant construction -- `Shape::Rect { w: 1, h: 2 }`,
///     `Opt<i32>::Some { .. }`, `.Rect { .. }`, `.Empty`, and an ADT variant
///     without a payload named as a value -- is checked against the
///     variant's own payload. X records what it found, the node's
///     `variant_decl` and each field's `field_decl`, and builds nothing:
///     VariantInitLowering makes the node. `.V` takes its enum from the
///     expected type, as a `.V` pattern takes it from the scrutinee; as a call
///     argument it waits, like an untyped literal, for the parameter overload
///     resolution picks (dotted_variant_shape).
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
import Sema::Check::EffectPropagation::*;
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::OverloadResolution::*;
import Sema::Type::NullnessFlow::*;
import Sema::Type::VariadicEnum::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
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
import Token::TokenKind::*;
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
            dyn()->sc->diag->report(DiagID::SC039E, at->range.start,
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
        // A `bool?` place as the condition reads its value (NULLABLE.md §4).
        if dyn()->tu.is_bool(dyn()->tu.strip_nullable(t)) {
            t = dyn()->read_value(e);
            if t == &null { return false; }
            if dyn()->tu.is_bool(t) { return true; }
        }
        dyn()->fail(e, DiagID::SC084E, f"{what} must be 'bool', not '{dyn()->tu.str(t)}\x27");
        return false;
    }

    // === if / match / try as expressions ====================================

    /// Each arm is typed under its condition's true set, the next
    /// condition under the false sets before it (NULLABLE.md 3.3); after
    /// the expression, the join of every arm's end.
    fn type_if_expr(self, n: *IfExpr, expected: *Type) -> *Type {
        self.require_bool(n->condition, "the 'if' condition");
        var c = dyn()->flow.cond_of(n->condition);
        var acc: *Type = &null;
        var ok = true;
        dyn()->flow.env = c.t;
        var t = self._arm_value(n->then_expr, expected);
        var out = dyn()->flow.env;
        var rest = c.f;
        ok = self._join_into(&acc, t, n->then_expr, "the 'if' branch") && ok;
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            var arm = n->else_ifs.get(i);
            dyn()->flow.env = rest;
            self.require_bool(arm->condition, "the 'else if' condition");
            var ac = dyn()->flow.cond_of(arm->condition);
            dyn()->flow.env = ac.t;
            var at = self._arm_value(arm->body, (expected) if (expected != &null) else (acc));
            var arm_end = dyn()->flow.env;
            out  = dyn()->flow.join(&out, &arm_end);
            rest = ac.f;
            ok = self._join_into(&acc, at, arm->body, "this 'else if' branch") && ok;
        }
        dyn()->flow.env = rest;
        var et = self._arm_value(n->else_expr, (expected) if (expected != &null) else (acc));
        var else_end = dyn()->flow.env;
        dyn()->flow.env = dyn()->flow.join(&out, &else_end);
        ok = self._join_into(&acc, et, n->else_expr, "the 'else' branch") && ok;
        if !ok { dyn()->poison_only(n); return &null; }
        if acc == &null { dyn()->mark_unknown(n); return &null; }
        // every branch must actually convert to the join.
        dyn()->check_convertible(n->then_expr, acc);
        for var i: usize = 0; i < n->else_ifs.size(); ++i { dyn()->check_convertible(n->else_ifs.get(i)->body, acc); }
        dyn()->check_convertible(n->else_expr, acc);
        return acc;
    }

    /// An arm of a value-producing `if`: a nullable place its condition
    /// proved is its value (`if a? => a else 0` is an `i32`, the `??`
    /// expansion of NULLABLE.md 2.4); one not proven stays the nullable,
    /// which the join may well want.
    priv fn _arm_value(self, e: *Expr, expected: *Type) -> *Type {
        return dyn()->value_if_proven(e, dyn()->type_of(e, expected));
    }

    // === match on a nullable (NULLABLE.md 3.6) ===============================

    /// \p p is the `null` literal pattern.
    priv fn _null_pattern(self, p: *Pattern) -> bool {
        if (p == &null) || (p->kind != PatternKind::LiteralPattern) { return false; }
        return null_literal_of(cast::<LiteralPattern>(p)->value) != &null;
    }

    /// \p p is, or has as an alternative, the `null` literal pattern.
    priv fn _has_null_pattern(self, p: *Pattern) -> bool {
        if self._null_pattern(p) { return true; }
        if (p == &null) || (p->kind != PatternKind::AlternationPattern) { return false; }
        var a = cast::<AlternationPattern>(p);
        for var i: usize = 0; i < a->alternatives.size(); ++i { if self._has_null_pattern(a->alternatives[i]) { return true; } }
        return false;
    }

    priv fn _arm_has_null(self, mc: *MatchCase) -> bool {
        for var j: usize = 0; j < mc->patterns.size(); ++j { if self._has_null_pattern(mc->patterns[j]) { return true; } }
        return false;
    }

    /// The `null_arm` of a match on \p st: whether its first arm is `case
    /// null`, alone and unguarded, so every later arm, `default` included,
    /// matches only a value. A match on a `T?` that does not answer null
    /// first is an error (DECIDED, NULLABLE.md 3.6): with a fix-it inserting
    /// the arm when the match has none (statement form; an expression arm
    /// needs a value the fix-it cannot invent), else a note at the
    /// `case null` that is out of place. The scrutinee is then poisoned, so
    /// the pattern checks after typing do not judge a match whose arms were
    /// typed for a shape it does not have.
    fn match_null_first(self, scrutinee: *Expr, cases: *FrozenList::<MatchCase>, st: *Type,
                        at: SourceRange, stmt_form: bool) -> bool {
        if st == &null { return false; }
        var nt = dyn()->tu.as_value(st);
        if dyn()->tu.nullable_inner(nt) == &null { return false; }
        if cases->size() == 0 { return false; }
        var first = cases->get(0);
        if (!first->is_default) && (first->patterns.size() == 1) && self._null_pattern(first->patterns[0]) && (first->guard == &null) {
            return true;
        }
        var ts = dyn()->tu.str(nt);
        var b = dyn()->sc->diag->report(DiagID::SC001E, at.start, f"a match on '{ts}' must answer null first");
        b.first(scrutinee->range);
        var late: usize = cases->size();
        for var i: usize = 0; i < cases->size(); ++i {
            if self._arm_has_null(cases->get(i)) { late = i; break; }
        }
        if (late == 0) && (first->guard != &null) {
            b.note(first->guard->range.start, "'case null' takes no 'where' guard: null is answered once, by the first arm");
        } else if late == 0 {
            b.note(first->range.start, "write 'case null' as an arm of its own: every arm after it matches only a value");
        } else if late < cases->size() {
            b.note(cases->get(late)->range.start, "move this arm to the top: every arm after the first matches only a value");
        } else if stmt_form {
            var lc = dyn()->sc->ctx->sm->get_line_col(first->range.start);
            var pad = "";
            for var c: u32 = 1; c < lc.column; ++c { pad = pad + " "; }
            b.insert(first->range.start, "case null { }\n" + pad, "answer null in the first arm");
        } else {
            b.note(first->range.start, "add 'case null => <value>' as the first arm");
        }
        b.emit();
        return false;
    }

    /// The match on \p st is on a `T?` and does not answer null first: the
    /// error match_null_first reported. Its scrutinee is poisoned once the
    /// arms are typed.
    fn match_null_missed(self, null_arm: bool, st: *Type) -> bool {
        return (!null_arm) && (st != &null) && (dyn()->tu.nullable_inner(dyn()->tu.as_value(st)) != &null);
    }

    /// Arm \p i of a match on \p st enters: sets the nullness state its body
    /// starts from (out of \p entry) and returns the column its patterns are
    /// typed against. A `T?` scrutinee: the `case null` arm sees the place
    /// Null and matches the `T?`; every other arm sees it NonNull and matches
    /// the unwrapped `T` (`case var v` binds a `T`, `1..=3` is an integer
    /// range). A `case null` after the first arm is an error when \p null_arm
    /// already answered null (unless `T` is itself nullable: then it is
    /// `T`'s own null).
    fn match_arm_enter(self, null_arm: bool, scrutinee: *Expr, mc: *MatchCase, i: usize, st: *Type,
                       entry: *NullEnv) -> *Type {
        dyn()->flow.env = *entry;
        if st == &null { return st; }
        var nt = dyn()->tu.as_value(st);
        var inner = dyn()->tu.nullable_inner(nt);
        if inner == &null { return st; }
        if self._arm_has_null(mc) {
            if null_arm && (i > 0) && (dyn()->tu.nullable_inner(inner) == &null) {
                for var j: usize = 0; j < mc->patterns.size(); ++j {
                    var p = mc->patterns[j];
                    if !self._has_null_pattern(p) { continue; }
                    dyn()->sc->diag->report(DiagID::SC001E, p->range.start,
                        f"'null' is answered by the first arm; this arm matches only a '{dyn()->tu.str(inner)}' value"
                    ).first(p->range).emit();
                    p->poison();
                }
                dyn()->flow.put_state(&(dyn()->flow.env), scrutinee, Nullness::NonNull, mc->range);
                return inner;
            }
            if (i == 0) && null_arm { dyn()->flow.put_state(&(dyn()->flow.env), scrutinee, Nullness::Null, mc->range); }
            return st;
        }
        dyn()->flow.put_state(&(dyn()->flow.env), scrutinee, Nullness::NonNull, mc->range);
        return inner;
    }

    /// A `where` guard: bool, and its true set refines the arm (3.6).
    fn match_guard(self, mc: *MatchCase) {
        if mc->guard == &null { return; }
        self.require_bool(mc->guard, "a 'where' guard");
        dyn()->flow.env = dyn()->flow.cond_of(mc->guard).t;
    }

    fn type_match_expr(self, n: *MatchExpr, expected: *Type) -> *Type {
        var st = dyn()->type_of(n->scrutinee, &null);
        var acc: *Type = &null;
        var ok = true;
        // As the statement form (StmtTyping::traverse_match_stmt).
        var entry = dyn()->flow.env;
        n->null_arm = self.match_null_first(n->scrutinee, &(n->cases), st, n->range, false);
        var bad_null = self.match_null_missed(n->null_arm, st);
        var fl = dyn()->flow.dead_env();
        for var i: usize = 0; i < n->cases.size(); ++i {
            var mc = n->cases.get(i);
            if i > 0 {
                var end = dyn()->flow.env;
                fl = dyn()->flow.join(&fl, &end);
            }
            var col = self.match_arm_enter(n->null_arm, n->scrutinee, mc, i, st, &entry);
            for var j: usize = 0; j < mc->patterns.size(); ++j { dyn()->type_pattern(mc->patterns[j], col); }
            self.match_guard(mc);
            if mc->expression != &null {
                var t = dyn()->type_of(mc->expression, (expected) if (expected != &null) else (acc));
                ok = self._join_into(&acc, t, mc->expression, "this 'case' value") && ok;
            } else if mc->body != &null {
                dyn()->dispatch_stmt(static_cast::<*Stmt>(mc->body));
            }
        }
        if n->cases.size() > 0 {
            var last = dyn()->flow.env;
            fl = dyn()->flow.join(&fl, &last);
        }
        dyn()->flow.env = fl;
        if bad_null { n->scrutinee->poison(); }
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
        // A catch arm may start after any part of the `try` value ran: from
        // the state before it, with every global forgotten (calls).
        var entry = dyn()->flow.env;
        var arm_entry = dyn()->flow.try_entry(&entry, &null, n->try_expr);
        var t = dyn()->type_of(n->try_expr, expected);
        var fl = dyn()->flow.env;
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
            dyn()->flow.env = arm_entry;
            var at = dyn()->type_of(arm->body, (expected) if (expected != &null) else (acc));
            var arm_end = dyn()->flow.env;
            fl = dyn()->flow.join(&fl, &arm_end);
            ok = self._join_into(&acc, at, arm->body, "this 'catch' value") && ok;
        }
        dyn()->flow.env = fl;
        if !ok { dyn()->poison_only(n); return &null; }
        if acc == &null { dyn()->mark_unknown(n); return &null; }
        dyn()->check_convertible(n->try_expr, acc);
        for var i: usize = 0; i < n->catch_arms.size(); ++i { dyn()->check_convertible(n->catch_arms.get(i)->body, acc); }
        return acc;
    }

    // === ranges, async ======================================================

    fn type_range(self, n: *RangeExpr, expected: *Type) -> *Type {
        if ((n->begin == &null) || (n->end == &null)) && (!n->as_index) {
            dyn()->fail(n, DiagID::SC085E, "an open range is only valid as a slice index; give it both bounds");
            return &null;
        }
        var bt: *Type = &null; var et: *Type = &null;
        var b_lit = (n->begin != &null) && dyn()->is_untyped_literal(n->begin);
        var e_lit = (n->end   != &null) && dyn()->is_untyped_literal(n->end);
        // An index range's literal bounds are usize, not i32: every `op []`
        // taking a range takes `Range<usize>` (and the open forms), and a
        // `Range<i32>` from `s[1..3]` would match none of them. Only a
        // literal takes the hint; a typed bound keeps its own type.
        var lit_t: *Type = &null;
        if n->as_index { lit_t = dyn()->tu.builtin(BuiltinKind::USize); }
        if b_lit && (!e_lit) {
            if n->end != &null { et = dyn()->type_of(n->end, &null); }
            var b_hint = et;
            if b_hint == &null { b_hint = lit_t; }
            bt = dyn()->type_of(n->begin, b_hint);
        } else {
            var b_hint: *Type = &null;
            if b_lit { b_hint = lit_t; }
            if n->begin != &null { bt = dyn()->type_of(n->begin, b_hint); }
            var e_hint = bt;
            if (e_hint == &null) && e_lit { e_hint = lit_t; }
            if n->end   != &null { et = dyn()->type_of(n->end, e_hint); }
        }
        if ((n->begin != &null) && dyn()->propagate(n, n->begin)) || ((n->end != &null) && dyn()->propagate(n, n->end)) { return &null; }
        var elem = (bt) if (bt != &null) else (et);
        if (bt != &null) && (et != &null) {
            elem = dyn()->unify_operands(bt, et);
            if elem == &null {
                dyn()->fail(n, DiagID::SC085E, f"range bounds '{dyn()->tu.str(bt)}' and '{dyn()->tu.str(et)}' do not unify");
                return &null;
            }
        }
        if elem == &null { elem = dyn()->tu.builtin(BuiltinKind::USize); }   // `..`: the whole index space.
        if !dyn()->tu.is_integer(elem) {
            dyn()->fail(n, DiagID::SC085E, f"range bounds must be integers, not '{dyn()->tu.str(elem)}\x27");
            return &null;
        }
        // An open range (only reachable as an index, gated above) is the
        // record of the bound it has: `a..` and `..` start somewhere and run
        // to the end, `..b` / `..=b` run from the start.
        var k = WellKnownType::Range;
        if n->end == &null        { k = WellKnownType::RangeFrom; }
        else if n->begin == &null { k = WellKnownType::RangeTo; }
        var a = vec::<*Type>(); a.push_back(elem);
        var r = dyn()->tu.lang_record(k, &a);
        if r == &null { dyn()->missing_lang_item(n, to_string(k)); return &null; }
        return r;
    }

    fn type_await(self, n: *AwaitExpr, expected: *Type) -> *Type {
        var ot = dyn()->type_of(n->operand, &null);
        if dyn()->propagate(n, n->operand) { return &null; }
        if ot == &null { return &null; }
        if !dyn()->tu.is_lang(ot, WellKnownType::Future) {
            if dyn()->sc->well_known->get(WellKnownType::Future) == &null { dyn()->missing_lang_item(n, to_string(WellKnownType::Future)); return &null; }
            dyn()->fail(n, DiagID::SC086E, f"'await' requires a 'Future', not '{dyn()->tu.str(ot)}\x27");
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
        if f == &null { dyn()->missing_lang_item(n, to_string(WellKnownType::Future)); return &null; }
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
                else { dyn()->fail(n, DiagID::SC087E, f"closure parameter '{dyn()->tu.param_name(p)}' needs a type annotation"); }
                ok = false;
                continue;
            }
            // a function type has no top-level cv on its parameters ([dcl.fct]/5)
            params.push_back(canon_unqual(p->type_->canonical));
            modes.push_back(p->mode);
            if p->default_val != &null {
                dyn()->push_null_target(p->default_val, p->type_, static_cast::<*Decl>(p));
                dyn()->type_of(p->default_val, p->type_->canonical);
                dyn()->pop_null_target();
                dyn()->check_convertible(p->default_val, p->type_->canonical);
            }
        }
        for var i: usize = 0; i < n->captures.size(); ++i {
            var c = n->captures.get(i);
            if c->name != &null {
                dyn()->type_of(static_cast::<*Expr>(c->name), &null);
                dyn()->flow.consumed(static_cast::<*Expr>(c->name));   // the closure holds it: closure_made.
            }
        }
        // What calling it may write (NULLABLE.md 3.7).
        dyn()->flow.closure_made(n);

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
        // The effect is part of the type (PANIC.md §2.2): the declared set,
        // which a closure must write (P4); a bare `panic` closure is the
        // error PanicEffectChecking reports, and its type has no set.
        var panics = (static_cast::<u16>(n->modifiers) & static_cast::<u16>(FnModifier::IsPanic)) != 0;
        var pset = vec::<*Type>();
        if panics { canonical_set(&(dyn()->tu), &(n->panic_set), &pset); }
        return dyn()->sc->types->func(&params, &modes, canon_unqual(ret), panics, &pset);
    }

    // === initializers =======================================================

    /// `Point { x: 1, y: 2 }`; and an enum variant built with its payload,
    /// `Shape::Rect { w: 1, h: 2 }` / `Opt<i32>::Some { v: 1 }`, or written
    /// dotted, `.Rect { .. }` / `.Empty`, with the expected type's enum.
    fn type_named_init(self, n: *NamedInitializerExpr, expected: *Type) -> *Type {
        if n->is_dotted { return self._type_dotted_init(n, expected); }
        // A head, not a value: a variant it names is the one this initializer
        // builds, not a construction of its own.
        self.type_head(n->type_expr);
        var rec = dyn()->denoted_type(n->type_expr);
        if rec == &null {
            if n->type_expr->is_poisoned() { dyn()->poison_only(n); return &null; }
            var v = dyn_cast::<EnumVariantDecl>(dyn()->_head_decl(n->type_expr));
            if v != &null { return self._type_variant_head(n, v); }
            dyn()->fail(n, DiagID::SC088E, "initializer head does not name a type");
            return &null;
        }
        return self._init_fields(static_cast::<*Expr>(n), rec, n->fields);
    }

    /// `{ .x: 1, .y: 2 }` -- the type comes from context.
    fn type_anon_init(self, n: *AnonInitializerExpr, expected: *Type) -> *Type {
        var rec = dyn()->tu.strip_nullable(expected);
        if (rec == &null) || (dyn()->tu.record_decl(rec) == &null) {
            for var i: usize = 0; i < n->fields.size(); ++i { dyn()->type_of(n->fields.get(i)->value, &null); }
            dyn()->fail(n, DiagID::SC088E, "cannot infer the type of an anonymous initializer here; name the type or annotate the target");
            return &null;
        }
        return self._init_fields(static_cast::<*Expr>(n), rec, n->fields);
    }

    /// A dependent head that can be NAMED -- `Cell<T>`, `Box<U>`, `Self` in a
    /// generic body -- is a type, not unknown: the node is typed with that
    /// dependent canonical and its fields are checked against the record's
    /// declared fields, read through the head's arguments. MemberLookup keys
    /// on the decl, so the names resolve exactly as `self.x` does in
    /// `class <T> Foo`. Only a head with no record to name (an unbounded
    /// `T::Inner`, a duck-typed `T`) stays unknown; codegen ICEs on an
    /// untyped initializer, so this is the line between the two.
    priv fn _init_fields(self, n: *Expr, rec: *Type, fields: FrozenList::<InitField>) -> *Type {
        if isa::<AssocType>(canon_unqual(rec)) { return self._assoc_init(n, rec, fields); }
        var d = dyn()->tu.record_decl(rec);
        if (d == &null) && rec->is_dependent() {
            for var i: usize = 0; i < fields.size(); ++i { dyn()->type_of(fields.get(i)->value, &null); }
            dyn()->mark_unknown(n);
            return &null;
        }
        if d == &null { dyn()->fail(n, DiagID::SC088E, f"'{dyn()->tu.str(rec)}' is not an aggregate"); return &null; }
        if (!rec->is_dependent()) && dyn()->reject_abstract(n, d) {
            for var i: usize = 0; i < fields.size(); ++i { dyn()->type_of(fields.get(i)->value, &null); }
            return &null;
        }
        // The table the fields live in: a partial specialization's, for an
        // instance (or a dependent `Pair<X, i32>`) its args select.
        var body = dyn()->sc->record_body(rec);
        if body == &null { body = dyn()->tu.pattern_of(d); }
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
                dyn()->sc->diag->report(DiagID::SC040E, f->range.start,
                    f"'{dyn()->tu.decl_name(d)}' has no field named '{spelled}\x27"
                ).first(f->range).emit();
                ok = false;
                continue;
            }
            var ft = (fd->type_->canonical) if (fd->type_ != &null) else (&null);
            if ft != &null { ft = dyn()->ded_scratch()->member_through(rec, ft); }
            dyn()->push_null_target(f->value, fd->type_, static_cast::<*Decl>(fd));
            dyn()->type_of(f->value, ft);
            dyn()->pop_null_target();
            if dyn()->reject_slice_literal(f->value, "stored in a field") { ok = false; continue; }
            // `Full{ buf: self.buf }` reached clang as an array copy.
            if (ft != &null) && dyn()->reject_array_copy(f->value, ft) { ok = false; continue; }
            // Either side dependent: whether `v: T` converts to `.x: T` is the
            // instance's question, asked again once T is known.
            var vt = f->value->type_;
            if (ft != &null) && ft->is_dependent() { continue; }
            if (vt != &null) && vt->is_dependent() { continue; }
            if (ft != &null) && (!dyn()->check_convertible(f->value, ft)) { ok = false; }
        }
        if !ok { dyn()->poison_only(n); return &null; }
        return rec;
    }

    /// `T::Node { }`: a generic body builds an associated type only through
    /// a constructor its bounds promise (interfaces.md, Generic Bodies: a
    /// body uses exactly what the bounds declare), so `{ }` needs a bound
    /// with a no-argument constructor requirement, `type Node impl Default`.
    /// Its fields are no bound's, so a field list is never allowed.
    priv fn _assoc_init(self, n: *Expr, rec: *Type, fields: FrozenList::<InitField>) -> *Type {
        for var i: usize = 0; i < fields.size(); ++i { dyn()->type_of(fields.get(i)->value, &null); }
        var a  = cast::<AssocType>(canon_unqual(rec));
        var ts = dyn()->tu.str(rec);
        var an = dyn()->tu.decl_name(a->assoc);
        if fields.size() > 0 {
            var b = dyn()->sc->diag->report(DiagID::SC088E, n->range.start,
                f"'{ts}' is an associated type: a generic body knows none of its fields");
            b.first(n->range);
            b.note(a->assoc->range.start, f"'{an}' is declared here; build it through a constructor bound ('type {an} impl ...')").first(a->assoc->range);
            b.emit();
            dyn()->poison_only(n);
            return &null;
        }
        if !dyn()->tu.assoc_has_ctor(rec, 0) {
            var b = dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                f"cannot construct '{ts}': no bound of associated type '{an}' requires a constructor taking no arguments");
            b.first(n->range);
            b.note(a->assoc->range.start, f"'{an}' is declared here; bound it with an interface that declares a constructor requirement").first(a->assoc->range);
            b.emit();
            dyn()->poison_only(n);
            return &null;
        }
        n->value_category = Expr::ValueCategory::RValue;
        return rec;
    }

    // === enum variants ======================================================

    /// Type \p e as a head -- the path before an initializer's braces or a
    /// pattern's payload -- rather than as a value. A variant it names is
    /// what the initializer builds or the pattern matches, so it must not
    /// become a construction of its own (type_variant_value).
    fn type_head(self, e: *Expr) -> *Type {
        if e == &null { return &null; }
        var outer = dyn()->variant_head;
        dyn()->variant_head = e;
        var t = dyn()->type_of(e, &null);
        dyn()->variant_head = outer;
        return t;
    }

    /// A variant named as a value -- `Opt::None`, `Opt<i32>::None`, or a bare
    /// `None` inside its enum -- already typed \p t, the enum, by MemberTyping
    /// or _type_ident. An ADT's variant is a construction, checked as `.None`
    /// is: only one without a payload may be written without braces. A plain
    /// enum's stays the value it names; so does a head (type_head), and a
    /// variant read inside its enum's discriminants, where it is an integer.
    fn type_variant_value(self, at: *Expr, v: *EnumVariantDecl, t: *Type) -> *Type {
        if (t == &null) || (at == dyn()->variant_head) || (dyn()->discr_enum != &null) { return t; }
        var en = dyn()->_enum_of(t);
        if (en == &null) || (!en->is_adt) { return t; }
        var idx = self._variant_index(en, dyn()->tu.decl_name(static_cast::<*Decl>(v)));
        if idx < 0 { return t; }
        return self._check_variant(at, en, usize(idx), t, false, create_empty_frozen_list::<InitField>());
    }

    /// `.V` as a call argument. Nothing gives it a type until the call is
    /// resolved, so, like an untyped literal, it is ranked by its shape --
    /// viable against a parameter whose enum has a variant of that name -- and
    /// typed against the parameter selection picked (finish_call_args).
    fn dotted_variant_shape(self, e_in: *Expr, a: *ArgInfo) -> bool {
        var e = dyn()->tu.strip_parens(e_in);
        if (e == &null) || (!isa::<NamedInitializerExpr>(e)) { return false; }
        var n = cast::<NamedInitializerExpr>(e);
        if (!n->is_dotted) || (n->type_ != &null) || n->is_poisoned() { return false; }
        a->lit      = LitKind::Variant;
        a->lit_name = dyn()->sc->ctx->get_spelling(n->dotted_name);
        return true;
    }

    /// `Shape::Rect { .. }` / `Opt<i32>::Some { .. }`. The head is typed as the
    /// enum -- its instance when it has arguments -- and that is the type the
    /// construction has. The variant is found again by name in the enum's own
    /// list: its position there is its tag, and its payload is the one the
    /// enum's layout holds.
    priv fn _type_variant_head(self, n: *NamedInitializerExpr, v: *EnumVariantDecl) -> *Type {
        var rec = n->type_expr->type_;
        var en: *EnumDecl = &null;
        if rec != &null { en = dyn()->_enum_of(rec); }
        var idx: i32 = -1;
        if en != &null { idx = self._variant_index(en, dyn()->tu.decl_name(static_cast::<*Decl>(v))); }
        if idx < 0 {
            // The head's enum is not known here (dependent, or foreign): there
            // is no payload to check the fields against.
            self._type_fields_unknown(n->fields);
            dyn()->mark_unknown(n);
            return &null;
        }
        return self._check_variant(static_cast::<*Expr>(n), en, usize(idx), rec, true, n->fields);
    }

    /// `.Rect { .. }` / `.Empty`. The expected type names the enum, as the
    /// scrutinee does for a `.Rect` pattern, and a failure is the pattern's
    /// SC123E. A nullable target names its inner type. A bare generic
    /// parameter has no enum to resolve against until the instance: unknown,
    /// as an initializer whose head is one is (_init_fields).
    priv fn _type_dotted_init(self, n: *NamedInitializerExpr, expected: *Type) -> *Type {
        var nm = dyn()->sc->ctx->get_spelling(n->dotted_name);
        var st: *Type = &null;
        if expected != &null { st = canon_unqual(dyn()->tu.strip_nullable(dyn()->tu.as_value(expected))); }
        if st == &null {
            self._type_fields_unknown(n->fields);
            dyn()->fail(n, DiagID::SC123E, f"'.{nm}' names an enum variant, but nothing here gives it an enum type; write the enum's name before it");
            return &null;
        }
        var en = dyn()->_enum_of(st);
        if en == &null {
            self._type_fields_unknown(n->fields);
            if st->is_dependent() && (dyn()->tu.record_decl(st) == &null) { dyn()->mark_unknown(n); return &null; }
            dyn()->fail(n, DiagID::SC123E, f"'.{nm}' names an enum variant, but the expected type is '{dyn()->tu.str(st)}', not an enum");
            return &null;
        }
        var idx = self._variant_index(en, nm);
        if idx < 0 {
            self._type_fields_unknown(n->fields);
            dyn()->fail(n, DiagID::SC123E, f"'{dyn()->tu.str(st)}' has no variant named '{nm}\x27");
            return &null;
        }
        return self._check_variant(static_cast::<*Expr>(n), en, usize(idx), st, n->has_braces, n->fields);
    }

    /// Check one variant construction, written as \p n, and record it: the
    /// variant on \p n (`variant_decl`) and on each field the payload field
    /// it fills (`field_decl`). VariantInitLowering builds the node from
    /// those. \p rec is the enum type the construction has: the head's, or
    /// the expected type for `.V`.
    ///
    /// The payload FieldDecls are read off the variant itself, not looked up
    /// in a scope: they are the variant's own, and the enum's layout and the
    /// match lowering both key on their identity. Each written field is
    /// matched by name and typed against its field seen through \p rec, as
    /// _init_fields does for a generic record. A field the payload lacks is
    /// _init_fields' SC040E; a field given twice, a field left out, braces on
    /// a variant without a payload and none on one with a payload are SC131E.
    priv fn _check_variant(self, n: *Expr, en: *EnumDecl, idx: usize, rec: *Type,
                           braces: bool, fields: FrozenList::<InitField>) -> *Type {
        var v  = en->variants[idx];
        var nm = dyn()->tu.decl_name(static_cast::<*Decl>(en)) + "::" + dyn()->tu.decl_name(static_cast::<*Decl>(v));
        var np = v->payload.size();

        if (np == 0) && braces {
            self._type_fields_unknown(fields);
            dyn()->sc->diag->report(DiagID::SC131E, n->range.start,
                f"'{nm}' carries no payload; write it without braces"
            ).first(n->range)
             .note(DiagID::SC131N, v->range.start, "declared here without a payload")
             .emit();
            dyn()->poison_only(n);
            return &null;
        }
        if (np > 0) && (!braces) {
            dyn()->sc->diag->report(DiagID::SC131E, n->range.start,
                f"'{nm}' carries a payload; give its fields in braces after the name"
            ).first(n->range)
             .note(DiagID::SC131N, v->range.start, "declared here with its payload")
             .emit();
            dyn()->poison_only(n);
            return &null;
        }

        // A pack-expanded variant is one variant per element at a concrete
        // instance; which one is built is the payload's type (VariadicEnum).
        var ve = VariadicEnum(dyn()->sc);
        var pes = vec::<*Type>();
        if v->is_pack_expansion {
            var vn = dyn()->tu.decl_name(static_cast::<*Decl>(v));
            if (rec == &null) || (!ve.elems(rec, &pes)) {
                self._type_fields_unknown(fields);
                var b = dyn()->sc->diag->report(DiagID::SC116E, n->range.start,
                    f"building pack-expanded variant '{nm}' at a type that depends on a generic parameter is not supported yet");
                b.first(n->range, "which element this builds is known only per instance");
                b.note(DiagID::SC116N, v->range.start, "the variant is expanded over the pack here").first(v->range);
                b.emit();
                dyn()->poison_only(n);
                return &null;
            }
            if pes.size() == 0 {
                self._type_fields_unknown(fields);
                var b = dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                    f"'{dyn()->tu.str(rec)}' has no '{vn}' variant: its pack is empty");
                b.first(n->range);
                b.note(v->range.start, "one variant per element of the pack").first(v->range);
                b.emit();
                dyn()->poison_only(n);
                return &null;
            }
        }

        // Per payload field: the initializer written for it.
        var given = vec::<*InitField>();
        for var k: usize = 0; k < np; ++k { given.push_back(&null); }

        var ok = true;
        for var i: usize = 0; i < fields.size(); ++i {
            var f = fields.get(i);
            var spelled = dyn()->sc->ctx->get_spelling(f->name);
            var k: i32 = -1;
            for var j: usize = 0; j < np; ++j {
                if dyn()->tu.decl_name(static_cast::<*Decl>(v->payload[j])) == spelled { k = i32(j); break; }
            }
            if k < 0 {
                dyn()->type_of(f->value, &null);
                dyn()->sc->diag->report(DiagID::SC040E, f->range.start,
                    f"'{nm}' has no field named '{spelled}\x27"
                ).first(f->range).emit();
                ok = false;
                continue;
            }
            var uk = usize(k);
            if given[uk] != &null {
                dyn()->type_of(f->value, &null);
                dyn()->sc->diag->report(DiagID::SC131E, f->range.start,
                    f"field '{spelled}' of '{nm}' is given twice"
                ).first(f->range)
                 .note(DiagID::SC131N, given[uk]->range.start, "first given here")
                 .emit();
                ok = false;
                continue;
            }
            given[uk] = f;

            var fd = v->payload[uk];
            // A field naming the pack is typed on its own; its type picks the
            // element, against which it is checked below.
            if v->is_pack_expansion && ve.is_pack_field(fd) { dyn()->type_of(f->value, &null); continue; }
            var ft = (fd->type_->canonical) if (fd->type_ != &null) else (&null);
            if ft != &null { ft = dyn()->ded_scratch()->member_through(rec, ft); }
            dyn()->push_null_target(f->value, fd->type_, static_cast::<*Decl>(fd));
            dyn()->type_of(f->value, ft);
            dyn()->pop_null_target();
            if dyn()->reject_slice_literal(f->value, "stored in a field") { ok = false; continue; }
            if (ft != &null) && dyn()->reject_array_copy(f->value, ft) { ok = false; continue; }
            // Either side dependent: the instance's question, as for a record.
            var vt = f->value->type_;
            if (ft != &null) && ft->is_dependent() { continue; }
            if (vt != &null) && vt->is_dependent() { continue; }
            if (ft != &null) && (!dyn()->check_convertible(f->value, ft)) { ok = false; }
        }
        for var k: usize = 0; k < np; ++k {
            if given[k] != &null { continue; }
            var fd = v->payload[k];
            var fname = dyn()->tu.decl_name(static_cast::<*Decl>(fd));
            dyn()->sc->diag->report(DiagID::SC131E, n->range.start,
                f"'{nm}' is missing field '{fname}\x27"
            ).first(n->range)
             .note(DiagID::SC131N, fd->range.start, "declared here")
             .emit();
            ok = false;
        }
        if !ok { dyn()->poison_only(n); return &null; }

        var pick: i32 = -1;
        if v->is_pack_expansion {
            pick = self._init_pick_element(n, v, rec, nm, &given, &ve, &pes);
            if pick < 0 { dyn()->poison_only(n); return &null; }
        }

        // Only now, every field matched exactly once: a failed construction
        // carries no fact for a later pass to build from.
        for var k: usize = 0; k < np; ++k { given[k]->field_decl = static_cast::<*Decl>(v->payload[k]); }
        self._set_variant_decl(n, static_cast::<*Decl>(v));
        if isa::<NamedInitializerExpr>(n) { cast::<NamedInitializerExpr>(n)->variant_pack = pick; }
        n->value_category = Expr::ValueCategory::RValue;
        return rec;
    }

    /// The element of pack-expanded \p v a construction builds: the one
    /// whose type every pack-typed field's value has exactly, else the one
    /// they all convert to; -1 after reporting none or several. Each value
    /// is then checked against the element picked.
    priv fn _init_pick_element(self, n: *Expr, v: *EnumVariantDecl, rec: *Type, nm: string,
                          given: *vec::<*InitField>, ve: *VariadicEnum, pes: *vec::<*Type>) -> i32 {
        var pick: i32 = -1;
        var vals = vec::<*Expr>();
        for var k: usize = 0; k < v->payload.size(); ++k {
            if !ve->is_pack_field(v->payload[k]) { continue; }
            var e = (*given)[k]->value;
            if e->is_poisoned() { return -1; }
            if e->type_ == &null {
                dyn()->sc->diag->report(DiagID::SC001E, e->range.start,
                    f"the type of this value decides which '{nm}' is built, and it is not known here"
                ).first(e->range).emit();
                return -1;
            }
            vals.push_back(e);
        }
        if vals.size() == 0 { return (0) if (pes->size() == 1) else (-1); }   // PackChecking: a pack-expanded payload names the pack.
        // Exact: every value's own type is the one element.
        for var i: usize = 0; i < vals.size(); ++i {
            var k = ve->exact(rec, vals[i]->type_);
            if (k < 0) || ((pick >= 0) && (k != pick)) { pick = -1; break; }
            pick = k;
        }
        // Else the one element every value converts to.
        if pick < 0 {
            var hits: usize = 0;
            for var k: usize = 0; k < pes->size(); ++k {
                var all = true;
                for var i: usize = 0; i < vals.size(); ++i {
                    if !dyn()->conv.convertible(vals[i]->type_, (*pes)[k]) { all = false; break; }
                }
                if all { hits += 1; pick = i32(k); }
            }
            if hits != 1 {
                var what = dyn()->tu.str(vals[0]->type_);
                var msg = (f"no '{nm}' of '{dyn()->tu.str(rec)}' holds a '{what}\x27") if (hits == 0)
                          else (f"a '{what}' fits more than one '{nm}' of '{dyn()->tu.str(rec)}'; the payload's type must pick one");
                var b = dyn()->sc->diag->report(DiagID::SC001E, vals[0]->range.start, msg);
                b.first(vals[0]->range, "the payload's type picks the variant");
                b.note(v->range.start, f"its variants here: {ve->describe(rec, v)}").first(v->range);
                b.emit();
                return -1;
            }
        }
        for var i: usize = 0; i < vals.size(); ++i {
            if !dyn()->check_convertible(vals[i], (*pes)[usize(pick)]) { return -1; }
        }
        return pick;
    }

    /// The one writer of `variant_decl`, on whichever node the construction
    /// was written as.
    priv fn _set_variant_decl(self, n: *Expr, v: *Decl) {
        if isa::<NamedInitializerExpr>(n) { cast::<NamedInitializerExpr>(n)->variant_decl = v; return; }
        if isa::<ChainExpr>(n)            { cast::<ChainExpr>(n)->variant_decl = v; return; }
        if isa::<NamedIdentExpr>(n)       { cast::<NamedIdentExpr>(n)->variant_decl = v; return; }
        ICE_FAIL("ControlTyping: a variant construction written as neither an initializer nor a name");
    }

    /// The position of the variant named \p name in \p en, or -1.
    priv fn _variant_index(self, en: *EnumDecl, name: string) -> i32 {
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if (v != &null) && (dyn()->tu.decl_name(static_cast::<*Decl>(v)) == name) { return i32(i); }
        }
        return -1;
    }

    /// Every field value typed with nothing expected: the construction failed
    /// before its fields could be matched, and each value still needs a
    /// terminal state.
    priv fn _type_fields_unknown(self, fields: FrozenList::<InitField>) {
        for var i: usize = 0; i < fields.size(); ++i { dyn()->type_of(fields.get(i)->value, &null); }
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
        // `unsafe &x` is how a safe binding becomes a raw pointer (c-c++.md):
        // the address leaves AMT, so its type is `unsafe *T`, not the `*T`
        // plain `&x` makes. Without this a C `T *` parameter, which imports
        // as `unsafe *T`, could not be reached from a safe binding at all.
        var u = dyn_cast::<UnaryOperatorExpr>(n->operand);
        if (u != &null) && u->is_prefix() && (u->op_token.kind == TokenKind::OpAmp)
        && (t != &null) && (dyn()->tu.pointee(t) != &null) && (!dyn()->tu.is_unsafe_ptr(t)) {
            return dyn()->sc->types->pointer(dyn()->tu.pointee(t), true);
        }
        return t;
    }

    /// `({ s0; s1; e })`: a prvalue of the last statement's expression.
    ///
    /// The leading statements go through the ordinary statement typer, in
    /// order, BEFORE the value: `e` may read a local whose type they infer.
    /// The value is typed here rather than by dispatching the whole block,
    /// because only this arm can hand it \p expected -- `var x: u8 = ({ 5 })`
    /// must type the literal as u8, and type_of is memoized, so a later
    /// dispatch could not correct it.
    ///
    /// Prvalue, like the GNU extension it emits as: a reference-typed value
    /// (an imported `T&` call) yields its referent, and top-level cv drops. A
    /// fixed array is rejected: it would be a copy out of the block, which
    /// Kairo does not do implicitly (see reject_array_copy).
    fn type_stmt_expr(self, n: *StmtExpr, expected: *Type) -> *Type {
        var body = n->body;
        var count = (body->body.size()) if (body != &null) else (0);
        // A `try` arm that leaves (`=> return v`, PANIC.md §3.2): the jump is
        // typed as the statement it is, and the arm is `!`, so it fits beside
        // arms of any type and the flow after it is dead.
        if n->is_jump {
            for var i: usize = 0; i < count; ++i { dyn()->dispatch_stmt(body->body[i]); }
            n->value_category = Expr::ValueCategory::RValue;
            return dyn()->tu.builtin(BuiltinKind::Never);
        }
        // The parser guarantees a trailing ExpressionStmt for source forms and
        // SequenceLowering builds one; anything else is a malformed tree.
        var last_stmt: *Stmt = (body->body[count - 1]) if (count > 0) else (&null);
        if (last_stmt == &null) || (!isa::<ExpressionStmt>(last_stmt)) {
            dyn()->fail(n, DiagID::SC089E, "statement expression has no trailing value expression");
            return &null;
        }

        for var i: usize = 0; i + 1 < count; ++i {
            dyn()->dispatch_stmt(body->body[i]);
        }

        var value = cast::<ExpressionStmt>(last_stmt)->expr;
        var t = dyn()->type_of(value, expected);
        if dyn()->propagate(n, value) { return &null; }
        if t == &null { dyn()->mark_unknown(n); return &null; }

        if isa::<CXXLValueRefType>(t)      { t = cast::<CXXLValueRefType>(t)->referee; }
        else if isa::<CXXRValueRefType>(t) { t = cast::<CXXRValueRefType>(t)->referee; }
        t = canon_unqual(t);

        if isa::<FixedArrayType>(t) {
            dyn()->fail(n, DiagID::SC089E, f"a statement expression cannot yield an array ('{dyn()->tu.str(t)}\x27); an array is not copied implicitly");
            return &null;
        }
        n->value_category = Expr::ValueCategory::RValue;
        return t;
    }

    fn type_delete(self, n: *DeleteExpr, expected: *Type) -> *Type {
        var t = dyn()->type_of(n->operand, &null);
        if dyn()->propagate(n, n->operand) { return &null; }
        if (t != &null) && (dyn()->tu.pointee(dyn()->tu.strip_nullable(t)) == &null) {
            dyn()->fail(n, DiagID::SC090E, f"'delete' requires a pointer, not '{dyn()->tu.str(t)}\x27");
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
}
