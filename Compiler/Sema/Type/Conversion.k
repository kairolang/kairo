/// --- The Kairo Project ---------------------- Sema/Type/Conversion.k --- ///
///
///   \brief THE conversion relation. One concept in the whole language:
///          classify(S, T) over primitives per the Primitive Conversion
///          Lattice, plus the non-primitive implicit forms (`T -> T?`,
///          `*Derived -> *Base`, `*T -> *const T`, `! -> anything`).
///
///   \detail
///     Two ranks only, and no ordering inside rank 2 (lattice §7): Exact is
///     I, Converted is everything W-shaped. `-fno-implicit-conv` demotes W to
///     E here and nowhere else, which is what makes the flag a strict subset:
///     it can remove a candidate, never reorder two.
///
///     Qualifiers. A canonical carries its cv (CanonicalTypes.k), and this
///     relation reads them in exactly two places. At the TOP level of a value
///     they are not part of the conversion at all: reading a `const i32`
///     yields an `i32` ([conv.lval]) and initializing a `const i32` from an
///     `i32` is copy-initialization, so both are Exact and implicit() strips
///     them before anything else looks. UNDER a pointer they are: `*i32 ->
///     *const i32` is the qualification conversion ([conv.qual]), Converted;
///     `*const i32 -> *i32` is nothing. Reference binding sees the referee's
///     cv as C++ does: a plain `T&` takes no const lvalue.
///
///     The primitive relation is rule-based here (R1-R5, §4). The lattice doc
///     asks for a table-generated `classify` with property tests; that is a
///     tooling follow-up and the rules below are the table's oracle until
///     then. Every ordered pair returns exactly one class; there is no
///     `default` fallthrough that could hide a missing cell.
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
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::TypeKind::*;

/// \enum ConvClass
/// \brief Lattice §1. The class of an ordered primitive pair.
enum ConvClass derives u8 {
    I = 0,  ///< identity.
    W,      ///< implicit: value-preserving, target-independent.
    E,      ///< explicit: `as` required.
    U,      ///< `as` inside an unsafe context.
    X,      ///< no cast exists.
}

/// \enum ImplicitRank
/// \brief What a call site / assignment gets from an implicit sequence.
enum ImplicitRank derives u8 {
    Exact = 0,
    Converted,
    None,
}

/// \enum RefRel
/// \brief How an argument's VALUE type relates to a reference parameter's
///        referee, before its value category is consulted (ref_binding).
enum RefRel derives u8 {
    None = 0,   ///< binds at no category.
    Same,       ///< the referee itself.
    Derived,    ///< a class derived from the referee: binds the base subobject.
    Converts,   ///< converts implicitly: binding goes through a temporary.
}

/// Can an untyped integer literal of the given magnitude take builtin \p bk?
/// \p negative is the unary-minus fold; the magnitude then may reach 2^(bits-1).
fn literal_fits_int(lo: u64, hi: u64, big: bool, negative: bool, bk: BuiltinKind, ptr_bits: usize) -> bool {
    if !builtin_info(bk)->is_integer() { return false; }
    if big { return false; }
    var bits = builtin_info(bk)->bits;
    if bits == 0 { bits = ptr_bits; }
    var is_signed = builtin_info(bk)->is_signed();
    if negative && (!is_signed) { return false; }

    // magnitude limit as a 128-bit number. Every shift below is done on a
    // u64 ONE: a bare `1` is an i32, and `1 << 63` on one is undefined
    // behaviour, not a large number.
    var one: u64 = 1;
    if bits >= 128 {
        // anything that fit in 128 bits is fine, except the signed top bit.
        if !is_signed { return true; }
        if bits > 128 { return true; }
        if negative { return (hi < (one << 63)) || ((hi == (one << 63)) && (lo == 0)); }
        return hi < (one << 63);
    }
    if hi != 0 { return false; }
    var limit_bits = (bits - 1) if (is_signed) else (bits);
    if limit_bits >= 64 { return true; }
    var limit: u64 = (one << limit_bits);   // exclusive for non-negative
    if negative { return lo <= limit; }
    return lo < limit;
}

class Conversion {
    pub var sc: *SemaContext;
    pub var tu: TypeUtil;

    fn Conversion(self) { self.sc = &null; }
    fn Conversion(self, sc: *SemaContext) {
        self.sc = sc;
        self.tu = TypeUtil(sc);
    }

    fn implicit_enabled(self) -> bool {
        return self.sc->opts.on(self.sc->opts.implicit_conv, true);
    }

    // === primitive lattice ==================================================

    fn classify(self, s: BuiltinKind, t: BuiltinKind) -> ConvClass {
        if s == t { return ConvClass::I; }
        if (s == BuiltinKind::Void) || (t == BuiltinKind::Void) { return ConvClass::X; }
        if (s == BuiltinKind::Never) { return ConvClass::W; }
        if (t == BuiltinKind::Never) { return ConvClass::X; }

        var si = builtin_info(s)->is_integer();
        var ti = builtin_info(t)->is_integer();
        var sf = builtin_info(s)->is_float();
        var tf = builtin_info(t)->is_float();

        if si && ti { return self._int_int(s, t); }
        if si && tf { return self._int_float(s, t); }
        if sf && ti { return ConvClass::E; }
        if sf && tf { return self._float_float(s, t); }

        // non-numeric primitives: §4.
        if s == BuiltinKind::Bool { return (ConvClass::E) if (ti) else (ConvClass::X); }
        if t == BuiltinKind::Bool { return (ConvClass::E) if (si) else (ConvClass::X); }
        if s == BuiltinKind::Char { return (ConvClass::E) if (ti) else (ConvClass::X); }
        if t == BuiltinKind::Char { return (ConvClass::E) if (si) else (ConvClass::X); }
        if s == BuiltinKind::Byte { return (ConvClass::E) if (ti) else (ConvClass::X); }
        if t == BuiltinKind::Byte { return (ConvClass::E) if (si) else (ConvClass::X); }
        return ConvClass::X;
    }

    priv fn _is_ptr_int(self, b: BuiltinKind) -> bool {
        return (b == BuiltinKind::USize) || (b == BuiltinKind::ISize);
    }

    priv fn _int_int(self, s: BuiltinKind, t: BuiltinKind) -> ConvClass {
        if self._is_ptr_int(s) || self._is_ptr_int(t) { return ConvClass::E; }   // §4
        var sb = builtin_info(s)->bits;
        var tb = builtin_info(t)->bits;
        if (sb > 64) || (tb > 64) { return ConvClass::E; }                       // R5
        var ss = builtin_info(s)->is_signed();
        var ts = builtin_info(t)->is_signed();
        if (!ss) && (!ts) { return (ConvClass::W) if (tb > sb) else (ConvClass::E); } // R1
        if ss && ts       { return (ConvClass::W) if (tb > sb) else (ConvClass::E); } // R1
        if (!ss) && ts    { return (ConvClass::W) if (tb > sb) else (ConvClass::E); } // R2 uN->iM
        return ConvClass::E;                                                     // R2 iN->uM never
    }

    priv fn _mantissa(self, f: BuiltinKind) -> usize {
        switch f {
            case BuiltinKind::F16  { return 11; }
            case BuiltinKind::BF16 { return 8;  }
            case BuiltinKind::F32  { return 24; }
            case BuiltinKind::F64  { return 53; }
            default                { return 0;  }   // f8*, f80, f128+: never a W target (R5).
        }
    }

    priv fn _int_float(self, s: BuiltinKind, t: BuiltinKind) -> ConvClass {
        if self._is_ptr_int(s) { return ConvClass::E; }
        var sb = builtin_info(s)->bits;
        if sb > 64 { return ConvClass::E; }
        var m = self._mantissa(t);
        if m == 0 { return ConvClass::E; }
        return (ConvClass::W) if (sb <= m) else (ConvClass::E);                 // R3
    }

    priv fn _float_float(self, s: BuiltinKind, t: BuiltinKind) -> ConvClass {
        // R4, plus bf16 -> f32/f64 which is exact by construction.
        if (s == BuiltinKind::F16) && ((t == BuiltinKind::F32) || (t == BuiltinKind::F64)) { return ConvClass::W; }
        if (s == BuiltinKind::BF16) && ((t == BuiltinKind::F32) || (t == BuiltinKind::F64)) { return ConvClass::W; }
        if (s == BuiltinKind::F32) && (t == BuiltinKind::F64) { return ConvClass::W; }
        return ConvClass::E;
    }

    // === the implicit sequence ==============================================

    /// Rank of \p from -> \p to as an implicit conversion. Both canonical.
    fn implicit(self, from: *Type, to: *Type) -> ImplicitRank {
        if (from == &null) || (to == &null) { return ImplicitRank::None; }
        if from == to { return ImplicitRank::Exact; }
        if self.tu.is_never(from) { return ImplicitRank::Converted; }

        // C++ references. Only imported signatures carry them (Kairo has no
        // spelling), so this is the rule every `const T&` parameter in a
        // header is judged by.
        if isa::<CXXLValueRefType>(to) || isa::<CXXRValueRefType>(to) { return self._bind_ref(from, to); }
        // A reference READ as a value is its referee (lvalue-to-rvalue): a
        // `const T&` return converts wherever a T would.
        if isa::<CXXLValueRefType>(from) { return self.implicit(cast::<CXXLValueRefType>(from)->referee, to); }
        if isa::<CXXRValueRefType>(from) { return self.implicit(cast::<CXXRValueRefType>(from)->referee, to); }

        // Top-level cv is not part of a VALUE: the read strips it and
        // copy-initialization ignores it on the target. `const i32 -> i32`
        // and `i32 -> const i32` are both the identity.
        var fu = canon_unqual(from);
        var tq = canon_unqual(to);
        if fu == tq { return ImplicitRank::Exact; }

        // primitives
        var fk = self.tu.kind_of(fu);
        var tk = self.tu.kind_of(tq);
        if (fk != BuiltinKind::COUNT) && (tk != BuiltinKind::COUNT) {
            if self.classify(fk, tk) == ConvClass::W {
                return (ImplicitRank::Converted) if (self.implicit_enabled()) else (ImplicitRank::None);
            }
            return ImplicitRank::None;
        }

        // T -> T?  (and *D -> *B?, i32 -> i64?, both via the inner)
        var to_inner = self.tu.nullable_inner(tq);
        if to_inner != &null {
            var from_inner = self.tu.nullable_inner(fu);
            if from_inner != &null {
                // T? -> U?: only when the inners relate; never Exact (different type).
                return (ImplicitRank::Converted) if (self.implicit(from_inner, to_inner) != ImplicitRank::None)
                       else (ImplicitRank::None);
            }
            return (ImplicitRank::Converted) if (self.implicit(fu, to_inner) != ImplicitRank::None)
                   else (ImplicitRank::None);
        }

        // Pointers: qualification ([conv.qual]) and derived-to-base, same
        // safety on both sides.
        var fp = self.tu.pointee(fu);
        var tp = self.tu.pointee(tq);
        if (fp != &null) && (tp != &null) {
            if self.tu.is_unsafe_ptr(fu) != self.tu.is_unsafe_ptr(tq) { return ImplicitRank::None; }
            // A qualifier the pointee loses is never implicit.
            if !self._quals_kept(fp, tp) { return ImplicitRank::None; }
            var fd = self.tu.record_decl(fp);
            var td = self.tu.record_decl(tp);
            if (fd != &null) && (td != &null) && (fd != td) && self.tu.derives_from(fd, td) {
                return ImplicitRank::Converted;
            }
            if self._qual_conv(fu, tq, true) { return ImplicitRank::Converted; }
            return ImplicitRank::None;
        }

        // `[T;]` -> `[T]`: a slice converts to the vector that owns a copy of
        // it. The one container rung in the lattice, and it is invariant in
        // the element -- `[D;] -> [B]` would copy through a base and slice
        // every element. (`[T;]` -> `const [T;]` is the cv rule above.)
        if self.tu.is_slice(fu) && self.tu.is_vector_like(tq) {
            var se = self.tu.container_elem(fu);
            var ve = self.tu.container_elem(tq);
            if (se != &null) && (se == ve) { return ImplicitRank::Converted; }
        }

        return ImplicitRank::None;
    }

    /// \p to's pointee carries every qualifier \p from's does.
    priv fn _quals_kept(self, fp: *Type, tp: *Type) -> bool {
        var fq = canon_quals(fp);
        var tq = canon_quals(tp);
        return (fq & (~tq)) == 0;
    }

    /// [conv.qual] over the pointee chains of two pointer types whose own
    /// top-level cv has already been stripped: at every level the target
    /// keeps the source's qualifiers, and a qualifier ADDED at any level but
    /// the first needs `const` on every level above it -- that is the rule
    /// that keeps `T** -> const T**` out while letting `T** -> const T*
    /// const*` in. \p const_above is that condition for the level being
    /// compared; the first level always passes it. True when the two chains
    /// meet on one canonical, i.e. the conversion is qualification and
    /// nothing else.
    priv fn _qual_conv(self, from: *Type, to: *Type, const_above: bool) -> bool {
        var fp = self.tu.pointee(from);
        var tp = self.tu.pointee(to);
        if (fp == &null) || (tp == &null) { return false; }
        if self.tu.is_unsafe_ptr(from) != self.tu.is_unsafe_ptr(to) { return false; }
        if !self._quals_kept(fp, tp) { return false; }
        if (canon_quals(fp) != canon_quals(tp)) && (!const_above) { return false; }
        var fpu = canon_unqual(fp);
        var tpu = canon_unqual(tp);
        if fpu == tpu { return true; }
        if (self.tu.pointee(fpu) == &null) || (self.tu.pointee(tpu) == &null) { return false; }
        return self._qual_conv(fpu, tpu, const_above && canon_has_const(tp));
    }

    /// Reference binding, C++'s ranking where Kairo can see it:
    ///
    ///   `T&` / `const T&` <- T         Exact (binding is an identity, not a conversion)
    ///   `T&`              <- const T   None  (drops const)
    ///   `const T&`        <- U, U->T   Converted (binds a temporary)
    ///   `B&` / `const B&` <- D, D:B    Converted (derived-to-base)
    ///   `T&&`             <- T / U->T  Converted
    ///
    /// The referee's cv is read off the referee (`const T&` is
    /// cxx_lref(qualified(CONST, T))); the source's is its own top-level cv,
    /// or its referee's when the source is itself a reference.
    ///
    /// Rvalue references rank Converted, never Exact: Conversion sees types,
    /// not value categories, so the C++ tiebreak that sends an lvalue to
    /// `const T&` and a temporary to `T&&` cannot be expressed here. Ranking
    /// `&&` lower makes a `(const T&, T&&)` overload pair resolve to the
    /// const& one for every argument -- a copy where C++ would move, but
    /// never an ambiguity.
    priv fn _bind_ref(self, from: *Type, to: *Type) -> ImplicitRank {
        var src = from;
        if isa::<CXXLValueRefType>(from)      { src = cast::<CXXLValueRefType>(from)->referee; }
        else if isa::<CXXRValueRefType>(from) { src = cast::<CXXRValueRefType>(from)->referee; }
        var sq = canon_quals(src);
        src = canon_unqual(src);

        if isa::<CXXRValueRefType>(to) {
            var rr = cast::<CXXRValueRefType>(to)->referee;
            if (sq & (~canon_quals(rr))) != 0 { return ImplicitRank::None; }
            var rru = canon_unqual(rr);
            if (src == rru) || (self.implicit(src, rru) != ImplicitRank::None) { return ImplicitRank::Converted; }
            return ImplicitRank::None;
        }

        var referee = cast::<CXXLValueRefType>(to)->referee;
        // A plain `T&` (or `volatile T&`) from a more-qualified lvalue: the
        // binding would drop a qualifier.
        if (sq & (~canon_quals(referee))) != 0 { return ImplicitRank::None; }
        var ru = canon_unqual(referee);
        if src == ru { return ImplicitRank::Exact; }
        var fd = self.tu.record_decl(src);
        var td = self.tu.record_decl(ru);
        if (fd != &null) && (td != &null) && (fd != td) && self.tu.derives_from(fd, td) {
            return ImplicitRank::Converted;
        }
        if canon_has_const(referee) && (self.implicit(src, ru) != ImplicitRank::None) { return ImplicitRank::Converted; }
        return ImplicitRank::None;
    }

    // === reference binding at an argument ([over.ics.ref]) ===================

    /// Binding an ARGUMENT of known value category to \p to, a C++ reference
    /// parameter. [over.ics.ref] reduced to what Kairo has:
    ///
    ///   `T&`        a non-const LVALUE of T                   Exact
    ///   `const T&`  any lvalue or rvalue of T                 Exact
    ///   `T&&`       an RVALUE (prvalue or xvalue) of T        Exact
    ///
    /// and outside that table, today's ranking on the referee: a derived
    /// class binds the base subobject at Converted under the same category
    /// rule, and a value that only CONVERTS to T binds a temporary at
    /// Converted -- viable for `const T&` and `T&&` whatever its category,
    /// never for a plain `T&`.
    ///
    /// Only an argument site knows the category. implicit() -- returns,
    /// initializers, the post-selection re-check -- keeps the category-blind
    /// _bind_ref, which accepts everything this accepts.
    fn ref_binding(self, to: *Type, cat: Expr::ValueCategory, from_const: bool, rel: RefRel) -> ImplicitRank {
        if rel == RefRel::None { return ImplicitRank::None; }
        var rvalue = (cat == Expr::ValueCategory::RValue) || (cat == Expr::ValueCategory::XValue);
        var lvalue = cat == Expr::ValueCategory::LValue;
        var exact  = rel == RefRel::Same;

        if isa::<CXXRValueRefType>(to) {
            if rel == RefRel::Converts { return ImplicitRank::Converted; }   // a temporary is an rvalue.
            if !rvalue { return ImplicitRank::None; }
            return (ImplicitRank::Exact) if (exact) else (ImplicitRank::Converted);
        }
        if !isa::<CXXLValueRefType>(to) { return ImplicitRank::None; }
        if canon_has_const(cast::<CXXLValueRefType>(to)->referee) {
            return (ImplicitRank::Exact) if (exact) else (ImplicitRank::Converted);
        }
        // Plain `T&`: a modifiable lvalue, and never a temporary.
        if (!lvalue) || from_const || (rel == RefRel::Converts) { return ImplicitRank::None; }
        return (ImplicitRank::Exact) if (exact) else (ImplicitRank::Converted);
    }

    /// \p src (a value type) against \p referee, cv of both ignored: the
    /// relation is between the objects, and whether the binding may drop a
    /// qualifier is ref_binding's question (its `from_const`).
    fn ref_rel(self, src: *Type, referee: *Type) -> RefRel {
        if (src == &null) || (referee == &null) { return RefRel::None; }
        var su = canon_unqual(src);
        var ru = canon_unqual(referee);
        if su == ru { return RefRel::Same; }
        var fd = self.tu.record_decl(su);
        var td = self.tu.record_decl(ru);
        if (fd != &null) && (td != &null) && (fd != td) && self.tu.derives_from(fd, td) { return RefRel::Derived; }
        if self.implicit(su, ru) != ImplicitRank::None { return RefRel::Converts; }
        return RefRel::None;
    }

    /// implicit() for an ARGUMENT whose category is known: a reference
    /// parameter goes through ref_binding, anything else is unchanged.
    fn implicit_arg(self, from: *Type, to: *Type, cat: Expr::ValueCategory, from_const: bool) -> ImplicitRank {
        if (from == &null) || (to == &null) { return ImplicitRank::None; }
        var to_l = isa::<CXXLValueRefType>(to);
        var to_r = isa::<CXXRValueRefType>(to);
        if (!to_l) && (!to_r) { return self.implicit(from, to); }
        // A reference-typed argument's value is its referee, and a const
        // one -- by its own top-level cv or its referee's -- is const
        // whatever its arm said.
        var src = from;
        if isa::<CXXLValueRefType>(from)      { src = cast::<CXXLValueRefType>(from)->referee; }
        else if isa::<CXXRValueRefType>(from) { src = cast::<CXXRValueRefType>(from)->referee; }
        var c = from_const || canon_has_const(src);
        var referee = (cast::<CXXLValueRefType>(to)->referee) if (to_l) else (cast::<CXXRValueRefType>(to)->referee);
        return self.ref_binding(to, cat, c, self.ref_rel(src, referee));
    }

    fn convertible(self, from: *Type, to: *Type) -> bool {
        return self.implicit(from, to) != ImplicitRank::None;
    }

    /// Branch join for if/match/try: the type both sides convert to, or null.
    /// The join is a prvalue, so it carries no top-level cv: `const i32` and
    /// `i32` join to `i32`.
    fn join(self, a: *Type, b: *Type) -> *Type {
        if a == &null { return canon_unqual(b); }
        if b == &null { return canon_unqual(a); }
        var au = canon_unqual(a);
        var bu = canon_unqual(b);
        if au == bu { return au; }
        if self.tu.is_never(au) { return bu; }
        if self.tu.is_never(bu) { return au; }
        var ab = self.implicit(au, bu);
        var ba = self.implicit(bu, au);
        if (ab != ImplicitRank::None) && (ba == ImplicitRank::None) { return bu; }
        if (ba != ImplicitRank::None) && (ab == ImplicitRank::None) { return au; }
        return &null;   // neither or both: the caller errors (both = a W-cycle, invariant 2).
    }
}