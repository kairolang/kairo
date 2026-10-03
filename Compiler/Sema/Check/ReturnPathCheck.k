/// --- The Kairo Project ------------------- Sema/Check/ReturnPathCheck.k --- ///
///
///   \brief Error when a value-returning function can reach its closing
///          brace, or a `-> !` function can.
///
///   \detail
///     Structural, not a CFG: one question asked of the statement tree,
///     "can control fall out of the bottom of this statement?". A block
///     falls through unless some statement in it does not; a statement does
///     not fall through when it is
///
///         return / panic / break / continue / jump!
///         a call (or any expression) whose type is `!`
///         `if` WITH an `else`, both arms not falling through
///         `match` that is exhaustive, every arm not falling through
///         `try` whose body and every catch arm do not fall through
///         `loop {}`, `while true {}`, `for ;; {}` with no `break` out
///         a block / `unsafe` / context binding / label whose body doesn't
///
///     `break` and `continue` count as "does not fall through" because they
///     leave the BLOCK, not the function; the loop that owns them is what
///     decides whether the function can continue past it, and the loop rule
///     above asks exactly that.
///
///   \par match counts only when it is exhaustive
///     A `match` with a `default`, an unguarded catch-all arm (`_`, a bare
///     binder), every variant of an enum scrutinee, or both `true` and
///     `false` for a bool. Anything the arms do not cover falls out of the
///     match, so an arm-wise "every arm returns" is not enough on its own.
///     Variants are compared by NAME against the enum's declaration, which
///     is exact within one enum and needs no pattern-head resolution
///     (PatternChecking's job, not done yet). An ADT arm covers its variant
///     only when every payload subpattern is irrefutable: `.Some(1)` does
///     not cover `.Some`.
///
///   \par Conservative on unknowns
///     A recovery node, an `inline` foreign block, `jump!`, and a match on a
///     scrutinee whose type is unknown are all treated as NOT falling
///     through. Each of those either already produced an error or hides
///     control flow this pass cannot see, and a missing-return on top of
///     either is noise. Missing a real bug there is the chosen trade.
///
///   \par Generators
///     `-> yield T` names what each `yield` produces; falling off the bottom
///     ends the sequence, so a generator body is never checked. Only the
///     written qualifier counts: a spelled-out `-> Yield<T>` is an ordinary
///     record return and is checked like any other.
///
///   \par What this is NOT
///     Unreachable-code warnings (TerminatorCheck, lexical), definite
///     initialization, or a general exhaustiveness diagnostic
///     (MatchExhaustiveness). The coverage test here only decides whether a
///     match can fall through; it reports nothing about the match itself.
///
///   Phase: CHECK (after ExprTyper: reads expression and scrutinee types)
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
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Patterns::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::StmtKind::*;
import AST::Kind::PatternKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Token::Token::*;
import Diagnostic::Registry::*;

class ReturnPathCheck derives RecursiveASTVisitor::<ReturnPathCheck> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;

    fn ReturnPathCheck(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    // === entry points =====================================================

    fn visit_function_decl(self, n: *FunctionDecl) -> bool {
        if n == &null { return true; }
        if n->is_poisoned() { return true; }
        // A generator's `-> yield T` declares each YIELDED value, not a
        // returned one: falling off the end of a coroutine is how it ends.
        // X's fact, not a re-read of the return type.
        if n->is_generator { return true; }
        // An expression body IS its value; there is no bottom to fall off.
        if n->body_kind != FnBodyKind::Block { return true; }
        if n->body_block == &null { return true; }

        if n->is_noreturn {
            self._check(n->body_block, &null, true, (n->range) if (n->is_operator) else (n->name.range), n);
            return true;
        }
        // No annotation on a block body is `void` (StmtTyping), and a ctor /
        // dtor never carries one.
        if n->return_type == &null { return true; }
        self._check(n->body_block, n->return_type, false, n->return_type->range, n);
        return true;
    }

    fn visit_closure_expr(self, n: *ClosureExpr) -> bool {
        if n == &null { return true; }
        if n->body_kind != FnBodyKind::Block { return true; }
        if n->body_block == &null { return true; }
        if n->is_noreturn {
            self._check(n->body_block, &null, true, n->range, &null);
            return true;
        }
        // Inferred: the returns seen define the type, so there is nothing
        // declared for the bottom of the body to disagree with.
        if n->return_type == &null { return true; }
        if self._tu.is_generator_return(n->return_type) { return true; }    // see visit_function_decl.
        self._check(n->body_block, n->return_type, false, n->return_type->range, &null);
        return true;
    }

    /// Spelled only on the error path: an operator's `name` token is a
    /// sentinel, and resolving it asserts in TokenText.
    priv fn _subject(self, f: *FunctionDecl) -> string {
        if f == &null { return "this closure"; }
        if f->is_operator { return "this operator"; }
        return f"'{self._tu.decl_name(static_cast::<*Decl>(f))}\x27";
    }

    /// \p f is the function, or null for a closure; it names the subject.
    priv fn _check(self, body: *CompoundStmt, ret: *Type, noreturn: bool,
                   decl_at: SourceRange, f: *FunctionDecl) {
        var never = noreturn;
        if (!never) {
            var rc = ret->canonical;
            // Unresolved return type: T already reported it.
            if rc == &null { return; }
            if self._tu.is_void(rc) { return; }
            if self._tu.is_never(rc) { never = true; }
        }
        if !self._falls_through(static_cast::<*Stmt>(body)) { return; }

        // `end` is exclusive; the closing brace is the byte before it.
        var brace = SourceRange::from_bounds(body->range.end.with_offset(-1), u32(1));
        var what  = self._subject(f);

        if never {
            var b = self.sc->diag->report(DiagID::SC105E, brace.start,
                f"{what} is declared to never return, but control can reach the end of its body");
            b.first(brace);
            b.note(DiagID::SC105N, decl_at.start,
                "declared '-> !' here; end the body with a 'panic', a call to another '-> !' function, or an infinite loop"
            ).first(decl_at);
            b.emit();
            return;
        }

        var ty = self._tu.str(ret->canonical);
        var b = self.sc->diag->report(DiagID::SC104E, brace.start,
            f"{what} does not return a value on all control paths");
        b.first(brace);
        b.note(DiagID::SC104N, decl_at.start,
            f"declared to return '{ty}' here; every path must end in 'return', 'panic', or a call that does not return"
        ).first(decl_at);
        b.emit();
    }

    // === the fall-through predicate =======================================

    /// Can control leave \p s at its bottom and continue with the next
    /// statement? See the file header for the rule per statement.
    priv fn _falls_through(self, s: *Stmt) -> bool {
        if s == &null { return true; }
        switch s->kind {
            case StmtKind::RecoveryStmt       { return false; }
            case StmtKind::ReturnStmt         { return false; }
            case StmtKind::PanicStmt          { return false; }
            case StmtKind::BreakStmt          { return false; }
            case StmtKind::ContinueStmt       { return false; }
            case StmtKind::JumpIntrinsicStmt  { return false; }
            case StmtKind::InlineBlockStmt    { return false; }

            case StmtKind::CompoundStmt {
                return self._block_falls_through(cast::<CompoundStmt>(s));
            }
            case StmtKind::UnsafeBlockStmt {
                return self._block_falls_through(cast::<UnsafeBlockStmt>(s)->body);
            }
            case StmtKind::ContextBindingStmt {
                return self._block_falls_through(cast::<ContextBindingStmt>(s)->body);
            }
            case StmtKind::ExpressionStmt {
                return !self._diverges(cast::<ExpressionStmt>(s)->expr);
            }
            case StmtKind::ConditionalStmt {
                var c = cast::<ConditionalStmt>(s);
                // No `else`: the false edge falls through regardless of `then`.
                if c->else_ == &null { return true; }
                if self._block_falls_through(c->then_) { return true; }
                return self._falls_through(c->else_);
            }
            case StmtKind::MatchStmt {
                return self._match_falls_through(cast::<MatchStmt>(s));
            }
            case StmtKind::TryCatchStmt {
                var t = cast::<TryCatchStmt>(s);
                if self._block_falls_through(t->try_body) { return true; }
                for var i: usize = 0; i < t->arms.size(); ++i {
                    var arm = t->arms.get(i);
                    if self._block_falls_through(arm->body) { return true; }
                }
                return false;
            }
            case StmtKind::LabeledStmt {
                var l = cast::<LabeledStmt>(s);
                return self._loop_falls_through(l->inner, self._imm(l->label));
            }
            case StmtKind::LoopStmt       { return self._loop_falls_through(s, u32(-1)); }
            case StmtKind::WhileLoopStmt  { return self._loop_falls_through(s, u32(-1)); }
            case StmtKind::IndexedForStmt { return self._loop_falls_through(s, u32(-1)); }
            default { return true; }
        }
    }

    priv fn _block_falls_through(self, b: *CompoundStmt) -> bool {
        if b == &null { return true; }
        var dead = false;
        for var i: usize = 0; i < b->body.size(); ++i {
            var s = b->body[i];
            if s == &null { continue; }
            // A `label!` is a `jump!` target: whatever precedes it, control
            // can arrive here, so the block is live again from this point.
            if s->kind == StmtKind::LabelIntrinsicStmt { dead = false; continue; }
            if !self._falls_through(s) { dead = true; }
        }
        return !dead;
    }

    /// An expression whose type is `!` -- a call to a `-> !` function is the
    /// case that matters. Unknown type is "may return".
    priv fn _diverges(self, e: *Expr) -> bool {
        if e == &null { return false; }
        if e->type_ == &null { return false; }
        return self._tu.is_never(e->type_);
    }

    // --- loops ------------------------------------------------------------

    /// \p label is the imm of a LabeledStmt wrapping \p s, or -1.
    priv fn _loop_falls_through(self, s: *Stmt, label: u32) -> bool {
        if s == &null { return true; }
        var body: *CompoundStmt = &null;
        switch s->kind {
            case StmtKind::LoopStmt { body = cast::<LoopStmt>(s)->body; }
            case StmtKind::WhileLoopStmt {
                var w = cast::<WhileLoopStmt>(s);
                if !self._is_true_literal(w->cond) { return true; }
                body = w->body;
            }
            case StmtKind::IndexedForStmt {
                var f = cast::<IndexedForStmt>(s);
                if (f->cond != &null) && (!self._is_true_literal(f->cond)) { return true; }
                body = f->body;
            }
            // A label on a finite loop (a ranged `for`, say): the loop
            // exhausts and falls through like the unlabeled form.
            default { return self._falls_through(s); }
        }
        // Infinite: the only way past it is a `break` that targets it.
        return self._breaks_out(static_cast::<*Stmt>(body), 0, label);
    }

    /// Does \p s contain a `break` that exits the loop under inspection?
    /// \p depth counts loops entered below that one: an unlabeled break at
    /// depth 0 is ours, a labeled one is ours at any depth when it names us.
    priv fn _breaks_out(self, s: *Stmt, depth: u32, label: u32) -> bool {
        if s == &null { return false; }
        switch s->kind {
            case StmtKind::BreakStmt {
                var b = cast::<BreakStmt>(s);
                if (!b->has_label) { return depth == 0; }
                return (label != u32(-1)) && (self._imm(b->label) == label);
            }
            case StmtKind::CompoundStmt {
                var c = cast::<CompoundStmt>(s);
                for var i: usize = 0; i < c->body.size(); ++i {
                    if self._breaks_out(c->body[i], depth, label) { return true; }
                }
                return false;
            }
            case StmtKind::UnsafeBlockStmt {
                return self._breaks_out(static_cast::<*Stmt>(cast::<UnsafeBlockStmt>(s)->body), depth, label);
            }
            case StmtKind::ContextBindingStmt {
                return self._breaks_out(static_cast::<*Stmt>(cast::<ContextBindingStmt>(s)->body), depth, label);
            }
            case StmtKind::ConditionalStmt {
                var c = cast::<ConditionalStmt>(s);
                if self._breaks_out(static_cast::<*Stmt>(c->then_), depth, label) { return true; }
                return self._breaks_out(c->else_, depth, label);
            }
            case StmtKind::MatchStmt {
                // `break` inside a match targets the enclosing loop (StmtKind
                // doc), so a match is not a depth step.
                var m = cast::<MatchStmt>(s);
                for var i: usize = 0; i < m->cases.size(); ++i {
                    var mc = m->cases.get(i);
                    if self._breaks_out(static_cast::<*Stmt>(mc->body), depth, label) { return true; }
                }
                return false;
            }
            case StmtKind::TryCatchStmt {
                var t = cast::<TryCatchStmt>(s);
                if self._breaks_out(static_cast::<*Stmt>(t->try_body), depth, label) { return true; }
                for var i: usize = 0; i < t->arms.size(); ++i {
                    var arm = t->arms.get(i);
                    if self._breaks_out(static_cast::<*Stmt>(arm->body), depth, label) { return true; }
                }
                return false;
            }
            case StmtKind::LabeledStmt {
                return self._breaks_out(cast::<LabeledStmt>(s)->inner, depth, label);
            }
            case StmtKind::LoopStmt {
                return self._breaks_out(static_cast::<*Stmt>(cast::<LoopStmt>(s)->body), depth + 1, label);
            }
            case StmtKind::WhileLoopStmt {
                return self._breaks_out(static_cast::<*Stmt>(cast::<WhileLoopStmt>(s)->body), depth + 1, label);
            }
            case StmtKind::IndexedForStmt {
                return self._breaks_out(static_cast::<*Stmt>(cast::<IndexedForStmt>(s)->body), depth + 1, label);
            }
            case StmtKind::RangedForStmt {
                return self._breaks_out(static_cast::<*Stmt>(cast::<RangedForStmt>(s)->body), depth + 1, label);
            }
            default { return false; }
        }
    }

    priv fn _is_true_literal(self, e: *Expr) -> bool {
        if e == &null { return false; }
        if !isa::<BooleanLiteralExpr>(e) { return false; }
        return cast::<BooleanLiteralExpr>(e)->value;
    }

    // --- match ------------------------------------------------------------

    priv fn _match_falls_through(self, m: *MatchStmt) -> bool {
        for var i: usize = 0; i < m->cases.size(); ++i {
            var mc = m->cases.get(i);
            if mc->body != &null {
                if self._block_falls_through(mc->body) { return true; }
            } else if !self._diverges(mc->expression) {
                return true;
            }
        }
        return !self._exhaustive(m);
    }

    /// Only what the fall-through question needs; see the file header.
    priv fn _exhaustive(self, m: *MatchStmt) -> bool {
        var st: *Type = &null;
        if (m->scrutinee != &null) && (m->scrutinee->type_ != &null) {
            st = canon_unqual(m->scrutinee->type_);
        }
        // Unknown scrutinee type: already an error upstream. Do not stack a
        // missing-return on it.
        if st == &null { return true; }

        var en: *EnumDecl = &null;
        if isa::<RecordType>(st) { en = dyn_cast::<EnumDecl>(cast::<RecordType>(st)->decl); }
        var is_bool = self._tu.is_bool(st);

        var covered: vec::<u32>;
        var saw_true  = false;
        var saw_false = false;

        for var i: usize = 0; i < m->cases.size(); ++i {
            var mc = m->cases.get(i);
            if mc->is_default { return true; }
            // A guarded arm may decline; it covers nothing for certain.
            if mc->guard != &null { continue; }
            for var j: usize = 0; j < mc->patterns.size(); ++j {
                var p = mc->patterns[j];
                if self._irrefutable(p) { return true; }
                if en != &null { self._collect_variants(p, &covered); }
                if is_bool {
                    var v = self._bool_value(p);
                    if v == 1 { saw_true  = true; }
                    if v == 0 { saw_false = true; }
                }
            }
        }

        if is_bool { return saw_true && saw_false; }
        if en == &null { return false; }
        for var i: usize = 0; i < en->variants.size(); ++i {
            var vd = en->variants[i];
            if vd == &null { continue; }
            var want = self._imm(vd->name);
            var hit  = false;
            for var k: usize = 0; k < covered.size(); ++k {
                if covered[k] == want { hit = true; break; }
            }
            if (!hit) { return false; }
        }
        return true;
    }

    /// Matches every value: `_`, or a binder with no type test.
    priv fn _irrefutable(self, p: *Pattern) -> bool {
        if p == &null { return false; }
        switch p->kind {
            case PatternKind::WildcardPattern { return true; }
            case PatternKind::BindingPattern  { return cast::<BindingPattern>(p)->type_ == &null; }
            case PatternKind::TupleDestructurePattern {
                var t = cast::<TupleDestructurePattern>(p);
                for var i: usize = 0; i < t->elements.size(); ++i {
                    if (!self._irrefutable(t->elements[i])) { return false; }
                }
                return true;
            }
            case PatternKind::AlternationPattern {
                var a = cast::<AlternationPattern>(p);
                for var i: usize = 0; i < a->alternatives.size(); ++i {
                    if self._irrefutable(a->alternatives[i]) { return true; }
                }
                return false;
            }
            default { return false; }
        }
    }

    /// Record the variant \p p covers WHOLE: a constructor head whose
    /// payload (if any) is all irrefutable.
    priv fn _collect_variants(self, p: *Pattern, out: *vec::<u32>) {
        if p == &null { return; }
        if p->kind == PatternKind::AlternationPattern {
            var a = cast::<AlternationPattern>(p);
            for var i: usize = 0; i < a->alternatives.size(); ++i {
                self._collect_variants(a->alternatives[i], out);
            }
            return;
        }
        if p->kind != PatternKind::ConstructorPattern { return; }
        var c = cast::<ConstructorPattern>(p);
        for var i: usize = 0; i < c->subpatterns.size(); ++i {
            if (!self._irrefutable(c->subpatterns[i])) { return; }
        }
        var imm = u32(-1);
        if c->is_dotted { imm = self._imm(c->dotted_name); }
        else            { imm = self._head_imm(c->head); }
        if imm != u32(-1) { out->push_back(imm); }
    }

    /// The LAST name of a path head: `Color::Red` -> Red, `Red` -> Red.
    priv fn _head_imm(self, e: *Expr) -> u32 {
        if e == &null { return u32(-1); }
        if isa::<NamedIdentExpr>(e) { return self._imm(cast::<NamedIdentExpr>(e)->name); }
        if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            var n  = ch->steps.size();
            if n == 0 { return self._head_imm(ch->base); }
            var last = ch->steps.get(n - 1);
            if last->name == &null { return u32(-1); }
            return self._imm(last->name->name);
        }
        return u32(-1);
    }

    /// 1 for a `true` literal pattern, 0 for `false`, -1 otherwise.
    priv fn _bool_value(self, p: *Pattern) -> i32 {
        if p == &null { return -1; }
        if p->kind != PatternKind::LiteralPattern { return -1; }
        var v = cast::<LiteralPattern>(p)->value;
        if (v == &null) || (!isa::<BooleanLiteralExpr>(v)) { return -1; }
        return (1) if (cast::<BooleanLiteralExpr>(v)->value) else (0);
    }

    priv fn _imm(self, tok: Token) -> u32 {
        return self.sc->ctx->get_ident_imm(tok);
    }
}
