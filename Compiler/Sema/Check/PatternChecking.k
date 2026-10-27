/// --- The Kairo Project -------------------- Sema/Check/PatternChecking.k --- ///
///
///   \brief Exhaustiveness and dead arms for every `match`, and the facts
///          MatchLowering and ReturnPathCheck read off a match.
///
///   \detail
///     Usefulness over a pattern matrix (Maranget, "Warnings for pattern
///     matching", JFP 2007): a pattern vector q is USEFUL against rows P when
///     some value matches q and no row of P. Then
///
///       exhaustive   <=>  the all-wildcard vector is not useful against
///                         every unguarded row;
///       dead row     <=>  the row is not useful against the unguarded rows
///                         before it.
///
///     The search that proves usefulness also builds a WITNESS -- a value no
///     arm takes -- which the non-exhaustive error names: "`.West` is not
///     covered", "`(0, _)` is not covered".
///
///     Rows: one per case-level alternative (`case A, B` is two rows of one
///     arm), plus one wildcard row for `default`. A guarded row may decline at
///     run time, so it never covers anything; it is still checked for being
///     dead itself. An arm whose every row is dead is an error; a single dead
///     alternative of a live arm is an error at that alternative.
///
///     Integer columns are cut into segments at every range boundary in the
///     column, so `0..=127` and `128..=255` together complete `u8`. Closed
///     enums are complete when every variant is listed. Strings, chars,
///     floats, nullables and open enums never are: they need a wildcard.
///
///   \par Facts written (one writer: this pass)
///       is_exhaustive  every value of the scrutinee type reaches an arm.
///       covering_arm   the arm the remainder falls to: the last arm, when
///                      exhaustive; -1 otherwise.
///       open_tail      exhaustive only because a closed enum's variants were
///                      all listed. An undeclared discriminant (from C++, or
///                      `as`) still reaches no arm; MatchLowering applies
///                      UnmatchedPolicy to it.
///
///   \par Both forms must be exhaustive
///     The statement form too (control-flow.md, Exhaustiveness). One switch,
///     `_requires_exhaustive`, if that ever changes.
///
///   \par Skipped matches
///     A scrutinee whose type is unknown or dependent, and any match holding
///     a poisoned or recovery pattern, are not analysed: the error is already
///     out, and a second one is noise. They are recorded exhaustive so
///     ReturnPathCheck stays quiet too. A dependent scrutinee is M2's.
///
///   Phase: CHECK (after ExprTyper: reads Pattern::type_, resolved_decl and
///          field_decl, which PatternTyping writes; before ReturnPathCheck,
///          which reads is_exhaustive)
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
import Sema::Check::PatternSpace::*;
import AST::DeclFacts::*;
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
import AST::Kind::PatternKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

/// The answer to "is q useful against P?", with the witness when asked for.
/// `witness` holds one rendered pattern per column of q.
struct Usefulness {
    var useful:  bool = false;
    var witness: vec::<string>;
}

/// What one analysis of one match concluded.
struct MatchVerdict {
    var analysed:      bool = false;
    var is_exhaustive: bool = true;
    var covering_arm:  i32  = -1;
    var open_tail:     bool = false;
}

class PatternChecking derives RecursiveASTVisitor::<PatternChecking> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;
    priv var _ps: PatternSpace;

    fn PatternChecking(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
        self._ps = PatternSpace(sc);
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

    fn visit_match_stmt(self, n: *MatchStmt) -> bool {
        if n == &null { return true; }
        var v = self._check(n->scrutinee, &(n->cases), n->range, true, n->null_arm);
        n->is_exhaustive = v.is_exhaustive;
        n->covering_arm  = v.covering_arm;
        n->open_tail     = v.open_tail;
        return true;
    }

    fn visit_match_expr(self, n: *MatchExpr) -> bool {
        if n == &null { return true; }
        var v = self._check(n->scrutinee, &(n->cases), n->range, false, n->null_arm);
        n->is_exhaustive = v.is_exhaustive;
        n->covering_arm  = v.covering_arm;
        n->open_tail     = v.open_tail;
        return true;
    }

    /// Statement and expression form alike; see the file header.
    priv fn _requires_exhaustive(self, stmt_form: bool) -> bool { return true; }

    // === one match ========================================================

    /// \p null_arm: a match on `T?` whose arm 0 is `case null` (NULLABLE.md
    /// 3.6). That arm is no row: it answers the null the other arms never
    /// see, and they were typed against `T`, so the column is `T` (a
    /// `bool?` with `case null`, `true`, `false` is exhaustive).
    priv fn _check(self, scrutinee: *Expr, cases: *FrozenList::<MatchCase>,
                   at: SourceRange, stmt_form: bool, null_arm: bool) -> MatchVerdict {
        var v = MatchVerdict{};
        if (scrutinee == &null) || (scrutinee->type_ == &null) || scrutinee->is_poisoned() { return v; }
        if canon_unqual(scrutinee->type_) == &null { return v; }
        if canon_unqual(scrutinee->type_)->is_dependent() { return v; }
        for var i: usize = 0; i < cases->size(); ++i {
            var mc = cases->get(i);
            for var j: usize = 0; j < mc->patterns.size(); ++j {
                if self._broken(mc->patterns[j]) { return v; }
            }
        }
        v.analysed = true;

        // One row per case-level alternative; `default` is one wildcard row.
        var rows = vec::<PatRow>();
        var first = match_first_row(null_arm);
        for var i: usize = first; i < cases->size(); ++i {
            var mc = cases->get(i);
            if mc->is_default || (mc->patterns.size() == 0) {
                var r = PatRow{};
                r.arm = u32(i); r.alt = 0; r.guarded = (mc->guard != &null);
                r.cols.push_back(&null);
                rows.push_back(r);
                continue;
            }
            for var j: usize = 0; j < mc->patterns.size(); ++j {
                var r = PatRow{};
                r.arm = u32(i); r.alt = u32(j); r.guarded = (mc->guard != &null);
                r.cols.push_back(mc->patterns[j]);
                rows.push_back(r);
            }
        }

        self._report_dead(cases, &rows);

        // Exhaustiveness, closed enums first.
        var covering = vec::<PatRow>();
        for var i: usize = 0; i < rows.size(); ++i { if !rows[i].guarded { covering.push_back(rows[i]); } }
        var q = vec::<*Pattern>();
        q.push_back(&null);

        var closed = self._useful(&covering, &q, true, true);
        if closed.useful {
            v.is_exhaustive = false;
            v.covering_arm  = -1;
            if self._requires_exhaustive(stmt_form) {
                self._report_missing(scrutinee, at, &closed);
            }
            return v;
        }

        v.is_exhaustive = true;
        v.covering_arm  = i32(cases->size()) - 1;
        // Exhaustive over declared values; would it be over every value?
        var open = self._useful(&covering, &q, false, false);
        v.open_tail = open.useful;
        return v;
    }

    /// A pattern tree already diagnosed: skip the whole match.
    priv fn _broken(self, p: *Pattern) -> bool {
        if p == &null { return false; }
        if p->is_error() || p->is_poisoned() { return true; }
        switch p->kind {
            case PatternKind::TupleDestructurePattern {
                var t = cast::<TupleDestructurePattern>(p);
                for var i: usize = 0; i < t->elements.size(); ++i { if self._broken(t->elements[i]) { return true; } }
            }
            case PatternKind::AlternationPattern {
                var a = cast::<AlternationPattern>(p);
                for var i: usize = 0; i < a->alternatives.size(); ++i { if self._broken(a->alternatives[i]) { return true; } }
            }
            case PatternKind::ConstructorPattern {
                var c = cast::<ConstructorPattern>(p);
                if c->resolved_decl == &null { return true; }
                for var i: usize = 0; i < c->subpatterns.size(); ++i { if self._broken(c->subpatterns[i]) { return true; } }
            }
            case PatternKind::UnresolvedConstructorPattern {
                var c = cast::<UnresolvedConstructorPattern>(p);
                if c->resolved_decl == &null { return true; }
                for var i: usize = 0; i < c->subpatterns.size(); ++i { if self._broken(c->subpatterns[i]) { return true; } }
            }
            default { 0; }
        }
        return false;
    }

    // === dead rows ========================================================

    priv fn _report_dead(self, cases: *FrozenList::<MatchCase>, rows: *vec::<PatRow>) {
        var dead = vec::<bool>();
        for var i: usize = 0; i < rows->size(); ++i {
            var before = vec::<PatRow>();
            for var k: usize = 0; k < i; ++k { if !(*rows)[k].guarded { before.push_back((*rows)[k]); } }
            var q = (*rows)[i].cols;
            var u = self._useful(&before, &q, true, false);
            dead.push_back(!u.useful);
        }

        var i: usize = 0;
        while i < rows->size() {
            var arm = (*rows)[i].arm;
            var first = i;
            var all_dead = true;
            while (i < rows->size()) && ((*rows)[i].arm == arm) {
                if !dead[i] { all_dead = false; }
                i = i + 1;
            }
            var mc = cases->get(usize(arm));
            if all_dead {
                self.sc->diag->report(DiagID::SC121E, mc->range.start,
                    "this arm can never match: the arms before it already cover every value it matches"
                ).first(mc->range)
                 .note(mc->range.start, "remove it, or move it above the arm that covers it")
                 .emit();
                continue;
            }
            for var k: usize = first; k < i; ++k {
                if !dead[k] { continue; }
                var p = (*rows)[k].cols[0];
                if p == &null { continue; }
                self.sc->diag->report(DiagID::SC122E, p->range.start,
                    "this alternative can never match: earlier patterns already cover every value it matches"
                ).first(p->range).emit();
            }
        }
    }

    // === non-exhaustive ===================================================

    priv fn _report_missing(self, scrutinee: *Expr, at: SourceRange, u: *Usefulness) {
        var w = "_";
        if u->witness.size() > 0 { w = u->witness[0]; }
        var ty = self._tu.str(scrutinee->type_);
        if w == "_" {
            self.sc->diag->report(DiagID::SC120E, at.start,
                f"match is not exhaustive: '{ty}' values other than the ones listed are not covered"
            ).first(scrutinee->range)
             .note(at.start, f"'{ty}' can hold values no list of patterns names; add a 'default' arm")
             .emit();
            return;
        }
        self.sc->diag->report(DiagID::SC120E, at.start,
            f"match is not exhaustive: '{w}' is not covered"
        ).first(scrutinee->range)
         .note(at.start, f"add an arm for '{w}', or a 'default' arm")
         .emit();
    }

    // === usefulness =======================================================

    /// Is \p q useful against \p rows0? \p closed: closed enums are complete
    /// when every variant is listed. \p want: build the witness.
    priv fn _useful(self, rows0: *vec::<PatRow>, q: *vec::<*Pattern>, closed: bool, want: bool) -> Usefulness {
        var res = Usefulness{};
        var rows = self._ps.expand_heads(rows0);

        if q->size() == 0 {
            res.useful = (rows.size() == 0);
            return res;
        }

        var qh = (*q)[0];

        // An alternation in q: useful when any alternative is.
        if (qh != &null) && (qh->kind == PatternKind::AlternationPattern) {
            var a = cast::<AlternationPattern>(qh);
            for var k: usize = 0; k < a->alternatives.size(); ++k {
                var q2 = *q;
                q2[0] = a->alternatives[k];
                var r = self._useful(&rows, &q2, closed, want);
                if r.useful { return r; }
            }
            return res;
        }

        // A constructor in q: specialize by it (an integer range by each of
        // its segments).
        if !self._ps.is_wild(qh) {
            var d = self._ps.domain_of(qh->type_);
            var c = self._ps.ctor_of(qh);
            if c.kind == CtorKind::Int {
                var segs = self._ps.int_segments(&rows, c.lo, c.hi);
                for var k: usize = 0; k < segs.size(); ++k {
                    var r = self._useful_ctor(&rows, q, segs[k], d, closed, want);
                    if r.useful { return r; }
                }
                return res;
            }
            return self._useful_ctor(&rows, q, c, d, closed, want);
        }

        // A wildcard in q: either the heads of column 0 form a complete
        // signature (try every constructor), or some constructor is missing
        // and the default matrix decides.
        var d = self._ps.head_domain(&rows);
        var missing = "_";

        switch d.kind {
            case DomainKind::ClosedEnum {
                var n = usize(d.nctors);   // a pack-expanded variant counts once per element.
                var seen = vec::<bool>();
                for var k: usize = 0; k < n; ++k { seen.push_back(false); }
                for var i: usize = 0; i < rows.size(); ++i {
                    var h = rows[i].cols[0];
                    if self._ps.is_wild(h) { continue; }
                    var hc = self._ps.ctor_of(h);
                    if (hc.kind == CtorKind::Variant) && (usize(hc.index) < n) { seen[usize(hc.index)] = true; }
                }
                var first_missing: i32 = -1;
                for var k: usize = 0; k < n; ++k { if (!seen[k]) && (first_missing < 0) { first_missing = i32(k); } }
                if closed && (first_missing < 0) {
                    for var k: usize = 0; k < n; ++k {
                        var c = Ctor{};
                        c.kind  = CtorKind::Variant;
                        c.index = u32(k);
                        c.arity = u32(adt_variant_at(d.en, k)->payload.size());
                        var r = self._useful_ctor(&rows, q, c, d, closed, want);
                        if r.useful { return r; }
                    }
                    return res;
                }
                if closed && (first_missing >= 0) {
                    var c = Ctor{};
                    c.kind = CtorKind::Variant; c.index = u32(first_missing);
                    var none = vec::<string>();
                    missing = self._ps.render(d, c, &none);
                }
            }
            case DomainKind::Bool {
                var saw_f = false;
                var saw_t = false;
                for var i: usize = 0; i < rows.size(); ++i {
                    var h = rows[i].cols[0];
                    if self._ps.is_wild(h) { continue; }
                    var hc = self._ps.ctor_of(h);
                    if hc.kind != CtorKind::Bool { continue; }
                    if hc.lo == u64(1) { saw_t = true; } else { saw_f = true; }
                }
                if saw_f && saw_t {
                    for var b: u64 = 0; b < u64(2); ++b {
                        var c = Ctor{};
                        c.kind = CtorKind::Bool; c.lo = b; c.hi = b;
                        var r = self._useful_ctor(&rows, q, c, d, closed, want);
                        if r.useful { return r; }
                    }
                    return res;
                }
                missing = ("true") if (!saw_t) else ("false");
            }
            case DomainKind::Int {
                var segs = self._ps.int_segments(&rows, u64(0), d.max_key);
                var hole: i32 = -1;
                for var k: usize = 0; k < segs.size(); ++k {
                    if (!self._segment_covered(&rows, segs[k])) && (hole < 0) { hole = i32(k); }
                }
                if hole < 0 {
                    for var k: usize = 0; k < segs.size(); ++k {
                        var r = self._useful_ctor(&rows, q, segs[k], d, closed, want);
                        if r.useful { return r; }
                    }
                    return res;
                }
                var c = segs[usize(hole)];
                missing = self._ps.range_str(d, c.lo, c.hi);
            }
            case DomainKind::Record {
                var c = Ctor{};
                c.kind = CtorKind::Record; c.arity = d.arity;
                return self._useful_ctor(&rows, q, c, d, closed, want);
            }
            default { 0; }
        }

        // Incomplete signature: the default matrix decides; a missing
        // constructor heads the witness.
        var drows = self._ps.default_rows(&rows);
        var qt = vec::<*Pattern>();
        for var k: usize = 1; k < q->size(); ++k { qt.push_back((*q)[k]); }
        var r = self._useful(&drows, &qt, closed, want);
        if r.useful && want {
            var w = vec::<string>();
            w.push_back(missing);
            for var k: usize = 0; k < r.witness.size(); ++k { w.push_back(r.witness[k]); }
            r.witness = w;
        }
        return r;
    }

    /// Specialize rows and q by \p c, recurse, and wrap the sub-witness.
    priv fn _useful_ctor(self, rows: *vec::<PatRow>, q: *vec::<*Pattern>, c: Ctor, d: Domain,
                         closed: bool, want: bool) -> Usefulness {
        var srows = self._ps.specialize(rows, c);
        var sq = self._ps.sub_columns((*q)[0], c.arity);
        for var k: usize = 1; k < q->size(); ++k { sq.push_back((*q)[k]); }
        var r = self._useful(&srows, &sq, closed, want);
        if r.useful && want {
            var subs = vec::<string>();
            var rest = vec::<string>();
            for var k: usize = 0; k < r.witness.size(); ++k {
                if k < usize(c.arity) { subs.push_back(r.witness[k]); }
                else                  { rest.push_back(r.witness[k]); }
            }
            var w = vec::<string>();
            w.push_back(self._ps.render(d, c, &subs));
            for var k: usize = 0; k < rest.size(); ++k { w.push_back(rest[k]); }
            r.witness = w;
        }
        return r;
    }

    /// Some Int head of column 0 contains segment \p s.
    priv fn _segment_covered(self, rows: *vec::<PatRow>, s: Ctor) -> bool {
        for var i: usize = 0; i < rows->size(); ++i {
            var h = (*rows)[i].cols[0];
            if self._ps.is_wild(h) { continue; }
            var hc = self._ps.ctor_of(h);
            if (hc.kind == CtorKind::Int) && (hc.lo <= s.lo) && (s.hi <= hc.hi) { return true; }
        }
        return false;
    }
}