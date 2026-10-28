/// --- The Kairo Project ------------------ Sema/Lower/PatternCompilation.k --- ///
///
///   \brief Every match's rows become a decision DAG: which occurrence of
///          the scrutinee to test, in what order, and which arm each
///          outcome reaches. MatchLowering renders it and decides nothing.
///
///   \detail
///     Maranget, "Compiling Pattern Matching to Good Decision Trees" (ML
///     2008), over PatternSpace's vocabulary. A matrix is rows of patterns
///     over a vector of OCCURRENCES: paths into the scrutinee (`$`, `$.0`,
///     `$.x`, `$.Found.key`). An occurrence is structural, so a binder's
///     occurrence never depends on the order the tests run in.
///
///       first row all wildcards  Leaf, or Guard whose failure continues
///                                with the rows below it.
///       otherwise                pick a column the first row needs, and
///                                branch on its constructors.
///
///     Column choice: a column the first row tests; among those, the
///     longest run of rows from the top that test it; then the fewest
///     distinct heads; then the leftmost.
///
///     Branching, by the column's domain:
///       Record           no test: the column is replaced by its fields
///                        (a tuple is its arity's record).
///       ClosedEnum       Switch on the variant. Complete when every variant
///                        heads some row; the default edge then exists only
///                        when wildcard rows remain, which is where an
///                        undeclared discriminant goes. Without them the
///                        default is UnmatchedPolicy's.
///       Bool             Switch; complete with both values.
///       Int              Switch over segments: the key space cut at every
///                        head's bounds, adjacent segments with the same
///                        surviving rows merged into one `lo...hi` edge.
///       string           Switch keyed by the decoded bytes of literal and
///                        constant heads. Two spellings of one string are
///                        one key, so the edges are disjoint.
///       anything else    Test on the first row's head: a binary node whose
///                        success branch keeps every row that may still
///                        match (equal heads become wildcards, other heads
///                        stay to be tested) and whose failure branch drops
///                        the rows with that head. Sound when two heads
///                        overlap (`'a'..='z'` and `'a'..='f'`), which is
///                        all an opaque value promises.
///
///   \par Size bound
///     Maranget trees can grow exponentially in the column count. Past
///     `16 * rows + 64` nodes the tree is dropped and the match compiles as
///     a backtracking automaton instead: rows in order, each a chain of
///     Tests whose failures share the next row's chain. Linear in the
///     patterns; the sharing makes it a DAG, and MatchLowering labels every
///     node with more than one parent.
///
///   \par Guards
///     A guarded row is a Guard node: success goes to the arm, failure to
///     the matrix of the rows below it. The same row can be reached on
///     several paths; each gets its own Guard node, and MatchLowering emits
///     the guard expression once per arm.
///
///   \par Diagnostics
///     This pass rejects, as SC116E, two tests it has no C++ rendering for:
///     a string column with a head that is not a literal or a constant
///     with a literal initializer, and an opaque test on a record value
///     (equality on a record is a user operator, and OperatorLowering has
///     already run when MatchLowering does).
///
///   \par Skipped matches
///     The same ones PatternChecking skips: unknown or poisoned scrutinee,
///     or a broken pattern. A non-exhaustive match is skipped too; it is
///     already an error. `decision` stays null on all of them.
///
///   \par Slot written (one writer: this pass)
///       MatchStmt::decision / MatchExpr::decision   a *DecisionTree in the
///       TU's arena, as `*void` (the node files cannot import this one).
///
///   Phase: CHECKS, last (after FeatureGate). Reads PatternChecking's facts;
///   --print-sema shows the tree.
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
import Sema::Type::VariadicEnum::*;
import Sema::Lower::LowerSynth::*;
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
import AST::Context::DeclContext::*;
import AST::Visitor::ASTWriter::*;
import Lexer::Immediate::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

// === the tree ===================================================================

/// How an occurrence is reached from its parent.
enum OccKind derives u8 {
    Root = 0,   ///< the scrutinee.
    Field,      ///< `field` of a record; a tuple's element is its field `_i`.
    Payload,    ///< `field` of variant `index`'s payload.
}

struct DOcc {
    var parent: i32       = -1;
    var kind:   OccKind   = OccKind::Root;
    var index:  u32       = 0;
    var field:  *FieldDecl = &null;
    var type_:  *Type     = &null;   ///< the values at this path; from a pattern when one is typed.
}

enum DKind derives u8 {
    Fail = 0,   ///< no row matches: UnmatchedPolicy.
    Leaf,       ///< arm `arm` is taken, binders `binds`.
    Guard,      ///< arm `arm` if its guard holds, else `other`.
    Switch,     ///< multiway on `occ`: edges [edge0, edge0 + nedge), else `other`.
    Test,       ///< binary on `occ`: edge `edge0` holds -> its child, else `other`.
}

/// One outcome of a test. `kind` is the constructor kind; `pat` is a head
/// that tests it, for the kinds whose value lives in a pattern (Opaque,
/// string keys) and for the dump.
struct DEdge {
    var kind:  CtorKind = CtorKind::Wild;
    var index: u32      = 0;       ///< Variant: position in the enum.
    var lo:    u64      = 0;       ///< Bool: 0/1. Int: keys, inclusive.
    var hi:    u64      = 0;
    var pat:   *Pattern = &null;
    var child: u32      = 0;
}

struct DBind {
    var pat: *BindingPattern = &null;
    var occ: u32             = 0;
}

struct DNode {
    var kind:    DKind = DKind::Fail;
    var occ:     u32   = 0;
    var edge0:   u32   = 0;
    var nedge:   u32   = 0;
    var other:   i32   = -1;     ///< Switch: default (-1: complete). Test / Guard: failure.
    var strings: bool  = false;  ///< Switch: keyed by string bytes.
    var arm:     u32   = 0;
    var row:     u32   = 0;      ///< Leaf / Guard: the expanded row's id.
    var bind0:   u32   = 0;
    var nbind:   u32   = 0;
}

/// The compiled match. Arena memory, never freed on its own: it lives as
/// long as the AST it points into.
class DecisionTree {
    pub var nodes:     FrozenList::<DNode>;
    pub var edges:     FrozenList::<DEdge>;
    pub var occs:      FrozenList::<DOcc>;
    pub var binds:     FrozenList::<DBind>;
    pub var root:      u32  = 0;
    pub var row_count: u32  = 0;     ///< distinct row ids.
    pub var automaton: bool = false; ///< the size bound fell back to the backtracking automaton.
}

/// A string head's bytes: a literal's decoded text, or a constant's literal
/// initializer's. False when the head is neither.
fn pattern_string_bytes(sc: *SemaContext, p: *Pattern, out: *vec::<u8>) -> bool {
    if p == &null { return false; }
    var tu = TypeUtil(sc);
    var e: *Expr = &null;
    if p->kind == PatternKind::LiteralPattern {
        e = cast::<LiteralPattern>(p)->value;
    } else if (p->kind == PatternKind::ConstructorPattern) || (p->kind == PatternKind::UnresolvedConstructorPattern) {
        var vd = dyn_cast::<VariableDecl>(p->resolved_decl);
        if (vd == &null) || ((!vd->is_const()) && (!vd->is_eval())) { return false; }
        e = vd->init;
    }
    if e == &null { return false; }
    e = tu.strip_parens(e);
    if (e == &null) || (!isa::<StringLiteralExpr>(e)) { return false; }
    var lit = cast::<StringLiteralExpr>(e);
    if lit->is_format() || (lit->imm == &null) { return false; }

    // StringLowering::_collect, without spending the chain: the literal is
    // still in the tree, and StringLowering lowers it later.
    var synth = LowerSynth(sc);
    var tbl = sc->imm_table();
    var seg = lit->imm;
    var raw = lit->is_raw();
    while seg != &null {
        if seg->has_owned_text() {
            for var i: usize = 0; i < static_cast::<usize>(seg->owned_len); ++i { out->push_back(seg->owned_ptr[i]); }
        } else {
            ICE_IF(!synth.decode_text(seg->body, raw, out),
                "PatternCompilation: escape the lexer accepted but the decoder does not know; keep Lexer::is_valid_escape and LowerSynth::decode_text in step");
        }
        if seg->next == u32(-1) { break; }
        seg = tbl->get::<Immediate::StringData>(seg->next);
        raw = (static_cast::<u8>(seg->prefix_kind) & static_cast::<u8>(Immediate::TextPrefixKind::Raw)) != 0;
    }
    return true;
}

// === build state ================================================================

/// A row while it is being compiled: PatRow plus the binders it has already
/// passed and an id that names it across paths.
struct CRow {
    var cols:    vec::<*Pattern>;
    var arm:     u32  = 0;
    var guarded: bool = false;
    var key:     string;           ///< `arm.alt`, extended at each alternation it expands.
    var binds:   vec::<DBind>;
}

/// One test of a flattened row.
struct FlatTest {
    var occ:  u32 = 0;
    var edge: DEdge;
}

/// A row of the backtracking automaton: its tests in order, then accept.
struct FlatRow {
    var row:   CRow;
    var tests: vec::<FlatTest>;
}

class PatternCompilation derives RecursiveASTVisitor::<PatternCompilation> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;
    priv var _ps: PatternSpace;

    // One match at a time.
    priv var _nodes:  vec::<DNode>;
    priv var _edges:  vec::<DEdge>;
    priv var _occs:   vec::<DOcc>;
    priv var _binds:  vec::<DBind>;
    priv var _keys:   vec::<string>;
    priv var _budget: usize = 0;
    priv var _over:   bool  = false;
    priv var _bad:    bool  = false;   ///< a test with no rendering was reported.
    priv var _flat:   vec::<FlatRow>;  ///< the automaton's rows.

    fn PatternCompilation(self, sc: *SemaContext) {
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
        if (n == &null) || (!n->is_exhaustive) { return true; }
        n->decision = reinterpret_cast::<*void>(self._compile(n->scrutinee, &(n->cases), n->null_arm));
        return true;
    }

    fn visit_match_expr(self, n: *MatchExpr) -> bool {
        if (n == &null) || (!n->is_exhaustive) { return true; }
        n->decision = reinterpret_cast::<*void>(self._compile(n->scrutinee, &(n->cases), n->null_arm));
        return true;
    }

    // === one match ========================================================

    /// \p null_arm (NULLABLE.md 3.6): arm 0 is `case null`, which this tree
    /// never reaches; CoalesceLowering answers it before the match, whose
    /// scrutinee it makes the unwrapped value. So the rows start at arm 1
    /// (arm numbers kept) and the root is `T`.
    priv fn _compile(self, scrutinee: *Expr, cases: *FrozenList::<MatchCase>, null_arm: bool) -> *DecisionTree {
        self._bad = false;
        if (scrutinee == &null) || (scrutinee->type_ == &null) || scrutinee->is_poisoned() { return &null; }
        if canon_unqual(scrutinee->type_) == &null { return &null; }
        for var i: usize = 0; i < cases->size(); ++i {
            var mc = cases->get(i);
            for var j: usize = 0; j < mc->patterns.size(); ++j {
                if self._broken(mc->patterns[j]) { return &null; }
            }
        }

        var rows = self._rows(cases, match_first_row(null_arm));
        var root_ty = scrutinee->type_;
        if null_arm { root_ty = self._tu.nullable_inner(self._tu.as_value(root_ty)); }
        self._reset();
        self._budget = usize(16) * rows.size() + usize(64);
        var root_occ = self._root(root_ty);
        var occs = vec::<u32>();
        occs.push_back(root_occ);

        var root = self._build(&rows, &occs);
        var automaton = false;
        if self._over {
            self._reset();
            root_occ = self._root(root_ty);
            root = self._automaton(&rows, root_occ);
            automaton = true;
        }
        if self._bad { return &null; }
        return self._freeze(root, automaton);
    }

    /// One row per case-level alternative; `default` is one wildcard row.
    priv fn _rows(self, cases: *FrozenList::<MatchCase>, first: usize) -> vec::<CRow> {
        var rows = vec::<CRow>();
        for var i: usize = first; i < cases->size(); ++i {
            var mc = cases->get(i);
            if mc->is_default || (mc->patterns.size() == 0) {
                var r = CRow{};
                r.arm = u32(i); r.guarded = (mc->guard != &null); r.key = f"{i}.0";
                r.cols.push_back(&null);
                rows.push_back(r);
                continue;
            }
            for var j: usize = 0; j < mc->patterns.size(); ++j {
                var r = CRow{};
                r.arm = u32(i); r.guarded = (mc->guard != &null); r.key = f"{i}.{j}";
                r.cols.push_back(mc->patterns[j]);
                rows.push_back(r);
            }
        }
        return rows;
    }

    priv fn _reset(self) {
        self._nodes = vec::<DNode>();
        self._edges = vec::<DEdge>();
        self._occs  = vec::<DOcc>();
        self._binds = vec::<DBind>();
        self._keys  = vec::<string>();
        self._flat  = vec::<FlatRow>();
        self._over  = false;
    }

    /// PatternChecking::_broken: a pattern tree already diagnosed.
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

    // === occurrences ======================================================

    priv fn _root(self, t: *Type) -> u32 {
        var o = DOcc{};
        o.kind = OccKind::Root; o.type_ = t;
        self._occs.push_back(o);
        return u32(self._occs.size() - 1);
    }

    /// The occurrence `parent.<step>`, one id per path.
    priv fn _occ(self, parent: u32, kind: OccKind, index: u32, field: *FieldDecl, t: *Type) -> u32 {
        for var i: usize = 0; i < self._occs.size(); ++i {
            var o = &(self._occs[i]);
            if (o->parent == i32(parent)) && (o->kind == kind) && (o->index == index) && (o->field == field) { return u32(i); }
        }
        var o = DOcc{};
        o.parent = i32(parent); o.kind = kind; o.index = index; o.field = field; o.type_ = t;
        self._occs.push_back(o);
        return u32(self._occs.size() - 1);
    }

    /// A typed head at \p occ refines its type: a field declared `T` in a
    /// generic record is `i32` in the instance the pattern was typed in.
    priv fn _note_type(self, occ: u32, p: *Pattern) {
        if (p == &null) || (p->type_ == &null) { return; }
        var cur = self._occs[usize(occ)].type_;
        if (cur == &null) || ((canon_unqual(cur) != &null) && canon_unqual(cur)->is_dependent()) {
            self._occs[usize(occ)].type_ = p->type_;
        }
    }

    /// The sub-occurrences constructor \p c opens at \p occ in domain \p d.
    priv fn _sub_occs(self, occ: u32, c: Ctor, d: Domain) -> vec::<u32> {
        var out = vec::<u32>();
        switch c.kind {
            case CtorKind::Record {
                var fs = self._ps.instance_fields(d.rec);
                // A tuple's field is declared `Ti`; the element is the
                // instance's argument i, so a wildcard column still has a
                // concrete domain to classify.
                var ot = self._occs[usize(occ)].type_;
                var te = self._tu.tuple_elems(canon_unqual(self._tu.as_value(ot)));
                var is_tup = self._tu.is_tuple(canon_unqual(self._tu.as_value(ot)));
                for var i: usize = 0; (i < fs.size()) && (i < usize(c.arity)); ++i {
                    var ft = self._canon(fs[i]->type_);
                    if is_tup && (i < te.size()) { ft = te[i]; }
                    out.push_back(self._occ(occ, OccKind::Field, 0, fs[i], ft));
                }
            }
            case CtorKind::Variant {
                var v = adt_variant_at(d.en, usize(c.index));
                // Element k of a pack-expanded variant: its fields read at
                // that element's type, which is the occurrence's.
                var k = adt_expansion_at(d.en, usize(c.index));
                for var i: usize = 0; (i < v->payload.size()) && (i < usize(c.arity)); ++i {
                    var f = v->payload[i];
                    var ft = self._canon(f->type_);
                    if k >= 0 { ft = VariadicEnum(self._ps.sc).field_at(d.ty, f, usize(k)); }
                    out.push_back(self._occ(occ, OccKind::Payload, c.index, f, ft));
                }
            }
            default { 0; }
        }
        return out;
    }

    /// A field's WRITTEN type is a syntax node; an occurrence carries the
    /// canonical, which is what PatternSpace::domain_of classifies.
    priv fn _canon(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        return t->canonical;
    }

    // === nodes ============================================================

    priv fn _push(self, n: DNode) -> u32 {
        self._nodes.push_back(n);
        if self._nodes.size() > self._budget { self._over = true; }
        return u32(self._nodes.size() - 1);
    }

    priv fn _fail(self) -> u32 {
        var n = DNode{};
        n.kind = DKind::Fail;
        return self._push(n);
    }

    priv fn _row_id(self, key: string) -> u32 {
        for var i: usize = 0; i < self._keys.size(); ++i { if self._keys[i] == key { return u32(i); } }
        self._keys.push_back(key);
        return u32(self._keys.size() - 1);
    }

    /// Leaf or Guard for \p r, every column of which is a wildcard.
    priv fn _accept(self, r: *CRow, occs: *vec::<u32>, fail: i32) -> u32 {
        var n = DNode{};
        n.kind  = (DKind::Guard) if (r->guarded) else (DKind::Leaf);
        n.arm   = r->arm;
        n.row   = self._row_id(r->key);
        n.other = fail;
        n.bind0 = u32(self._binds.size());
        for var i: usize = 0; i < r->binds.size(); ++i { self._binds.push_back(r->binds[i]); }
        for var c: usize = 0; c < r->cols.size(); ++c {
            var p = r->cols[c];
            if (p != &null) && (p->kind == PatternKind::BindingPattern) {
                var b = DBind{};
                b.pat = cast::<BindingPattern>(p); b.occ = (*occs)[c];
                self._binds.push_back(b);
            }
        }
        n.nbind = u32(self._binds.size()) - n.bind0;
        return self._push(n);
    }

    // === Maranget =========================================================

    priv fn _build(self, rows: *vec::<CRow>, occs: *vec::<u32>) -> u32 {
        if self._over || self._bad { return self._fail(); }
        if rows->size() == 0 { return self._fail(); }

        var r0 = &((*rows)[0]);
        var col: i32 = self._pick_column(rows);
        if col < 0 {
            var fail: i32 = -1;
            if r0->guarded {
                var rest = vec::<CRow>();
                for var i: usize = 1; i < rows->size(); ++i { rest.push_back((*rows)[i]); }
                fail = i32(self._build(&rest, occs));
            }
            return self._accept(&((*rows)[0]), occs, fail);
        }

        // Column `col` to the front.
        var m = vec::<CRow>();
        for var i: usize = 0; i < rows->size(); ++i {
            var r = (*rows)[i];
            if col > 0 {
                var t = r.cols[usize(col)];
                r.cols[usize(col)] = r.cols[0];
                r.cols[0] = t;
            }
            m.push_back(r);
        }
        var o = *occs;
        if col > 0 {
            var t = o[usize(col)];
            o[usize(col)] = o[0];
            o[0] = t;
        }
        var head = o[0];
        var rows2 = self._expand(&m, head);

        for var i: usize = 0; i < rows2.size(); ++i {
            if !self._ps.is_wild(rows2[i].cols[0]) { self._note_type(head, rows2[i].cols[0]); }
        }

        var d = self._head_domain(&rows2);
        switch d.kind {
            case DomainKind::Record {
                var c = Ctor{};
                c.kind = CtorKind::Record; c.arity = d.arity;
                return self._through(&rows2, &o, c, d);
            }
            case DomainKind::ClosedEnum { return self._switch_enum(&rows2, &o, d); }
            case DomainKind::Bool       { return self._switch_bool(&rows2, &o, d); }
            case DomainKind::Int {
                // A constant this file cannot evaluate is an opaque head in
                // an integer column; segments cannot place it, so the column
                // is tested head by head instead.
                if self._all_heads(&rows2, CtorKind::Int) { return self._switch_int(&rows2, &o, d); }
                return self._test(&rows2, &o);
            }
            default { 0; }
        }
        if self._is_string_column(&rows2, head) { return self._switch_string(&rows2, &o); }
        return self._test(&rows2, &o);
    }

    priv fn _all_heads(self, rows: *vec::<CRow>, k: CtorKind) -> bool {
        for var i: usize = 0; i < rows->size(); ++i {
            var h = (*rows)[i].cols[0];
            if self._ps.is_wild(h) { continue; }
            if self._ps.ctor_of(h).kind != k { return false; }
        }
        return true;
    }

    /// The column to branch on, or -1 when the first row is all wildcards.
    priv fn _pick_column(self, rows: *vec::<CRow>) -> i32 {
        var r0 = &((*rows)[0]);
        var best: i32 = -1;
        var best_run: usize = 0;
        var best_heads: usize = 0;
        for var c: usize = 0; c < r0->cols.size(); ++c {
            if self._ps.is_wild(r0->cols[c]) { continue; }
            var run: usize = 0;
            while (run < rows->size()) && (!self._ps.is_wild((*rows)[run].cols[c])) { run += 1; }
            var heads = self._distinct_heads(rows, c);
            if (best < 0) || (run > best_run) || ((run == best_run) && (heads < best_heads)) {
                best = i32(c); best_run = run; best_heads = heads;
            }
        }
        return best;
    }

    /// Distinct heads in column \p c, counted by spelling. A tiebreak only.
    priv fn _distinct_heads(self, rows: *vec::<CRow>, c: usize) -> usize {
        var seen = vec::<string>();
        for var i: usize = 0; i < rows->size(); ++i {
            var p = (*rows)[i].cols[c];
            if self._ps.is_wild(p) { continue; }
            var s = self.sc->ctx->get_spelling(p->range);
            var dup = false;
            for var k: usize = 0; k < seen.size(); ++k { if seen[k] == s { dup = true; break; } }
            if !dup { seen.push_back(s); }
        }
        return seen.size();
    }

    /// Every row whose head is an alternation becomes one row per
    /// alternative, recursively; each choice extends the row's key, so one
    /// choice on two paths is one row id.
    priv fn _expand(self, rows: *vec::<CRow>, occ: u32) -> vec::<CRow> {
        var out = vec::<CRow>();
        for var i: usize = 0; i < rows->size(); ++i { self._expand_into(&((*rows)[i]), occ, &out); }
        return out;
    }

    priv fn _expand_into(self, r: *CRow, occ: u32, out: *vec::<CRow>) {
        var h = r->cols[0];
        if (h == &null) || (h->kind != PatternKind::AlternationPattern) {
            out->push_back(*r);
            return;
        }
        var a = cast::<AlternationPattern>(h);
        for var k: usize = 0; k < a->alternatives.size(); ++k {
            var nr = *r;
            nr.cols[0] = a->alternatives[k];
            nr.key = r->key + f"/{occ}:{k}";
            self._expand_into(&nr, occ, out);
        }
    }

    /// PatternSpace::head_domain over CRow.
    priv fn _head_domain(self, rows: *vec::<CRow>) -> Domain {
        for var i: usize = 0; i < rows->size(); ++i {
            var h = (*rows)[i].cols[0];
            if self._ps.is_wild(h) { continue; }
            if h->type_ != &null { return self._ps.domain_of(h->type_); }
        }
        return Domain{};
    }

    /// Rows surviving \p c at the head occurrence, head replaced by the
    /// constructor's fields. A binder head is recorded before it is dropped.
    priv fn _specialize(self, rows: *vec::<CRow>, occs: *vec::<u32>, c: Ctor) -> vec::<CRow> {
        var out = vec::<CRow>();
        for var i: usize = 0; i < rows->size(); ++i {
            var r = &((*rows)[i]);
            var h = r->cols[0];
            var nr = CRow{};
            nr.arm = r->arm; nr.guarded = r->guarded; nr.key = r->key; nr.binds = r->binds;
            if self._ps.is_wild(h) {
                self._bind_head(&nr, h, (*occs)[0]);
                for var k: u32 = 0; k < c.arity; ++k { nr.cols.push_back(&null); }
            } else {
                if !self._ps.covers(self._ps.ctor_of(h), c) { continue; }
                nr.cols = self._ps.sub_columns(h, c.arity);
            }
            for var k: usize = 1; k < r->cols.size(); ++k { nr.cols.push_back(r->cols[k]); }
            out.push_back(nr);
        }
        return out;
    }

    /// Rows whose head is a wildcard, head dropped.
    priv fn _defaults(self, rows: *vec::<CRow>, occs: *vec::<u32>) -> vec::<CRow> {
        var out = vec::<CRow>();
        for var i: usize = 0; i < rows->size(); ++i {
            var r = &((*rows)[i]);
            var h = r->cols[0];
            if !self._ps.is_wild(h) { continue; }
            var nr = CRow{};
            nr.arm = r->arm; nr.guarded = r->guarded; nr.key = r->key; nr.binds = r->binds;
            self._bind_head(&nr, h, (*occs)[0]);
            for var k: usize = 1; k < r->cols.size(); ++k { nr.cols.push_back(r->cols[k]); }
            out.push_back(nr);
        }
        return out;
    }

    priv fn _bind_head(self, r: *CRow, h: *Pattern, occ: u32) {
        if (h == &null) || (h->kind != PatternKind::BindingPattern) { return; }
        var b = DBind{};
        b.pat = cast::<BindingPattern>(h); b.occ = occ;
        r->binds.push_back(b);
    }

    /// `occs` with the head replaced by \p sub.
    priv fn _with_sub(self, occs: *vec::<u32>, sub: *vec::<u32>) -> vec::<u32> {
        var out = *sub;
        for var k: usize = 1; k < occs->size(); ++k { out.push_back((*occs)[k]); }
        return out;
    }

    priv fn _rest(self, occs: *vec::<u32>) -> vec::<u32> {
        var out = vec::<u32>();
        for var k: usize = 1; k < occs->size(); ++k { out.push_back((*occs)[k]); }
        return out;
    }

    /// A one-constructor domain: no test, the column becomes its fields.
    priv fn _through(self, rows: *vec::<CRow>, occs: *vec::<u32>, c: Ctor, d: Domain) -> u32 {
        var sub = self._sub_occs((*occs)[0], c, d);
        var srows = self._specialize(rows, occs, c);
        var socc = self._with_sub(occs, &sub);
        return self._build(&srows, &socc);
    }

    /// Children first, then the edges in one run, then the node.
    priv fn _switch_node(self, occ: u32, kids: *vec::<DEdge>, other: i32, strings: bool) -> u32 {
        var n = DNode{};
        n.kind    = DKind::Switch;
        n.occ     = occ;
        n.edge0   = u32(self._edges.size());
        n.nedge   = u32(kids->size());
        n.other   = other;
        n.strings = strings;
        for var i: usize = 0; i < kids->size(); ++i { self._edges.push_back((*kids)[i]); }
        return self._push(n);
    }

    priv fn _switch_enum(self, rows: *vec::<CRow>, occs: *vec::<u32>, d: Domain) -> u32 {
        var n = usize(d.nctors);   // a pack-expanded variant counts once per element.
        var order = vec::<u32>();
        var heads = vec::<*Pattern>();
        for var i: usize = 0; i < rows->size(); ++i {
            var h = (*rows)[i].cols[0];
            if self._ps.is_wild(h) { continue; }
            var hc = self._ps.ctor_of(h);
            if hc.kind != CtorKind::Variant { continue; }
            var dup = false;
            for var k: usize = 0; k < order.size(); ++k { if order[k] == hc.index { dup = true; break; } }
            if !dup { order.push_back(hc.index); heads.push_back(h); }
        }

        var kids = vec::<DEdge>();
        for var k: usize = 0; k < order.size(); ++k {
            var c = Ctor{};
            c.kind  = CtorKind::Variant;
            c.index = order[k];
            c.arity = u32(adt_variant_at(d.en, usize(order[k]))->payload.size());
            var sub   = self._sub_occs((*occs)[0], c, d);
            var srows = self._specialize(rows, occs, c);
            var socc  = self._with_sub(occs, &sub);
            var e = DEdge{};
            e.kind = CtorKind::Variant; e.index = order[k]; e.pat = heads[k];
            e.child = self._build(&srows, &socc);
            kids.push_back(e);
        }

        // Complete over the declared variants: the default is where an
        // undeclared discriminant goes, which is the wildcard rows, or
        // UnmatchedPolicy when there are none.
        var drows = self._defaults(rows, occs);
        var rest  = self._rest(occs);
        var other: i32 = -1;
        if (order.size() < n) || (drows.size() > 0) { other = i32(self._build(&drows, &rest)); }
        return self._switch_node((*occs)[0], &kids, other, false);
    }

    priv fn _switch_bool(self, rows: *vec::<CRow>, occs: *vec::<u32>, d: Domain) -> u32 {
        var have = vec::<bool>();
        have.push_back(false); have.push_back(false);
        var heads = vec::<*Pattern>();
        heads.push_back(&null); heads.push_back(&null);
        for var i: usize = 0; i < rows->size(); ++i {
            var h = (*rows)[i].cols[0];
            if self._ps.is_wild(h) { continue; }
            var hc = self._ps.ctor_of(h);
            if hc.kind != CtorKind::Bool { continue; }
            if !have[usize(hc.lo)] { have[usize(hc.lo)] = true; heads[usize(hc.lo)] = h; }
        }
        var kids = vec::<DEdge>();
        for var b: u64 = 0; b < u64(2); ++b {
            var v = u64(1) - b;            // `true` first: the dump reads in source order more often.
            if !have[usize(v)] { continue; }
            var c = Ctor{};
            c.kind = CtorKind::Bool; c.lo = v; c.hi = v;
            var srows = self._specialize(rows, occs, c);
            var socc  = self._rest(occs);
            var e = DEdge{};
            e.kind = CtorKind::Bool; e.lo = v; e.hi = v; e.pat = heads[usize(v)];
            e.child = self._build(&srows, &socc);
            kids.push_back(e);
        }
        var other: i32 = -1;
        if !(have[0] && have[1]) {
            var drows = self._defaults(rows, occs);
            var rest  = self._rest(occs);
            other = i32(self._build(&drows, &rest));
        }
        return self._switch_node((*occs)[0], &kids, other, false);
    }

    priv fn _switch_int(self, rows: *vec::<CRow>, occs: *vec::<u32>, d: Domain) -> u32 {
        var segs = self._int_segments(rows, d.max_key);

        // Which Int heads survive each segment; merge neighbours that agree.
        var kids = vec::<DEdge>();
        var any_hole = false;
        var prev_set = vec::<u32>();
        var have_prev = false;
        var i: usize = 0;
        while i < segs.size() {
            var set = self._covering_rows(rows, segs[i]);
            if set.size() == 0 { any_hole = true; have_prev = false; i += 1; continue; }
            if have_prev && self._same_rows(rows, &set, &prev_set) {
                kids[kids.size() - 1].hi = segs[i].hi;
                i += 1;
                continue;
            }
            var e = DEdge{};
            e.kind = CtorKind::Int; e.lo = segs[i].lo; e.hi = segs[i].hi;
            e.pat  = (*rows)[usize(set[0])].cols[0];
            kids.push_back(e);
            prev_set = set;
            have_prev = true;
            i += 1;
        }

        for var k: usize = 0; k < kids.size(); ++k {
            var c = Ctor{};
            c.kind = CtorKind::Int; c.lo = kids[k].lo; c.hi = kids[k].lo;   // a key inside the edge: containment is all-or-nothing per segment.
            var srows = self._specialize(rows, occs, c);
            var socc  = self._rest(occs);
            kids[k].child = self._build(&srows, &socc);
        }

        var other: i32 = -1;
        if any_hole {
            var drows = self._defaults(rows, occs);
            var rest  = self._rest(occs);
            other = i32(self._build(&drows, &rest));
        }
        return self._switch_node((*occs)[0], &kids, other, false);
    }

    /// PatternSpace::int_segments over CRow, across the whole key space.
    priv fn _int_segments(self, rows: *vec::<CRow>, max_key: u64) -> vec::<Ctor> {
        var cuts = vec::<u64>();
        for var i: usize = 0; i < rows->size(); ++i {
            var h = (*rows)[i].cols[0];
            if self._ps.is_wild(h) { continue; }
            var c = self._ps.ctor_of(h);
            if c.kind != CtorKind::Int { continue; }
            if c.lo > u64(0)  { self._add_cut(&cuts, c.lo); }
            if c.hi < max_key { self._add_cut(&cuts, c.hi + u64(1)); }
        }
        for var i: usize = 1; i < cuts.size(); ++i {
            var x = cuts[i];
            var j = i;
            while (j > 0) && (cuts[j - 1] > x) { cuts[j] = cuts[j - 1]; j = j - 1; }
            cuts[j] = x;
        }
        var out = vec::<Ctor>();
        var start: u64 = 0;
        for var i: usize = 0; i <= cuts.size(); ++i {
            var end = (cuts[i] - u64(1)) if (i < cuts.size()) else (max_key);
            var c = Ctor{};
            c.kind = CtorKind::Int; c.lo = start; c.hi = end;
            out.push_back(c);
            if i < cuts.size() { start = cuts[i]; }
        }
        return out;
    }

    priv fn _add_cut(self, cuts: *vec::<u64>, k: u64) {
        for var i: usize = 0; i < cuts->size(); ++i { if (*cuts)[i] == k { return; } }
        cuts->push_back(k);
    }

    /// Rows whose Int head contains segment \p s, by index.
    priv fn _covering_rows(self, rows: *vec::<CRow>, s: Ctor) -> vec::<u32> {
        var out = vec::<u32>();
        for var i: usize = 0; i < rows->size(); ++i {
            var h = (*rows)[i].cols[0];
            if self._ps.is_wild(h) { continue; }
            var hc = self._ps.ctor_of(h);
            if (hc.kind == CtorKind::Int) && (hc.lo <= s.lo) && (s.hi <= hc.hi) { out.push_back(u32(i)); }
        }
        return out;
    }

    /// Two segments lead to the same subtree when their surviving Int rows
    /// agree position by position on everything below the head: arm, guard,
    /// remaining columns, binders. `case 1, 2, 3` is three rows of one arm;
    /// this merges their segments into one `1...3` edge.
    priv fn _same_rows(self, rows: *vec::<CRow>, a: *vec::<u32>, b: *vec::<u32>) -> bool {
        if a->size() != b->size() { return false; }
        for var i: usize = 0; i < a->size(); ++i {
            var x = &((*rows)[usize((*a)[i])]);
            var y = &((*rows)[usize((*b)[i])]);
            if (x->arm != y->arm) || (x->guarded != y->guarded) { return false; }
            if x->cols.size() != y->cols.size() { return false; }
            for var k: usize = 1; k < x->cols.size(); ++k { if x->cols[k] != y->cols[k] { return false; } }
            if x->binds.size() != y->binds.size() { return false; }
            for var k: usize = 0; k < x->binds.size(); ++k {
                if (x->binds[k].pat->decl != y->binds[k].pat->decl) || (x->binds[k].occ != y->binds[k].occ) { return false; }
            }
        }
        return true;
    }

    // --- strings ------------------------------------------------------------------------

    /// A string column every head of which has known bytes. A head without
    /// them has no rendering (string `==` is a user operator, lowered before
    /// MatchLowering runs): SC116E.
    priv fn _is_string_column(self, rows: *vec::<CRow>, occ: u32) -> bool {
        var t = self._occs[usize(occ)].type_;
        if (t == &null) || (!self._tu.is_string(t)) { return false; }
        for var i: usize = 0; i < rows->size(); ++i {
            var h = (*rows)[i].cols[0];
            if self._ps.is_wild(h) { continue; }
            var bytes = vec::<u8>();
            if !pattern_string_bytes(self.sc, h, &bytes) {
                self._unsupported(h, "matching a string against a pattern that is not a string literal or a constant initialized with one");
                return false;
            }
        }
        return true;
    }

    priv fn _switch_string(self, rows: *vec::<CRow>, occs: *vec::<u32>) -> u32 {
        var keys = vec::<vec::<u8>>();
        var heads = vec::<*Pattern>();
        for var i: usize = 0; i < rows->size(); ++i {
            var h = (*rows)[i].cols[0];
            if self._ps.is_wild(h) { continue; }
            var b = vec::<u8>();
            pattern_string_bytes(self.sc, h, &b);
            if self._find_key(&keys, &b) >= 0 { continue; }
            keys.push_back(b);
            heads.push_back(h);
        }

        var kids = vec::<DEdge>();
        for var k: usize = 0; k < keys.size(); ++k {
            var srows = vec::<CRow>();
            for var i: usize = 0; i < rows->size(); ++i {
                var r = &((*rows)[i]);
                var h = r->cols[0];
                if !self._ps.is_wild(h) {
                    var b = vec::<u8>();
                    pattern_string_bytes(self.sc, h, &b);
                    if !self._same_bytes(&b, &(keys[k])) { continue; }
                }
                var nr = CRow{};
                nr.arm = r->arm; nr.guarded = r->guarded; nr.key = r->key; nr.binds = r->binds;
                self._bind_head(&nr, h, (*occs)[0]);
                for var c: usize = 1; c < r->cols.size(); ++c { nr.cols.push_back(r->cols[c]); }
                srows.push_back(nr);
            }
            var socc = self._rest(occs);
            var e = DEdge{};
            e.kind = CtorKind::Opaque; e.pat = heads[k];
            e.child = self._build(&srows, &socc);
            kids.push_back(e);
        }
        var drows = self._defaults(rows, occs);
        var rest  = self._rest(occs);
        var other = i32(self._build(&drows, &rest));
        return self._switch_node((*occs)[0], &kids, other, true);
    }

    priv fn _find_key(self, keys: *vec::<vec::<u8>>, b: *vec::<u8>) -> i32 {
        for var i: usize = 0; i < keys->size(); ++i { if self._same_bytes(&((*keys)[i]), b) { return i32(i); } }
        return -1;
    }

    priv fn _same_bytes(self, a: *vec::<u8>, b: *vec::<u8>) -> bool {
        if a->size() != b->size() { return false; }
        for var i: usize = 0; i < a->size(); ++i { if (*a)[i] != (*b)[i] { return false; } }
        return true;
    }

    // --- opaque -------------------------------------------------------------------------

    /// Binary test on the first non-wildcard head. See the file header.
    priv fn _test(self, rows: *vec::<CRow>, occs: *vec::<u32>) -> u32 {
        var h: *Pattern = &null;
        for var i: usize = 0; (i < rows->size()) && (h == &null); ++i {
            if !self._ps.is_wild((*rows)[i].cols[0]) { h = (*rows)[i].cols[0]; }
        }
        ICE_IF(h == &null, "PatternCompilation: a test column with no head; _pick_column chose a wildcard column");
        self._check_opaque(h);
        var hc = self._ps.ctor_of(h);

        var yes = vec::<CRow>();
        var no  = vec::<CRow>();
        for var i: usize = 0; i < rows->size(); ++i {
            var r = (*rows)[i];
            var p = r.cols[0];
            var same = (!self._ps.is_wild(p)) && self._same_ctor(self._ps.ctor_of(p), hc);
            if same {
                r.cols[0] = &null;
                yes.push_back(r);
            } else {
                yes.push_back(r);
                no.push_back(r);
            }
        }
        var t = self._build(&yes, occs);
        var f = self._build(&no, occs);

        var e = DEdge{};
        e.kind = hc.kind; e.index = hc.index; e.lo = hc.lo; e.hi = hc.hi; e.pat = h; e.child = t;
        var n = DNode{};
        n.kind  = DKind::Test;
        n.occ   = (*occs)[0];
        n.edge0 = u32(self._edges.size());
        n.nedge = 1;
        n.other = i32(f);
        self._edges.push_back(e);
        return self._push(n);
    }

    priv fn _same_ctor(self, a: Ctor, b: Ctor) -> bool {
        if a.kind != b.kind { return false; }
        switch a.kind {
            case CtorKind::Opaque  { return a.key == b.key; }
            case CtorKind::Variant { return a.index == b.index; }
            case CtorKind::Bool    { return a.lo == b.lo; }
            case CtorKind::Int     { return (a.lo == b.lo) && (a.hi == b.hi); }
            default { return true; }
        }
        return false;
    }

    /// An opaque test MatchLowering cannot render: `==` on a record.
    priv fn _check_opaque(self, h: *Pattern) {
        if (h == &null) || (h->type_ == &null) { return; }
        var u = canon_unqual(self._tu.as_value(h->type_));
        if (u == &null) || (!isa::<RecordType>(u)) { return; }
        var rd = self._tu.pattern_of(cast::<RecordType>(u)->decl);
        if isa::<EnumDecl>(rd) { return; }
        self._unsupported(h, f"matching a value of type '{self._tu.str(h->type_)}' against this pattern");
    }

    priv fn _unsupported(self, p: *Pattern, what: string) {
        if self._bad { return; }
        self._bad = true;
        self.sc->diag->report(DiagID::SC116E, p->range.start, f"{what} is not yet supported")
            .first(p->range).emit();
    }

    // === backtracking automaton ===========================================

    /// Rows in order; row i's tests chain into its accept node, and every
    /// failure goes to row i+1's chain.
    priv fn _automaton(self, rows0: *vec::<CRow>, root: u32) -> u32 {
        // Full expansion: an alternation anywhere is one row per choice.
        for var i: usize = 0; i < rows0->size(); ++i {
            var flat = vec::<FlatRow>();
            var start = FlatRow{};
            start.row = (*rows0)[i];
            self._flatten((*rows0)[i].cols[0], root, &start, &flat);
            for var k: usize = 0; k < flat.size(); ++k { self._flat.push_back(flat[k]); }
        }

        var cont = self._fail();
        var k = self._flat.size();
        while k > 0 {
            k = k - 1;
            var fr = &(self._flat[k]);
            var occs = vec::<u32>();
            var acc = self._accept(&(fr->row), &occs, i32(cont));
            var node = acc;
            var t = fr->tests.size();
            while t > 0 {
                t = t - 1;
                var ft = fr->tests[t];
                ft.edge.child = node;
                var n = DNode{};
                n.kind  = DKind::Test;
                n.occ   = ft.occ;
                n.edge0 = u32(self._edges.size());
                n.nedge = 1;
                n.other = i32(cont);
                self._edges.push_back(ft.edge);
                node = self._push(n);
            }
            cont = node;
        }
        self._flat = vec::<FlatRow>();
        return cont;
    }

    /// Walk \p p at \p occ, appending its tests in pre-order (a variant's
    /// tag before its payload) and its binders; an alternation forks the
    /// row. Every fork lands in \p out.
    priv fn _flatten(self, p: *Pattern, occ: u32, acc: *FlatRow, out: *vec::<FlatRow>) {
        var cur = vec::<FlatRow>();
        cur.push_back(*acc);
        self._flatten_into(p, occ, &cur);
        for var i: usize = 0; i < cur.size(); ++i {
            cur[i].row.cols = vec::<*Pattern>();   // all consumed: _accept reads binds only.
            out->push_back(cur[i]);
        }
    }

    priv fn _flatten_into(self, p: *Pattern, occ: u32, rows: *vec::<FlatRow>) {
        if p == &null { return; }
        self._note_type(occ, p);
        switch p->kind {
            case PatternKind::WildcardPattern { return; }
            case PatternKind::BindingPattern {
                for var i: usize = 0; i < rows->size(); ++i {
                    var b = DBind{};
                    b.pat = cast::<BindingPattern>(p); b.occ = occ;
                    (*rows)[i].row.binds.push_back(b);
                }
                return;
            }
            case PatternKind::AlternationPattern {
                var a = cast::<AlternationPattern>(p);
                var out = vec::<FlatRow>();
                for var k: usize = 0; k < a->alternatives.size(); ++k {
                    var fork = *rows;
                    for var i: usize = 0; i < fork.size(); ++i { fork[i].row.key = fork[i].row.key + f"/{occ}:{k}"; }
                    self._flatten_into(a->alternatives[k], occ, &fork);
                    for var i: usize = 0; i < fork.size(); ++i { out.push_back(fork[i]); }
                }
                (*rows) = out;
                return;
            }
            default { 0; }
        }

        var d = self._ps.domain_of(p->type_);
        var c = self._ps.ctor_of(p);
        if c.kind == CtorKind::Record {
            var sub  = self._sub_occs(occ, c, d);
            var cols = self._ps.sub_columns(p, c.arity);
            for var k: usize = 0; k < cols.size(); ++k { self._flatten_into(cols[k], sub[k], rows); }
            return;
        }

        if c.kind == CtorKind::Opaque {
            var t = self._occs[usize(occ)].type_;
            if (t != &null) && self._tu.is_string(t) {
                var b = vec::<u8>();
                if !pattern_string_bytes(self.sc, p, &b) {
                    self._unsupported(p, "matching a string against a pattern that is not a string literal or a constant initialized with one");
                }
            } else {
                self._check_opaque(p);
            }
        }

        var ft = FlatTest{};
        ft.occ = occ;
        ft.edge.kind = c.kind; ft.edge.index = c.index; ft.edge.lo = c.lo; ft.edge.hi = c.hi; ft.edge.pat = p;
        for var i: usize = 0; i < rows->size(); ++i { (*rows)[i].tests.push_back(ft); }

        if c.kind == CtorKind::Variant {
            var sub  = self._sub_occs(occ, c, d);
            var cols = self._ps.sub_columns(p, c.arity);
            for var k: usize = 0; k < cols.size(); ++k { self._flatten_into(cols[k], sub[k], rows); }
        }
    }

    // === freeze ===========================================================

    priv fn _freeze(self, root: u32, automaton: bool) -> *DecisionTree {
        var ctx = self.sc->ctx;
        var t = ctx->alloc::<DecisionTree>();
        var nb = ListBuilder::<DNode>(ctx);
        for var i: usize = 0; i < self._nodes.size(); ++i { nb.push(self._nodes[i]); }
        nb.freeze_into(&(t->nodes));
        var eb = ListBuilder::<DEdge>(ctx);
        for var i: usize = 0; i < self._edges.size(); ++i { eb.push(self._edges[i]); }
        eb.freeze_into(&(t->edges));
        var ob = ListBuilder::<DOcc>(ctx);
        for var i: usize = 0; i < self._occs.size(); ++i { ob.push(self._occs[i]); }
        ob.freeze_into(&(t->occs));
        var bb = ListBuilder::<DBind>(ctx);
        for var i: usize = 0; i < self._binds.size(); ++i { bb.push(self._binds[i]); }
        bb.freeze_into(&(t->binds));
        t->root      = root;
        t->row_count = u32(self._keys.size());
        t->automaton = automaton;
        return t;
    }
}

// === --print-sema ================================================================

fn decision_occ(sc: *SemaContext, t: *DecisionTree, o: u32) -> string {
    var tu = TypeUtil(sc);
    var d = t->occs[usize(o)];
    switch d.kind {
        case OccKind::Root  { return "$"; }
        case OccKind::Field {
            // A tuple's element prints as it is indexed, `$.0`, not `$._0`.
            var owner = reinterpret_cast::<*DeclContext>(static_cast::<*Decl>(d.field)->semantic_dc);
            if (owner != &null) && tu.is_tuple_decl(owner->dc_owner) {
                return decision_occ(sc, t, u32(d.parent)) + f".{d.field->index}";
            }
            return decision_occ(sc, t, u32(d.parent)) + "." + tu.decl_name(static_cast::<*Decl>(d.field));
        }
        case OccKind::Payload {
            var ps = PatternSpace(sc);
            var pd = ps.domain_of(t->occs[usize(d.parent)].type_);
            var v = "?";
            var pv = adt_variant_at(pd.en, usize(d.index));
            if pv != &null { v = tu.decl_name(static_cast::<*Decl>(pv)); }
            var pk = adt_expansion_at(pd.en, usize(d.index));
            if pk >= 0 { v += f"[{pk}]"; }
            return decision_occ(sc, t, u32(d.parent)) + "." + v + "." + tu.decl_name(static_cast::<*Decl>(d.field));
        }
    }
    return "?";
}

fn decision_ctor(sc: *SemaContext, t: *DecisionTree, o: u32, e: DEdge) -> string {
    var ps = PatternSpace(sc);
    var d = ps.domain_of(t->occs[usize(o)].type_);
    switch e.kind {
        case CtorKind::Bool { return ("true") if (e.lo == u64(1)) else ("false"); }
        case CtorKind::Int  { return ps.range_str(d, e.lo, e.hi); }
        case CtorKind::Variant {
            var c = Ctor{};
            c.kind = CtorKind::Variant; c.index = e.index;
            var none = vec::<string>();
            return ps.render(d, c, &none);
        }
        default {
            if e.pat != &null { return sc->ctx->get_spelling(e.pat->range); }
            return "_";
        }
    }
    return "_";
}

fn decision_binds(sc: *SemaContext, t: *DecisionTree, n: DNode) -> string {
    if n.nbind == 0 { return ""; }
    var s = " [";
    for var k: u32 = 0; k < n.nbind; ++k {
        var b = t->binds[usize(n.bind0 + k)];
        if k > 0 { s = s + " "; }
        s = s + sc->ctx->get_spelling(b.pat->name) + "=" + decision_occ(sc, t, b.occ);
    }
    return s + "]";
}

fn decision_row(sc: *SemaContext, t: *DecisionTree, i: u32) -> string {
    var n = t->nodes[usize(i)];
    var head = f"n{i}: ";
    switch n.kind {
        case DKind::Fail { return head + "fail"; }
        case DKind::Leaf { return head + f"leaf arm {n.arm}" + decision_binds(sc, t, n); }
        case DKind::Guard {
            return head + f"guard arm {n.arm} else n{n.other}" + decision_binds(sc, t, n);
        }
        case DKind::Test {
            var e = t->edges[usize(n.edge0)];
            return head + f"test {decision_occ(sc, t, n.occ)} is " + decision_ctor(sc, t, n.occ, e)
                 + f" ? n{e.child} : n{n.other}";
        }
        case DKind::Switch {
            var s = head + f"switch {decision_occ(sc, t, n.occ)} " + "{ ";
            for var k: u32 = 0; k < n.nedge; ++k {
                var e = t->edges[usize(n.edge0 + k)];
                if k > 0 { s = s + ", "; }
                s = s + decision_ctor(sc, t, n.occ, e) + f" => n{e.child}";
            }
            if n.other >= 0 { s = s + f", _ => n{n.other}"; }
            else if PatternSpace(sc).domain_of(t->occs[usize(n.occ)].type_).kind == DomainKind::ClosedEnum {
                s = s + ", _ => unmatched";   // an undeclared discriminant: UnmatchedPolicy.
            }
            return s + " }";
        }
    }
    return head + "?";
}

/// The tree as text rows, one per node, for SemaDump:
///
///     decision [nodes=5 rows=3]
///       n4: switch $ { .North => n0, .East => n1, _ => n3 }
///       n0: leaf arm 0
///       n3: guard arm 2 else n2 [x=$.0]
///       n2: fail
///
/// `_ => unmatched` closes a complete closed-enum switch: an undeclared
/// discriminant takes UnmatchedPolicy.
///
/// Root first, then every other node in index order.
fn decision_rows(sc: *SemaContext, t: *DecisionTree) -> vec::<string> {
    var out = vec::<string>();
    if t == &null { return out; }
    var mode = (" automaton") if (t->automaton) else ("");
    out.push_back(f"decision{mode} [nodes={t->nodes.size()} rows={t->row_count}]");
    out.push_back("  " + decision_row(sc, t, t->root));
    for var i: usize = 0; i < t->nodes.size(); ++i {
        if u32(i) == t->root { continue; }
        out.push_back("  " + decision_row(sc, t, u32(i)));
    }
    return out;
}
