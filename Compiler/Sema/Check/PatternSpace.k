/// --- The Kairo Project -------------------- Sema/Check/PatternSpace.k --- ///
///
///   \brief The value space patterns are checked against: what a column of a
///          pattern matrix ranges over (its domain), which constructor a
///          pattern tests (its head), and the rows a matrix is made of.
///
///   \detail
///     Shared by PatternChecking (usefulness: exhaustiveness and dead arms)
///     and PatternCompilation (decision trees). Neither owns the other's
///     questions, so the vocabulary lives here and holds no policy: nothing
///     in this file diagnoses or writes a slot.
///
///     A column's DOMAIN is read off a pattern's `type_`, which X writes on
///     every pattern it types. A column in which no row has a constructor
///     never needs a domain: the algorithms take the default matrix there.
///
///       ClosedEnum   a Kairo enum, plain or ADT, that is not a flags enum.
///                    Its variants are the whole space (see `closed` below).
///       OpenEnum     a flags enum (a discriminant WRITTEN as `|` or `<<`), or
///                    an imported C++ enum. Any underlying value can occur;
///                    the variants never complete it.
///       Bool         `true`, `false`.
///       Int          an integer of at most 64 bits. Values are KEYS: the
///                    value biased so the type's minimum is 0, which keeps
///                    signed and unsigned in one u64 order. Wider integers
///                    are Opaque.
///       Record       one constructor; arity = instance fields. A tuple is
///                    its arity's record (TupleRecords), so `(a, b)` and
///                    `P(a, b)` are one domain; only the rendering differs.
///       Opaque       everything else (strings, chars, floats, nullables,
///                    pointers, wide integers): values compare by identity
///                    and no finite set of them is complete.
///
///     `closed` is the switch PatternChecking turns to find out whether an
///     exhaustive match relied on the enum being closed. Kairo enums are
///     emitted as C++ `enum class` with a fixed underlying type, so any
///     underlying value is representable (from C++, or through `as`); a
///     match that lists every variant and has no wildcard is exhaustive
///     over the DECLARED values only. MatchLowering applies UnmatchedPolicy
///     to the rest.
///
///     Integer constants are ConstEval's (Sema/Check/ConstEval.k). A bound
///     that does not evaluate, or needs more than 64 bits, is Opaque, which
///     is sound: an opaque value covers nothing, so it can only ask for a
///     `default`, never hide one.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/STLExtras.h"
ffi "c++" import "vector"

import AST::ASTSupport::create_empty_frozen_list
import AST::DeclFacts::{
    adt_expansion_at,
    adt_pack_variant,
    adt_variant_at,
    decl_is_imported,
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
    ClassDecl, EnumDecl, EnumVariantDecl, FieldDecl, IntConst, StructDecl, VariableDecl,
}
import AST::Node::Expressions::BinaryOperatorExpr
import AST::Node::Patterns::{
    AlternationPattern,
    ConstructorPattern,
    LiteralPattern,
    RangePattern,
    TupleDestructurePattern,
    UnresolvedConstructorPattern,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    NullLiteralExpr,
}
import Sema::Check::ConstEval::ConstEval
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil
import Sema::Type::VariadicEnum::VariadicEnum
import Token::TokenKind::TokenKind

/// Sort \p v ascending and drop repeats: a match's integer cuts, which
/// are O(rows) and must not cost O(rows^2).
pub fn sort_unique_keys(v: unsafe *cxx::std::vector<u64>) {
    llvm::sort(v->begin(), v->end())
    var n: usize = 0
    for var i: usize = 0; i < v->size(); ++i {
        if n > 0 && (*v)[n - 1] == (*v)[i] {
            continue
        }

        (*v)[n] = (*v)[i]
        n += 1
    }

    v->resize(n, 0 as u64)
}

/// What a column ranges over. See the file header.
pub enum DomainKind derives u8 {
    Unknown = 0,
    ClosedEnum,
    OpenEnum,
    Bool,
    Int,
    Record,
    Opaque,
}

pub struct Domain {
    var kind:    DomainKind       = DomainKind::Unknown
    var en:      unsafe *EnumDecl = &null ///< ClosedEnum / OpenEnum: the pattern decl.
    var rec:     unsafe *Decl     = &null ///< Record: the pattern decl.
    var bits:    u32              = 0 ///< Int.
    var signed_: bool             = false ///< Int.
    var max_key: u64              = 0 ///< Int: the largest key (2^bits - 1).
    var arity:   u32              = 0 ///< Record.
    /// ClosedEnum: its constructors at this type, in EXPANDED index order
    /// (adt_variant_at): the variants, a pack-expanded one once per element.
    var nctors: u32          = 0
    var ty:     unsafe *Type = &null ///< ClosedEnum: the column's type, which a pack's elements are read off.
}

/// What a pattern's head tests. `Wild` matches every value of the column.
pub enum CtorKind derives u8 {
    Wild = 0,
    Variant, ///< `index` = position in the enum's variant list.
    Bool,    ///< `lo` = 0 (false) or 1 (true).
    Int,     ///< `lo..=hi` in key space.
    Record,
    Opaque, ///< `key` = identity; equal keys are the same value.
}

pub struct Ctor {
    var kind:  CtorKind = CtorKind::Wild
    var index: u32      = 0
    var lo:    u64      = 0
    var hi:    u64      = 0
    var key:   string
    var arity: u32      = 0              ///< sub-columns this constructor opens.
}

/// One row of a pattern matrix. A null column is a wildcard; so is a
/// WildcardPattern or a BindingPattern (X has already rejected an ascribed
/// binder whose type does not match its column).
pub struct PatRow {
    var cols:    cxx::std::vector<unsafe *Pattern>
    var arm:     u32                               = 0 ///< index of the MatchCase this row came from.
    var alt:     u32                               = 0 ///< index of the alternative within the arm.
    var guarded: bool                              = false
}

pub class PatternSpace {
    pub var sc: unsafe *SemaContext
    pub var tu: TypeUtil
    pub var ce: ConstEval
    /// domain_of by type address. The domain walks the enum's variant list
    /// (is_open_enum, ctor_count), and ctor_of asks it once per head per
    /// specialization: uncached, a 5000-arm match was cubic. A pass's types
    /// do not change under it, and the key is an address, never reserved.
    priv var _domains: llvm::DenseMap<u64, Domain>

    fn PatternSpace(self) {
        self.sc = &null
    }

    fn PatternSpace(self, sc: unsafe *SemaContext) {
        self.sc = sc
        self.tu = TypeUtil(sc)
        self.ce = ConstEval(sc)
    }

    /// # domains

    /// The domain of a column whose values have type \p t.
    fn domain_of(self, t: unsafe *Type) -> Domain {
        if t == &null {
            return Domain{}
        }

        // Keyed by the canonical: every head's `type_` is its own node.
        var unsafe *u = canon_unqual(self.tu.as_value(t))
        if u == &null {
            return Domain{}
        }

        var key = (u as usize as u64)
        var it  = self._domains.find(key)
        if it != self._domains.end() {
            return it->second
        }

        var d = self._domain_of(u)
        self._domains[key] = d
        return d
    }

    priv fn _domain_of(self, u: unsafe *Type) -> Domain {
        var d = Domain{}
        // A bounds-checked parameter (Compiler/Spec/Generics.md#decisions) has values no pattern
        // can name: only a wildcard or a binder covers it.
        if u->is_dependent() {
            if self.tu.checked_head(u) != &null {
                d.kind = DomainKind::Opaque
            }

            // A generic ADT at dependent arguments: its variants are its
            // pattern's, one list for every instance unless a variant is
            // pack-expanded (PatternTyping::dependent_adt).
            if isa<RecordType>(u) {
                var unsafe *den = dyn_cast<EnumDecl>(self.tu.pattern_of(cast<RecordType>(u)->decl))
                if den != &null
                    && den->is_adt
                    && !den->is_imported()
                    && adt_pack_variant(den) == &null {
                    d.en = den
                    d.kind = if (self.is_open_enum(den)) => (DomainKind::OpenEnum)
                             else => DomainKind::ClosedEnum
                    d.ty     = u
                    d.nctors = (den->variants.size() as u32)
                }
            }

            return d
        }

        if self.tu.is_bool(u) {
            d.kind = DomainKind::Bool
            return d
        }

        if self.tu.is_integer(u) {
            var bits = self.tu.int_bits(u)
            if bits == 0 || bits > 64 {
                d.kind = DomainKind::Opaque
                return d
            }

            d.kind    = DomainKind::Int
            d.bits    = (bits as u32)
            d.signed_ = self.tu.is_signed_int(u)
            d.max_key = if (bits == 64) => ((0 as u64) - (1 as u64))
                        else => ((1 as u64) << (bits as u64)) - (1 as u64)
            return d
        }

        if isa<RecordType>(u) {
            if self.tu.is_string(u) {
                d.kind = DomainKind::Opaque
                return d
            }

            var unsafe *rd = self.tu.pattern_of(cast<RecordType>(u)->decl)
            var unsafe *en = dyn_cast<EnumDecl>(rd)
            if en != &null {
                d.en = en
                d.kind = if (self.is_open_enum(en)) => (DomainKind::OpenEnum)
                         else => DomainKind::ClosedEnum
                d.ty     = u
                d.nctors = (VariadicEnum(self.sc).ctor_count(en, u) as u32)
                return d
            }

            if isa<StructDecl>(rd) || isa<ClassDecl>(rd) {
                if decl_is_imported(rd) {
                    d.kind = DomainKind::Opaque
                    return d
                }

                d.kind  = DomainKind::Record
                d.rec   = rd
                d.arity = (self.instance_field_count(rd) as u32)
                return d
            }
        }

        d.kind = DomainKind::Opaque
        return d
    }

    /// An enum whose values are not limited to its variants: an imported C++
    /// enum, or a flags enum. Flags are inferred from the WRITTEN discriminant
    /// syntax -- a `|` or `<<` at its top -- never from the numeric values:
    /// `West = 3 = East | South` in a default-numbered enum is a coincidence.
    fn is_open_enum(self, en: unsafe *EnumDecl) -> bool {
        if en == &null {
            return false
        }

        if en->is_imported() {
            return true
        }

        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v == &null || v->discriminant == &null {
                continue
            }

            var unsafe *e = self.tu.strip_parens(v->discriminant)
            if e == &null || !isa<BinaryOperatorExpr>(e) {
                continue
            }

            var k = cast<BinaryOperatorExpr>(e)->op_token.kind
            if k == TokenKind::OpPipe || k == TokenKind::OpLessLess || k == TokenKind::KwBitor {
                return true
            }
        }

        return false
    }

    /// Fields a record pattern destructures: the non-static ones, in order.
    fn instance_fields(self, rd: unsafe *Decl) -> cxx::std::vector<unsafe *FieldDecl> {
        var out    = cxx::std::vector<unsafe *FieldDecl>()
        var fields = create_empty_frozen_list<unsafe *FieldDecl>()
        if isa<StructDecl>(rd) {
            fields = cast<StructDecl>(rd)->fields
        } else if isa<ClassDecl>(rd) {
            fields = cast<ClassDecl>(rd)->fields
        }

        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *f = fields[i]
            if f == &null || f->is_static() {
                continue
            }

            out.push_back(f)
        }

        return out
    }

    fn instance_field_count(self, rd: unsafe *Decl) -> usize {
        return self.instance_fields(rd).size()
    }

    /// The variant's position in \p en, or -1.
    fn variant_index(self, en: unsafe *EnumDecl, v: unsafe *EnumVariantDecl) -> i32 {
        if en == &null || v == &null {
            return -1
        }

        // The declaration-order slot first: the scan below is per head, and
        // a match lists every variant.
        if (v->index as usize) < en->variants.size() && en->variants[v->index as usize] == v {
            return v->index as i32
        }

        for var i: usize = 0; i < en->variants.size(); ++i {
            if en->variants[i] == v {
                return i as i32
            }
        }

        // A generic enum's instance may carry its own variant decls: match by
        // name, which is unique within one enum.
        var want = self.tu.decl_name(unsafe (v as unsafe *Decl))
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *o = en->variants[i]
            if o != &null && self.tu.decl_name(unsafe (o as unsafe *Decl)) == want {
                return i as i32
            }
        }

        return -1
    }

    /// # integer constants

    /// Evaluate \p e as an integer constant. A value past 64 bits is no
    /// key of any Int domain, so it reads as not a constant here.
    fn eval_int(self, e: unsafe *Expr) -> IntConst {
        var c = self.ce.eval_int(e)
        if c.overflow {
            c.ok = false
        }

        return c
    }

    /// \p c as a key of \p d, or false when it is out of the type's range.
    fn key_of(self, d: Domain, c: IntConst, out: unsafe *u64) -> bool {
        if !c.ok || d.kind != DomainKind::Int {
            return false
        }

        if !d.signed_ {
            if c.neg {
                return false
            }

            if c.mag > d.max_key {
                return false
            }

            *out = c.mag
            return true
        }

        var bias = (1 as u64) << ((d.bits - 1) as u64)
        if c.neg {
            if c.mag > bias {
                return false
            }

            *out = bias - c.mag
            return true
        }

        if c.mag > bias - (1 as u64) {
            return false
        }

        *out = bias + c.mag
        return true
    }

    /// The source spelling of key \p k.
    fn key_str(self, d: Domain, k: u64) -> string {
        if !d.signed_ {
            return f"{k}"
        }

        var bias = (1 as u64) << ((d.bits - 1) as u64)
        if k >= bias {
            return f"{k - bias}"
        }

        return f"-{bias - k}"
    }

    fn range_str(self, d: Domain, lo: u64, hi: u64) -> string {
        if lo == hi {
            return self.key_str(d, lo)
        }

        return self.key_str(d, lo) + "..=" + self.key_str(d, hi)
    }

    /// # heads

    /// A pattern that matches every value of its column.
    fn is_wild(self, p: unsafe *Pattern) -> bool {
        if p == &null {
            return true
        }

        return p->kind == PatternKind::WildcardPattern || p->kind == PatternKind::BindingPattern
    }

    /// The constructor \p p tests. Never called on an AlternationPattern
    /// (rows are expanded first) or a wildcard.
    fn ctor_of(self, p: unsafe *Pattern) -> Ctor {
        var c = Ctor{}
        if self.is_wild(p) {
            return c
        }

        var d = self.domain_of(p->type_)

        match p->kind {
            case PatternKind::LiteralPattern {
                var unsafe *v = cast<LiteralPattern>(p)->value
                if v != &null && isa<BooleanLiteralExpr>(self.tu.strip_parens(v)) {
                    c.kind = CtorKind::Bool
                    c.lo = if (cast<BooleanLiteralExpr>(self.tu.strip_parens(v))->value) => (1)
                           else => (0)
                    c.hi = c.lo
                    return c
                }

                if d.kind == DomainKind::Int {
                    var k: u64 = 0
                    if self.key_of(d, self.eval_int(v), unsafe &k) {
                        c.kind = CtorKind::Int
                        c.lo   = k
                        c.hi   = k
                        return c
                    }
                }

                return self._opaque(self._expr_key(v))
            } case PatternKind::RangePattern {
                var unsafe *r = cast<RangePattern>(p)
                if d.kind == DomainKind::Int {
                    var lo: u64 = 0
                    var hi: u64 = d.max_key
                    var ok      = true
                    if r->lo != &null {
                        ok = self.key_of(d, self.eval_int(r->lo), unsafe &lo) && ok
                    }

                    if r->hi != &null {
                        ok = self.key_of(d, self.eval_int(r->hi), unsafe &hi) && ok
                        if ok && !r->is_inclusive {
                            if hi == (0 as u64) {
                                ok = false
                            } // empty: X reported it.
                            else {
                                hi = hi - (1 as u64)
                            }
                        }
                    }

                    if ok && lo <= hi {
                        c.kind = CtorKind::Int
                        c.lo   = lo
                        c.hi   = hi
                        return c
                    }
                }

                return self._opaque(f"range:{self.sc->ctx->get_spelling(p->range)}")
            } case PatternKind::TupleDestructurePattern {
                // Positional over the tuple's record: field i is element i.
                c.kind  = CtorKind::Record
                c.arity = (cast<TupleDestructurePattern>(p)->elements.size() as u32)
                return c
            } case PatternKind::ConstructorPattern {
                return self._ctor_from_resolved(p, d)
            } case PatternKind::UnresolvedConstructorPattern {
                return self._ctor_from_resolved(p, d)
            } default {
                // Slices, recovery: a test this file cannot reason about.
                return self._opaque(f"pat:{(p as usize as u64)}")
            }
        }
    }

    priv fn _ctor_from_resolved(self, p: unsafe *Pattern, d: Domain) -> Ctor {
        var unsafe *rd = p->resolved_decl
        if rd == &null {
            return self._opaque(f"pat:{(p as usize as u64)}")
        }

        var unsafe *v = dyn_cast<EnumVariantDecl>(rd)
        if v != &null {
            if d.kind == DomainKind::ClosedEnum {
                var idx = self.variant_index(d.en, v)
                if idx >= 0 {
                    // Element k of a pack-expanded variant is its own
                    // constructor, at the variant's position plus k.
                    if v->is_pack_expansion && p->pack_index >= 0 {
                        idx += p->pack_index
                    }

                    var c = Ctor{}
                    c.kind  = CtorKind::Variant
                    c.index = (idx as u32)
                    c.arity = (v->payload.size() as u32)
                    return c
                }
            }

            // Open enum: a variant is one value among unlisted others.
            return self._opaque(f"variant:{self.tu.decl_name((unsafe (v as unsafe *Decl)))}")
        }

        if isa<StructDecl>(rd) || isa<ClassDecl>(rd) {
            var c = Ctor{}
            c.kind  = CtorKind::Record
            c.arity = (self.instance_field_count(rd) as u32)
            return c
        }

        var unsafe *vd = dyn_cast<VariableDecl>(rd)
        if vd != &null {
            if d.kind == DomainKind::Int {
                var k: u64 = 0
                if self.key_of(d, self.eval_int(vd->init), unsafe &k) {
                    var c = Ctor{}
                    c.kind = CtorKind::Int
                    c.lo   = k
                    c.hi   = k
                    return c
                }
            }

            return self._opaque(f"const:{(vd as usize as u64)}")
        }

        return self._opaque(f"pat:{(p as usize as u64)}")
    }

    priv fn _opaque(self, const key: string) -> Ctor {
        var c = Ctor{}
        c.kind = CtorKind::Opaque
        c.key  = key
        return c
    }

    /// Identity of a literal value: its spelling. Two spellings of one value
    /// (`"a"` / `"\x61"`) compare unequal, which only ever keeps an arm alive.
    priv fn _expr_key(self, e: unsafe *Expr) -> string {
        if e == &null {
            return "null-expr"
        }

        var unsafe *s = self.tu.strip_parens(e)
        if isa<NullLiteralExpr>(s) {
            return "null"
        }

        return f"lit:{self.sc->ctx->get_spelling(s->range)}"
    }

    /// Does a row whose head is \p h survive specialization by \p c? Integer
    /// segments are cut so that containment is all-or-nothing.
    fn covers(self, const h: Ctor, const c: Ctor) -> bool {
        if h.kind == CtorKind::Wild {
            return true
        }

        if h.kind != c.kind {
            return false
        }

        match c.kind {
            case CtorKind::Variant {
                return h.index == c.index
            } case CtorKind::Bool {
                return h.lo == c.lo
            } case CtorKind::Int {
                return h.lo <= c.lo && c.hi <= h.hi
            } case CtorKind::Opaque {
                return h.key == c.key
            } case CtorKind::Record {
                return true
            } default {
                return false
            }
        }
    }

    /// # sub-columns

    /// The \p arity sub-columns of \p p under its own constructor. A field the
    /// pattern does not name is a wildcard (null).
    fn sub_columns(self, p: unsafe *Pattern, arity: u32) -> cxx::std::vector<unsafe *Pattern> {
        var out = cxx::std::vector<unsafe *Pattern>()
        for var i: u32 = 0; i < arity; ++i {
            out.push_back(&null)
        }

        if self.is_wild(p) {
            return out
        }

        if p->kind == PatternKind::TupleDestructurePattern {
            var unsafe *t = cast<TupleDestructurePattern>(p)
            for var i: usize = 0; i < t->elements.size() && i < (arity as usize); ++i {
                out[i] = t->elements[i]
            }

            return out
        }

        var subs = create_empty_frozen_list<unsafe *Pattern>()
        if p->kind == PatternKind::ConstructorPattern {
            subs = cast<ConstructorPattern>(p)->subpatterns
        } else if p->kind == PatternKind::UnresolvedConstructorPattern {
            subs = cast<UnresolvedConstructorPattern>(p)->subpatterns
        } else {
            return out
        }

        var fields = self.fields_of_resolved(p->resolved_decl)
        for var i: usize = 0; i < subs.size(); ++i {
            var unsafe *sp = subs[i]
            if sp == &null || sp->field_decl == &null {
                continue
            }

            for var k: usize = 0; k < fields.size() && k < (arity as usize); ++k {
                if (unsafe (fields[k] as unsafe *Decl)) == sp->field_decl {
                    out[k] = sp
                    break
                }
            }
        }

        return out
    }

    /// The fields a constructor head destructures, in declaration order:
    /// a variant's payload, or a record's instance fields.
    fn fields_of_resolved(self, rd: unsafe *Decl) -> cxx::std::vector<unsafe *FieldDecl> {
        var out = cxx::std::vector<unsafe *FieldDecl>()
        if rd == &null {
            return out
        }

        var unsafe *v = dyn_cast<EnumVariantDecl>(rd)
        if v != &null {
            for var i: usize = 0; i < v->payload.size(); ++i {
                out.push_back(v->payload[i])
            }

            return out
        }

        if isa<StructDecl>(rd) || isa<ClassDecl>(rd) {
            return self.instance_fields(rd)
        }

        return out
    }

    /// # rows

    /// Expand every row whose head is an alternation into one row per
    /// alternative, recursively, keeping arm / alt / guard.
    fn expand_heads(self, @inout rows: cxx::std::vector<PatRow>) -> cxx::std::vector<PatRow> {
        var out = cxx::std::vector<PatRow>()
        for var i: usize = 0; i < rows.size(); ++i {
            self._expand_into(&(rows)[i], unsafe &out)
        }

        return out
    }

    priv fn _expand_into(self, r: *PatRow, out: unsafe *cxx::std::vector<PatRow>) {
        if r->cols.size() == 0
            || r->cols[0] == &null
            || r->cols[0]->kind != PatternKind::AlternationPattern {
            out->push_back(*r)
            return
        }

        var unsafe *a = cast<AlternationPattern>(r->cols[0])
        for var k: usize = 0; k < a->alternatives.size(); ++k {
            var nr = *r
            nr.cols[0] = a->alternatives[k]
            self._expand_into(&nr, out)
        }
    }

    /// Rows of \p rows whose head survives \p c, with the head replaced by
    /// its \p c.arity sub-columns.
    fn specialize(self,
                  @inout rows: cxx::std::vector<PatRow>,
                  const c:     Ctor) -> cxx::std::vector<PatRow> {
        var out = cxx::std::vector<PatRow>()
        for var i: usize = 0; i < rows.size(); ++i {
            var        *r = &(rows)[i]
            var unsafe *h = r->cols[0]
            var        hc = self.ctor_of(h)
            if !self.covers(hc, c) {
                continue
            }

            var nr = PatRow{}
            nr.arm     = r->arm
            nr.alt     = r->alt
            nr.guarded = r->guarded
            nr.cols    = self.sub_columns(h, c.arity)
            for var k: usize = 1; k < r->cols.size(); ++k {
                nr.cols.push_back(r->cols[k])
            }

            out.push_back(nr)
        }

        return out
    }

    /// Rows whose head is a wildcard, head dropped.
    fn default_rows(self, @inout rows: cxx::std::vector<PatRow>) -> cxx::std::vector<PatRow> {
        var out = cxx::std::vector<PatRow>()
        for var i: usize = 0; i < rows.size(); ++i {
            var *r = &(rows)[i]
            if !self.is_wild(r->cols[0]) {
                continue
            }

            var nr = PatRow{}
            nr.arm     = r->arm
            nr.alt     = r->alt
            nr.guarded = r->guarded
            for var k: usize = 1; k < r->cols.size(); ++k {
                nr.cols.push_back(r->cols[k])
            }

            out.push_back(nr)
        }

        return out
    }

    /// The domain of column 0: read off the first head that carries a type.
    fn head_domain(self, const rows: cxx::std::vector<PatRow>) -> Domain {
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *h = (rows)[i].cols[0]
            if self.is_wild(h) {
                continue
            }

            if h->type_ != &null {
                return self.domain_of(h->type_)
            }
        }

        return Domain{}
    }

    /// # integer segments

    /// Cut [lo, hi] at every boundary of the Int heads in column 0, so each
    /// segment is either inside or outside each head's range.
    fn int_segments(self,
                    const rows: cxx::std::vector<PatRow>,
                    lo:         u64,
                    hi:         u64) -> cxx::std::vector<Ctor> {
        var cuts = cxx::std::vector<u64>() // segment starts, beyond `lo`
        for var i: usize = 0; i < rows.size(); ++i {
            var unsafe *h = (rows)[i].cols[0]
            if self.is_wild(h) {
                continue
            }

            var c = self.ctor_of(h)
            if c.kind != CtorKind::Int {
                continue
            }

            if c.lo > lo && c.lo <= hi {
                cuts.push_back(c.lo)
            }

            if c.hi >= lo && c.hi < hi {
                cuts.push_back(c.hi + (1 as u64))
            }
        }

        sort_unique_keys(unsafe &cuts)
        var out   = cxx::std::vector<Ctor>()
        var start = lo
        for var i: usize = 0; i <= cuts.size(); ++i {
            var end = if (i < cuts.size()) => (cuts[i] - (1 as u64)) else => hi
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


    /// # rendering

    /// A witness for constructor \p c of domain \p d with sub-witnesses \p subs.
    fn render(self, d: Domain, const c: Ctor, subs: unsafe *cxx::std::vector<string>) -> string {
        match c.kind {
            case CtorKind::Wild {
                return "_"
            } case CtorKind::Bool {
                return if (c.lo == (1 as u64)) => ("true") else => "false"
            } case CtorKind::Int {
                return self.range_str(d, c.lo, c.hi)
            } case CtorKind::Opaque {
                return "_"
            } case CtorKind::Variant {
                var        name = "_"
                var unsafe *vv  = adt_variant_at(d.en, c.index as usize)
                if vv != &null {
                    name = "." + self.tu.decl_name(unsafe (vv as unsafe *Decl))
                }

                // An element of a pack-expanded variant reads as the pattern
                // that picks it: its pack field's binder, typed.
                var k = adt_expansion_at(d.en, c.index as usize)
                if k >= 0 && self._all_wild(*subs) {
                    var ve = VariadicEnum(self.sc)
                    for var j: usize = 0; j < vv->payload.size(); ++j {
                        if !ve.is_pack_field(vv->payload[j]) {
                            continue
                        }

                        var unsafe *et = ve.field_at(d.ty, vv->payload[j], k as usize)
                        var        tn  = if (et == &null) => ("?") else => self.tu.str(et)
                        return name + "(var " + self.tu.decl_name(vv->payload[j]) + ": " + tn + ")"
                    }
                }

                if self._all_wild(*subs) {
                    return name
                }

                return name + "(" + self._join(*subs) + ")"
            } case CtorKind::Record {
                // A tuple's witness reads as a tuple is written: `(false, _)`.
                if d.rec != &null && self.tu.is_tuple_decl(d.rec) {
                    return "(" + self._join(*subs) + ")"
                }

                var name = "_"
                if d.rec != &null {
                    name = self.tu.decl_name(d.rec)
                }

                if self._all_wild(*subs) {
                    return name
                }

                return name + "(" + self._join(*subs) + ")"
            }
        }
    }

    priv fn _all_wild(self, const subs: cxx::std::vector<string>) -> bool {
        for var i: usize = 0; i < subs.size(); ++i {
            if (subs)[i] != "_" {
                return false
            }
        }

        return true
    }

    priv fn _join(self, const subs: cxx::std::vector<string>) -> string {
        var s = ""
        for var i: usize = 0; i < subs.size(); ++i {
            if i > 0 {
                s = s + ", "
            }

            s = s + (subs)[i]
        }

        return s
    }
}
