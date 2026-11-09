/// --- The Kairo Project ----------------- Sema/Check/PatternChecking.k --- ///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::DeclFacts::{
    adt_pack_variant,
    adt_variant_at,
}
import AST::Kind::PatternKind::PatternKind
import AST::Node::Base::{
    Expr,
    Pattern,
}
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::cast
import AST::Node::Expressions::MatchExpr
import AST::Node::Patterns::{
    AlternationPattern,
    ConstructorPattern,
    TupleDestructurePattern,
    UnresolvedConstructorPattern,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    MatchCase,
    MatchStmt,
    match_first_row,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::PatternSpace::{
    Ctor, CtorKind, Domain, DomainKind, PatRow, PatternSpace, sort_unique_keys,
}
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil

/// The answer to "is q useful against P?", with the witness when asked for.
/// `witness` holds one rendered pattern per column of q.
pub struct Usefulness {
    var useful:  bool                     = false
    var witness: cxx::std::vector<string>
}

/// The constant-rows answer (PatternChecking::_flat_check): the dead
/// verdict per row, and the non-exhaustive witness when one is missing.
pub struct FlatVerdict {
    var dead:      cxx::std::vector<u8>
    var missing:   Usefulness
    var open_tail: bool                 = false
}

/// What one analysis of one match concluded.
pub struct MatchVerdict {
    var analysed:      bool = false
    var is_exhaustive: bool = true
    var covering_arm:  i32  = -1
    var open_tail:     bool = false
}

pub class PatternChecking derives RecursiveASTVisitor<PatternChecking> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    priv var _ps: PatternSpace

    fn PatternChecking(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
        self._ps = PatternSpace(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
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
    }

    /// # entry points

    fn visit_match_stmt(self, n: unsafe *MatchStmt) -> bool {
        if n == &null {
            return true
        }

        var v = self._check(n->scrutinee, &n->cases, n->range, true, n->null_arm)
        n->is_exhaustive = v.is_exhaustive
        n->covering_arm  = v.covering_arm
        n->open_tail     = v.open_tail
        return true
    }

    fn visit_match_expr(self, n: unsafe *MatchExpr) -> bool {
        if n == &null {
            return true
        }

        var v = self._check(n->scrutinee, &n->cases, n->range, false, n->null_arm)
        n->is_exhaustive = v.is_exhaustive
        n->covering_arm  = v.covering_arm
        n->open_tail     = v.open_tail
        return true
    }

    /// Statement and expression form alike; see the file header.
    priv fn _requires_exhaustive(self, stmt_form: bool) -> bool {
        return true
    }

    /// # one match

    /// \p null_arm: a match on `T?` whose arm 0 is `case null` (Compiler/Spec/Nullables.md
    /// 3.6). That arm is no row: it answers the null the other arms never
    /// see, and they were typed against `T`, so the column is `T` (a
    /// `bool?` with `case null`, `true`, `false` is exhaustive).
    priv fn _check(self,
                   scrutinee: unsafe *Expr,
                   cases:     *FrozenList<MatchCase>,
                   at:        SourceRange,
                   stmt_form: bool,
                   null_arm:  bool) -> MatchVerdict {
        var v = MatchVerdict{}
        if scrutinee == &null || scrutinee->type_ == &null || scrutinee->is_poisoned() {
            return v
        }

        if canon_unqual(scrutinee->type_) == &null {
            return v
        }

        // A bounds-checked parameter's match is analysed like any other:
        // its rows can only bind (PatternTyping refused the rest), so it is
        // exhaustive exactly when an unguarded binder or wildcard ends it.
        // So is a generic ADT's at dependent arguments, whose variants are
        // known (PatternSpace::domain_of); anything else dependent is not.
        if canon_unqual(scrutinee->type_)->is_dependent()
            && self._ps.domain_of(scrutinee->type_).kind == DomainKind::Unknown {
            return v
        }

        for var i: usize = 0; i < cases->size(); ++i {
            var unsafe *mc = cases->get(i)
            for var j: usize = 0; j < mc->patterns.size(); ++j {
                if self._broken(mc->patterns[j]) {
                    return v
                }
            }
        }

        v.analysed = true
        // `@open enum E` holds values no variant names (enums-plain.md): a match
        // listing every variant is exhaustive (its tail traps, open_tail), and a
        // `default` after them is reachable, the arm those values take.
        var sdom      = self._ps.domain_of(scrutinee->type_)
        var decl_open = sdom.en != &null && sdom.en->is_open

        // One row per case-level alternative; `default` is one wildcard row.
        var rows  = cxx::std::vector<PatRow>()
        var first = match_first_row(null_arm)
        for var i: usize = first; i < cases->size(); ++i {
            var unsafe *mc = cases->get(i)
            if mc->is_default || mc->patterns.size() == 0 {
                var r = PatRow{}
                r.arm     = (i as u32)
                r.alt     = 0
                r.guarded = mc->guard != &null
                r.cols.push_back(&null)
                rows.push_back(r)
                continue
            }

            for var j: usize = 0; j < mc->patterns.size(); ++j {
                var r = PatRow{}
                r.arm     = (i as u32)
                r.alt     = (j as u32)
                r.guarded = mc->guard != &null
                r.cols.push_back(mc->patterns[j])
                rows.push_back(r)
            }
        }

        // Every head a constant (or a wildcard): usefulness is set
        // membership, in one pass over the rows (see _flat_check).
        var flat = cxx::std::vector<cxx::std::vector<Ctor>>()
        var fd   = Domain{}
        if self._flat_rows(&rows, &flat, &fd) {
            var fv = FlatVerdict{}
            self._flat_check(rows, &flat, fd, &fv)
            if decl_open {
                self._spare_open_default(&rows, &fv.dead)
            }

            self._report_dead(cases, &rows, fv.dead)
            if fv.missing.useful {
                v.is_exhaustive = false
                v.covering_arm  = -1
                if self._requires_exhaustive(stmt_form) {
                    self._report_missing(scrutinee, at, &fv.missing)
                }

                return v
            }

            v.is_exhaustive = true
            v.covering_arm  = (cases->size() as i32) - 1
            v.open_tail     = fv.open_tail
            return v
        }

        var dead = self._dead_rows(rows)
        if decl_open {
            self._spare_open_default(&rows, &dead)
        }

        self._report_dead(cases, &rows, dead)

        // Exhaustiveness, closed enums first.
        var covering = cxx::std::vector<PatRow>()
        for var i: usize = 0; i < rows.size(); ++i {
            if !rows[i].guarded {
                covering.push_back(rows[i])
            }
        }

        var q = cxx::std::vector<unsafe *Pattern>()
        q.push_back(&null)

        var closed = self._useful(unsafe &covering, unsafe &q, true, true)
        if closed.useful {
            v.is_exhaustive = false
            v.covering_arm  = -1
            if self._requires_exhaustive(stmt_form) {
                self._report_missing(scrutinee, at, &closed)
            }

            return v
        }

        v.is_exhaustive = true
        v.covering_arm  = (cases->size() as i32) - 1
        // Exhaustive over declared values; would it be over every value?
        var open = self._useful(unsafe &covering, unsafe &q, false, false)
        v.open_tail = open.useful
        return v
    }

    /// A pattern tree already diagnosed: skip the whole match.
    priv fn _broken(self, p: unsafe *Pattern) -> bool {
        if p == &null {
            return false
        }

        if p->is_error() || p->is_poisoned() {
            return true
        }

        match p->kind {
            case PatternKind::TupleDestructurePattern {
                var unsafe *t = cast<TupleDestructurePattern>(p)
                for var i: usize = 0; i < t->elements.size(); ++i {
                    if self._broken(t->elements[i]) {
                        return true
                    }
                }
            } case PatternKind::AlternationPattern {
                var unsafe *a = cast<AlternationPattern>(p)
                for var i: usize = 0; i < a->alternatives.size(); ++i {
                    if self._broken(a->alternatives[i]) {
                        return true
                    }
                }
            } case PatternKind::ConstructorPattern {
                var unsafe *c = cast<ConstructorPattern>(p)
                if c->resolved_decl == &null {
                    return true
                }

                for var i: usize = 0; i < c->subpatterns.size(); ++i {
                    if self._broken(c->subpatterns[i]) {
                        return true
                    }
                }
            } case PatternKind::UnresolvedConstructorPattern {
                var unsafe *c = cast<UnresolvedConstructorPattern>(p)
                if c->resolved_decl == &null {
                    return true
                }

                for var i: usize = 0; i < c->subpatterns.size(); ++i {
                    if self._broken(c->subpatterns[i]) {
                        return true
                    }
                }
            } default {
                0
            }
        }

        return false
    }

    /// # dead rows

    /// Row i is dead when it is not useful against the unguarded rows
    /// before it. The general matrix: O(rows^2) specializations.
    priv fn _dead_rows(self, const rows: cxx::std::vector<PatRow>) -> cxx::std::vector<u8> {
        var dead = cxx::std::vector<u8>()
        for var i: usize = 0; i < rows.size(); ++i {
            var before = cxx::std::vector<PatRow>()
            for var k: usize = 0; k < i; ++k {
                if !(rows)[k].guarded {
                    before.push_back((rows)[k])
                }
            }

            var q = (rows)[i].cols
            var u = self._useful(unsafe &before, unsafe &q, true, false)
            dead.push_back((!u.useful) as u8)
        }

        return dead
    }

    /// A `default` row (no pattern) over an `@open` enum is never dead: the
    /// values no variant names reach it however many variants come before.
    priv fn _spare_open_default(self,
                                @inout rows: cxx::std::vector<PatRow>,
                                @inout dead: cxx::std::vector<u8>) {
        for var i: usize = 0; i < rows.size(); ++i {
            if i < dead.size()
                && (dead)[i] != 0
                && (rows)[i].cols.size() == 1
                && (rows)[i].cols[0] == &null {
                (dead)[i] = 0
            }
        }
    }

    priv fn _report_dead(self,
                         cases:       *FrozenList<MatchCase>,
                         @inout rows: cxx::std::vector<PatRow>,
                         const deadp: cxx::std::vector<u8>) {
        var dead       = deadp
        var i:   usize = 0
        while i < rows.size() {
            var arm      = (rows)[i].arm
            var first    = i
            var all_dead = true
            while i < rows.size() && (rows)[i].arm == arm {
                if dead[i] == 0 {
                    all_dead = false
                }

                i = i + 1
            }

            var unsafe *mc = cases->get(arm as usize)
            if all_dead {
                self.sc->diag->report(
                    DiagID::SC121E,
                    mc->range.start,
                    "this arm can never match: the arms before it already cover every value it matches",
                ).first(mc->range)->note(
                    mc->range.start,
                    "remove it, or move it above the arm that covers it",
                )->emit()
                continue
            }

            for var k: usize = first; k < i; ++k {
                if dead[k] == 0 {
                    continue
                }

                var unsafe *p = (rows)[k].cols[0]
                if p == &null {
                    continue
                }

                self.sc->diag->report(
                    DiagID::SC122E,
                    p->range.start,
                    "this alternative can never match: earlier patterns already cover every value it matches",
                ).first(p->range)->emit()
            }
        }
    }

    /// # constant rows
    ///
    /// The shape of a generated table (the diagnostic registry's 5000-arm
    /// matches): one column whose every head is a wildcard or a constant --
    /// a payload-free variant, a bool, a single integer, an opaque literal.
    /// A constant covers exactly the rows with its own constructor, so for
    /// q a constant, "useful against P" is "no wildcard and no equal head in
    /// P", and for q a wildcard it is "no wildcard, and the heads seen are not
    /// the whole domain". The general matrix answers the same questions with
    /// a specialization per row per earlier row; this answers them with one
    /// set, so the verdicts and witnesses are the general path's, in O(rows).

    /// The heads of every row, an alternation's alternatives each a head;
    /// false when some head is not a constant of the column's one domain
    /// (\p d, from the first typed head), which leaves the general path.
    priv fn _flat_rows(self,
                       @inout rows: cxx::std::vector<PatRow>,
                       @inout out:  cxx::std::vector<cxx::std::vector<Ctor>>,
                       d:           *Domain) -> bool {
        var have = false
        for var i: usize = 0; i < rows.size(); ++i {
            if (rows)[i].cols.size() != 1 {
                return false
            }

            var alts = cxx::std::vector<unsafe *Pattern>()
            self._flat_alts((rows)[i].cols[0], unsafe &alts)
            var hs = cxx::std::vector<Ctor>()
            for var k: usize = 0; k < alts.size(); ++k {
                var unsafe *p = alts[k]
                if self._ps.is_wild(p) {
                    hs.push_back(Ctor{})
                    continue
                }

                if p->type_ == &null {
                    return false
                }

                var pd = self._ps.domain_of(p->type_)
                if !have {
                    *d   = pd
                    have = true
                    // Once: the scan is O(variants), and this runs per head.
                    if pd.kind == DomainKind::ClosedEnum && adt_pack_variant(pd.en) != &null {
                        return false
                    }
                } else if pd.kind != d->kind
                    || pd.en != d->en
                    || pd.bits != d->bits
                    || pd.signed_ != d->signed_ {
                    return false
                }

                var c = self._ps.ctor_of(p)
                match d->kind {
                    case DomainKind::ClosedEnum {
                        if c.kind != CtorKind::Variant
                            || c.arity != (0 as u32)
                            || c.index >= d->nctors {
                            return false
                        }
                    } case DomainKind::Bool {
                        if c.kind != CtorKind::Bool {
                            return false
                        }
                    } case DomainKind::Int {
                        if c.kind != CtorKind::Int || c.lo != c.hi {
                            return false
                        }
                    } case DomainKind::OpenEnum {
                        if c.kind != CtorKind::Opaque {
                            return false
                        }
                    } case DomainKind::Opaque {
                        if c.kind != CtorKind::Opaque {
                            return false
                        }
                    } default {
                        return false
                    }
                }

                hs.push_back(c)
            }

            out.push_back(hs)
        }

        return true
    }

    /// \p p's alternatives, nested alternations flattened, in order.
    priv fn _flat_alts(self, p: unsafe *Pattern, out: unsafe *cxx::std::vector<unsafe *Pattern>) {
        if p != &null && p->kind == PatternKind::AlternationPattern {
            var unsafe *a = cast<AlternationPattern>(p)
            for var k: usize = 0; k < a->alternatives.size(); ++k {
                self._flat_alts(a->alternatives[k], out)
            }

            return
        }

        out->push_back(p)
    }

    /// One constant's identity within its domain.
    priv fn _flat_key(self, const c: Ctor) -> string {
        match c.kind {
            case CtorKind::Variant {
                return f"v{c.index}"
            } case CtorKind::Bool {
                return f"b{c.lo}"
            } case CtorKind::Int {
                return f"i{c.lo}"
            } default {
                0
            }
        }

        return "o" + c.key
    }

    /// \p distinct different constants cover all of \p d.
    priv fn _flat_complete(self, d: Domain, distinct: u64) -> bool {
        match d.kind {
            case DomainKind::ClosedEnum {
                return distinct == (d.nctors as u64)
            } case DomainKind::Bool {
                return distinct == (2 as u64)
            } case DomainKind::Int {
                return distinct > (0 as u64) && distinct - (1 as u64) == d.max_key
            } default {
                0
            }
        }

        return false
    }

    priv fn _flat_check(self,
                        const rows:   cxx::std::vector<PatRow>,
                        @inout heads: cxx::std::vector<cxx::std::vector<Ctor>>,
                        d:            Domain,
                        out:          *FlatVerdict) {
        var seen:     llvm::StringMap<u32>
        var distinct: u64                  = 0
        var any_wild                       = false
        var ints                           = cxx::std::vector<u64>()
        for var i: usize = 0; i < rows.size(); ++i {
            var *hs    = &(heads)[i]
            var useful = false
            for var k: usize = 0; k < hs->size(); ++k {
                var c = (*hs)[k]
                if any_wild {
                    break
                }

                if c.kind == CtorKind::Wild {
                    if !self._flat_complete(d, distinct) {
                        useful = true
                    }
                } else {
                    var key = self._flat_key(c)
                    if seen.find(kairo::sref(key)) == seen.end() {
                        useful = true
                    }
                }
            }

            out->dead.push_back((!useful) as u8)
            if (rows)[i].guarded {
                continue
            }

            for var k: usize = 0; k < hs->size(); ++k {
                var c = (*hs)[k]
                if c.kind == CtorKind::Wild {
                    any_wild = true
                    continue
                }

                var key = self._flat_key(c)
                if seen.find(kairo::sref(key)) != seen.end() {
                    continue
                }

                seen.try_emplace(kairo::sref(key), i as u32)
                distinct += (1)
                if c.kind == CtorKind::Int {
                    ints.push_back(c.lo)
                }
            }
        }

        if any_wild || self._flat_complete(d, distinct) {
            // Exhaustive; over every value, or only over the declared
            // variants (the general path's closed=false question).
            out->open_tail = d.kind == DomainKind::ClosedEnum && !any_wild
            return
        }

        // The witness the general path builds: the first missing
        // constructor, or `_` where no list of constants is complete.
        var w = "_"
        match d.kind {
            case DomainKind::ClosedEnum {
                for var k: u32 = 0; k < d.nctors; ++k {
                    var c = Ctor{}
                    c.kind  = CtorKind::Variant
                    c.index = k
                    if seen.find(kairo::sref(self._flat_key(c))) != seen.end() {
                        continue
                    }

                    var none = cxx::std::vector<string>()
                    w = self._ps.render(d, c, unsafe &none)
                    break
                }
            } case DomainKind::Bool {
                var t = Ctor{}
                t.kind = CtorKind::Bool
                t.lo   = (1)
                w = if (seen.find(kairo::sref(self._flat_key(t))) != seen.end()) => ("false")
                    else => "true"
            } case DomainKind::Int {
                // The first segment no head covers: below the least key, or
                // between two keys, or above the greatest.
                sort_unique_keys(unsafe &ints)
                var lo:   u64 = 0
                var hi:   u64 = d.max_key
                var found     = false
                for var k: usize = 0; k < ints.size() && !found; ++k {
                    if ints[k] > lo {
                        hi    = ints[k] - (1 as u64)
                        found = true
                    } else {
                        lo = ints[k] + (1 as u64)
                    }
                }

                w = self._ps.range_str(d, lo, hi)
            } default {
                0
            }
        }

        out->missing.useful = true
        out->missing.witness.push_back(w)
    }

    /// # non-exhaustive

    priv fn _report_missing(self, scrutinee: unsafe *Expr, at: SourceRange, u: *Usefulness) {
        var w = "_"
        if u->witness.size() > 0 {
            w = u->witness[0]
        }

        var ty = self._tu.str(scrutinee->type_)
        if w == "_" {
            self.sc->diag->report(
                DiagID::SC120E,
                at.start,
                f"match is not exhaustive: '{ty}' values other than the ones listed are not covered",
            ).first(scrutinee->range)->note(
                at.start,
                f"'{ty}' can hold values no list of patterns names; add a 'default' arm",
            )->emit()
            return
        }

        self.sc->diag->report(
            DiagID::SC120E,
            at.start,
            f"match is not exhaustive: '{w}' is not covered",
        ).first(scrutinee->range)->note(
            at.start,
            f"add an arm for '{w}', or a 'default' arm",
        )->emit()
    }

    /// # usefulness

    /// Is \p q useful against \p rows0? \p closed: closed enums are complete
    /// when every variant is listed. \p want: build the witness.
    priv fn _useful(self,
                    rows0:  unsafe *cxx::std::vector<PatRow>,
                    q:      unsafe *cxx::std::vector<unsafe *Pattern>,
                    closed: bool,
                    want:   bool) -> Usefulness {
        var res  = Usefulness{}
        var rows = self._ps.expand_heads(&*rows0)

        if q->size() == 0 {
            res.useful = rows.size() == 0
            return res
        }

        var unsafe *qh = (*q)[0]

        // An alternation in q: useful when any alternative is.
        if qh != &null && qh->kind == PatternKind::AlternationPattern {
            var unsafe *a = cast<AlternationPattern>(qh)
            for var k: usize = 0; k < a->alternatives.size(); ++k {
                var q2 = *q
                q2[0] = a->alternatives[k]
                var r = self._useful(unsafe &rows, unsafe &q2, closed, want)
                if r.useful {
                    return r
                }
            }

            return res
        }

        // A constructor in q: specialize by it (an integer range by each of
        // its segments).
        if !self._ps.is_wild(qh) {
            var d = self._ps.domain_of(qh->type_)
            var c = self._ps.ctor_of(qh)
            if c.kind == CtorKind::Int {
                var segs = self._ps.int_segments(rows, c.lo, c.hi)
                for var k: usize = 0; k < segs.size(); ++k {
                    var r = self._useful_ctor(unsafe &rows, *q, segs[k], d, closed, want)
                    if r.useful {
                        return r
                    }
                }

                return res
            }

            return self._useful_ctor(unsafe &rows, *q, c, d, closed, want)
        }

        // A wildcard in q: either the heads of column 0 form a complete
        // signature (try every constructor), or some constructor is missing
        // and the default matrix decides.
        var d       = self._ps.head_domain(rows)
        var missing = "_"

        match d.kind {
            case DomainKind::ClosedEnum {
                var n    = (d.nctors as usize) // a pack-expanded variant counts once per element.
                var seen = cxx::std::vector<u8>()
                for var k: usize = 0; k < n; ++k {
                    seen.push_back(0)
                }

                for var i: usize = 0; i < rows.size(); ++i {
                    var unsafe *h = rows[i].cols[0]
                    if self._ps.is_wild(h) {
                        continue
                    }

                    var hc = self._ps.ctor_of(h)
                    if hc.kind == CtorKind::Variant && (hc.index as usize) < n {
                        seen[hc.index as usize] = 1
                    }
                }

                var first_missing: i32 = -1
                for var k: usize = 0; k < n; ++k {
                    if seen[k] == 0 && first_missing < 0 {
                        first_missing = (k as i32)
                    }
                }

                if closed && first_missing < 0 {
                    for var k: usize = 0; k < n; ++k {
                        var c = Ctor{}
                        c.kind  = CtorKind::Variant
                        c.index = (k as u32)
                        c.arity = (adt_variant_at(d.en, k)->payload.size() as u32)
                        var r = self._useful_ctor(unsafe &rows, *q, c, d, closed, want)
                        if r.useful {
                            return r
                        }
                    }

                    return res
                }

                if closed && first_missing >= 0 {
                    var c = Ctor{}
                    c.kind  = CtorKind::Variant
                    c.index = (first_missing as u32)
                    var none = cxx::std::vector<string>()
                    missing = self._ps.render(d, c, unsafe &none)
                }
            } case DomainKind::Bool {
                var saw_f = false
                var saw_t = false
                for var i: usize = 0; i < rows.size(); ++i {
                    var unsafe *h = rows[i].cols[0]
                    if self._ps.is_wild(h) {
                        continue
                    }

                    var hc = self._ps.ctor_of(h)
                    if hc.kind != CtorKind::Bool {
                        continue
                    }

                    if hc.lo == (1 as u64) {
                        saw_t = true
                    } else {
                        saw_f = true
                    }
                }

                if saw_f && saw_t {
                    for var b: u64 = 0; b < (2 as u64); ++b {
                        var c = Ctor{}
                        c.kind = CtorKind::Bool
                        c.lo   = b
                        c.hi   = b
                        var r = self._useful_ctor(unsafe &rows, *q, c, d, closed, want)
                        if r.useful {
                            return r
                        }
                    }

                    return res
                }

                missing = if (!saw_t) => ("true") else => "false"
            } case DomainKind::Int {
                var segs      = self._ps.int_segments(rows, 0, d.max_key)
                var hole: i32 = -1
                for var k: usize = 0; k < segs.size(); ++k {
                    if !self._segment_covered(rows, segs[k]) && hole < 0 {
                        hole = (k as i32)
                    }
                }

                if hole < 0 {
                    for var k: usize = 0; k < segs.size(); ++k {
                        var r = self._useful_ctor(unsafe &rows, *q, segs[k], d, closed, want)
                        if r.useful {
                            return r
                        }
                    }

                    return res
                }

                var c = segs[hole as usize]
                missing = self._ps.range_str(d, c.lo, c.hi)
            } case DomainKind::Record {
                var c = Ctor{}
                c.kind  = CtorKind::Record
                c.arity = d.arity
                return self._useful_ctor(unsafe &rows, *q, c, d, closed, want)
            } default {
                0
            }
        }

        // Incomplete signature: the default matrix decides; a missing
        // constructor heads the witness.
        var drows = self._ps.default_rows(&rows)
        var qt    = cxx::std::vector<unsafe *Pattern>()
        for var k: usize = 1; k < q->size(); ++k {
            qt.push_back((*q)[k])
        }

        var r = self._useful(unsafe &drows, unsafe &qt, closed, want)
        if r.useful && want {
            var w = cxx::std::vector<string>()
            w.push_back(missing)
            for var k: usize = 0; k < r.witness.size(); ++k {
                w.push_back(r.witness[k])
            }

            r.witness = w
        }

        return r
    }

    /// Specialize rows and q by \p c, recurse, and wrap the sub-witness.
    priv fn _useful_ctor(self,
                         rows:    unsafe *cxx::std::vector<PatRow>,
                         const q: cxx::std::vector<unsafe *Pattern>,
                         const c: Ctor,
                         d:       Domain,
                         closed:  bool,
                         want:    bool) -> Usefulness {
        var srows = self._ps.specialize(&*rows, c)
        var sq    = self._ps.sub_columns((q)[0], c.arity)
        for var k: usize = 1; k < q.size(); ++k {
            sq.push_back((q)[k])
        }

        var r = self._useful(unsafe &srows, unsafe &sq, closed, want)
        if r.useful && want {
            var subs = cxx::std::vector<string>()
            var rest = cxx::std::vector<string>()
            for var k: usize = 0; k < r.witness.size(); ++k {
                if k < (c.arity as usize) {
                    subs.push_back(r.witness[k])
                } else {
                    rest.push_back(r.witness[k])
                }
            }

            var w = cxx::std::vector<string>()
            w.push_back(self._ps.render(d, c, unsafe &subs))
            for var k: usize = 0; k < rest.size(); ++k {
                w.push_back(rest[k])
            }

            r.witness = w
        }

        return r
    }

    /// Some Int head of column 0 contains segment \p s.
    priv fn _segment_covered(self, const rows: cxx::std::vector<PatRow>, const s: Ctor) -> bool {
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *h = (rows)[i].cols[0]
            if self._ps.is_wild(h) {
                continue
            }

            var hc = self._ps.ctor_of(h)
            if hc.kind == CtorKind::Int && hc.lo <= s.lo && s.hi <= hc.hi {
                return true
            }
        }

        return false
    }
}
