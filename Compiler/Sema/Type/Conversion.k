/// --- The Kairo Project ----------------------- Sema/Type/Conversion.k --- ///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::Context::SymbolTable::DeclName
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,  QualifiedType,  RecordType, builtin_info, canon_has_const, canon_quals,
    canon_unqual, is_c_character,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::FunctionDecl
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FunctionPointerType,
    GenericParamType,
    NullableType,
    PointerType,
}
import AST::OperatorFacts::OperatorFacts
import AST::ParamMode::ParamMode
import Sema::Resolve::MemberLookup::MemberLookup
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Sema::Type::Substitution::Substitution
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

/// \enum ConvClass
/// \brief Lattice §1. The class of an ordered primitive pair.
pub enum ConvClass derives u8 {
    I = 0, ///< identity.
    W,     ///< implicit: value-preserving, target-independent.
    E,     ///< explicit: `as` required.
    U,     ///< `as` inside an unsafe context.
    X,     ///< no cast exists.
}

/// \enum ImplicitRank
/// \brief What a call site / assignment gets from an implicit sequence.
pub enum ImplicitRank derives u8 {
    Exact = 0,
    Converted,
    None,
}

/// \enum RefRel
/// \brief How an argument's VALUE type relates to a reference parameter's
///        referee, before its value category is consulted (ref_binding).
pub enum RefRel derives u8 {
    None = 0, ///< binds at no category.
    Same,     ///< the referee itself.
    Derived,  ///< a class derived from the referee: binds the base subobject.
    Converts, ///< converts implicitly: binding goes through a temporary.
}

/// Can an untyped integer literal of the given magnitude take builtin \p bk?
/// \p negative is the unary-minus fold; the magnitude then may reach 2^(bits-1).
pub fn literal_fits_int(lo:       u64,
                        hi:       u64,
                        big:      bool,
                        negative: bool,
                        bk:       BuiltinKind,
                        ptr_bits: usize) -> bool {
    // C's `char` is no integer, but takes a literal where both of its
    // possible signednesses agree: 0..=127.
    if bk == BuiltinKind::CChar {
        return !negative && !big && hi == 0 && lo <= 127
    }

    // wchar_t is signed 32 bits on x86 Linux, unsigned 32 on AArch64 Linux
    // and unsigned 16 on Windows: 0..=0xFFFF fits all three. char16_t and
    // char8_t are unsigned everywhere, so their whole range fits.
    if bk == BuiltinKind::CWChar || bk == BuiltinKind::CChar16 {
        return !negative && !big && hi == 0 && lo <= 0xFFFF
    }

    // byte is no integer (every conversion to or from one is explicit), but
    // it is exactly eight unsigned bits, so a literal that fits them is
    // unambiguous: `var b: byte = 0xFF`.
    if bk == BuiltinKind::CChar8 || bk == BuiltinKind::Byte {
        return !negative && !big && hi == 0 && lo <= 0xFF
    }

    // Kairo's `char` is a Unicode scalar value: surrogates and anything above
    // 0x10FFFF never exist as a char, so a literal outside that set must not
    // be typed as one.
    if bk == BuiltinKind::Char {
        if negative || big || hi != 0 {
            return false
        }

        return lo <= 0xD7FF || lo >= 0xE000 && lo <= 0x10FFFF
    }

    if !builtin_info(bk)->is_integer() {
        return false
    }

    if big {
        return false
    }

    var bits = builtin_info(bk)->bits
    if bits == 0 {
        bits = ptr_bits
    }

    var is_signed = builtin_info(bk)->is_signed()
    if negative && !is_signed {
        return false
    }

    // magnitude limit as a 128-bit number. Every shift below is done on a
    // u64 ONE: a bare `1` is an i32, and `1 << 63` on one is undefined
    // behaviour, not a large number.
    var one: u64 = 1
    if bits >= 128 {
        // anything that fit in 128 bits is fine, except the signed top bit.
        if !is_signed {
            return true
        }

        if bits > 128 {
            return true
        }

        if negative {
            return hi < one << 63 || hi == one << 63 && lo == 0
        }

        return hi < one << 63
    }

    if hi != 0 {
        return false
    }

    var limit_bits = if (is_signed) => (bits - 1) else => bits
    if limit_bits >= 64 {
        return true
    }

    var limit: u64 = one << limit_bits // exclusive for non-negative
    if negative {
        return lo <= limit
    }

    return lo < limit
}

pub class Conversion {
    pub var sc: unsafe *SemaContext
    pub var tu: TypeUtil
    /// For the user rung's `op as` lookup only. Its extension index is
    /// never built: `op as` is member-only (OperatorSignatureCheck), so the
    /// record's own table and its bases are the whole search.
    priv var _ml: MemberLookup

    fn Conversion(self) {
        self.sc = &null
    }

    fn Conversion(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self.tu  = TypeUtil(sc)
        self._ml = MemberLookup(sc)
    }

    fn implicit_enabled(self) -> bool {
        return self.sc->opts.on(self.sc->opts.implicit_conv, true)
    }

    /// # primitive lattice

    fn classify(self, s: BuiltinKind, t: BuiltinKind) -> ConvClass {
        if s == t {
            return ConvClass::I
        }

        if s == BuiltinKind::Void || t == BuiltinKind::Void {
            return ConvClass::X
        }

        if s == BuiltinKind::Never {
            return ConvClass::W
        }

        if t == BuiltinKind::Never {
            return ConvClass::X
        }

        var si = builtin_info(s)->is_integer()
        var ti = builtin_info(t)->is_integer()
        var sf = builtin_info(s)->is_float()
        var tf = builtin_info(t)->is_float()

        if si && ti {
            return self._int_int(s, t)
        }

        if si && tf {
            return self._int_float(s, t)
        }

        if sf && ti {
            return ConvClass::E
        }

        if sf && tf {
            return self._float_float(s, t)
        }

        // non-numeric primitives: §4.
        if s == BuiltinKind::Bool {
            return if (ti) => (ConvClass::E) else => ConvClass::X
        }

        if t == BuiltinKind::Bool {
            return if (si) => (ConvClass::E) else => ConvClass::X
        }

        // `char` is a 32-bit Unicode scalar: it converts implicitly to and from an
        // integer only when the TARGET is equal or wider, and never to or from
        // the pointer-sized ones (target-dependent width, section 4). Signed
        // 32-bit and narrower stay explicit.
        if s == BuiltinKind::Char {
            return if (ti) => self._char_to_int(t) else => ConvClass::X
        }

        if t == BuiltinKind::Char {
            return if (si) => self._int_to_char(s) else => ConvClass::X
        }

        if s == BuiltinKind::Byte {
            return if (ti) => (ConvClass::E) else => ConvClass::X
        }

        if t == BuiltinKind::Byte {
            return if (si) => (ConvClass::E) else => ConvClass::X
        }

        // C's `char`: explicit to and from every integer, never implicit --
        // its signedness is the target's, so no widening is portable. The
        // same for wchar_t (width and signedness the target's) and, to keep
        // the four C character types one rule, char16_t and char8_t. Between
        // two of them, as between a character and a float, nothing.
        if is_c_character(s) {
            return if (ti) => (ConvClass::E) else => ConvClass::X
        }

        if is_c_character(t) {
            return if (si) => (ConvClass::E) else => ConvClass::X
        }

        return ConvClass::X
    }

    priv fn _is_ptr_int(self, b: BuiltinKind) -> bool {
        return b == BuiltinKind::USize || b == BuiltinKind::ISize
    }

    priv fn _char_to_int(self, t: BuiltinKind) -> ConvClass {
        if self._is_ptr_int(t) {
            return ConvClass::E
        }

        var tb = builtin_info(t)->bits
        var ts = builtin_info(t)->is_signed()
        if !ts { // u32, u64, u128...
            return if (tb >= 32) => (ConvClass::W) else => ConvClass::E
        }

        return if (tb > 32) => (ConvClass::W) else => ConvClass::E // i64, i128...: strictly wider
    }

    priv fn _int_to_char(self, s: BuiltinKind) -> ConvClass {
        if self._is_ptr_int(s) {
            return ConvClass::E
        }

        if builtin_info(s)->is_signed() {
            return ConvClass::E
        }

        return if (builtin_info(s)->bits <= 32) => (ConvClass::W) else => ConvClass::E // u8, u16, u32
    }

    priv fn _int_int(self, s: BuiltinKind, t: BuiltinKind) -> ConvClass {
        if self._is_ptr_int(s) || self._is_ptr_int(t) { // §4
            return ConvClass::E
        }

        var sb = builtin_info(s)->bits
        var tb = builtin_info(t)->bits
        if sb > 64 || tb > 64 { // R5
            return ConvClass::E
        }

        var ss = builtin_info(s)->is_signed()
        var ts = builtin_info(t)->is_signed()
        if !ss && !ts { // R1
            return if (tb > sb) => (ConvClass::W) else => ConvClass::E
        }

        if ss && ts { // R1
            return if (tb > sb) => (ConvClass::W) else => ConvClass::E
        }

        if !ss && ts { // R2 uN->iM
            return if (tb > sb) => (ConvClass::W) else => ConvClass::E
        }

        return ConvClass::E // R2 iN->uM never
    }

    priv fn _mantissa(self, f: BuiltinKind) -> usize {
        match f {
            case BuiltinKind::F16 {
                return 11
            } case BuiltinKind::BF16 {
                return 8
            } case BuiltinKind::F32 {
                return 24
            } case BuiltinKind::F64 {
                return 53
            } default { // f8*, f80, f128+: never a W target (R5).
                return 0
            }
        }
    }

    priv fn _int_float(self, s: BuiltinKind, t: BuiltinKind) -> ConvClass {
        if self._is_ptr_int(s) {
            return ConvClass::E
        }

        var sb = builtin_info(s)->bits
        if sb > 64 {
            return ConvClass::E
        }

        var m = self._mantissa(t)
        if m == 0 {
            return ConvClass::E
        }

        return if (sb <= m) => (ConvClass::W) else => ConvClass::E // R3
    }

    priv fn _float_float(self, s: BuiltinKind, t: BuiltinKind) -> ConvClass {
        // R4, plus bf16 -> f32/f64 which is exact by construction.
        if s == BuiltinKind::F16 && (t == BuiltinKind::F32 || t == BuiltinKind::F64) {
            return ConvClass::W
        }

        if s == BuiltinKind::BF16 && (t == BuiltinKind::F32 || t == BuiltinKind::F64) {
            return ConvClass::W
        }

        if s == BuiltinKind::F32 && t == BuiltinKind::F64 {
            return ConvClass::W
        }

        return ConvClass::E
    }

    /// # the ABI boundary rung

    /// Integer widening INTO a C/C++ signature. Asked only for an argument
    /// to an imported callee, after implicit() said None.
    ///
    /// §4 keeps the pointer-sized integers out of W because `usize -> u64`
    /// would compile on x86_64 and fail on wasm32. This rung keeps that
    /// property across 32- and 64-bit targets: a pointer-sized integer is the
    /// RANGE of widths it has over them, [32, 64], a fixed-width one is
    /// [N, N], and S -> D widens only when the widest S fits the narrowest D.
    /// What one of those triples accepts, all of them accept. A 16-bit
    /// target lowers the floor to its own width (_min_width): `u32 -> usize`
    /// would narrow there, so it is refused there, and only there.
    ///
    /// Never narrowing: same signedness needs max(S) <= min(D), unsigned to
    /// signed needs it strict, signed to unsigned never. Pairs of
    /// fixed-width types are the lattice's alone, and wide (R5), float and
    /// non-numeric types never take this rung.
    ///
    /// `size_t`/`ptrdiff_t` already arrive as usize/isize (the importer
    /// reads the typedef off the sugar); a bare `unsigned long` stays u64 by
    /// design and is judged as one.
    fn abi_widen(self, from: unsafe *Type, to: unsafe *Type) -> ImplicitRank {
        if from == &null || to == &null {
            return ImplicitRank::None
        }

        var fk = self.tu.kind_of(canon_unqual(self.tu.as_value(from)))
        var tk = self.tu.kind_of(canon_unqual(self.tu.as_value(to)))
        if fk == BuiltinKind::COUNT || tk == BuiltinKind::COUNT {
            return ImplicitRank::None
        }

        if !builtin_info(fk)->is_integer() || !builtin_info(tk)->is_integer() {
            return ImplicitRank::None
        }

        if !self._is_ptr_int(fk) && !self._is_ptr_int(tk) {
            return ImplicitRank::None
        }

        if !self.implicit_enabled() {
            return ImplicitRank::None
        }

        var s_max = self._max_width(fk)
        var d_min = self._min_width(tk)
        if s_max > 64 || self._max_width(tk) > 64 { // R5
            return ImplicitRank::None
        }

        var ss = builtin_info(fk)->is_signed()
        var ts = builtin_info(tk)->is_signed()
        if ss == ts {
            return if (s_max <= d_min) => (ImplicitRank::Converted) else => ImplicitRank::None
        }

        if !ss && ts {
            return if (s_max < d_min) => (ImplicitRank::Converted) else => ImplicitRank::None
        }

        return ImplicitRank::None // iN -> uM never
    }

    /// The narrowest a builtin integer is taken to be: its own width when
    /// fixed. Pointer-sized, 32 -- the narrowest 32/64-bit target, so those
    /// all agree -- unless THIS target is narrower still, which is the one
    /// place the width is read: a 16-bit `usize` must not take a `u32`.
    priv fn _min_width(self, b: BuiltinKind) -> usize {
        if !self._is_ptr_int(b) {
            return builtin_info(b)->bits
        }

        var pb = self.tu.builtin(BuiltinKind::USize)->size_bits
        return if (pb != 0 && pb < 32) => (pb) else => 32
    }

    /// The widest a builtin integer is on any supported target.
    priv fn _max_width(self, b: BuiltinKind) -> usize {
        return if (self._is_ptr_int(b)) => (64) else => builtin_info(b)->bits
    }

    /// # the implicit sequence

    /// Rank of \p from -> \p to as an implicit conversion. Both canonical.
    fn implicit(self, from: unsafe *Type, to: unsafe *Type) -> ImplicitRank {
        return self._seq(from, to, true)
    }

    /// implicit() without the user rung (`@implicit op as`, array -> slice):
    /// the language's own lattice only. What a JOIN asks -- an if/match arm
    /// or a binary operand must not be converted by a user function nobody
    /// wrote a target for.
    fn implicit_builtin(self, from: unsafe *Type, to: unsafe *Type) -> ImplicitRank {
        return self._seq(from, to, false)
    }

    /// \p user: the view and `@implicit` rungs are open. At most ONE of
    /// them applies per sequence: the nullable rung below recurses with it
    /// closed, so `T -> U?` never hides a user conversion under the wrap.
    priv fn _seq(self, from: unsafe *Type, to: unsafe *Type, user: bool) -> ImplicitRank {
        if from == &null || to == &null {
            return ImplicitRank::None
        }

        if from == to {
            return ImplicitRank::Exact
        }

        if self.tu.is_never(from) {
            return ImplicitRank::Converted
        }

        // C++ references. Only imported signatures carry them (Kairo has no
        // spelling), so this is the rule every `const T&` parameter in a
        // header is judged by.
        if isa<CXXLValueRefType>(to) || isa<CXXRValueRefType>(to) {
            return self._bind_ref(from, to)
        }

        // A reference READ as a value is its referee (lvalue-to-rvalue): a
        // `const T&` return converts wherever a T would.
        if isa<CXXLValueRefType>(from) {
            return self._seq(cast<CXXLValueRefType>(from)->referee, to, user)
        }

        if isa<CXXRValueRefType>(from) {
            return self._seq(cast<CXXRValueRefType>(from)->referee, to, user)
        }

        // Top-level cv is not part of a VALUE: the read strips it and
        // copy-initialization ignores it on the target. `const i32 -> i32`
        // and `i32 -> const i32` are both the identity.
        var unsafe *fu = canon_unqual(from)
        var unsafe *tq = canon_unqual(to)
        if fu == tq {
            return ImplicitRank::Exact
        }

        // primitives
        var fk = self.tu.kind_of(fu)
        var tk = self.tu.kind_of(tq)
        if fk != BuiltinKind::COUNT && tk != BuiltinKind::COUNT {
            if self.classify(fk, tk) == ConvClass::W {
                return if (self.implicit_enabled()) => (ImplicitRank::Converted)
                       else => ImplicitRank::None
            }

            return ImplicitRank::None
        }

        // T -> T?  (and *D -> *B?, i32 -> i64?, both via the inner)
        var unsafe *to_inner = self.tu.nullable_inner(tq)
        if to_inner != &null {
            var unsafe *from_inner = self.tu.nullable_inner(fu)
            // One level per conversion (Compiler/Spec/Nullables.md#nested-nullables): a value becomes
            // present in ONE `?`. `T -> (T?)?` would be two wraps, which no
            // single constructor of Nullable<Nullable<T>> is -- C++ refuses
            // the second user conversion, and so does Kairo. `T? -> (T?)?`
            // wraps the whole nullable, its null included, as the present
            // outer value.
            if from_inner == &null && self.tu.nullable_inner(to_inner) != &null {
                return ImplicitRank::None
            }

            if from_inner != &null && canon_unqual(to_inner) == fu {
                return ImplicitRank::Converted
            }

            if from_inner != &null {
                // T? -> U?: only when the inners relate; never Exact (different type).
                return if (self._seq(
                           from_inner,
                           to_inner,
                           false,
                       ) != ImplicitRank::None) => (ImplicitRank::Converted)
                       else => ImplicitRank::None
            }

            return if (self._seq(
                       fu,
                       to_inner,
                       false,
                   ) != ImplicitRank::None) => (ImplicitRank::Converted)
                   else => ImplicitRank::None
        }

        // Pointers: qualification ([conv.qual]) and derived-to-base, same
        // safety on both sides.
        var unsafe *fp = self.tu.pointee(fu)
        var unsafe *tp = self.tu.pointee(tq)
        if fp != &null && tp != &null {
            if self.tu.is_unsafe_ptr(fu) != self.tu.is_unsafe_ptr(tq) {
                return ImplicitRank::None
            }

            // A qualifier the pointee loses is never implicit.
            if !self._quals_kept(fp, tp) {
                return ImplicitRank::None
            }

            var unsafe *fd = self.tu.record_decl(fp)
            var unsafe *td = self.tu.record_decl(tp)
            if fd != &null
                && td != &null
                && fd != td
                && Substitution(self.sc).derives_from(fp, tp) {
                return ImplicitRank::Converted
            }

            if self._qual_conv(fu, tq, true) {
                return ImplicitRank::Converted
            }

            // `unsafe *T -> unsafe *void`, C's own implicit erasure: unsafe
            // pointers ARE C pointers, and without it every call into a
            // `void *` parameter needs a cast the spec never spells. Raw only
            // -- a safe `*void` stays behind `as`, it drops the pointee type
            // AMT tracks -- and cv-preserving: _quals_kept above already
            // refused `unsafe *const T -> unsafe *void`.
            if self.tu.is_unsafe_ptr(fu)
                && self.tu.is_void(canon_unqual(tp))
                && !self.tu.is_void(canon_unqual(fp)) {
                return ImplicitRank::Converted
            }

            return ImplicitRank::None
        }

        // `fn` values: the same signature, and an effect the target allows
        // (Compiler/Spec/Panic.md#declared-sets). A function whose set is S converts to a `fn` type
        // whose set is S' only when S is a subset of S'; one that does not
        // panic converts to any panicking `fn` type. The effect is in the
        // canonical, so only the effect can differ here.
        //
        // A raw `unsafe fn` widens to the `fn` value of its signature (a
        // function pointer is one of the things a `fn` value holds); a `fn`
        // value never narrows to raw, since it may hold a capturing closure
        // that has no function pointer to give (ExprTyper::check_convertible
        // says so, SC001E).
        if isa<FunctionPointerType>(fu) && isa<FunctionPointerType>(tq) {
            var unsafe *ff = cast<FunctionPointerType>(fu)
            var unsafe *tf = cast<FunctionPointerType>(tq)
            if tf->is_raw && !ff->is_raw {
                return ImplicitRank::None
            }

            // A calling convention converts only to itself, either way.
            if tf->call_conv != ff->call_conv {
                return ImplicitRank::None
            }

            return if (self._fn_effect_widens(ff, tf)) => (ImplicitRank::Converted)
                   else => ImplicitRank::None
        }

        if !user {
            return ImplicitRank::None
        }

        // `[T; N]` -> `[T;]`: a view of the array, nothing copied. The one
        // container conversion the compiler owns, because an array has no
        // body to declare an `op as` in. EmitIR builds the Slice.
        if self.array_views_as(from, tq) {
            return ImplicitRank::Converted
        }

        // `@implicit fn op as (self) -> T` on the source.
        if self.implicit_op(from, tq) != &null {
            return ImplicitRank::Converted
        }

        return ImplicitRank::None
    }

    /// \p a and \p b are one signature (parameters, modes, result) and \p a's
    /// panic effect is within \p b's: \p a does not panic, or both do and
    /// \p a's set is a subset of \p b's.
    priv fn _fn_effect_widens(self,
                              a: unsafe *FunctionPointerType,
                              b: unsafe *FunctionPointerType) -> bool {
        if a->return_type != b->return_type || a->params.size() != b->params.size() {
            return false
        }

        if a->is_unprototyped != b->is_unprototyped {
            return false
        }

        for var i: usize = 0; i < a->params.size(); ++i {
            if a->params[i] != b->params[i] {
                return false
            }

            var ma = if (i < a->modes.size()) => (a->modes[i]) else => ParamMode::Value
            var mb = if (i < b->modes.size()) => (b->modes[i]) else => ParamMode::Value
            if ma != mb {
                return false
            }
        }

        if !a->canon_panics {
            return true
        }

        if !b->canon_panics {
            return false
        }

        for var i: usize = 0; i < a->panic_set.size(); ++i {
            var found = false
            for var j: usize = 0; j < b->panic_set.size(); ++j {
                if a->panic_set[i] == b->panic_set[j] {
                    found = true
                    break
                }
            }

            if !found {
                return false
            }
        }

        return true
    }

    /// `[T; N]` seen as the slice \p to: `[T;]`, or `[const T;]`. A const
    /// array views only as `[const T;]` -- the view must not launder the
    /// qualifier away. Type-level only: a `const` BINDING's constness is not
    /// in its type, and clang rejects the `const T*` -> `T*` that leaks.
    fn array_views_as(self, from: unsafe *Type, to: unsafe *Type) -> bool {
        var unsafe *elem = self.tu.element_of(from)
        if elem == &null || !self.tu.is_slice(to) {
            return false
        }

        var args = self.tu.record_args(to)
        if args.size() != 1 {
            return false
        }

        var unsafe *want = args[0]
        if canon_unqual(want) != canon_unqual(elem) {
            return false
        }

        if canon_has_const(want) {
            return true
        }

        return !canon_has_const(from) && !canon_has_const(elem)
    }

    /// The `@implicit op as` on \p from whose result is exactly \p to, or
    /// null. EXACT: no second conversion rides on the result, so `A -> B`
    /// and `B -> C` never chain into `A -> C`. A const source needs a
    /// `const self` operator. Two matches (an own and an inherited one) is
    /// the first: own members come first in the walk and hide the base's.
    fn implicit_op(self, from: unsafe *Type, to: unsafe *Type) -> unsafe *FunctionDecl {
        var unsafe *fu = canon_unqual(from)
        var unsafe *tq = canon_unqual(to)
        if fu == &null || tq == &null || !isa<RecordType>(fu) {
            return &null
        }

        var cands = cxx::std::vector<unsafe *Decl>()
        self._ml.lookup(fu, DeclName::op_name(TokenKind::KwAs, TokenKind::TkUnknown), unsafe &cands)
        if cands.size() == 0 {
            return &null
        }

        var unsafe *pat = NameLookup::representative(self.tu.pattern_of(self.tu.record_decl(fu)))
        var        args = self.tu.record_args(fu)
        for var i: usize = 0; i < cands.size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>(cands[i])
            if f == &null || f->is_poisoned() || !OperatorFacts::is_implicit_conv(f) {
                continue
            }

            if f->return_type == &null || f->return_type->canonical == &null {
                continue
            }

            if canon_has_const(from) && !f->is_const() {
                continue
            }

            if self._same_through(canon_unqual(f->return_type->canonical), tq, pat, unsafe &args) {
                return f
            }
        }

        return &null
    }

    /// \p pattern, a type written inside the generic record \p owner, IS
    /// \p concrete once \p owner's parameters read as \p args: `Vector<T>`'s
    /// `-> [T;]` against `[i32;]` through `Vector<i32>`. A structural
    /// match rather than Deduction::substitute, which lives above this file
    /// (it holds a Conversion) and would build types only to compare them.
    priv fn _same_through(self,
                          pattern:  unsafe *Type,
                          concrete: unsafe *Type,
                          owner:    unsafe *Decl,
                          args:     unsafe *FrozenList<unsafe *Type>) -> bool {
        if pattern == &null || concrete == &null {
            return false
        }

        if pattern == concrete {
            return true
        }

        if !pattern->is_dependent() {
            return false
        }

        if isa<GenericParamType>(pattern) {
            var unsafe *g = cast<GenericParamType>(pattern)
            if g->owner != owner || (g->param_index as usize) >= args->size() {
                return false
            }

            return (*args)[g->param_index as usize] == concrete
        }

        if isa<QualifiedType>(pattern) {
            if canon_quals(pattern) != canon_quals(concrete) {
                return false
            }

            return self._same_through(canon_unqual(pattern), canon_unqual(concrete), owner, args)
        }

        if isa<PointerType>(pattern) {
            if !isa<PointerType>(concrete)
                || self.tu.is_unsafe_ptr(pattern) != self.tu.is_unsafe_ptr(concrete) {
                return false
            }

            return self._same_through(
                cast<PointerType>(pattern)->pointee,
                cast<PointerType>(concrete)->pointee,
                owner,
                args,
            )
        }

        if isa<NullableType>(pattern) {
            if !isa<NullableType>(concrete) {
                return false
            }

            return self._same_through(
                cast<NullableType>(pattern)->inner,
                cast<NullableType>(concrete)->inner,
                owner,
                args,
            )
        }

        if isa<RecordType>(pattern) {
            if !isa<RecordType>(concrete) {
                return false
            }

            var unsafe *pd = NameLookup::representative(
                self.tu.pattern_of(self.tu.record_decl(pattern)),
            )

            var unsafe *cd = NameLookup::representative(
                self.tu.pattern_of(self.tu.record_decl(concrete)),
            )

            if pd != cd {
                return false
            }

            var pa = self.tu.record_args(pattern)
            var ca = self.tu.record_args(concrete)
            if pa.size() != ca.size() {
                return false
            }

            for var i: usize = 0; i < pa.size(); ++i {
                if !self._same_through(pa[i], ca[i], owner, args) {
                    return false
                }
            }

            return true
        }

        return false
    }

    /// \p to's pointee carries every qualifier \p from's does.
    priv fn _quals_kept(self, fp: unsafe *Type, tp: unsafe *Type) -> bool {
        var fq = canon_quals(fp)
        var tq = canon_quals(tp)
        return (fq & ~tq) == 0
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
    /// [conv.qual] alone, for `as`: \p from and \p to are pointers that
    /// differ only in pointee qualifiers, and every difference is an addition
    /// the rule allows. The pointers' own top-level cv is ignored -- copying
    /// a `const` pointer out is a value copy, not a qualifier lost.
    fn qualification(self, from: unsafe *Type, to: unsafe *Type) -> bool {
        return self._qual_conv(canon_unqual(from), canon_unqual(to), true)
    }

    priv fn _qual_conv(self, from: unsafe *Type, to: unsafe *Type, const_above: bool) -> bool {
        var unsafe *fp = self.tu.pointee(from)
        var unsafe *tp = self.tu.pointee(to)
        if fp == &null || tp == &null {
            return false
        }

        if self.tu.is_unsafe_ptr(from) != self.tu.is_unsafe_ptr(to) {
            return false
        }

        if !self._quals_kept(fp, tp) {
            return false
        }

        if canon_quals(fp) != canon_quals(tp) && !const_above {
            return false
        }

        var unsafe *fpu = canon_unqual(fp)
        var unsafe *tpu = canon_unqual(tp)
        if fpu == tpu {
            return true
        }

        if self.tu.pointee(fpu) == &null || self.tu.pointee(tpu) == &null {
            return false
        }

        return self._qual_conv(fpu, tpu, const_above && canon_has_const(tp))
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
    priv fn _bind_ref(self, from: unsafe *Type, to: unsafe *Type) -> ImplicitRank {
        var unsafe *src = from
        if isa<CXXLValueRefType>(from) {
            src = cast<CXXLValueRefType>(from)->referee
        } else if isa<CXXRValueRefType>(from) {
            src = cast<CXXRValueRefType>(from)->referee
        }

        var sq = canon_quals(src)
        src = canon_unqual(src)

        if isa<CXXRValueRefType>(to) {
            var unsafe *rr = cast<CXXRValueRefType>(to)->referee
            if (sq & ~canon_quals(rr)) != 0 {
                return ImplicitRank::None
            }

            var unsafe *rru = canon_unqual(rr)
            if src == rru || self.implicit(src, rru) != ImplicitRank::None {
                return ImplicitRank::Converted
            }

            return ImplicitRank::None
        }

        var unsafe *referee = cast<CXXLValueRefType>(to)->referee
        // A plain `T&` (or `volatile T&`) from a more-qualified lvalue: the
        // binding would drop a qualifier.
        if (sq & ~canon_quals(referee)) != 0 {
            return ImplicitRank::None
        }

        var unsafe *ru = canon_unqual(referee)
        if src == ru {
            return ImplicitRank::Exact
        }

        var unsafe *fd = self.tu.record_decl(src)
        var unsafe *td = self.tu.record_decl(ru)
        if fd != &null && td != &null && fd != td && Substitution(self.sc).derives_from(src, ru) {
            return ImplicitRank::Converted
        }

        if canon_has_const(referee) && self.implicit(src, ru) != ImplicitRank::None {
            return ImplicitRank::Converted
        }

        return ImplicitRank::None
    }

    /// # reference binding at an argument ([over.ics.ref])

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
    fn ref_binding(self,
                   to:         unsafe *Type,
                   cat:        Expr::ValueCategory,
                   from_const: bool,
                   rel:        RefRel) -> ImplicitRank {
        if rel == RefRel::None {
            return ImplicitRank::None
        }

        var rvalue = cat == Expr::ValueCategory::RValue || cat == Expr::ValueCategory::XValue
        var lvalue = cat == Expr::ValueCategory::LValue
        var exact  = rel == RefRel::Same

        if isa<CXXRValueRefType>(to) {
            if rel == RefRel::Converts { // a temporary is an rvalue.
                return ImplicitRank::Converted
            }

            if !rvalue {
                return ImplicitRank::None
            }

            return if (exact) => (ImplicitRank::Exact) else => ImplicitRank::Converted
        }

        if !isa<CXXLValueRefType>(to) {
            return ImplicitRank::None
        }

        if canon_has_const(cast<CXXLValueRefType>(to)->referee) {
            return if (exact) => (ImplicitRank::Exact) else => ImplicitRank::Converted
        }

        // Plain `T&`: a modifiable lvalue, and never a temporary.
        if !lvalue || from_const || rel == RefRel::Converts {
            return ImplicitRank::None
        }

        return if (exact) => (ImplicitRank::Exact) else => ImplicitRank::Converted
    }

    /// \p src (a value type) against \p referee, cv of both ignored: the
    /// relation is between the objects, and whether the binding may drop a
    /// qualifier is ref_binding's question (its `from_const`).
    fn ref_rel(self, src: unsafe *Type, referee: unsafe *Type) -> RefRel {
        if src == &null || referee == &null {
            return RefRel::None
        }

        var unsafe *su = canon_unqual(src)
        var unsafe *ru = canon_unqual(referee)
        if su == ru {
            return RefRel::Same
        }

        var unsafe *fd = self.tu.record_decl(su)
        var unsafe *td = self.tu.record_decl(ru)
        if fd != &null && td != &null && fd != td && Substitution(self.sc).derives_from(su, ru) {
            return RefRel::Derived
        }

        if self.implicit(su, ru) != ImplicitRank::None {
            return RefRel::Converts
        }

        return RefRel::None
    }

    /// implicit() for an ARGUMENT whose category is known: a reference
    /// parameter goes through ref_binding, anything else is unchanged.
    fn implicit_arg(self,
                    from:       unsafe *Type,
                    to:         unsafe *Type,
                    cat:        Expr::ValueCategory,
                    from_const: bool) -> ImplicitRank {
        if from == &null || to == &null {
            return ImplicitRank::None
        }

        var to_l = isa<CXXLValueRefType>(to)
        var to_r = isa<CXXRValueRefType>(to)
        if !to_l && !to_r {
            return self.implicit(from, to)
        }

        // A reference-typed argument's value is its referee, and a const
        // one -- by its own top-level cv or its referee's -- is const
        // whatever its arm said.
        var unsafe *src = from
        if isa<CXXLValueRefType>(from) {
            src = cast<CXXLValueRefType>(from)->referee
        } else if isa<CXXRValueRefType>(from) {
            src = cast<CXXRValueRefType>(from)->referee
        }

        var c = from_const || canon_has_const(src)
        var unsafe *referee = if (to_l) => (cast<CXXLValueRefType>(to)->referee)
                              else => cast<CXXRValueRefType>(to)->referee
        return self.ref_binding(to, cat, c, self.ref_rel(src, referee))
    }

    fn convertible(self, from: unsafe *Type, to: unsafe *Type) -> bool {
        return self.implicit(from, to) != ImplicitRank::None
    }

    /// Branch join for if/match/try: the type both sides convert to, or null.
    /// The join is a prvalue, so it carries no top-level cv: `const i32` and
    /// `i32` join to `i32`.
    fn join(self, a: unsafe *Type, b: unsafe *Type) -> unsafe *Type {
        if a == &null {
            return canon_unqual(b)
        }

        if b == &null {
            return canon_unqual(a)
        }

        var unsafe *au = canon_unqual(a)
        var unsafe *bu = canon_unqual(b)
        if au == bu {
            return au
        }

        if self.tu.is_never(au) {
            return bu
        }

        if self.tu.is_never(bu) {
            return au
        }

        // The language's lattice only: an arm is not converted by a user's
        // `@implicit op as` toward a type nobody wrote.
        var ab = self.implicit_builtin(au, bu)
        var ba = self.implicit_builtin(bu, au)
        if ab != ImplicitRank::None && ba == ImplicitRank::None {
            return bu
        }

        if ba != ImplicitRank::None && ab == ImplicitRank::None {
            return au
        }

        return &null // neither or both: the caller errors (both = a W-cycle, invariant 2).
    }
}
