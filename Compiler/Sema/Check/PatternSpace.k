/// --- The Kairo Project ----------------------- Sema/Check/PatternSpace.k --- ///
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import Sema::Check::ConstEval::*;
import AST::Context::ASTContext::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import Sema::Type::VariadicEnum::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Patterns::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::PatternKind::*;
import AST::Kind::ExprKind::*;
import Token::Token::*;
import Token::TokenKind::*;

/// What a column ranges over. See the file header.
enum DomainKind derives u8 {
    Unknown = 0,
    ClosedEnum,
    OpenEnum,
    Bool,
    Int,
    Record,
    Opaque,
}

struct Domain {
    var kind:    DomainKind = DomainKind::Unknown;
    var en:      *EnumDecl  = &null;   ///< ClosedEnum / OpenEnum: the pattern decl.
    var rec:     *Decl      = &null;   ///< Record: the pattern decl.
    var bits:    u32        = 0;       ///< Int.
    var signed:  bool       = false;   ///< Int.
    var max_key: u64        = 0;       ///< Int: the largest key (2^bits - 1).
    var arity:   u32        = 0;       ///< Record.
    /// ClosedEnum: its constructors at this type, in EXPANDED index order
    /// (adt_variant_at): the variants, a pack-expanded one once per element.
    var nctors:  u32        = 0;
    var ty:      *Type      = &null;   ///< ClosedEnum: the column's type, which a pack's elements are read off.
}

/// What a pattern's head tests. `Wild` matches every value of the column.
enum CtorKind derives u8 {
    Wild = 0,
    Variant,    ///< `index` = position in the enum's variant list.
    Bool,       ///< `lo` = 0 (false) or 1 (true).
    Int,        ///< `lo..=hi` in key space.
    Record,
    Opaque,     ///< `key` = identity; equal keys are the same value.
}

struct Ctor {
    var kind:  CtorKind = CtorKind::Wild;
    var index: u32      = 0;
    var lo:    u64      = 0;
    var hi:    u64      = 0;
    var key:   string;
    var arity: u32      = 0;   ///< sub-columns this constructor opens.
}

/// One row of a pattern matrix. A null column is a wildcard; so is a
/// WildcardPattern or a BindingPattern (X has already rejected an ascribed
/// binder whose type does not match its column).
struct PatRow {
    var cols:    vec::<*Pattern>;
    var arm:     u32  = 0;        ///< index of the MatchCase this row came from.
    var alt:     u32  = 0;        ///< index of the alternative within the arm.
    var guarded: bool = false;
}

class PatternSpace {
    pub var sc: *SemaContext;
    pub var tu: TypeUtil;
    pub var ce: ConstEval;

    fn PatternSpace(self) { self.sc = &null; }
    fn PatternSpace(self, sc: *SemaContext) {
        self.sc = sc;
        self.tu = TypeUtil(sc);
        self.ce = ConstEval(sc);
    }

    // === domains ============================================================

    /// The domain of a column whose values have type \p t.
    fn domain_of(self, t: *Type) -> Domain {
        var d = Domain{};
        if t == &null { return d; }
        var u = canon_unqual(self.tu.as_value(t));
        if u == &null { return d; }
        if u->is_dependent() { return d; }

        if self.tu.is_bool(u) { d.kind = DomainKind::Bool; return d; }

        if self.tu.is_integer(u) {
            var bits = self.tu.int_bits(u);
            if (bits == 0) || (bits > 64) { d.kind = DomainKind::Opaque; return d; }
            d.kind    = DomainKind::Int;
            d.bits    = u32(bits);
            d.signed  = self.tu.is_signed_int(u);
            d.max_key = (u64(0) - u64(1)) if (bits == 64) else ((u64(1) << u64(bits)) - u64(1));
            return d;
        }

        if isa::<RecordType>(u) {
            if self.tu.is_string(u) { d.kind = DomainKind::Opaque; return d; }
            var rd = self.tu.pattern_of(cast::<RecordType>(u)->decl);
            var en = dyn_cast::<EnumDecl>(rd);
            if en != &null {
                d.en = en;
                d.kind = (DomainKind::OpenEnum) if (self.is_open_enum(en)) else (DomainKind::ClosedEnum);
                d.ty = u;
                d.nctors = u32(VariadicEnum(self.sc).ctor_count(en, u));
                return d;
            }
            if isa::<StructDecl>(rd) || isa::<ClassDecl>(rd) {
                if decl_is_imported(rd) { d.kind = DomainKind::Opaque; return d; }
                d.kind  = DomainKind::Record;
                d.rec   = rd;
                d.arity = u32(self.instance_field_count(rd));
                return d;
            }
        }

        d.kind = DomainKind::Opaque;
        return d;
    }

    /// An enum whose values are not limited to its variants: an imported C++
    /// enum, or a flags enum. Flags are inferred from the WRITTEN discriminant
    /// syntax -- a `|` or `<<` at its top -- never from the numeric values:
    /// `West = 3 = East | South` in a default-numbered enum is a coincidence.
    fn is_open_enum(self, en: *EnumDecl) -> bool {
        if en == &null { return false; }
        if en->is_imported() { return true; }
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if (v == &null) || (v->discriminant == &null) { continue; }
            var e = self.tu.strip_parens(v->discriminant);
            if (e == &null) || (!isa::<BinaryOperatorExpr>(e)) { continue; }
            var k = cast::<BinaryOperatorExpr>(e)->op_token.kind;
            if (k == TokenKind::OpPipe) || (k == TokenKind::OpLessLess) || (k == TokenKind::KwBitor) { return true; }
        }
        return false;
    }

    /// Fields a record pattern destructures: the non-static ones, in order.
    fn instance_fields(self, rd: *Decl) -> vec::<*FieldDecl> {
        var out = vec::<*FieldDecl>();
        var fields = create_empty_frozen_list::<*FieldDecl>();
        if isa::<StructDecl>(rd)     { fields = cast::<StructDecl>(rd)->fields; }
        else if isa::<ClassDecl>(rd) { fields = cast::<ClassDecl>(rd)->fields; }
        for var i: usize = 0; i < fields.size(); ++i {
            var f = fields[i];
            if (f == &null) || f->is_static() { continue; }
            out.push_back(f);
        }
        return out;
    }

    fn instance_field_count(self, rd: *Decl) -> usize { return self.instance_fields(rd).size(); }

    /// The variant's position in \p en, or -1.
    fn variant_index(self, en: *EnumDecl, v: *EnumVariantDecl) -> i32 {
        if (en == &null) || (v == &null) { return -1; }
        for var i: usize = 0; i < en->variants.size(); ++i {
            if en->variants[i] == v { return i32(i); }
        }
        // A generic enum's instance may carry its own variant decls: match by
        // name, which is unique within one enum.
        var want = self.tu.decl_name(static_cast::<*Decl>(v));
        for var i: usize = 0; i < en->variants.size(); ++i {
            var o = en->variants[i];
            if (o != &null) && (self.tu.decl_name(static_cast::<*Decl>(o)) == want) { return i32(i); }
        }
        return -1;
    }

    // === integer constants ==================================================

    /// Evaluate \p e as an integer constant. A value past 64 bits is no
    /// key of any Int domain, so it reads as not a constant here.
    fn eval_int(self, e: *Expr) -> IntConst {
        var c = self.ce.eval_int(e);
        if c.overflow { c.ok = false; }
        return c;
    }

    /// \p c as a key of \p d, or false when it is out of the type's range.
    fn key_of(self, d: Domain, c: IntConst, out: *u64) -> bool {
        if (!c.ok) || (d.kind != DomainKind::Int) { return false; }
        if !d.signed {
            if c.neg { return false; }
            if c.mag > d.max_key { return false; }
            (*out) = c.mag;
            return true;
        }
        var bias = u64(1) << u64(d.bits - 1);
        if c.neg {
            if c.mag > bias { return false; }
            (*out) = bias - c.mag;
            return true;
        }
        if c.mag > (bias - u64(1)) { return false; }
        (*out) = bias + c.mag;
        return true;
    }

    /// The source spelling of key \p k.
    fn key_str(self, d: Domain, k: u64) -> string {
        if !d.signed { return f"{k}"; }
        var bias = u64(1) << u64(d.bits - 1);
        if k >= bias { return f"{k - bias}"; }
        return f"-{bias - k}";
    }

    fn range_str(self, d: Domain, lo: u64, hi: u64) -> string {
        if lo == hi { return self.key_str(d, lo); }
        return self.key_str(d, lo) + "..=" + self.key_str(d, hi);
    }

    // === heads ==============================================================

    /// A pattern that matches every value of its column.
    fn is_wild(self, p: *Pattern) -> bool {
        if p == &null { return true; }
        return (p->kind == PatternKind::WildcardPattern) || (p->kind == PatternKind::BindingPattern);
    }

    /// The constructor \p p tests. Never called on an AlternationPattern
    /// (rows are expanded first) or a wildcard.
    fn ctor_of(self, p: *Pattern) -> Ctor {
        var c = Ctor{};
        if self.is_wild(p) { return c; }
        var d = self.domain_of(p->type_);

        switch p->kind {
            case PatternKind::LiteralPattern {
                var v = cast::<LiteralPattern>(p)->value;
                if (v != &null) && isa::<BooleanLiteralExpr>(self.tu.strip_parens(v)) {
                    c.kind = CtorKind::Bool;
                    c.lo   = (u64(1)) if (cast::<BooleanLiteralExpr>(self.tu.strip_parens(v))->value) else (u64(0));
                    c.hi   = c.lo;
                    return c;
                }
                if d.kind == DomainKind::Int {
                    var k: u64 = 0;
                    if self.key_of(d, self.eval_int(v), &k) {
                        c.kind = CtorKind::Int; c.lo = k; c.hi = k;
                        return c;
                    }
                }
                return self._opaque(self._expr_key(v));
            }

            case PatternKind::RangePattern {
                var r = cast::<RangePattern>(p);
                if d.kind == DomainKind::Int {
                    var lo: u64 = 0;
                    var hi: u64 = d.max_key;
                    var ok = true;
                    if r->lo != &null { ok = self.key_of(d, self.eval_int(r->lo), &lo) && ok; }
                    if r->hi != &null {
                        ok = self.key_of(d, self.eval_int(r->hi), &hi) && ok;
                        if ok && (!r->is_inclusive) {
                            if hi == u64(0) { ok = false; }   // empty: X reported it.
                            else { hi = hi - u64(1); }
                        }
                    }
                    if ok && (lo <= hi) {
                        c.kind = CtorKind::Int; c.lo = lo; c.hi = hi;
                        return c;
                    }
                }
                return self._opaque(f"range:{self.sc->ctx->get_spelling(p->range)}");
            }

            case PatternKind::TupleDestructurePattern {
                // Positional over the tuple's record: field i is element i.
                c.kind  = CtorKind::Record;
                c.arity = u32(cast::<TupleDestructurePattern>(p)->elements.size());
                return c;
            }

            case PatternKind::ConstructorPattern {
                return self._ctor_from_resolved(p, d);
            }

            case PatternKind::UnresolvedConstructorPattern {
                return self._ctor_from_resolved(p, d);
            }

            default {
                // Slices, recovery: a test this file cannot reason about.
                return self._opaque(f"pat:{reinterpret_cast::<u64>(p)}");
            }
        }
        return c;
    }

    priv fn _ctor_from_resolved(self, p: *Pattern, d: Domain) -> Ctor {
        var rd = p->resolved_decl;
        if rd == &null { return self._opaque(f"pat:{reinterpret_cast::<u64>(p)}"); }

        var v = dyn_cast::<EnumVariantDecl>(rd);
        if v != &null {
            if d.kind == DomainKind::ClosedEnum {
                var idx = self.variant_index(d.en, v);
                if idx >= 0 {
                    // Element k of a pack-expanded variant is its own
                    // constructor, at the variant's position plus k.
                    if v->is_pack_expansion && (p->pack_index >= 0) { idx += p->pack_index; }
                    var c = Ctor{};
                    c.kind  = CtorKind::Variant;
                    c.index = u32(idx);
                    c.arity = u32(v->payload.size());
                    return c;
                }
            }
            // Open enum: a variant is one value among unlisted others.
            return self._opaque(f"variant:{self.tu.decl_name(static_cast::<*Decl>(v))}");
        }

        if isa::<StructDecl>(rd) || isa::<ClassDecl>(rd) {
            var c = Ctor{};
            c.kind  = CtorKind::Record;
            c.arity = u32(self.instance_field_count(rd));
            return c;
        }

        var vd = dyn_cast::<VariableDecl>(rd);
        if vd != &null {
            if d.kind == DomainKind::Int {
                var k: u64 = 0;
                if self.key_of(d, self.eval_int(vd->init), &k) {
                    var c = Ctor{};
                    c.kind = CtorKind::Int; c.lo = k; c.hi = k;
                    return c;
                }
            }
            return self._opaque(f"const:{reinterpret_cast::<u64>(vd)}");
        }

        return self._opaque(f"pat:{reinterpret_cast::<u64>(p)}");
    }

    priv fn _opaque(self, key: string) -> Ctor {
        var c = Ctor{};
        c.kind = CtorKind::Opaque;
        c.key  = key;
        return c;
    }

    /// Identity of a literal value: its spelling. Two spellings of one value
    /// (`"a"` / `"\x61"`) compare unequal, which only ever keeps an arm alive.
    priv fn _expr_key(self, e: *Expr) -> string {
        if e == &null { return "null-expr"; }
        var s = self.tu.strip_parens(e);
        if isa::<NullLiteralExpr>(s) { return "null"; }
        return f"lit:{self.sc->ctx->get_spelling(s->range)}";
    }

    /// Does a row whose head is \p h survive specialization by \p c? Integer
    /// segments are cut so that containment is all-or-nothing.
    fn covers(self, h: Ctor, c: Ctor) -> bool {
        if h.kind == CtorKind::Wild { return true; }
        if h.kind != c.kind { return false; }
        switch c.kind {
            case CtorKind::Variant { return h.index == c.index; }
            case CtorKind::Bool    { return h.lo == c.lo; }
            case CtorKind::Int     { return (h.lo <= c.lo) && (c.hi <= h.hi); }
            case CtorKind::Opaque  { return h.key == c.key; }
            case CtorKind::Record  { return true; }
            default { return false; }
        }
        return false;
    }

    // === sub-columns ========================================================

    /// The \p arity sub-columns of \p p under its own constructor. A field the
    /// pattern does not name is a wildcard (null).
    fn sub_columns(self, p: *Pattern, arity: u32) -> vec::<*Pattern> {
        var out = vec::<*Pattern>();
        for var i: u32 = 0; i < arity; ++i { out.push_back(&null); }
        if self.is_wild(p) { return out; }

        if p->kind == PatternKind::TupleDestructurePattern {
            var t = cast::<TupleDestructurePattern>(p);
            for var i: usize = 0; (i < t->elements.size()) && (i < usize(arity)); ++i { out[i] = t->elements[i]; }
            return out;
        }

        var subs = create_empty_frozen_list::<*Pattern>();
        if p->kind == PatternKind::ConstructorPattern           { subs = cast::<ConstructorPattern>(p)->subpatterns; }
        else if p->kind == PatternKind::UnresolvedConstructorPattern { subs = cast::<UnresolvedConstructorPattern>(p)->subpatterns; }
        else { return out; }

        var fields = self.fields_of_resolved(p->resolved_decl);
        for var i: usize = 0; i < subs.size(); ++i {
            var sp = subs[i];
            if (sp == &null) || (sp->field_decl == &null) { continue; }
            for var k: usize = 0; (k < fields.size()) && (k < usize(arity)); ++k {
                if static_cast::<*Decl>(fields[k]) == sp->field_decl { out[k] = sp; break; }
            }
        }
        return out;
    }

    /// The fields a constructor head destructures, in declaration order:
    /// a variant's payload, or a record's instance fields.
    fn fields_of_resolved(self, rd: *Decl) -> vec::<*FieldDecl> {
        var out = vec::<*FieldDecl>();
        if rd == &null { return out; }
        var v = dyn_cast::<EnumVariantDecl>(rd);
        if v != &null {
            for var i: usize = 0; i < v->payload.size(); ++i { out.push_back(v->payload[i]); }
            return out;
        }
        if isa::<StructDecl>(rd) || isa::<ClassDecl>(rd) { return self.instance_fields(rd); }
        return out;
    }

    // === rows ===============================================================

    /// Expand every row whose head is an alternation into one row per
    /// alternative, recursively, keeping arm / alt / guard.
    fn expand_heads(self, rows: *vec::<PatRow>) -> vec::<PatRow> {
        var out = vec::<PatRow>();
        for var i: usize = 0; i < rows->size(); ++i {
            self._expand_into(&(*rows)[i], &out);
        }
        return out;
    }

    priv fn _expand_into(self, r: *PatRow, out: *vec::<PatRow>) {
        if (r->cols.size() == 0) || (r->cols[0] == &null) || (r->cols[0]->kind != PatternKind::AlternationPattern) {
            out->push_back(*r);
            return;
        }
        var a = cast::<AlternationPattern>(r->cols[0]);
        for var k: usize = 0; k < a->alternatives.size(); ++k {
            var nr = *r;
            nr.cols[0] = a->alternatives[k];
            self._expand_into(&nr, out);
        }
    }

    /// Rows of \p rows whose head survives \p c, with the head replaced by
    /// its \p c.arity sub-columns.
    fn specialize(self, rows: *vec::<PatRow>, c: Ctor) -> vec::<PatRow> {
        var out = vec::<PatRow>();
        for var i: usize = 0; i < rows->size(); ++i {
            var r = &(*rows)[i];
            var h = r->cols[0];
            var hc = self.ctor_of(h);
            if !self.covers(hc, c) { continue; }
            var nr = PatRow{};
            nr.arm = r->arm; nr.alt = r->alt; nr.guarded = r->guarded;
            nr.cols = self.sub_columns(h, c.arity);
            for var k: usize = 1; k < r->cols.size(); ++k { nr.cols.push_back(r->cols[k]); }
            out.push_back(nr);
        }
        return out;
    }

    /// Rows whose head is a wildcard, head dropped.
    fn default_rows(self, rows: *vec::<PatRow>) -> vec::<PatRow> {
        var out = vec::<PatRow>();
        for var i: usize = 0; i < rows->size(); ++i {
            var r = &(*rows)[i];
            if !self.is_wild(r->cols[0]) { continue; }
            var nr = PatRow{};
            nr.arm = r->arm; nr.alt = r->alt; nr.guarded = r->guarded;
            for var k: usize = 1; k < r->cols.size(); ++k { nr.cols.push_back(r->cols[k]); }
            out.push_back(nr);
        }
        return out;
    }

    /// The domain of column 0: read off the first head that carries a type.
    fn head_domain(self, rows: *vec::<PatRow>) -> Domain {
        for var i: usize = 0; i < rows->size(); ++i {
            var h = (*rows)[i].cols[0];
            if self.is_wild(h) { continue; }
            if h->type_ != &null { return self.domain_of(h->type_); }
        }
        return Domain{};
    }

    // === integer segments ===================================================

    /// Cut [lo, hi] at every boundary of the Int heads in column 0, so each
    /// segment is either inside or outside each head's range.
    fn int_segments(self, rows: *vec::<PatRow>, lo: u64, hi: u64) -> vec::<Ctor> {
        var cuts = vec::<u64>();   // segment starts, beyond `lo`
        for var i: usize = 0; i < rows->size(); ++i {
            var h = (*rows)[i].cols[0];
            if self.is_wild(h) { continue; }
            var c = self.ctor_of(h);
            if c.kind != CtorKind::Int { continue; }
            if (c.lo > lo) && (c.lo <= hi) { self._add_cut(&cuts, c.lo); }
            if (c.hi >= lo) && (c.hi < hi) { self._add_cut(&cuts, c.hi + u64(1)); }
        }
        // insertion sort: the cut list is O(rows) and rows are few.
        for var i: usize = 1; i < cuts.size(); ++i {
            var x = cuts[i];
            var j = i;
            while (j > 0) && (cuts[j - 1] > x) { cuts[j] = cuts[j - 1]; j = j - 1; }
            cuts[j] = x;
        }
        var out = vec::<Ctor>();
        var start = lo;
        for var i: usize = 0; i <= cuts.size(); ++i {
            var end = (cuts[i] - u64(1)) if (i < cuts.size()) else (hi);
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

    // === rendering ==========================================================

    /// A witness for constructor \p c of domain \p d with sub-witnesses \p subs.
    fn render(self, d: Domain, c: Ctor, subs: *vec::<string>) -> string {
        switch c.kind {
            case CtorKind::Wild   { return "_"; }
            case CtorKind::Bool   { return ("true") if (c.lo == u64(1)) else ("false"); }
            case CtorKind::Int    { return self.range_str(d, c.lo, c.hi); }
            case CtorKind::Opaque { return "_"; }
            case CtorKind::Variant {
                var name = "_";
                var vv = adt_variant_at(d.en, usize(c.index));
                if vv != &null { name = "." + self.tu.decl_name(static_cast::<*Decl>(vv)); }
                // An element of a pack-expanded variant reads as the pattern
                // that picks it: its pack field's binder, typed.
                var k = adt_expansion_at(d.en, usize(c.index));
                if (k >= 0) && self._all_wild(subs) {
                    var ve = VariadicEnum(self.sc);
                    for var j: usize = 0; j < vv->payload.size(); ++j {
                        if !ve.is_pack_field(vv->payload[j]) { continue; }
                        var et = ve.field_at(d.ty, vv->payload[j], usize(k));
                        var tn = ("?") if (et == &null) else (self.tu.str(et));
                        return name + "(var " + self.tu.decl_name(static_cast::<*Decl>(vv->payload[j])) + ": " + tn + ")";
                    }
                }
                if self._all_wild(subs) { return name; }
                return name + "(" + self._join(subs) + ")";
            }
            case CtorKind::Record {
                // A tuple's witness reads as a tuple is written: `(false, _)`.
                if (d.rec != &null) && self.tu.is_tuple_decl(d.rec) { return "(" + self._join(subs) + ")"; }
                var name = "_";
                if d.rec != &null { name = self.tu.decl_name(d.rec); }
                if self._all_wild(subs) { return name; }
                return name + "(" + self._join(subs) + ")";
            }
            default { return "_"; }
        }
        return "_";
    }

    priv fn _all_wild(self, subs: *vec::<string>) -> bool {
        for var i: usize = 0; i < subs->size(); ++i { if (*subs)[i] != "_" { return false; } }
        return true;
    }

    priv fn _join(self, subs: *vec::<string>) -> string {
        var s = "";
        for var i: usize = 0; i < subs->size(); ++i {
            if i > 0 { s = s + ", "; }
            s = s + (*subs)[i];
        }
        return s;
    }
}