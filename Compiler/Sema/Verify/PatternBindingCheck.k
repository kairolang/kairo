/// --- The Kairo Project -------------------- Sema/Verify/PatternBindingCheck.k --- ///
///
///   \brief Verify binding structure inside patterns. Pure lexical check:
///          Token.imm comparison, no names, no types.
///
///   \detail
///     Checks owned here:
///       1. ALTERNATIVE CONSISTENCY: every alternative of an alternation
///          (`A | B` inside a pattern, or `case A, B` at case level) must
///          bind the SAME set of names `Some(x) | None` is an error
///          because the body's `x` is unbound when `None` matches.
///       2. DUPLICATE BINDINGS: one name bound twice within a single
///          alternative (`Pair(x, x)`) or destructuring (`var (a, a)`).
///       3. DEAD ALTERNATIVES: an irrefutable alternative (`_`, or a bare
///          un-ascribed binding) that is not last makes its following
///          siblings unreachable. The CASE-level analog (whole arm dead)
///          is ArmOrderCheck's; this is within one arm's alternatives.
///
///     Irrefutable = WildcardPattern, a BindingPattern with no `: T`
///     ascription (an ascribed binding is a runtime type test), or an
///     alternation with an irrefutable alternative.
///
///     Nested alternations own their internals: when collecting an
///     alternation's bound set from outside, the FIRST alternative stands
///     for the whole (consistency inside it is enforced by its own visit),
///     and its dup-check is skipped at the outer level to avoid double
///     reporting.
///
///   Phase: VERIFY (pre-N)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import Sema::SemaContext::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Statements::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Patterns::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::PatternKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Diagnostic::Registry::*;

class PatternBindingCheck derives RecursiveASTVisitor::<PatternBindingCheck> {
    pub var sc: *SemaContext;

    fn PatternBindingCheck(self, sc: *SemaContext) {
        self.sc = sc;
    }

    fn run(self) {
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }
        
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl { self.dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dispatch_expr(item.as_expr()); }
                default { }
            }
        }
    }

    /// Collect every binding name token in \p p. For a nested alternation,
    /// the first alternative stands for the whole (see header).
    priv fn _collect(self, p: *Pattern, out: *vec::<Token>) {
        if p == &null { return; }
        switch p->kind {
            case PatternKind::BindingPattern {
                out->push_back(cast::<BindingPattern>(p)->name);
            } case PatternKind::TupleDestructurePattern {
                var n = cast::<TupleDestructurePattern>(p);
                for var i: usize = 0; i < n->elements.size(); i++ {
                    self._collect(*(n->elements.get(i)), out);
                }
            } case PatternKind::ConstructorPattern {
                var n = cast::<ConstructorPattern>(p);
                for var i: usize = 0; i < n->subpatterns.size(); i++ {
                    self._collect(*(n->subpatterns.get(i)), out);
                }
            } case PatternKind::UnresolvedConstructorPattern {
                var n = cast::<UnresolvedConstructorPattern>(p);
                for var i: usize = 0; i < n->subpatterns.size(); i++ {
                    self._collect(*(n->subpatterns.get(i)), out);
                }
            } case PatternKind::SlicePattern {
                var n = cast::<SlicePattern>(p);
                for var i: usize = 0; i < n->prefix.size(); i++ {
                    self._collect(*(n->prefix.get(i)), out);
                }
                for var i: usize = 0; i < n->suffix.size(); i++ {
                    self._collect(*(n->suffix.get(i)), out);
                }
                if n->rest_binding != &null { self._collect(n->rest_binding, out); }
            } case PatternKind::AlternationPattern {
                var n = cast::<AlternationPattern>(p);
                if n->alternatives.size() > 0 {
                    self._collect(*(n->alternatives.get(0)), out);
                }
            } default { 0; }
        }
    }

    /// Report each name bound more than once in \p v (at the later token).
    priv fn _dup_check(self, v: *vec::<Token>) {
        for var i: usize = 1; i < v->size(); i++ {
            for var j: usize = 0; j < i; j++ {
                if (*v)[j].imm == (*v)[i].imm {
                    self.sc->diag->report(DiagID::SC001E, (*v)[i].range.start,
                        "duplicate binding name in pattern; a name may bind "
                        "only once per alternative"
                    ).first((*v)[i].range).emit();
                    break;
                }
            }
        }
    }

    priv fn _sets_equal(self, a: *vec::<Token>, b: *vec::<Token>) -> bool {
        // set semantics over imms; dup reporting is _dup_check's job.
        for var i: usize = 0; i < a->size(); i++ {
            var found: bool = false;
            for var j: usize = 0; j < b->size(); j++ {
                if (*a)[i].imm == (*b)[j].imm { found = true; break; }
            }

            if !found { return false; }
        }

        for var i: usize = 0; i < b->size(); i++ {
            var found: bool = false;
            for var j: usize = 0; j < a->size(); j++ {
                if (*b)[i].imm == (*a)[j].imm { found = true; break; }
            }

            if !found { return false; }
        }

        return true;
    }

    /// Matches every value: `_`, a bare un-ascribed binding, or an
    /// alternation with an irrefutable alternative.
    priv fn _is_irrefutable(self, p: *Pattern) -> bool {
        if p == &null { return false; }
        switch p->kind {
            case PatternKind::WildcardPattern { return true; }
            case PatternKind::BindingPattern {
                return cast::<BindingPattern>(p)->type_ == &null;
            } case PatternKind::AlternationPattern {
                var n = cast::<AlternationPattern>(p);
                for var i: usize = 0; i < n->alternatives.size(); i++ {
                    if self._is_irrefutable(*(n->alternatives.get(i))) { return true; }
                }
                return false;
            } default { return false; }
        }
    }

    /// The shared core: \p alts are sibling alternatives (an alternation's
    /// list, or a case's pattern list same FrozenList shape, same rules).
    priv fn _check_alternatives(self, alts: *FrozenList::<*Pattern>) {
        var first_set = vec::<Token>();
        var dead_reported: bool = false;

        for var i: usize = 0; i < alts->size(); i++ {
            var p = *(alts->get(i));
            if p == &null { continue; }

            var names = vec::<Token>();
            self._collect(p, &names);

            // nested alternation dup checks itself via its own visit.
            if p->kind != PatternKind::AlternationPattern {
                self._dup_check(&names);
            }

            if i == 0 {
                first_set = names;
            } else if !self._sets_equal(&first_set, &names) {
                self.sc->diag->report(DiagID::SC001E, p->range.start,
                    "alternative patterns must bind the same names; this "
                    "alternative's bindings differ from the first"
                ).first(p->range).emit();
            }

            if (!dead_reported) && ((i + 1) < alts->size()) && self._is_irrefutable(p) {
                var nx = *(alts->get(i + 1));
                if nx != &null {
                    self.sc->diag->report(DiagID::SC001W, nx->range.start,
                        "unreachable alternative; a previous alternative "
                        "matches everything first"
                    ).first(nx->range).emit();
                    dead_reported = true;
                }
            }
        }
    }

    fn visit_alternation_pattern(self, n: *AlternationPattern) -> bool {
        self._check_alternatives(&(n->alternatives));
        return true;
    }

    fn traverse_match_case(self, mc: *MatchCase) {
        self._check_alternatives(&(mc->patterns));
        for var i: usize = 0; i < mc->patterns.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_pattern(*(mc->patterns.get(i)));  // discard
        }

        if self.stop { return; }
        if mc->guard      != &null { self.dyn()->dispatch_expr(mc->guard); }
        if mc->body       != &null { self.dyn()->dispatch_stmt(mc->body); }
        if mc->expression != &null { self.dyn()->dispatch_expr(mc->expression); }
    }

    /// Destructuring bindings are plain named slots, not patterns; the
    /// only structural rule is no duplicate names.
    fn visit_destructuring_decl_stmt(self, n: *DestructuringDeclStmt) -> bool {
        var names = vec::<Token>();
        for var i: usize = 0; i < n->bindings.size(); i++ {
            var b = n->bindings.get(i);
            if b->is_discard { continue; }
            if b->name == &null { continue; }
            names.push_back(b->name->name);
        }

        self._dup_check(&names);
        return true;
    }
}
