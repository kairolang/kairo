/// --- The Kairo Project ----------------------- Sema/Check/ShadowCheck.k --- ///
///
///   \brief Warn when a local binding shadows an outer one OF THE SAME TYPE.
///
///   \detail
///     Shadowing is legal in Kairo and mostly harmless. The case that
///     correlates with bugs is narrow: an inner declaration with the SAME
///     TYPE as the outer one it hides, which is what you get when you meant
///     to ASSIGN to the outer binding and accidentally introduced a new one.
///
///         var count = 0
///         if cond {
///             var count = 0      // warned: you probably meant `count = 0`
///         }
///
///     A type CHANGE is the opposite signal -- it is the whole point of the
///     rebinding, and warning on it would fire constantly on correct code:
///
///         const raw = read()
///         if cond {
///             const raw = raw.trim()   // not warned: different type
///         }
///
///     This is why -Wshadow is not in C++'s -Wall and why Rust and clippy
///     do not lint plain shadowing at all: the unrestricted rule has a high
///     enough false-positive rate that projects disable it wholesale, and a
///     warning everyone opts out of is worse than no warning. Kairo has
///     warnings on by default, which raises that bar rather than lowering
///     it -- the restriction to same-type is what makes the warning
///     survivable.
///
///   \par Scope: LEXICAL FRAMES ONLY
///     A local hiding another local. NOT a local hiding a file-scope or
///     imported name: that fires on every local sharing a name with
///     anything in scope anywhere, which is exactly the noise pattern
///     above, and the outer name is reachable by qualification so nothing
///     is lost. NOT a parameter hiding a field, which is -Wshadow's worst
///     false positive (`fn C(self, x: i32)` initializing `self.x`).
///
///   \par Same-frame is not this pass
///     Two declarations in ONE frame are handled by
///     NameResolution::_declare_local: a `var` on either side is a
///     redefinition, two `const`s are a legal rebinding. By the time this
///     pass runs, a same-frame collision has already been diagnosed or
///     deliberately allowed. This pass only looks OUTWARD.
///
///   \par Why it runs after T, and why it is quiet today
///     Same-type-vs-different-type needs canonical types, so this cannot
///     live in N. It also needs INFERENCE: `var x = 10` carries an
///     InferredType whose canonical is null until TypeInference fills it,
///     and comparing two nulls is inconclusive. Until TypeInference lands
///     this pass is silent for unannotated locals, which is the honest
///     degradation -- it starts working as inference does, with no change
///     here.
///
///   \par FIXME(dedup): this duplicates N's lexical-frame walk
///     Every traverse_* override below mirrors NameResolution's, including
///     _suppress_next_block_frame and the statement-binder ordering. Two
///     copies of "what is a frame" will drift. The fix is a shared RAV base
///     that owns the frame stack and calls a hook on declare/open/close;
///     N, this pass, and anything else that needs lexical structure derive
///     from it. Not done here because changing N's frame handling while
///     chasing a live driver bug is a bad trade.
///
///   Phase: CHECK (after T; after TypeInference once that exists)
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
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Expressions::*;
import AST::Node::Patterns::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::Casting::*;
import AST::Kind::PatternKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

__inline_cpp("
#define RecursiveASTVisitor_ShadowCheck RecursiveASTVisitor<ShadowCheck>
");

/// One executable-scope frame: the names declared so far in this
/// block/function, in declaration order. Mirrors NameResolution::LocalScope;
/// see the dedup FIXME in the file header.
class ShadowFrame {
    pub var names: vec::<u32>;
    pub var decls: vec::<*Decl>;

    fn ShadowFrame(self) { }

    fn declare(self, imm: u32, d: *Decl) {
        self.names.push_back(imm);
        self.decls.push_back(d);
    }

    /// Latest-first, so a frame that legally rebound a const reports the
    /// newest binding as the thing being shadowed.
    fn index_of(self, imm: u32) -> usize {
        var n = self.names.size();
        for var i: usize = 0; i < n; ++i {
            var j = (n - 1) - i;
            if self.names[j] == imm { return j; }
        }
        return usize(-1);
    }
}

///
/// \class ShadowCheck
/// \brief The pass. Read-only: emits diagnostics, writes nothing to the AST.
///
class ShadowCheck derives RecursiveASTVisitor::<ShadowCheck> {
    pub var sc: *SemaContext;

    priv var _frames: vec::<ShadowFrame>;
    priv var _self_imm: u32 = u32(-1);

    /// A function body's params live in the frame pushed by
    /// traverse_function_decl; the body's own CompoundStmt must NOT push a
    /// second frame, or a local colliding with a param would look like a
    /// shadow instead of the redefinition N already reported.
    priv var _suppress_next_block_frame: bool = false;

    fn ShadowCheck(self, sc: *SemaContext) {
        self.sc = sc;
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        self._self_imm = self.sc->imm_table()->intern_ident_copy("self");

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

    // === the check ========================================================

    /// Push \p d into the innermost frame, warning first if it hides an
    /// outer binding of the same type.
    priv fn _declare(self, imm: u32, d: *Decl, at: SourceRange) {
        if imm == u32(-1) { return; }
        if self._frames.empty() { return; }
        if d == &null { return; }

        // A poisoned decl was already diagnosed (a redefinition, a bad
        // type). Piling a shadow warning on top adds noise to a line the
        // user is already fixing.
        if !d->is_poisoned() { self._check_shadow(imm, d, at); }

        var frame = &(self._frames[self._frames.size() - 1]);
        frame->declare(imm, d);
    }

    /// Search the OUTER frames only, innermost first. The innermost frame is
    /// same-frame territory and belongs to N (see the header).
    priv fn _check_shadow(self, imm: u32, d: *Decl, at: SourceRange) {
        var n = self._frames.size();
        if n < 2 { return; }

        var hidden: *Decl = &null;
        for var i: usize = 0; i < (n - 1); ++i {
            var fi    = (n - 2) - i;
            var frame = &(self._frames[fi]);
            var idx   = frame->index_of(imm);
            if idx != usize(-1) { hidden = frame->decls[idx]; break; }
        }
        if hidden == &null { return; }
        if hidden->is_poisoned() { return; }

        var a = self._type_of(d);
        var b = self._type_of(hidden);
        // Inconclusive: an unannotated local carries an InferredType whose
        // canonical is null until TypeInference runs. Silence is correct --
        // the alternative is warning on every shadow, which is the rule this
        // pass exists to avoid.
        if (a == &null) || (b == &null) { return; }
        if a != b { return; }               // a type CHANGE is the point.

        var nm = self.sc->imm_table()->get_ident(imm);
        self.sc->diag->report(DiagID::R048W, at.start,
            f"declaration of '{nm}' hides an outer binding of the same type"
        ).first(at)
         .note(DiagID::R048N, hidden->range.start,
            f"outer '{nm}' declared here; assign to it with '{nm} = ...' if that "
            "is what you meant, or rename this one"
        ).first(hidden->range).emit();
    }

    /// The canonical type of a binding, or null when it is not yet known.
    priv fn _type_of(self, d: *Decl) -> *Type {
        if d == &null { return &null; }
        var t: *Type = &null;
        if      isa::<VariableDecl>(d) { t = cast::<VariableDecl>(d)->type_; }
        else if isa::<ParamDecl>(d) {
            var tu = TypeUtil(self.sc);
            return tu.param_value_type(cast::<ParamDecl>(d));   // a pack is its slice.
        }
        else                           { return &null; }   // local fn/type: not a value rebinding.
        if t == &null { return &null; }
        return t->canonical;
    }

    // === frame management (mirrors NameResolution) ========================

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        if n == &null { return n; }
        var saved_suppress = self._suppress_next_block_frame;

        self._frames.push_back(ShadowFrame{});
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if p == &null { continue; }
            self._declare(self._name_imm(p->name), static_cast::<*Decl>(p), p->range);
        }

        self._suppress_next_block_frame = true;
        var out = RecursiveASTVisitor_ShadowCheck::traverse_function_decl(n);

        self._frames.pop_back();
        self._suppress_next_block_frame = saved_suppress;
        return out;
    }

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        if n == &null { return n; }
        var saved_suppress = self._suppress_next_block_frame;

        self._frames.push_back(ShadowFrame{});
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if p == &null { continue; }
            self._declare(self._name_imm(p->name), static_cast::<*Decl>(p), p->range);
        }

        self._suppress_next_block_frame = true;
        var out = RecursiveASTVisitor_ShadowCheck::traverse_closure_expr(n);

        self._frames.pop_back();
        self._suppress_next_block_frame = saved_suppress;
        return out;
    }

    fn traverse_compound_stmt(self, n: *CompoundStmt) -> *CompoundStmt {
        if n == &null { return n; }
        var push = !self._suppress_next_block_frame;
        self._suppress_next_block_frame = false;

        if push { self._frames.push_back(ShadowFrame{}); }
        var out = RecursiveASTVisitor_ShadowCheck::traverse_compound_stmt(n);
        if push { self._frames.pop_back(); }
        return out;
    }

    /// The initializer is walked FIRST, so `var x = x` sees the OUTER x and
    /// the shadow check runs against the world this name is about to hide.
    fn traverse_variable_decl(self, n: *VariableDecl) -> *VariableDecl {
        if n == &null { return n; }
        var out = RecursiveASTVisitor_ShadowCheck::traverse_variable_decl(n);
        if !self._frames.empty() {
            self._declare(self._name_imm(n->name), static_cast::<*Decl>(n), n->range);
        }
        return out;
    }

    // --- statement-level binders ------------------------------------------

    fn traverse_ranged_for_stmt(self, n: *RangedForStmt) -> *RangedForStmt {
        if n == &null { return n; }
        if self.dyn()->walkup_ranged_for_stmt(n) == false { return n; }
        if n->iterable != &null { n->iterable = self.dyn()->dispatch_expr(n->iterable); }

        self._frames.push_back(ShadowFrame{});
        self._declare_bindings(&(n->bindings));
        self._suppress_next_block_frame = true;
        n->body = self.dyn()->traverse_block(n->body);
        self._frames.pop_back();
        return n;
    }

    fn traverse_indexed_for_stmt(self, n: *IndexedForStmt) -> *IndexedForStmt {
        if n == &null { return n; }
        if self.dyn()->walkup_indexed_for_stmt(n) == false { return n; }

        self._frames.push_back(ShadowFrame{});
        if n->init   != &null { n->init   = self.dyn()->dispatch_stmt(n->init);   }
        if n->cond   != &null { n->cond   = self.dyn()->dispatch_expr(n->cond);   }
        if n->update != &null { n->update = self.dyn()->dispatch_expr(n->update); }
        self._suppress_next_block_frame = true;
        n->body = self.dyn()->traverse_block(n->body);
        self._frames.pop_back();
        return n;
    }

    fn traverse_context_binding_stmt(self, n: *ContextBindingStmt) -> *ContextBindingStmt {
        if n == &null { return n; }
        if self.dyn()->walkup_context_binding_stmt(n) == false { return n; }
        if n->value != &null { n->value = self.dyn()->dispatch_expr(n->value); }

        self._frames.push_back(ShadowFrame{});
        self._declare_bindings(&(n->bindings));
        self._suppress_next_block_frame = true;
        n->body = self.dyn()->traverse_block(n->body);
        self._frames.pop_back();
        return n;
    }

    /// Destructuring declares into the ENCLOSING frame (a decl statement,
    /// not a scope), so no frame push.
    fn traverse_destructuring_decl_stmt(self, n: *DestructuringDeclStmt)
            -> *DestructuringDeclStmt {
        if n == &null { return n; }
        if self.dyn()->walkup_destructuring_decl_stmt(n) == false { return n; }
        if n->value != &null { n->value = self.dyn()->dispatch_expr(n->value); }
        self._declare_bindings(&(n->bindings));
        return n;
    }

    fn traverse_try_catch_stmt(self, n: *TryCatchStmt) -> *TryCatchStmt {
        if n == &null { return n; }
        if self.dyn()->walkup_try_catch_stmt(n) == false { return n; }

        n->try_body = self.dyn()->traverse_block(n->try_body);
        for var i: usize = 0; i < n->arms.size(); ++i {
            if self.stop { break; }
            var arm = n->arms.get(i);
            self._frames.push_back(ShadowFrame{});
            self._declare_binder_decl(arm->decl);
            self._suppress_next_block_frame = true;
            if arm->body != &null { self.dyn()->dispatch_stmt(arm->body); }
            self._frames.pop_back();
        }
        return n;
    }

    fn traverse_try_catch_expr(self, n: *TryCatchExpr) -> *TryCatchExpr {
        if n == &null { return n; }
        if self.dyn()->walkup_try_catch_expr(n) == false { return n; }

        if n->try_expr != &null { n->try_expr = self.dyn()->dispatch_expr(n->try_expr); }
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            if self.stop { break; }
            var arm = n->catch_arms.get(i);
            self._frames.push_back(ShadowFrame{});
            self._declare_binder_decl(arm->decl);
            if arm->body != &null { self.dyn()->dispatch_expr(arm->body); }
            self._frames.pop_back();
        }
        return n;
    }

    fn traverse_match_case(self, mc: *MatchCase) {
        if mc == &null { return; }

        self._frames.push_back(ShadowFrame{});
        for var i: usize = 0; i < mc->patterns.size(); ++i {
            if self.stop { break; }
            var pat = *(mc->patterns.get(i));
            self._declare_pattern_binders(pat);
            self.dyn()->dispatch_pattern(pat);
        }
        if !self.stop {
            if mc->guard != &null { self.dyn()->dispatch_expr(mc->guard); }
            if mc->body  != &null {
                self._suppress_next_block_frame = true;
                self.dyn()->dispatch_stmt(mc->body);
            }
            if mc->expression != &null { self.dyn()->dispatch_expr(mc->expression); }
        }
        self._frames.pop_back();
    }

    priv fn _declare_bindings(self, list: *FrozenList::<Binding>) {
        for var i: usize = 0; i < list->size(); ++i {
            var b = (*list)[i];
            if b.is_discard { continue; }
            self._declare_binder_decl(b.decl);
        }
    }

    priv fn _declare_binder_decl(self, d: *Decl) {
        if d == &null { return; }
        var vd = dyn_cast::<VariableDecl>(d);
        if vd == &null { return; }
        self._declare(self._name_imm(vd->name), d, d->range);
    }

    priv fn _declare_pattern_binders(self, p: *Pattern) {
        if p == &null { return; }
        switch p->kind {
            case PatternKind::BindingPattern {
                self._declare_binder_decl(cast::<BindingPattern>(p)->decl);
            } case PatternKind::TupleDestructurePattern {
                var n = cast::<TupleDestructurePattern>(p);
                for var i: usize = 0; i < n->elements.size(); ++i {
                    self._declare_pattern_binders(*(n->elements.get(i)));
                }
            } case PatternKind::ConstructorPattern {
                var n = cast::<ConstructorPattern>(p);
                for var i: usize = 0; i < n->subpatterns.size(); ++i {
                    self._declare_pattern_binders(*(n->subpatterns.get(i)));
                }
            } case PatternKind::UnresolvedConstructorPattern {
                var n = cast::<UnresolvedConstructorPattern>(p);
                for var i: usize = 0; i < n->subpatterns.size(); ++i {
                    self._declare_pattern_binders(*(n->subpatterns.get(i)));
                }
            } case PatternKind::SlicePattern {
                var n = cast::<SlicePattern>(p);
                for var i: usize = 0; i < n->prefix.size(); ++i {
                    self._declare_pattern_binders(*(n->prefix.get(i)));
                }
                for var i: usize = 0; i < n->suffix.size(); ++i {
                    self._declare_pattern_binders(*(n->suffix.get(i)));
                }
                self._declare_pattern_binders(n->rest_binding);
            } case PatternKind::AlternationPattern {
                var n = cast::<AlternationPattern>(p);
                if n->alternatives.size() > 0 {
                    self._declare_pattern_binders(*(n->alternatives.get(0)));
                }
            } default { 0; }
        }
    }

    priv fn _name_imm(self, tok: Token) -> u32 {
        var im = self.sc->ctx->get_ident_imm(tok);
        if im != u32(-1) { return im; }
        if tok.kind == TokenKind::KwSelf { return self._self_imm; }
        return u32(-1);
    }
}