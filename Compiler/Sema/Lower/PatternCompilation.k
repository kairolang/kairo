/// --- The Kairo Project -------------- Sema/Lower/PatternCompilation.k --- ///
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
///       mixed            A Record, ClosedEnum or Bool column some head of
///                        which is no constructor of the domain (a literal
///                        or a constant: `case ONE` on a record, `case FAV`
///                        on an enum, an `op ==` test). First row's head
///                        opaque: Test on it, as below. Otherwise the rows
///                        are cut before the first opaque head; the rows
///                        above compile with the rows below as their
///                        failure (a backtracking split), since an opaque
///                        head has no fields to specialize into.
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
///     for which X recorded no `==` (SemaContext::pattern_eqs; a record's
///     `==` is a user operator, which MatchLowering renders from there).
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
    adt_expansion_at,
    adt_variant_at,
}
import AST::Kind::PatternKind::PatternKind
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    EnumDecl,
    FieldDecl,
    VariableDecl,
}
import AST::Node::Expressions::MatchExpr
import AST::Node::Patterns::{
    AlternationPattern,
    BindingPattern,
    ConstructorPattern,
    LiteralPattern,
    TupleDestructurePattern,
    UnresolvedConstructorPattern,
}
import AST::Node::PrimaryExpressions::StringLiteralExpr
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    MatchCase,
    MatchStmt,
    match_first_row,
}
import AST::Visitor::ASTWriter::ListBuilder
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Lexer::Immediate::Immediate
import Sema::Check::PatternSpace::{
    Ctor,
    CtorKind,
    Domain,
    DomainKind,
    PatternSpace,
    sort_unique_keys,
}
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Sema::Type::VariadicEnum::VariadicEnum

/// # the tree

/// How an occurrence is reached from its parent.
pub enum OccKind derives u8 {
    Root = 0, ///< the scrutinee.
    Field,    ///< `field` of a record; a tuple's element is its field `_i`.
    Payload,  ///< `field` of variant `index`'s payload.
}

pub struct DOcc {
    var parent: i32               = -1
    var kind:   OccKind           = OccKind::Root
    var index:  u32               = 0
    var field:  unsafe *FieldDecl = &null
    var type_:  unsafe *Type      = &null ///< the values at this path; from a pattern when one is typed.
}

pub enum DKind derives u8 {
    Fail = 0, ///< no row matches: UnmatchedPolicy.
    Leaf,     ///< arm `arm` is taken, binders `binds`.
    Guard,    ///< arm `arm` if its guard holds, else `other`.
    Switch,   ///< multiway on `occ`: edges [edge0, edge0 + nedge), else `other`.
    Test,     ///< binary on `occ`: edge `edge0` holds -> its child, else `other`.
}

/// One outcome of a test. `kind` is the constructor kind; `pat` is a head
/// that tests it, for the kinds whose value lives in a pattern (Opaque,
/// string keys) and for the dump.
pub struct DEdge {
    var kind:  CtorKind        = CtorKind::Wild
    var index: u32             = 0              ///< Variant: position in the enum.
    var lo:    u64             = 0              ///< Bool: 0/1. Int: keys, inclusive.
    var hi:    u64             = 0
    var pat:   unsafe *Pattern = &null
    var child: u32             = 0
}

pub struct DBind {
    var pat: unsafe *BindingPattern = &null
    var occ: u32                    = 0
}

pub struct DNode {
    var kind:    DKind = DKind::Fail
    var occ:     u32   = 0
    var edge0:   u32   = 0
    var nedge:   u32   = 0
    var other:   i32   = -1          ///< Switch: default (-1: complete). Test / Guard: failure.
    var strings: bool  = false       ///< Switch: keyed by string bytes.
    var arm:     u32   = 0
    var row:     u32   = 0           ///< Leaf / Guard: the expanded row's id.
    var bind0:   u32   = 0
    var nbind:   u32   = 0
}

/// The compiled match. Arena memory, never freed on its own: it lives as
/// long as the AST it points into.
pub class DecisionTree {
    pub var nodes:     FrozenList<DNode>
    pub var edges:     FrozenList<DEdge>
    pub var occs:      FrozenList<DOcc>
    pub var binds:     FrozenList<DBind>
    pub var root:      u32               = 0
    pub var row_count: u32               = 0 ///< distinct row ids.
    pub var automaton: bool              = false ///< the size bound fell back to the backtracking automaton.
}

/// A string head's bytes: a literal's decoded text, or a constant's literal
/// initializer's. False when the head is neither.
pub fn pattern_string_bytes(sc:  unsafe *SemaContext,
                            p:   unsafe *Pattern,
                            out: unsafe *cxx::std::vector<u8>) -> bool {
    if p == &null {
        return false
    }

    var tu              = TypeUtil(sc)
    var e: unsafe *Expr = &null
    if p->kind == PatternKind::LiteralPattern {
        e = cast<LiteralPattern>(p)->value
    } else if p->kind == PatternKind::ConstructorPattern
        || p->kind == PatternKind::UnresolvedConstructorPattern {
        var unsafe *vd = dyn_cast<VariableDecl>(p->resolved_decl)
        if vd == &null || !vd->is_const() && !vd->is_eval() {
            return false
        }

        e = vd->init
    }

    if e == &null {
        return false
    }

    e = tu.strip_parens(e)
    if e == &null || !isa<StringLiteralExpr>(e) {
        return false
    }

    var unsafe *lit = cast<StringLiteralExpr>(e)
    if lit->is_format() || lit->imm == &null {
        return false
    }

    // StringLowering::_collect, without spending the chain: the literal is
    // still in the tree, and StringLowering lowers it later.
    var        synth = LowerSynth(sc)
    var unsafe *tbl  = sc->imm_table()
    if lit->ctx != &null { // the writing file's (StringLowering::_collect).
        tbl = lit->ctx->get_payload_table(lit->token)
    }

    var unsafe *seg = lit->imm
    var        raw  = lit->is_raw()
    while seg != &null {
        if seg->has_owned_text() {
            for var i: usize = 0; i < (seg->owned_len as usize); ++i {
                out->push_back(seg->owned_ptr[i])
            }
        } else {
            if !synth.decode_text(seg->body, raw, out) {
                kairo::std::ice_fail(
                    "PatternCompilation: escape the lexer accepted but the decoder does not know; keep Lexer::is_valid_escape and LowerSynth::decode_text in step",
                )
            }
        }

        if seg->next == u32::MAX {
            break
        }

        seg = tbl->get<Immediate::StringData>(seg->next)
        raw = seg->prefix_kind.has(Immediate::TextPrefixKind::Raw)
    }

    return true
}

/// # build state

/// A row while it is being compiled: PatRow plus the binders it has already
/// passed and an id that names it across paths.
pub struct CRow {
    var cols:    cxx::std::vector<unsafe *Pattern>
    var arm:     u32                               = 0
    var guarded: bool                              = false
    var key:     string ///< `arm.alt`, extended at each alternation it expands.
    var binds:   cxx::std::vector<DBind>
}

/// One test of a flattened row.
pub struct FlatTest {
    var occ:  u32   = 0
    var edge: DEdge
}

/// A row of the backtracking automaton: its tests in order, then accept.
pub struct FlatRow {
    var row:   CRow
    var tests: cxx::std::vector<FlatTest>
}

pub class PatternCompilation derives RecursiveASTVisitor<PatternCompilation> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    priv var _ps: PatternSpace

    // One match at a time.
    priv var _nodes:   cxx::std::vector<DNode>
    priv var _edges:   cxx::std::vector<DEdge>
    priv var _occs:    cxx::std::vector<DOcc>
    priv var _binds:   cxx::std::vector<DBind>
    priv var _keys:    cxx::std::vector<string>
    priv var _key_ids: llvm::StringMap<u32> ///< _keys inverted: one probe per accept, not a scan.
    priv var _budget:  usize                     = 0
    priv var _over:    bool                      = false
    priv var _bad:     bool                      = false ///< a test with no rendering was reported.
    priv var _flat:    cxx::std::vector<FlatRow> ///< the automaton's rows.
    /// Where a matrix with no rows goes: -1 is a Fail node; inside the upper
    /// half of a split, the root of the lower half. Saved and restored.
    priv var _fallback: i32 = -1

    fn PatternCompilation(self, sc: unsafe *SemaContext) {
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

    /// ## entry points

    fn visit_match_stmt(self, n: unsafe *MatchStmt) -> bool {
        if n == &null || !n->is_exhaustive {
            return true
        }

        n->decision = unsafe (self._compile(n->scrutinee, &n->cases, n->null_arm) as unsafe *void)
        return true
    }

    fn visit_match_expr(self, n: unsafe *MatchExpr) -> bool {
        if n == &null || !n->is_exhaustive {
            return true
        }

        n->decision = unsafe (self._compile(n->scrutinee, &n->cases, n->null_arm) as unsafe *void)
        return true
    }

    /// ## one match

    /// \p null_arm (Compiler/Spec/Nullables.md#match): arm 0 is `case null`, which this tree
    /// never reaches; CoalesceLowering answers it before the match, whose
    /// scrutinee it makes the unwrapped value. So the rows start at arm 1
    /// (arm numbers kept) and the root is `T`.
    priv fn _compile(self,
                     scrutinee: unsafe *Expr,
                     cases:     *FrozenList<MatchCase>,
                     null_arm:  bool) -> unsafe *DecisionTree {
        self._bad = false
        if scrutinee == &null || scrutinee->type_ == &null || scrutinee->is_poisoned() {
            return &null
        }

        if canon_unqual(scrutinee->type_) == &null {
            return &null
        }

        for var i: usize = 0; i < cases->size(); ++i {
            var unsafe *mc = cases->get(i)
            for var j: usize = 0; j < mc->patterns.size(); ++j {
                if self._broken(mc->patterns[j]) {
                    // On a dependent column PatternTyping resolves only a
                    // constant; any other constructor head stays unresolved
                    // with nothing reported, and a match with no tree is an
                    // EmitIR ICE. Say so here instead.
                    var unsafe *bp = mc->patterns[j]
                    var unsafe *su = canon_unqual(scrutinee->type_)
                    if !bp->is_error() && !bp->is_poisoned() && su->is_dependent() {
                        self._unsupported(
                            bp,
                            "this pattern on a value whose type depends on a generic parameter",
                        )
                    }

                    return &null
                }
            }
        }

        var        rows     = self._rows(cases, match_first_row(null_arm))
        var unsafe *root_ty = scrutinee->type_
        if null_arm {
            root_ty = self._tu.nullable_inner(self._tu.as_value(root_ty))
        }

        self._reset()
        self._budget = (16 as usize) * rows.size() + (64 as usize)
        var root_occ = self._root(root_ty)
        var occs     = cxx::std::vector<u32>()
        occs.push_back(root_occ)

        var root      = self._build(unsafe &rows, unsafe &occs)
        var automaton = false
        if self._over {
            self._reset()
            root_occ  = self._root(root_ty)
            root      = self._automaton(rows, root_occ)
            automaton = true
        }

        if self._bad {
            return &null
        }

        return self._freeze(root, automaton)
    }

    /// One row per case-level alternative; `default` is one wildcard row.
    priv fn _rows(self, cases: *FrozenList<MatchCase>, first: usize) -> cxx::std::vector<CRow> {
        var rows = cxx::std::vector<CRow>()
        for var i: usize = first; i < cases->size(); ++i {
            var unsafe *mc = cases->get(i)
            if mc->is_default || mc->patterns.size() == 0 {
                var r = CRow{}
                r.arm     = (i as u32)
                r.guarded = mc->guard != &null
                r.key     = f"{i}.0"
                r.cols.push_back(&null)
                rows.push_back(r)
                continue
            }

            for var j: usize = 0; j < mc->patterns.size(); ++j {
                var r = CRow{}
                r.arm     = (i as u32)
                r.guarded = mc->guard != &null
                r.key     = f"{i}.{j}"
                r.cols.push_back(mc->patterns[j])
                rows.push_back(r)
            }
        }

        return rows
    }

    priv fn _reset(self) {
        self._nodes = cxx::std::vector<DNode>()
        self._edges = cxx::std::vector<DEdge>()
        self._occs  = cxx::std::vector<DOcc>()
        self._binds = cxx::std::vector<DBind>()
        self._keys  = cxx::std::vector<string>()
        self._key_ids.clear()
        self._flat     = cxx::std::vector<FlatRow>()
        self._over     = false
        self._fallback = -1
    }

    /// PatternChecking::_broken: a pattern tree already diagnosed.
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

    /// ## occurrences

    priv fn _root(self, t: unsafe *Type) -> u32 {
        var o = DOcc{}
        o.kind  = OccKind::Root
        o.type_ = t
        self._occs.push_back(o)
        return (self._occs.size() - 1) as u32
    }

    /// The occurrence `parent.<step>`, one id per path.
    priv fn _occ(self,
                 parent: u32,
                 kind:   OccKind,
                 index:  u32,
                 field:  unsafe *FieldDecl,
                 t:      unsafe *Type) -> u32 {
        for var i: usize = 0; i < self._occs.size(); ++i {
            var unsafe *o = unsafe &self._occs[i]
            if o->parent == (parent as i32)
                && o->kind == kind
                && o->index == index
                && o->field == field {
                return i as u32
            }
        }

        var o = DOcc{}
        o.parent = (parent as i32)
        o.kind   = kind
        o.index  = index
        o.field  = field
        o.type_  = t
        self._occs.push_back(o)
        return (self._occs.size() - 1) as u32
    }

    /// A typed head at \p occ refines its type: a field declared `T` in a
    /// generic record is `i32` in the instance the pattern was typed in.
    priv fn _note_type(self, occ: u32, p: unsafe *Pattern) {
        if p == &null || p->type_ == &null {
            return
        }

        var unsafe *cur = self._occs[occ as usize].type_
        if cur == &null || canon_unqual(cur) != &null && canon_unqual(cur)->is_dependent() {
            self._occs[occ as usize].type_ = p->type_
        }
    }

    /// The sub-occurrences constructor \p c opens at \p occ in domain \p d.
    priv fn _sub_occs(self, occ: u32, const c: Ctor, d: Domain) -> cxx::std::vector<u32> {
        var out = cxx::std::vector<u32>()
        match c.kind {
            case CtorKind::Record {
                var fs = self._ps.instance_fields(d.rec)
                // A tuple's field is declared `Ti`; the element is the
                // instance's argument i, so a wildcard column still has a
                // concrete domain to classify.
                var unsafe *ot    = self._occs[occ as usize].type_
                var        te     = self._tu.tuple_elems(canon_unqual(self._tu.as_value(ot)))
                var        is_tup = self._tu.is_tuple(canon_unqual(self._tu.as_value(ot)))
                for var i: usize = 0; i < fs.size() && i < (c.arity as usize); ++i {
                    var unsafe *ft = self._canon(fs[i]->type_)
                    if is_tup && i < te.size() {
                        ft = te[i]
                    }

                    out.push_back(self._occ(occ, OccKind::Field, 0, fs[i], ft))
                }
            } case CtorKind::Variant {
                var unsafe *v = adt_variant_at(d.en, c.index as usize)
                // Element k of a pack-expanded variant: its fields read at
                // that element's type, which is the occurrence's.
                var k = adt_expansion_at(d.en, c.index as usize)
                for var i: usize = 0; i < v->payload.size() && i < (c.arity as usize); ++i {
                    var unsafe *f  = v->payload[i]
                    var unsafe *ft = self._canon(f->type_)
                    if k >= 0 {
                        ft = VariadicEnum(self._ps.sc).field_at(d.ty, f, k as usize)
                    }

                    out.push_back(self._occ(occ, OccKind::Payload, c.index, f, ft))
                }
            } default {
                0
            }
        }

        return out
    }

    /// A field's WRITTEN type is a syntax node; an occurrence carries the
    /// canonical, which is what PatternSpace::domain_of classifies.
    priv fn _canon(self, t: unsafe *Type) -> unsafe *Type {
        if t == &null {
            return &null
        }

        return t->canonical
    }

    /// ## nodes

    priv fn _push(self, n: DNode) -> u32 {
        self._nodes.push_back(n)
        if self._nodes.size() > self._budget {
            self._over = true
        }

        return (self._nodes.size() - 1) as u32
    }

    priv fn _fail(self) -> u32 {
        var n = DNode{}
        n.kind = DKind::Fail
        return self._push(n)
    }

    priv fn _row_id(self, const key: string) -> u32 {
        var it = self._key_ids.find(kairo::sref(key))
        if it != self._key_ids.end() {
            return it->second
        }

        self._keys.push_back(key)
        var id = ((self._keys.size() - 1) as u32)
        self._key_ids.try_emplace(kairo::sref(key), id)
        return id
    }

    /// Leaf or Guard for \p r, every column of which is a wildcard.
    priv fn _accept(self, r: *CRow, const occs: cxx::std::vector<u32>, fail: i32) -> u32 {
        var n = DNode{}
        n.kind  = if (r->guarded) => (DKind::Guard) else => DKind::Leaf
        n.arm   = r->arm
        n.row   = self._row_id(r->key)
        n.other = fail
        n.bind0 = (self._binds.size() as u32)
        for var i: usize = 0; i < r->binds.size(); ++i {
            self._binds.push_back(r->binds[i])
        }

        for var c: usize = 0; c < r->cols.size(); ++c {
            var unsafe *p = r->cols[c]
            if p != &null && p->kind == PatternKind::BindingPattern {
                var b = DBind{}
                b.pat = cast<BindingPattern>(p)
                b.occ = (occs)[c]
                self._binds.push_back(b)
            }
        }

        n.nbind = (self._binds.size() as u32) - n.bind0
        return self._push(n)
    }

    /// ## Maranget

    priv fn _build(self,
                   rows: unsafe *cxx::std::vector<CRow>,
                   occs: unsafe *cxx::std::vector<u32>) -> u32 {
        if self._over || self._bad {
            return self._fail()
        }

        if rows->size() == 0 {
            if self._fallback >= 0 {
                return (self._fallback as u32)
            }

            return self._fail()
        }

        var *r0      = &(*rows)[0]
        var col: i32 = self._pick_column(rows)
        if col < 0 {
            var fail: i32 = -1
            if r0->guarded {
                var rest = cxx::std::vector<CRow>()
                for var i: usize = 1; i < rows->size(); ++i {
                    rest.push_back((*rows)[i])
                }

                fail = (self._build(unsafe &rest, occs) as i32)
            }

            return self._accept(&(*rows)[0], *occs, fail)
        }

        // Column `col` to the front.
        var m = cxx::std::vector<CRow>()
        for var i: usize = 0; i < rows->size(); ++i {
            var r = (*rows)[i]
            if col > 0 {
                var unsafe *t = r.cols[col as usize]
                r.cols[col as usize] = r.cols[0]
                r.cols[0]            = t
            }

            m.push_back(r)
        }

        var o = *occs
        if col > 0 {
            var t = o[col as usize]
            o[col as usize] = o[0]
            o[0]            = t
        }

        var head  = o[0]
        var rows2 = self._expand(&m, head)

        for var i: usize = 0; i < rows2.size(); ++i {
            if !self._ps.is_wild(rows2[i].cols[0]) {
                self._note_type(head, rows2[i].cols[0])
            }
        }

        var d = self._head_domain(rows2)
        // A literal or constant head in a column whose domain has
        // constructors (`case ONE` on a record, `case FAV` on an enum, a
        // `bool` constant) is no constructor of it: specializing would drop
        // its row. Test it, or split the rows above it off.
        if d.kind == DomainKind::Record
            || d.kind == DomainKind::ClosedEnum
            || d.kind == DomainKind::Bool {
            var cut = self._first_opaque(rows2)
            if cut == 0 {
                return self._test(rows2, unsafe &o)
            }

            if cut > 0 {
                return self._split(rows2, unsafe &o, cut as usize)
            }
        }

        match d.kind {
            case DomainKind::Record {
                var c = Ctor{}
                c.kind  = CtorKind::Record
                c.arity = d.arity
                return self._through(unsafe &rows2, unsafe &o, c, d)
            } case DomainKind::ClosedEnum {
                return self._switch_enum(unsafe &rows2, unsafe &o, d)
            } case DomainKind::Bool {
                return self._switch_bool(unsafe &rows2, unsafe &o, d)
            } case DomainKind::Int {
                // A constant this file cannot evaluate is an opaque head in
                // an integer column; segments cannot place it, so the column
                // is tested head by head instead.
                if self._all_heads(rows2, CtorKind::Int) {
                    return self._switch_int(unsafe &rows2, unsafe &o, d)
                }

                return self._test(rows2, unsafe &o)
            } default {
                0
            }
        }

        if self._is_string_column(rows2, head) {
            return self._switch_string(unsafe &rows2, unsafe &o)
        }

        return self._test(rows2, unsafe &o)
    }

    /// The first row whose head is opaque, or -1.
    priv fn _first_opaque(self, const rows: cxx::std::vector<CRow>) -> i32 {
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *h = (rows)[i].cols[0]
            if self._ps.is_wild(h) {
                continue
            }

            if self._ps.ctor_of(h).kind == CtorKind::Opaque {
                return (i as i32)
            }
        }

        return -1
    }

    /// Rows [0, cut) compiled with rows [cut, n) as where they fail: every
    /// empty matrix below the upper half lands on the lower half's root. The
    /// lower half is a matrix over the same occurrences, so it re-tests
    /// whatever the upper half already did; sound, and only on the
    /// failure path.
    priv fn _split(self,
                   const rows: cxx::std::vector<CRow>,
                   occs:       unsafe *cxx::std::vector<u32>,
                   cut:        usize) -> u32 {
        var top = cxx::std::vector<CRow>()
        var low = cxx::std::vector<CRow>()
        for var i: usize = 0; i < rows.size(); ++i {
            if i < cut {
                top.push_back((rows)[i])
            } else {
                low.push_back((rows)[i])
            }
        }

        var lower = self._build(unsafe &low, occs)
        var saved = self._fallback
        self._fallback = (lower as i32)
        var upper = self._build(unsafe &top, occs)
        self._fallback = saved
        return upper
    }

    priv fn _all_heads(self, const rows: cxx::std::vector<CRow>, k: CtorKind) -> bool {
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *h = (rows)[i].cols[0]
            if self._ps.is_wild(h) {
                continue
            }

            if self._ps.ctor_of(h).kind != k {
                return false
            }
        }

        return true
    }

    /// The column to branch on, or -1 when the first row is all wildcards.
    priv fn _pick_column(self, rows: unsafe *cxx::std::vector<CRow>) -> i32 {
        var *r0               = &(*rows)[0]
        var best:       i32   = -1
        var best_run:   usize = 0
        var best_heads: usize = 0
        for var c: usize = 0; c < r0->cols.size(); ++c {
            if self._ps.is_wild(r0->cols[c]) {
                continue
            }

            var run: usize = 0
            while run < rows->size() && !self._ps.is_wild((*rows)[run].cols[c]) {
                run += 1
            }

            // One candidate needs no tiebreak.
            var heads: usize = 0
            if r0->cols.size() > 1 {
                heads = self._distinct_heads(*rows, c)
            }

            if best < 0 || run > best_run || run == best_run && heads < best_heads {
                best       = (c as i32)
                best_run   = run
                best_heads = heads
            }
        }

        return best
    }

    /// Distinct heads in column \p c, counted by spelling. A tiebreak only.
    priv fn _distinct_heads(self, const rows: cxx::std::vector<CRow>, c: usize) -> usize {
        var seen: llvm::StringMap<u32>
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *p = (rows)[i].cols[c]
            if self._ps.is_wild(p) {
                continue
            }

            var s = self.sc->ctx->get_spelling(p->range)
            seen.try_emplace(kairo::sref(s), 0 as u32)
        }

        return seen.size() as usize
    }

    /// Every row whose head is an alternation becomes one row per
    /// alternative, recursively; each choice extends the row's key, so one
    /// choice on two paths is one row id.
    priv fn _expand(self, @inout rows: cxx::std::vector<CRow>, occ: u32) -> cxx::std::vector<CRow> {
        var out = cxx::std::vector<CRow>()
        for var i: usize = 0; i < rows.size(); ++i {
            self._expand_into(&(rows)[i], occ, unsafe &out)
        }

        return out
    }

    priv fn _expand_into(self, r: *CRow, occ: u32, out: unsafe *cxx::std::vector<CRow>) {
        var unsafe *h = r->cols[0]
        if h == &null || h->kind != PatternKind::AlternationPattern {
            out->push_back(*r)
            return
        }

        var unsafe *a = cast<AlternationPattern>(h)
        for var k: usize = 0; k < a->alternatives.size(); ++k {
            var nr = *r
            nr.cols[0] = a->alternatives[k]
            nr.key     = r->key + f"/{occ}:{k}"
            self._expand_into(&nr, occ, out)
        }
    }

    /// PatternSpace::head_domain over CRow.
    priv fn _head_domain(self, const rows: cxx::std::vector<CRow>) -> Domain {
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *h = (rows)[i].cols[0]
            if self._ps.is_wild(h) {
                continue
            }

            if h->type_ != &null {
                return self._ps.domain_of(h->type_)
            }
        }

        return Domain{}
    }

    /// Rows surviving \p c at the head occurrence, head replaced by the
    /// constructor's fields. A binder head is recorded before it is dropped.
    priv fn _specialize(self,
                        @inout rows: cxx::std::vector<CRow>,
                        const occs:  cxx::std::vector<u32>,
                        const c:     Ctor) -> cxx::std::vector<CRow> {
        var out = cxx::std::vector<CRow>()
        for var i: usize = 0; i < rows.size(); ++i {
            var        *r = &(rows)[i]
            var unsafe *h = r->cols[0]
            var        nr = CRow{}
            nr.arm     = r->arm
            nr.guarded = r->guarded
            nr.key     = r->key
            nr.binds   = r->binds
            if self._ps.is_wild(h) {
                self._bind_head(&nr, h, (occs)[0])
                for var k: u32 = 0; k < c.arity; ++k {
                    nr.cols.push_back(&null)
                }
            } else {
                if !self._ps.covers(self._ps.ctor_of(h), c) {
                    continue
                }

                nr.cols = self._ps.sub_columns(h, c.arity)
            }

            for var k: usize = 1; k < r->cols.size(); ++k {
                nr.cols.push_back(r->cols[k])
            }

            out.push_back(nr)
        }

        return out
    }

    /// _specialize over the rows \p idx names (ascending): an edge's own
    /// heads and the wildcard rows, bucketed by the caller in one pass, so
    /// a switch over n heads is O(rows) and not O(rows * edges).
    priv fn _specialize_idx(self,
                            const rows: cxx::std::vector<CRow>,
                            occs:       unsafe *cxx::std::vector<u32>,
                            const c:    Ctor,
                            const idx:  cxx::std::vector<u32>) -> cxx::std::vector<CRow> {
        var sub = cxx::std::vector<CRow>()
        for var i: usize = 0; i < idx.size(); ++i {
            sub.push_back((rows)[(idx)[i] as usize])
        }

        return self._specialize(&sub, *occs, c)
    }

    /// \p a and \p b, both ascending, merged.
    priv fn _merge_idx(self,
                       @inout a: cxx::std::vector<u32>,
                       const b:  cxx::std::vector<u32>) -> cxx::std::vector<u32> {
        var out       = cxx::std::vector<u32>()
        var i:  usize = 0
        var j:  usize = 0
        while i < a.size() || j < b.size() {
            if j >= b.size() || i < a.size() && (a)[i] < (b)[j] {
                out.push_back((a)[i])
                i += 1
            } else {
                out.push_back((b)[j])
                j += 1
            }
        }

        return out
    }

    /// Rows whose head is a wildcard, head dropped.
    priv fn _defaults(self,
                      @inout rows: cxx::std::vector<CRow>,
                      const occs:  cxx::std::vector<u32>) -> cxx::std::vector<CRow> {
        var out = cxx::std::vector<CRow>()
        for var i: usize = 0; i < rows.size(); ++i {
            var        *r = &(rows)[i]
            var unsafe *h = r->cols[0]
            if !self._ps.is_wild(h) {
                continue
            }

            var nr = CRow{}
            nr.arm     = r->arm
            nr.guarded = r->guarded
            nr.key     = r->key
            nr.binds   = r->binds
            self._bind_head(&nr, h, (occs)[0])
            for var k: usize = 1; k < r->cols.size(); ++k {
                nr.cols.push_back(r->cols[k])
            }

            out.push_back(nr)
        }

        return out
    }

    priv fn _bind_head(self, r: *CRow, h: unsafe *Pattern, occ: u32) {
        if h == &null || h->kind != PatternKind::BindingPattern {
            return
        }

        var b = DBind{}
        b.pat = cast<BindingPattern>(h)
        b.occ = occ
        r->binds.push_back(b)
    }

    /// `occs` with the head replaced by \p sub.
    priv fn _with_sub(self,
                      const occs: cxx::std::vector<u32>,
                      const sub:  cxx::std::vector<u32>) -> cxx::std::vector<u32> {
        var out = sub
        for var k: usize = 1; k < occs.size(); ++k {
            out.push_back((occs)[k])
        }

        return out
    }

    priv fn _rest(self, const occs: cxx::std::vector<u32>) -> cxx::std::vector<u32> {
        var out = cxx::std::vector<u32>()
        for var k: usize = 1; k < occs.size(); ++k {
            out.push_back((occs)[k])
        }

        return out
    }

    /// A one-constructor domain: no test, the column becomes its fields.
    priv fn _through(self,
                     rows:    unsafe *cxx::std::vector<CRow>,
                     occs:    unsafe *cxx::std::vector<u32>,
                     const c: Ctor,
                     d:       Domain) -> u32 {
        var sub   = self._sub_occs((*occs)[0], c, d)
        var srows = self._specialize(&*rows, *occs, c)
        var socc  = self._with_sub(*occs, sub)
        return self._build(unsafe &srows, unsafe &socc)
    }

    /// Children first, then the edges in one run, then the node.
    priv fn _switch_node(self,
                         occ:        u32,
                         const kids: cxx::std::vector<DEdge>,
                         other:      i32,
                         strings:    bool) -> u32 {
        var n = DNode{}
        n.kind    = DKind::Switch
        n.occ     = occ
        n.edge0   = (self._edges.size() as u32)
        n.nedge   = (kids.size() as u32)
        n.other   = other
        n.strings = strings
        for var i: usize = 0; i < kids.size(); ++i {
            self._edges.push_back((kids)[i])
        }

        return self._push(n)
    }

    priv fn _switch_enum(self,
                         rows: unsafe *cxx::std::vector<CRow>,
                         occs: unsafe *cxx::std::vector<u32>,
                         d:    Domain) -> u32 {
        var n = (d.nctors as usize) // a pack-expanded variant counts once per element.
        // Edges in first-appearance order; each edge's rows bucketed in the
        // same pass (wildcard rows join every edge at _specialize_idx).
        var order   = cxx::std::vector<u32>()
        var heads   = cxx::std::vector<unsafe *Pattern>()
        var buckets = cxx::std::vector<cxx::std::vector<u32>>()
        var wilds   = cxx::std::vector<u32>()
        var slot    = cxx::std::vector<i32>()
        for var k: usize = 0; k < n; ++k {
            slot.push_back(-1)
        }

        for var i: usize = 0; i < rows->size(); ++i {
            var unsafe *h = (*rows)[i].cols[0]
            if self._ps.is_wild(h) {
                wilds.push_back(i as u32)
                continue
            }

            var hc = self._ps.ctor_of(h)
            if hc.kind != CtorKind::Variant {
                continue
            }

            var at: i32 = -1
            if (hc.index as usize) < n {
                at = slot[hc.index as usize]
            } else {
                for var k: usize = 0; k < order.size(); ++k {
                    if order[k] == hc.index {
                        at = (k as i32)
                        break
                    }
                }
            }

            if at < 0 {
                at = (order.size() as i32)
                order.push_back(hc.index)
                heads.push_back(h)
                buckets.push_back(cxx::std::vector<u32>())
                if (hc.index as usize) < n {
                    slot[hc.index as usize] = at
                }
            }

            buckets[at as usize].push_back(i as u32)
        }

        var kids = cxx::std::vector<DEdge>()
        for var k: usize = 0; k < order.size(); ++k {
            var c = Ctor{}
            c.kind  = CtorKind::Variant
            c.index = order[k]
            c.arity = (adt_variant_at(d.en, order[k] as usize)->payload.size() as u32)
            var sub   = self._sub_occs((*occs)[0], c, d)
            var idx   = self._merge_idx(&buckets[k], wilds)
            var srows = self._specialize_idx(*rows, occs, c, idx)
            var socc  = self._with_sub(*occs, sub)
            var e     = DEdge{}
            e.kind  = CtorKind::Variant
            e.index = order[k]
            e.pat   = heads[k]
            e.child = self._build(unsafe &srows, unsafe &socc)
            kids.push_back(e)
        }

        // Complete over the declared variants: the default is where an
        // undeclared discriminant goes, which is the wildcard rows, or
        // UnmatchedPolicy when there are none.
        var drows      = self._defaults(&*rows, *occs)
        var rest       = self._rest(*occs)
        var other: i32 = -1
        // Under a split, an undeclared discriminant still owes the lower
        // half its chance (its default rows).
        if order.size() < n || drows.size() > 0 || self._fallback >= 0 {
            other = (self._build(unsafe &drows, unsafe &rest) as i32)
        }

        return self._switch_node((*occs)[0], kids, other, false)
    }

    priv fn _switch_bool(self,
                         rows: unsafe *cxx::std::vector<CRow>,
                         occs: unsafe *cxx::std::vector<u32>,
                         d:    Domain) -> u32 {
        var have = cxx::std::vector<u8>()
        have.push_back(0)
        have.push_back(0)
        var heads = cxx::std::vector<unsafe *Pattern>()
        heads.push_back(&null)
        heads.push_back(&null)
        for var i: usize = 0; i < rows->size(); ++i {
            var unsafe *h = (*rows)[i].cols[0]
            if self._ps.is_wild(h) {
                continue
            }

            var hc = self._ps.ctor_of(h)
            if hc.kind != CtorKind::Bool {
                continue
            }

            if have[hc.lo as usize] == 0 {
                have[hc.lo as usize]  = 1
                heads[hc.lo as usize] = h
            }
        }

        var kids = cxx::std::vector<DEdge>()
        for var b: u64 = 0; b < (2 as u64); ++b {
            var v = (1 as u64) - b // `true` first: the dump reads in source order more often.
            if have[v as usize] == 0 {
                continue
            }

            var c = Ctor{}
            c.kind = CtorKind::Bool
            c.lo   = v
            c.hi   = v
            var srows = self._specialize(&*rows, *occs, c)
            var socc  = self._rest(*occs)
            var e     = DEdge{}
            e.kind  = CtorKind::Bool
            e.lo    = v
            e.hi    = v
            e.pat   = heads[v as usize]
            e.child = self._build(unsafe &srows, unsafe &socc)
            kids.push_back(e)
        }

        var other: i32 = -1
        if !(have[0] != 0 && have[1] != 0) {
            var drows = self._defaults(&*rows, *occs)
            var rest  = self._rest(*occs)
            other = (self._build(unsafe &drows, unsafe &rest) as i32)
        }

        return self._switch_node((*occs)[0], kids, other, false)
    }

    priv fn _switch_int(self,
                        rows: unsafe *cxx::std::vector<CRow>,
                        occs: unsafe *cxx::std::vector<u32>,
                        d:    Domain) -> u32 {
        if self._all_points(*rows) {
            return self._switch_points(rows, occs, d)
        }

        var segs = self._int_segments(*rows, d.max_key)

        // Which Int heads survive each segment; merge neighbours that agree.
        var kids            = cxx::std::vector<DEdge>()
        var any_hole        = false
        var prev_set        = cxx::std::vector<u32>()
        var have_prev       = false
        var i:        usize = 0
        while i < segs.size() {
            var set = self._covering_rows(*rows, segs[i])
            if set.size() == 0 {
                any_hole  = true
                have_prev = false
                i += 1
                continue
            }

            if have_prev && self._same_rows(&*rows, set, prev_set) {
                kids[kids.size() - 1].hi = segs[i].hi
                i += 1
                continue
            }

            var e = DEdge{}
            e.kind = CtorKind::Int
            e.lo   = segs[i].lo
            e.hi   = segs[i].hi
            e.pat  = (*rows)[set[0] as usize].cols[0]
            kids.push_back(e)
            prev_set  = set
            have_prev = true
            i += 1
        }

        for var k: usize = 0; k < kids.size(); ++k {
            var c = Ctor{}
            c.kind = CtorKind::Int
            c.lo   = kids[k].lo
            c.hi   = kids[k].lo // a key inside the edge: containment is all-or-nothing per segment.
            var srows = self._specialize(&*rows, *occs, c)
            var socc  = self._rest(*occs)
            kids[k].child = self._build(unsafe &srows, unsafe &socc)
        }

        var other: i32 = -1
        if any_hole {
            var drows = self._defaults(&*rows, *occs)
            var rest  = self._rest(*occs)
            other = (self._build(unsafe &drows, unsafe &rest) as i32)
        }

        return self._switch_node((*occs)[0], kids, other, false)
    }

    /// Every Int head one key: a `case 1, 2, 3` table.
    priv fn _all_points(self, const rows: cxx::std::vector<CRow>) -> bool {
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *h = (rows)[i].cols[0]
            if self._ps.is_wild(h) {
                continue
            }

            var hc = self._ps.ctor_of(h)
            if hc.kind != CtorKind::Int || hc.lo != hc.hi {
                return false
            }
        }

        return true
    }

    /// _switch_int when every head is one key. The segments are then the
    /// keys and the gaps between them, and a key's surviving rows are its
    /// own heads, so the rows are bucketed by key in one pass instead of
    /// rescanned per segment. Same edges, merges and order as the general
    /// form: ascending keys, a gap a hole that breaks a merge run.
    priv fn _switch_points(self,
                           rows: unsafe *cxx::std::vector<CRow>,
                           occs: unsafe *cxx::std::vector<u32>,
                           d:    Domain) -> u32 {
        var at:     llvm::StringMap<u32>
        var buckets                      = cxx::std::vector<cxx::std::vector<u32>>()
        var bkey                         = cxx::std::vector<u64>()
        var wilds                        = cxx::std::vector<u32>()
        for var i: usize = 0; i < rows->size(); ++i {
            var unsafe *h = (*rows)[i].cols[0]
            if self._ps.is_wild(h) {
                wilds.push_back(i as u32)
                continue
            }

            var v      = self._ps.ctor_of(h).lo
            var ks     = f"{v}"
            var it     = at.find(kairo::sref(ks))
            var b: u32 = 0
            if it != at.end() {
                b = it->second
            } else {
                b = (buckets.size() as u32)
                buckets.push_back(cxx::std::vector<u32>())
                bkey.push_back(v)
                at.try_emplace(kairo::sref(ks), b)
            }

            buckets[b as usize].push_back(i as u32)
        }

        var keys = bkey
        sort_unique_keys(unsafe &keys)

        var kids          = cxx::std::vector<DEdge>()
        var kidb          = cxx::std::vector<u32>() // the bucket each edge's rows are read from: its first key's.
        var any_hole      = false
        var have_prev     = false
        var prev_set      = cxx::std::vector<u32>()
        var next:     u64 = 0 // the least key not yet placed in a segment.
        for var k: usize = 0; k < keys.size(); ++k {
            var v = keys[k]
            if v > next {
                any_hole  = true
                have_prev = false
            }

            var b   = at.find(kairo::sref(f"{v}"))->second
            var set = buckets[b as usize]
            if have_prev && self._same_rows(&*rows, set, prev_set) {
                kids[kids.size() - 1].hi = v
            } else {
                var e = DEdge{}
                e.kind = CtorKind::Int
                e.lo   = v
                e.hi   = v
                e.pat  = (*rows)[set[0] as usize].cols[0]
                kids.push_back(e)
                kidb.push_back(b)
                prev_set  = set
                have_prev = true
            }

            next = v + (1 as u64)
        }

        if keys.size() == 0 || keys[keys.size() - 1] < d.max_key {
            any_hole = true
        }

        for var k: usize = 0; k < kids.size(); ++k {
            var c = Ctor{}
            c.kind = CtorKind::Int
            c.lo   = kids[k].lo
            c.hi   = kids[k].lo
            var idx   = self._merge_idx(&buckets[kidb[k] as usize], wilds)
            var srows = self._specialize_idx(*rows, occs, c, idx)
            var socc  = self._rest(*occs)
            kids[k].child = self._build(unsafe &srows, unsafe &socc)
        }

        var other: i32 = -1
        if any_hole {
            var drows = self._defaults(&*rows, *occs)
            var rest  = self._rest(*occs)
            other = (self._build(unsafe &drows, unsafe &rest) as i32)
        }

        return self._switch_node((*occs)[0], kids, other, false)
    }

    /// PatternSpace::int_segments over CRow, across the whole key space.
    priv fn _int_segments(self,
                          const rows: cxx::std::vector<CRow>,
                          max_key:    u64) -> cxx::std::vector<Ctor> {
        var cuts = cxx::std::vector<u64>()
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *h = (rows)[i].cols[0]
            if self._ps.is_wild(h) {
                continue
            }

            var c = self._ps.ctor_of(h)
            if c.kind != CtorKind::Int {
                continue
            }

            if c.lo > (0 as u64) {
                cuts.push_back(c.lo)
            }

            if c.hi < max_key {
                cuts.push_back(c.hi + (1 as u64))
            }
        }

        sort_unique_keys(unsafe &cuts)
        var out        = cxx::std::vector<Ctor>()
        var start: u64 = 0
        for var i: usize = 0; i <= cuts.size(); ++i {
            var end = if (i < cuts.size()) => (cuts[i] - (1 as u64)) else => max_key
            var c   = Ctor{}
            c.kind = CtorKind::Int
            c.lo   = start
            c.hi   = end
            out.push_back(c)
            if i < cuts.size() {
                start = cuts[i]
            }
        }

        return out
    }

    /// Rows whose Int head contains segment \p s, by index.
    priv fn _covering_rows(self,
                           const rows: cxx::std::vector<CRow>,
                           const s:    Ctor) -> cxx::std::vector<u32> {
        var out = cxx::std::vector<u32>()
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *h = (rows)[i].cols[0]
            if self._ps.is_wild(h) {
                continue
            }

            var hc = self._ps.ctor_of(h)
            if hc.kind == CtorKind::Int && hc.lo <= s.lo && s.hi <= hc.hi {
                out.push_back(i as u32)
            }
        }

        return out
    }

    /// Two segments lead to the same subtree when their surviving Int rows
    /// agree position by position on everything below the head: arm, guard,
    /// remaining columns, binders. `case 1, 2, 3` is three rows of one arm;
    /// this merges their segments into one `1...3` edge.
    priv fn _same_rows(self,
                       @inout rows: cxx::std::vector<CRow>,
                       const a:     cxx::std::vector<u32>,
                       const b:     cxx::std::vector<u32>) -> bool {
        if a.size() != b.size() {
            return false
        }

        for var i: usize = 0; i < a.size(); ++i {
            var *x = &(rows)[(a)[i] as usize]
            var *y = &(rows)[(b)[i] as usize]
            if x->arm != y->arm || x->guarded != y->guarded {
                return false
            }

            if x->cols.size() != y->cols.size() {
                return false
            }

            for var k: usize = 1; k < x->cols.size(); ++k {
                if x->cols[k] != y->cols[k] {
                    return false
                }
            }

            if x->binds.size() != y->binds.size() {
                return false
            }

            for var k: usize = 0; k < x->binds.size(); ++k {
                if x->binds[k].pat->decl != y->binds[k].pat->decl
                    || x->binds[k].occ != y->binds[k].occ {
                    return false
                }
            }
        }

        return true
    }

    /// ### strings

    /// A string column every head of which has known bytes. A head without
    /// them has no rendering (string `==` is a user operator, lowered before
    /// MatchLowering runs): SC116E.
    priv fn _is_string_column(self, const rows: cxx::std::vector<CRow>, occ: u32) -> bool {
        var unsafe *t = self._occs[occ as usize].type_
        if t == &null || !self._tu.is_string(t) {
            return false
        }

        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *h = (rows)[i].cols[0]
            if self._ps.is_wild(h) {
                continue
            }

            var bytes = cxx::std::vector<u8>()
            if !pattern_string_bytes(self.sc, h, unsafe &bytes) {
                self._unsupported(
                    h,
                    "matching a string against a pattern that is not a string literal or a constant initialized with one",
                )

                return false
            }
        }

        return true
    }

    priv fn _switch_string(self,
                           rows: unsafe *cxx::std::vector<CRow>,
                           occs: unsafe *cxx::std::vector<u32>) -> u32 {
        // Keys in first-appearance order, each key's rows bucketed by its
        // decoded bytes in the same pass; wildcard rows join every key.
        var at:     llvm::StringMap<u32>
        var heads                        = cxx::std::vector<unsafe *Pattern>()
        var buckets                      = cxx::std::vector<cxx::std::vector<u32>>()
        var wilds                        = cxx::std::vector<u32>()
        for var i: usize = 0; i < rows->size(); ++i {
            var unsafe *h = (*rows)[i].cols[0]
            if self._ps.is_wild(h) {
                wilds.push_back(i as u32)
                continue
            }

            var b = cxx::std::vector<u8>()
            pattern_string_bytes(self.sc, h, unsafe &b)
            var ks: string
            for var j: usize = 0; j < b.size(); ++j {
                ks.push_back(b[j])
            }

            var it        = at.find(kairo::sref(ks))
            var slot: u32 = 0
            if it != at.end() {
                slot = it->second
            } else {
                slot = (heads.size() as u32)
                heads.push_back(h)
                buckets.push_back(cxx::std::vector<u32>())
                at.try_emplace(kairo::sref(ks), slot)
            }

            buckets[slot as usize].push_back(i as u32)
        }

        var kids = cxx::std::vector<DEdge>()
        for var k: usize = 0; k < heads.size(); ++k {
            var srows = cxx::std::vector<CRow>()
            var idx   = self._merge_idx(&buckets[k], wilds)
            for var ii: usize = 0; ii < idx.size(); ++ii {
                var        *r = &(*rows)[idx[ii] as usize]
                var unsafe *h = r->cols[0]
                var        nr = CRow{}
                nr.arm     = r->arm
                nr.guarded = r->guarded
                nr.key     = r->key
                nr.binds   = r->binds
                self._bind_head(&nr, h, (*occs)[0])
                for var c: usize = 1; c < r->cols.size(); ++c {
                    nr.cols.push_back(r->cols[c])
                }

                srows.push_back(nr)
            }

            var socc = self._rest(*occs)
            var e    = DEdge{}
            e.kind  = CtorKind::Opaque
            e.pat   = heads[k]
            e.child = self._build(unsafe &srows, unsafe &socc)
            kids.push_back(e)
        }

        var drows = self._defaults(&*rows, *occs)
        var rest  = self._rest(*occs)
        var other = (self._build(unsafe &drows, unsafe &rest) as i32)
        return self._switch_node((*occs)[0], kids, other, true)
    }

    /// ### opaque

    /// Binary test on the first non-wildcard head. See the file header.
    priv fn _test(self,
                  const rows: cxx::std::vector<CRow>,
                  occs:       unsafe *cxx::std::vector<u32>) -> u32 {
        var h: unsafe *Pattern = &null
        for var i: usize = 0; i < rows.size() && h == &null; ++i {
            if !self._ps.is_wild((rows)[i].cols[0]) {
                h = (rows)[i].cols[0]
            }
        }

        if h == &null {
            kairo::std::ice_fail(
                "PatternCompilation: a test column with no head; _pick_column chose a wildcard column",
            )
        }

        self._check_opaque(h)
        var hc = self._ps.ctor_of(h)

        var yes = cxx::std::vector<CRow>()
        var no  = cxx::std::vector<CRow>()
        for var i: usize = 0; i < rows.size(); ++i {
            var        r    = (rows)[i]
            var unsafe *p   = r.cols[0]
            var        same = !self._ps.is_wild(p) && self._same_ctor(self._ps.ctor_of(p), hc)
            if same {
                r.cols[0] = &null
                yes.push_back(r)
            } else {
                yes.push_back(r)
                no.push_back(r)
            }
        }

        var t = self._build(unsafe &yes, occs)
        var f = self._build(unsafe &no, occs)

        var e = DEdge{}
        e.kind  = hc.kind
        e.index = hc.index
        e.lo    = hc.lo
        e.hi    = hc.hi
        e.pat   = h
        e.child = t
        var n = DNode{}
        n.kind  = DKind::Test
        n.occ   = (*occs)[0]
        n.edge0 = (self._edges.size() as u32)
        n.nedge = 1
        n.other = (f as i32)
        self._edges.push_back(e)
        return self._push(n)
    }

    priv fn _same_ctor(self, const a: Ctor, const b: Ctor) -> bool {
        if a.kind != b.kind {
            return false
        }

        match a.kind {
            case CtorKind::Opaque {
                return a.key == b.key
            } case CtorKind::Variant {
                return a.index == b.index
            } case CtorKind::Bool {
                return a.lo == b.lo
            } case CtorKind::Int {
                return a.lo == b.lo && a.hi == b.hi
            } default {
                return true
            }
        }
    }

    /// An opaque test MatchLowering cannot render: `==` on a record that X
    /// typed no `==` for (PatternTyping::_type_eq_test).
    priv fn _check_opaque(self, h: unsafe *Pattern) {
        if h == &null || h->type_ == &null {
            return
        }

        var unsafe *u = canon_unqual(self._tu.as_value(h->type_))
        if u == &null || !isa<RecordType>(u) {
            return
        }

        if self.sc->pattern_eqs.find(h as usize as u64) != self.sc->pattern_eqs.end() {
            return
        }

        var unsafe *rd = self._tu.pattern_of(cast<RecordType>(u)->decl)
        if isa<EnumDecl>(rd) {
            return
        }

        self._unsupported(
            h,
            f"matching a value of type '{self._tu.str(h->type_)}' against this pattern",
        )
    }

    priv fn _unsupported(self, p: unsafe *Pattern, const what: string) {
        if self._bad {
            return
        }

        self._bad = true
        self.sc->diag->report(DiagID::SC116E, p->range.start, f"{what} is not yet supported").first(
            p->range,
        )->emit()
    }

    /// ## backtracking automaton

    /// Rows in order; row i's tests chain into its accept node, and every
    /// failure goes to row i+1's chain.
    priv fn _automaton(self, const rows0: cxx::std::vector<CRow>, root: u32) -> u32 {
        // Full expansion: an alternation anywhere is one row per choice.
        for var i: usize = 0; i < rows0.size(); ++i {
            var flat  = cxx::std::vector<FlatRow>()
            var start = FlatRow{}
            start.row = (rows0)[i]
            self._flatten((rows0)[i].cols[0], root, &start, &flat)
            for var k: usize = 0; k < flat.size(); ++k {
                self._flat.push_back(flat[k])
            }
        }

        var cont = self._fail()
        var k    = self._flat.size()
        while k > 0 {
            k = k - 1
            var *fr  = &self._flat[k]
            var occs = cxx::std::vector<u32>()
            var acc  = self._accept(&fr->row, occs, cont as i32)
            var node = acc
            var t    = fr->tests.size()
            while t > 0 {
                t = t - 1
                var ft = fr->tests[t]
                ft.edge.child = node
                var n = DNode{}
                n.kind  = DKind::Test
                n.occ   = ft.occ
                n.edge0 = (self._edges.size() as u32)
                n.nedge = 1
                n.other = (cont as i32)
                self._edges.push_back(ft.edge)
                node = self._push(n)
            }

            cont = node
        }

        self._flat = cxx::std::vector<FlatRow>()
        return cont
    }

    /// Walk \p p at \p occ, appending its tests in pre-order (a variant's
    /// tag before its payload) and its binders; an alternation forks the
    /// row. Every fork lands in \p out.
    priv fn _flatten(self,
                     p:          unsafe *Pattern,
                     occ:        u32,
                     acc:        *FlatRow,
                     @inout out: cxx::std::vector<FlatRow>) {
        var cur = cxx::std::vector<FlatRow>()
        cur.push_back(*acc)
        self._flatten_into(p, occ, unsafe &cur)
        for var i: usize = 0; i < cur.size(); ++i {
            cur[i].row.cols = cxx::std::vector<unsafe *Pattern>() // all consumed: _accept reads binds only.
            out.push_back(cur[i])
        }
    }

    priv fn _flatten_into(self,
                          p:    unsafe *Pattern,
                          occ:  u32,
                          rows: unsafe *cxx::std::vector<FlatRow>) {
        if p == &null {
            return
        }

        self._note_type(occ, p)
        match p->kind {
            case PatternKind::WildcardPattern {
                return
            } case PatternKind::BindingPattern {
                for var i: usize = 0; i < rows->size(); ++i {
                    var b = DBind{}
                    b.pat = cast<BindingPattern>(p)
                    b.occ = occ
                    (*rows)[i].row.binds.push_back(b)
                }

                return
            } case PatternKind::AlternationPattern {
                var unsafe *a  = cast<AlternationPattern>(p)
                var        out = cxx::std::vector<FlatRow>()
                for var k: usize = 0; k < a->alternatives.size(); ++k {
                    var fork = *rows
                    for var i: usize = 0; i < fork.size(); ++i {
                        fork[i].row.key = fork[i].row.key + f"/{occ}:{k}"
                    }

                    self._flatten_into(a->alternatives[k], occ, unsafe &fork)
                    for var i: usize = 0; i < fork.size(); ++i {
                        out.push_back(fork[i])
                    }
                }

                *rows = out
                return
            } default {
                0
            }
        }

        var d = self._ps.domain_of(p->type_)
        var c = self._ps.ctor_of(p)
        if c.kind == CtorKind::Record {
            var sub  = self._sub_occs(occ, c, d)
            var cols = self._ps.sub_columns(p, c.arity)
            for var k: usize = 0; k < cols.size(); ++k {
                self._flatten_into(cols[k], sub[k], rows)
            }

            return
        }

        if c.kind == CtorKind::Opaque {
            var unsafe *t = self._occs[occ as usize].type_
            if t != &null && self._tu.is_string(t) {
                var b = cxx::std::vector<u8>()
                if !pattern_string_bytes(self.sc, p, unsafe &b) {
                    self._unsupported(
                        p,
                        "matching a string against a pattern that is not a string literal or a constant initialized with one",
                    )
                }
            } else {
                self._check_opaque(p)
            }
        }

        var ft = FlatTest{}
        ft.occ        = occ
        ft.edge.kind  = c.kind
        ft.edge.index = c.index
        ft.edge.lo    = c.lo
        ft.edge.hi    = c.hi
        ft.edge.pat   = p
        for var i: usize = 0; i < rows->size(); ++i {
            (*rows)[i].tests.push_back(ft)
        }

        if c.kind == CtorKind::Variant {
            var sub  = self._sub_occs(occ, c, d)
            var cols = self._ps.sub_columns(p, c.arity)
            for var k: usize = 0; k < cols.size(); ++k {
                self._flatten_into(cols[k], sub[k], rows)
            }
        }
    }

    /// ## freeze

    priv fn _freeze(self, root: u32, automaton: bool) -> unsafe *DecisionTree {
        var unsafe *ctx = self.sc->ctx
        var unsafe *t   = ctx->alloc<DecisionTree>()
        var        nb   = ListBuilder<DNode>(ctx)
        for var i: usize = 0; i < self._nodes.size(); ++i {
            nb.push(self._nodes[i])
        }

        nb.freeze_into(&t->nodes)
        var eb = ListBuilder<DEdge>(ctx)
        for var i: usize = 0; i < self._edges.size(); ++i {
            eb.push(self._edges[i])
        }

        eb.freeze_into(&t->edges)
        var ob = ListBuilder<DOcc>(ctx)
        for var i: usize = 0; i < self._occs.size(); ++i {
            ob.push(self._occs[i])
        }

        ob.freeze_into(&t->occs)
        var bb = ListBuilder<DBind>(ctx)
        for var i: usize = 0; i < self._binds.size(); ++i {
            bb.push(self._binds[i])
        }

        bb.freeze_into(&t->binds)
        t->root      = root
        t->row_count = (self._keys.size() as u32)
        t->automaton = automaton
        return t
    }
}

/// # --print-sema

pub fn decision_occ(sc: unsafe *SemaContext, t: unsafe *DecisionTree, o: u32) -> string {
    var tu = TypeUtil(sc)
    var d  = t->occs[o as usize]
    match d.kind {
        case OccKind::Root {
            return "$"
        } case OccKind::Field {
            // A tuple's element prints as it is indexed, `$.0`, not `$._0`.
            var unsafe *owner = (unsafe (d.field as unsafe *Decl))->semantic_dc
            if owner != &null && tu.is_tuple_decl(owner->dc_owner) {
                return decision_occ(sc, t, d.parent as u32) + f".{d.field->index}"
            }

            return decision_occ(sc, t, d.parent as u32) + "." + tu.decl_name(d.field)
        } case OccKind::Payload {
            var        ps  = PatternSpace(sc)
            var        pd  = ps.domain_of(t->occs[d.parent as usize].type_)
            var        v   = "?"
            var unsafe *pv = adt_variant_at(pd.en, d.index as usize)
            if pv != &null {
                v = tu.decl_name(pv)
            }

            var pk = adt_expansion_at(pd.en, d.index as usize)
            if pk >= 0 {
                v += f"[{pk}]"
            }

            return decision_occ(sc, t, d.parent as u32) + "." + v + "." + tu.decl_name(d.field)
        }
    }
}

pub fn decision_ctor(sc: unsafe *SemaContext, t: unsafe *DecisionTree, o: u32, e: DEdge) -> string {
    var ps = PatternSpace(sc)
    var d  = ps.domain_of(t->occs[o as usize].type_)
    match e.kind {
        case CtorKind::Bool {
            return if (e.lo == (1 as u64)) => ("true") else => "false"
        } case CtorKind::Int {
            return ps.range_str(d, e.lo, e.hi)
        } case CtorKind::Variant {
            var c = Ctor{}
            c.kind  = CtorKind::Variant
            c.index = e.index
            var none = cxx::std::vector<string>()
            return ps.render(d, c, unsafe &none)
        } default {
            if e.pat != &null {
                return sc->ctx->get_spelling(e.pat->range)
            }

            return "_"
        }
    }
}

pub fn decision_binds(sc: unsafe *SemaContext, t: unsafe *DecisionTree, n: DNode) -> string {
    if n.nbind == 0 {
        return ""
    }

    var s = " ["
    for var k: u32 = 0; k < n.nbind; ++k {
        var b = t->binds[(n.bind0 + k) as usize]
        if k > 0 {
            s = s + " "
        }

        s = s + sc->ctx->get_spelling(b.pat->name) + "=" + decision_occ(sc, t, b.occ)
    }

    return s + "]"
}

pub fn decision_row(sc: unsafe *SemaContext, t: unsafe *DecisionTree, i: u32) -> string {
    var n    = t->nodes[i as usize]
    var head = f"n{i}: "
    match n.kind {
        case DKind::Fail {
            return head + "fail"
        } case DKind::Leaf {
            return head + f"leaf arm {n.arm}" + decision_binds(sc, t, n)
        } case DKind::Guard {
            return head + f"guard arm {n.arm} else n{n.other}" + decision_binds(sc, t, n)
        } case DKind::Test {
            var e = t->edges[n.edge0 as usize]
            return head + f"test {decision_occ(sc, t, n.occ)} is " + decision_ctor(
                sc,
                t,
                n.occ,
                e,
            ) + f" ? n{e.child} : n{n.other}"
        } case DKind::Switch {
            var s = head + f"switch {decision_occ(sc, t, n.occ)} " + "{ "
            for var k: u32 = 0; k < n.nedge; ++k {
                var e = t->edges[(n.edge0 + k) as usize]
                if k > 0 {
                    s = s + ", "
                }

                s = s + decision_ctor(sc, t, n.occ, e) + f" => n{e.child}"
            }

            if n.other >= 0 {
                s = s + f", _ => n{n.other}"
            } else if PatternSpace(sc).domain_of(
                t->occs[n.occ as usize].type_,
            ).kind == DomainKind::ClosedEnum {
                s = s + ", _ => unmatched" // an undeclared discriminant: UnmatchedPolicy.
            }

            return s + " }"
        }
    }
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
pub fn decision_rows(sc: unsafe *SemaContext, t: unsafe *DecisionTree) -> cxx::std::vector<string> {
    var out = cxx::std::vector<string>()
    if t == &null {
        return out
    }

    var mode = if (t->automaton) => (" automaton") else => ""
    out.push_back(f"decision{mode} [nodes={t->nodes.size()} rows={t->row_count}]")
    out.push_back("  " + decision_row(sc, t, t->root))
    for var i: usize = 0; i < t->nodes.size(); ++i {
        if (i as u32) == t->root {
            continue
        }

        out.push_back("  " + decision_row(sc, t, i as u32))
    }

    return out
}
