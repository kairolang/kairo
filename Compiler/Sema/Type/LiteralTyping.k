/// --- The Kairo Project -------------------- Sema/Type/LiteralTyping.k --- ///
///
///   \brief Literal typing (lattice §5): expected-type-first, defaults of
///          i32 / f64, fit checked AT the literal. Not a conversion and never
///          consults the lattice.
///
///   \detail
///     An unsuffixed integer literal has no type of its own. With an expected
///     type it takes it and the value is range-checked; without one it is i32,
///     widening only when the value does not fit i32. A suffixed literal is
///     typed at the literal and then participates in conversion normally.
///
///     Unary minus on a literal is folded here (`-128` fits i8) through the
///     `negative` argument; OperatorTyping passes it.
///
///     Aggregate literals push the expected element type down and join what
///     comes back up. A list literal takes its target from the expected type:
///     `[T; N]`, Slice or Vector; with none it is `[T; N]`. The constructors a
///     Slice or Vector target is built through are bound here, so the lowering
///     never looks one up.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::DeclContext::DeclContext
import AST::Context::SymbolTable::DeclName
import AST::Kind::ExprKind::to_string
import AST::LangItems::{
    FMT_ALT,    FMT_DEBUG,         FMT_SIGN_PLUS, FMT_UPPER,     FMT_ZERO,     FormatAlign,
    FormatKind, LangMembers,       WellKnownType, fmt_pack_spec, fmt_put_name, format_kind_of,
    fmt_spec_flags, to_string,  tuple_record_name,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    builtin_info,
    canon_unqual,
    is_c_character,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    EnumDecl,
    FunctionDecl,
}
import AST::Node::Expressions::{
    BinaryOperatorExpr, IfExpr,           ListLiteralExpr,   ListStorage, MapLiteralExpr,
    SetLiteralExpr,     TupleLiteralExpr, UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr, CharacterLiteralExpr, FloatingLiteralExpr, FormatHole, IntegerLiteralExpr,
    NullLiteralExpr,    StringLiteralExpr,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FixedArrayType,
    FunctionPointerType,
}
import AST::OperatorFacts::OperatorFacts
import Diagnostic::Registry::DiagID
import Lexer::Immediate::Immediate
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::Type::Conversion::literal_fits_int
import Sema::Type::OverloadResolution::{
    ArgInfo,
    ListShape,
    LitKind,
}
import Sema::Type::Substitution::Substitution
import Support::UTF8View::UTF8View
import Token::Token::Token
import Token::TokenKind::TokenKind

/// A declared slot a value is being typed into (pointers.mdx: `*T` is
/// never null). `root` is the value as written, `written` the slot's type as
/// written (its range is where a fix-it goes; null when the slot has no
/// written type, an inferred one or a canonical from an instance), `owner`
/// the declaration the slot belongs to (null when none: a function value's
/// parameter). ExprTyper keeps the stack (push_null_target); it is
/// declared here, ahead of the mixin that reads it.
pub struct NullTarget {
    var root:    *Expr
    var written: *Type
    var owner:   unsafe *Decl
}

// TODO(DUCK-GENERIC): T uses arg_info, check_convertible, conv, dotted_variant_shape, fail, missing_lang_item, ml, null_compared, null_targets, ovl, poison_only, propagate, ... (16). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> LiteralTyping {
    @move
    fn LiteralTyping(self, other: Self) = default
    fn LiteralTyping(self) = default
    priv inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    /// # classification

    /// Fill \p a's literal shape if \p e is an untyped literal (through parens
    /// and a leading unary minus). Returns true when it is.
    fn literal_shape(self, e_in: *Expr, a: *ArgInfo) -> bool {
        var e   = self.dyn()->tu.strip_parens(e_in)
        var neg = false
        if e != &null && isa<UnaryOperatorExpr>(e) {
            var u = cast<UnaryOperatorExpr>(e)
            if u->is_prefix() && u->op_token.kind == TokenKind::OpMinus {
                neg = true
                e   = self.dyn()->tu.strip_parens(u->operand)
            }
        }

        if e == &null {
            return false
        }

        if isa<IntegerLiteralExpr>(e) {
            var n = cast<IntegerLiteralExpr>(e)
            if n->imm == &null || n->has_suffix() {
                return false
            }

            a->lit     = LitKind::Int
            a->lit_lo  = n->get_value_lo()
            a->lit_hi  = n->get_value_hi()
            a->lit_big = n->is_big()
            a->lit_bits = n->big_bits()
            a->lit_neg = neg
            return true
        }

        if isa<FloatingLiteralExpr>(e) {
            var n = cast<FloatingLiteralExpr>(e)
            if n->imm != &null && n->has_suffix() {
                return false
            }

            a->lit = LitKind::Float
            return true
        }

        if !neg && isa<NullLiteralExpr>(e) {
            a->lit = if (cast<NullLiteralExpr>(e)->is_ref) => (LitKind::NullPtr)
                     else => LitKind::Null
            return true
        }

        return false
    }

    /// \p e is integer arithmetic over untyped integer literals only
    /// (`256 * 1024`, `(1 << 20) - 1`): still untyped, so it takes the type
    /// its parameter asks for, as one literal does (primitives.md §5: a
    /// parameter is an expected type). Ranked by its folded value; once
    /// selected, the typer hands the parameter type to every leaf. Only the
    /// argument path reads this: an operand beside a typed one already
    /// gets that type handed down.
    fn literal_expr_shape(self, e_in: *Expr, a: *ArgInfo) -> bool {
        var e = self.dyn()->tu.strip_parens(e_in)
        if e == &null || !isa<BinaryOperatorExpr>(e) {
            return false
        }

        var v: i64 = 0
        if !self._fold_lit_int(e, &v, 0) {
            return false
        }

        a->lit     = LitKind::Int
        a->lit_neg = false
        a->lit_lo  = (v as u64)
        a->lit_hi  = 0
        a->lit_big = false
        a->lit_bits = 0
        return true
    }

    /// Fold \p e_in into \p out when it is untyped integer literals under
    /// builtin binary integer operators, every step non-negative and below
    /// 2^62, so no step overflows i64; anything else is not folded (and
    /// stays the i32 arithmetic it was).
    priv fn _fold_lit_int(self, e_in: *Expr, out: unsafe *i64, depth: u32) -> bool {
        if depth > 32 {
            return false
        }

        var e = self.dyn()->tu.strip_parens(e_in)
        if e == &null {
            return false
        }

        var lim: i64 = (1 as i64) << 62
        if isa<IntegerLiteralExpr>(e) {
            var n = cast<IntegerLiteralExpr>(e)
            if n->imm == &null || n->has_suffix() || n->is_big() || n->get_value_hi() != 0 {
                return false
            }

            var lo = n->get_value_lo()
            if lo >= (lim as u64) {
                return false
            }

            *out = (lo as i64)
            return true
        }

        if !isa<BinaryOperatorExpr>(e) {
            return false
        }

        var b = cast<BinaryOperatorExpr>(e)
        if b->resolved_op != &null {
            return false
        }

        var l: i64 = 0
        var r: i64 = 0
        if !self._fold_lit_int(b->lhs, &l, depth + 1)
            || !self._fold_lit_int(b->rhs, &r, depth + 1) {
            return false
        }

        var k        = b->op_token.kind
        var res: i64 = 0
        if k == TokenKind::OpPlus {
            res = l + r
        } else if k == TokenKind::OpMinus {
            res = l - r
        } else if k == TokenKind::OpStar {
            var al = if (l < 0) => (-l) else => l
            var ar = if (r < 0) => (-r) else => r
            if al != 0 && ar >= lim / al {
                return false
            }

            res = l * r
        } else if k == TokenKind::OpSlash || k == TokenKind::OpPercent {
            if r == 0 {
                return false
            }

            res = if (k == TokenKind::OpSlash) => (l / r) else => l % r
        } else if k == TokenKind::OpLessLess || k == TokenKind::OpGreaterGreater {
            if r < 0 || r > 62 || l < 0 {
                return false
            }

            if k == TokenKind::OpGreaterGreater {
                res = l >> r
            } else {
                if l >= lim >> r {
                    return false
                }

                res = l << r
            }
        } else if k == TokenKind::OpAmp {
            res = l & r
        } else if k == TokenKind::OpPipe {
            res = l | r
        } else if k == TokenKind::OpCaret {
            res = l ^ r
        } else {
            return false
        }

        // Never negative: each leaf takes the parameter's type once
        // selected, so an unsigned one would see a value its ranking never
        // saw (`-(4) + 8` at a usize is SC075E at the `4`).
        if res >= lim || res < 0 {
            return false
        }

        *out = res
        return true
    }

    fn is_untyped_literal(self, e: *Expr) -> bool {
        var a = ArgInfo()
        return self.literal_shape(e, &a)
    }

    /// \p e has no type of its own: whatever it is typed against decides it.
    /// The shapes arg_info defers to selection -- an untyped scalar literal
    /// (`1`, `-1`, `2.5`, `null`, `&null`), a list literal and `.V` -- and
    /// for the same reason: until something gives one an expected type, its
    /// type is a default (`i32`, `f64`, `[i32; N]`) or an error (SC123E).
    /// OperatorTyping reads it to type the OTHER operand first. Pure: unlike
    /// list_literal_shape it records no shapes.
    fn is_context_typed(self, e_in: *Expr) -> bool {
        if self.is_untyped_literal(e_in) {
            return true
        }

        var e = self.dyn()->tu.strip_parens(e_in)
        if e == &null {
            return false
        }

        if isa<ListLiteralExpr>(e) {
            var l = cast<ListLiteralExpr>(e)
            return l->type_ == &null && !l->is_poisoned()
        }

        var a = ArgInfo()
        return self.dyn()->dotted_variant_shape(e, &a)
    }

    /// A list literal in ARGUMENT position is ranked by shape and typed after
    /// selection, as an untyped scalar literal is (§5): it takes the
    /// parameter's type. Kept out of literal_shape because is_untyped_literal
    /// feeds operand unification, which a list has no part in.
    ///
    /// A literal a parent already typed is not deferred; its type is fixed.
    fn list_literal_shape(self, e_in: *Expr, a: *ArgInfo) -> bool {
        var e = self.dyn()->tu.strip_parens(e_in)
        if e == &null || !isa<ListLiteralExpr>(e) {
            return false
        }

        var n = cast<ListLiteralExpr>(e)
        if n->type_ != &null || n->is_poisoned() {
            return false
        }

        a->lit = LitKind::List

        // The children are collected first and appended in one run: typing an
        // element can itself append (a nested list literal), and the range
        // this ArgInfo names has to be contiguous.
        var kids = cxx::std::vector<ListShape>()
        for var i: usize = 0; i < n->elements.size(); ++i {
            var el = self.dyn()->arg_info(n->elements[i])
            if el.dependent {
                a->dependent = true
            }

            var sh = ListShape()
            sh.lit      = el.lit
            sh.lit_lo   = el.lit_lo
            sh.lit_hi   = el.lit_hi
            sh.lit_big  = el.lit_big
            sh.lit_bits = el.lit_bits
            sh.lit_neg  = el.lit_neg
            sh.lit_name = el.lit_name
            sh.ty       = el.ty
            sh.kids_lo  = el.elems_lo
            sh.kids_n   = el.elems_n
            kids.push_back(sh)
        }

        a->elems_lo = self.dyn()->ovl.list_shapes.size()
        a->elems_n  = kids.size()
        for var i: usize = 0; i < kids.size(); ++i {
            self.dyn()->ovl.list_shapes.push_back(kids[i])
        }

        return true
    }

    /// # integers

    fn type_int_literal(self,
                        n:        unsafe *IntegerLiteralExpr,
                        expected: unsafe *Type,
                        negative: bool) -> unsafe *Type {
        if n->imm == &null {
            self.dyn()->fail(n, DiagID::SC073E, "integer literal has no immediate data")
            return &null
        }

        // Minted (`u64::MAX`): its type is fixed, and its value is right by
        // construction, the magnitude of a MIN under its `-` included.
        if n->is_pinned() {
            return self.dyn()->tu.builtin(n->pinned_kind as BuiltinKind)
        }

        var pb = self.dyn()->tu.builtin(BuiltinKind::USize)->size_bits

        // suffixed: typed at the literal.
        if n->has_suffix() {
            // The lexer's width is only a width when the suffix was `iN` /
            // `uN`: for any other text it fell back to the value's minimum
            // width, so `1f32` was silently an i8. Read the text.
            var sfx = n->get_suffix_text()
            var k   = BuiltinKind::COUNT
            if n->is_pointer_sized() {
                k = if (n->is_unsigned()) => (BuiltinKind::USize) else => BuiltinKind::ISize
            } else if self._suffix_width(sfx, 'i' as u8, ('I' as u8)) != 0
                || self._suffix_width(sfx, 'u' as u8, ('U' as u8)) != 0 {
                k = self._int_kind(n->get_bits(), n->is_unsigned())
            } else {
                // A float suffix on an integer body: `5f32` is the f32 5.
                var fk = self._float_suffix_kind(sfx)
                if fk != BuiltinKind::COUNT {
                    return self.dyn()->tu.builtin(fk)
                }
            }

            if k == BuiltinKind::COUNT {
                self.dyn()->fail(
                    n,
                    DiagID::SC074E,
                    f"unknown integer literal suffix '{n->get_suffix_text()}'",
                )

                return &null
            }

            if !literal_fits_int(
                n->get_value_lo(),
                n->get_value_hi(),
                n->is_big(),
                negative,
                k,
                pb,
                n->big_bits(),
            ) {
                self.dyn()->fail(
                    n,
                    DiagID::SC075E,
                    f"literal does not fit in '{builtin_info(k)->spelling}'",
                )

                return &null
            }

            return self.dyn()->tu.builtin(k)
        }

        // expected-type-first.
        var target = self.dyn()->tu.strip_nullable(expected)
        var tk     = self.dyn()->tu.kind_of(target)
        if tk != BuiltinKind::COUNT {
            if builtin_info(tk)->is_integer() {
                if !literal_fits_int(
                    n->get_value_lo(),
                    n->get_value_hi(),
                    n->is_big(),
                    negative,
                    tk,
                    pb,
                    n->big_bits(),
                ) {
                    self.dyn()->fail(
                        n,
                        DiagID::SC075E,
                        f"literal '{n->get_source_text()}' does not fit in '{builtin_info(tk)->spelling}'",
                    )

                    return &null
                }

                return target
            }

            if builtin_info(tk)->is_float() {
                return target
            }

            // C's `char` takes an untyped literal only where both of its
            // possible signednesses agree, 0..=127: `buf[i] == 0`, `c < 65`.
            if tk == BuiltinKind::Char {
                if literal_fits_int(
                    n->get_value_lo(),
                    n->get_value_hi(),
                    n->is_big(),
                    negative,
                    tk,
                    pb,
                    n->big_bits(),
                ) {
                    return target
                }

                self.dyn()->fail(
                    n,
                    DiagID::SC075E,
                    f"literal '{n->get_source_text()}' is not a Unicode scalar value, so it does not fit in 'char': only 0 through 0xD7FF and 0xE000 through 0x10FFFF do",
                )

                return &null
            }

            if tk == BuiltinKind::CChar {
                if literal_fits_int(
                    n->get_value_lo(),
                    n->get_value_hi(),
                    n->is_big(),
                    negative,
                    tk,
                    pb,
                    n->big_bits(),
                ) {
                    return target
                }

                self.dyn()->fail(
                    n,
                    DiagID::SC075E,
                    f"literal '{n->get_source_text()}' does not fit in 'c_char' on every target: only 0 through 127 do, whether C's char is signed or not",
                )

                return &null
            }

            if tk == BuiltinKind::CWChar {
                if literal_fits_int(
                    n->get_value_lo(),
                    n->get_value_hi(),
                    n->is_big(),
                    negative,
                    tk,
                    pb,
                    n->big_bits(),
                ) {
                    return target
                }

                self.dyn()->fail(
                    n,
                    DiagID::SC075E,
                    f"literal '{n->get_source_text()}' does not fit in 'c_wchar' on every target: only 0 through 0xFFFF do, as wchar_t is 16 bits on Windows",
                )

                return &null
            }

            if tk == BuiltinKind::CChar16 || tk == BuiltinKind::CChar8 || tk == BuiltinKind::Byte {
                if literal_fits_int(
                    n->get_value_lo(),
                    n->get_value_hi(),
                    n->is_big(),
                    negative,
                    tk,
                    pb,
                    n->big_bits(),
                ) {
                    return target
                }

                self.dyn()->fail(
                    n,
                    DiagID::SC075E,
                    f"literal '{n->get_source_text()}' does not fit in '{builtin_info(tk)->spelling}'",
                )

                return &null
            }
        }

        // default: i32, widening only when it does not fit.
        var order = cxx::std::vector<BuiltinKind>()
        order.push_back(BuiltinKind::I32)
        order.push_back(BuiltinKind::I64)
        order.push_back(BuiltinKind::I128)
        for var i: usize = 0; i < order.size(); ++i {
            if literal_fits_int(
                n->get_value_lo(),
                n->get_value_hi(),
                n->is_big(),
                negative,
                order[i],
                pb,
                n->big_bits(),
            ) {
                return self.dyn()->tu.builtin(order[i])
            }
        }

        self.dyn()->fail(
            n,
            DiagID::SC075E,
            "integer literal is too large for any integer type without a suffix",
        )

        return &null
    }

    priv fn _int_kind(self, bits: u16, unsigned_: bool) -> BuiltinKind {
        match bits {
            case 8 {
                return if (unsigned_) => (BuiltinKind::U8) else => BuiltinKind::I8
            } case 16 {
                return if (unsigned_) => (BuiltinKind::U16) else => BuiltinKind::I16
            } case 32 {
                return if (unsigned_) => (BuiltinKind::U32) else => BuiltinKind::I32
            } case 64 {
                return if (unsigned_) => (BuiltinKind::U64) else => BuiltinKind::I64
            } case 128 {
                return if (unsigned_) => (BuiltinKind::U128) else => BuiltinKind::I128
            } case 256 {
                return if (unsigned_) => (BuiltinKind::U256) else => BuiltinKind::I256
            } case 512 {
                return if (unsigned_) => (BuiltinKind::U512) else => BuiltinKind::I512
            } default {
                return BuiltinKind::COUNT
            }
        }
    }

    /// # floats

    fn type_float_literal(self,
                          n:        unsafe *FloatingLiteralExpr,
                          expected: unsafe *Type) -> unsafe *Type {
        if n->imm == &null {
            self.dyn()->fail(n, DiagID::SC073E, "float literal has no immediate data")
            return &null
        }

        if n->is_pinned() {
            return self.dyn()->tu.builtin(n->pinned_kind as BuiltinKind)
        }

        if n->has_suffix() {
            // From the text, not the lexer's width: an unknown suffix left
            // that at its f64 default, so `1.5bf16` and `1.5xyz` were f64.
            var k = self._float_suffix_kind(n->get_suffix_text())
            if k == BuiltinKind::COUNT {
                self.dyn()->fail(
                    n,
                    DiagID::SC074E,
                    f"unknown float literal suffix '{n->get_suffix_text()}'",
                )

                return &null
            }

            return self.dyn()->tu.builtin(k)
        }

        var target = self.dyn()->tu.strip_nullable(expected)
        if self.dyn()->tu.is_float(target) {
            return target
        }

        return self.dyn()->tu.builtin(BuiltinKind::F64)
    }

    /// The N of a suffix spelled `<lead>N` (\p lead or \p up, then N, all
    /// decimal digits), or 0 when \p sfx is not one.
    priv fn _suffix_width(self, const sfx: string, lead: u8, up: u8) -> u32 {
        if sfx.size() < 2 {
            return 0
        }

        var c0 = sfx[0]
        if c0 != lead && c0 != up {
            return 0
        }

        var w: u32 = 0
        for var i: usize = 1; i < sfx.size(); ++i {
            var c = sfx[i]
            if c < ('0' as u8) || c > ('9' as u8) {
                return 0
            }

            w = w * 10 + ((c - ('0' as u8)) as u32)
            if w > 65535 {
                return 0
            }
        }

        return w
    }

    /// `fN` for a float width Kairo has, or `bf16`; COUNT for anything else.
    priv fn _float_suffix_kind(self, const sfx: string) -> BuiltinKind {
        if sfx == "bf16" || sfx == "BF16" {
            return BuiltinKind::BF16
        }

        var w = self._suffix_width(sfx, 'f' as u8, ('F' as u8))
        if w == 0 {
            return BuiltinKind::COUNT
        }

        return self._float_kind(w)
    }

    priv fn _float_kind(self, bits: u32) -> BuiltinKind {
        match bits {
            case 16 {
                return BuiltinKind::F16
            } case 32 {
                return BuiltinKind::F32
            } case 64 {
                return BuiltinKind::F64
            } case 80 {
                return BuiltinKind::F80
            } case 128 {
                return BuiltinKind::F128
            } case 256 {
                return BuiltinKind::F256
            } case 512 {
                return BuiltinKind::F512
            } default {
                return BuiltinKind::COUNT
            }
        }
    }

    /// # the rest

    /// Every literal is a `string`. A plain one gets its constructor bound; a
    /// format one gets, per hole, everything FStringLowering needs to mint
    /// without a lookup: the kind, the conversion, the packed spec.
    fn type_string_literal(self,
                           n:        unsafe *StringLiteralExpr,
                           expected: unsafe *Type) -> unsafe *Type {
        var s = self.dyn()->tu.string_type()
        if s == &null {
            self.dyn()->missing_lang_item(n, to_string(WellKnownType::String))
            return &null
        }

        n->string_ctor = self._lang_ctor(WellKnownType::String, 3, false)
        if n->string_ctor == &null {
            self.dyn()->missing_lang_item(n, to_string(WellKnownType::String))
            return &null
        }

        // A suffix is never ignored: it names a literal operator or it is an
        // error. Ignoring it would type `"hi"_len` as `string` and
        // silently call nothing.
        // On a chain the suffix is the whole chain's, whichever segment
        // spells it (_chain_suffix).
        if n->imm != &null {
            var sfx  = n->get_suffix()
            var good = true
            if n->has_next() {
                good = self._chain_suffix(n, &sfx)
            }

            if !good {
                self.dyn()->poison_only(n)
                return &null
            }

            if sfx.range.is_valid() {
                return self._type_string_udl(n, sfx)
            }
        }

        if !n->is_format() {
            return s
        }

        if n->imm == &null {
            self.dyn()->fail(n, DiagID::SC073E, "format string literal has no immediate data")
            return &null
        }

        if !self._type_format_literal(n, s) {
            self.dyn()->poison_only(n)
            return &null
        }

        return s
    }

    /// The suffix of the chain \p n heads, into \p out (an invalid token
    /// when no segment has one); false after an error. C++'s rule:
    /// a suffix on any segment is the whole joined string's, so `"12"
    /// "3"_km` is `"123"_km`, and segments that spell DIFFERENT suffixes
    /// are an error (SC277E), since no one of them can be meant for all.
    /// Every chain with a suffix warns (SC276W), the head's as much as a
    /// later one's: read either way, a suffix that looks like a segment's is
    /// the whole string's. A chain with an f segment is SC074E in
    /// _type_string_udl whichever segment spells it, so it is not warned.
    priv fn _chain_suffix(self, n: unsafe *StringLiteralExpr, out: *Token) -> bool {
        var        first: unsafe *Immediate::StringData = &null
        var unsafe *last                                = n->imm
        var        segs:  usize                         = 0
        var unsafe *seg                                 = n->imm
        while seg != &null {
            segs = segs + 1
            last = seg
            if seg->suffix.range.is_valid() {
                if first == &null {
                    first = seg
                } else {
                    var a = n->ctx->get_spelling(first->suffix.range)
                    var b = n->ctx->get_spelling(seg->suffix.range)
                    if a != b {
                        var e = self.dyn()->sc->diag->report(
                            DiagID::SC277E,
                            seg->suffix.range.start,
                            f"segments of one string literal have different suffixes '{a}' and '{b}'; a suffix applies to the whole joined string, so it can have only one",
                        )

                        e.first(seg->suffix.range, f"'{b}' here")
                        e.second(first->suffix.range, f"'{a}' here")
                        e.note(DiagID::SC277N, first->suffix.range.start, f"'{a}' is spelled here; keep one suffix, on any segment")
                        e.emit()
                        return false
                    }
                }
            }

            seg = n->next_segment(seg)
        }

        if first == &null {
            return true
        }

        (*out) = first->suffix
        if n->is_format() {
            return true
        }

        var sfx  = n->ctx->get_spelling(first->suffix.range)
        var w    = self.dyn()->sc->diag->report(
            DiagID::SC276W,
            first->suffix.range.start,
            f"the literal suffix '{sfx}' applies to the whole string joined from these {segs} segments, not only to the segment it is written on",
        )

        w.first(first->suffix.range, f"suffix of all {segs} segments")
        var joined = self._join_chain(n, last, sfx)
        if !joined.empty() {
            var at = SourceRange(self._segment_start(n->imm), self._segment_end(last))
            w.fix(at, joined, "join the segments into one literal")
        } else {
            w.fix("write the string as one literal, with the suffix after its closing quote")
        }

        w.emit()
        return true
    }

    /// The chain's text as ONE literal carrying \p sfx, or "" when the
    /// segments cannot be joined by text alone: a segment the compiler made
    /// (stringify!, file!: no source body), an f segment (its holes), one
    /// whose prefix differs from the head's (`"a" r"\n"` decodes `\n` two
    /// ways), or a triple-quoted one (its own line rules).
    priv fn _join_chain(self,
                        n:         unsafe *StringLiteralExpr,
                        last:      unsafe *Immediate::StringData,
                        const sfx: string) -> string {
        var unsafe *head = n->imm
        var        body = ""
        var unsafe *seg  = head
        while seg != &null {
            if seg->has_owned_text() || (!seg->body.is_valid()) {
                return ""
            }

            if seg->prefix_kind.has(Immediate::TextPrefixKind::Format)
                || seg->prefix_kind.bits != head->prefix_kind.bits {
                return ""
            }

            if !self._single_quoted(n, seg) {
                return ""
            }

            // `"\1" "2"` is two bytes; joined, `"\12"` is one: an octal
            // escape takes up to three digits (Lexing.md), so a segment that
            // ends in a shorter one cannot be glued to a leading digit.
            var text = n->ctx->get_spelling(seg->body)
            if (!head->prefix_kind.has(Immediate::TextPrefixKind::Raw))
                && self._open_octal(body)
                && text.size() > 0 && text[0] >= ('0' as u8) && text[0] <= ('7' as u8) {
                return ""
            }

            body = body + text
            seg = n->next_segment(seg)
        }

        var pre = ""
        if head->prefix.range.is_valid() {
            pre = n->ctx->get_spelling(head->prefix.range)
        }

        return pre + "\"" + body + "\"" + sfx
    }

    /// \p seg is written `"..."`: one quote on each side of its body. Read
    /// at the closing side, which a triple-quoted body ends in three of: the
    /// byte before a head's opening quote may be the start of the file.
    priv fn _single_quoted(self, n: unsafe *StringLiteralExpr, seg: unsafe *Immediate::StringData) -> bool {
        var open  = n->ctx->get_spelling(SourceRange::from_bounds(seg->body.start.with_offset(-1), 1u32))
        var close = n->ctx->get_spelling(SourceRange::from_bounds(seg->body.end, 2u32))
        return open.size() == 1 && open[0] == ('"' as u8) && close.size() >= 1
            && close[0] == ('"' as u8) && (close.size() == 1 || close[1] != ('"' as u8))
    }

    /// \p text ends in an octal escape of fewer than three digits: a
    /// backslash an even run of backslashes does not escape, then one or two
    /// of 0-7.
    priv fn _open_octal(self, const text: string) -> bool {
        var n      = text.size()
        var digits: usize = 0
        while digits < 3 && digits < n
            && text[n - 1 - digits] >= ('0' as u8) && text[n - 1 - digits] <= ('7' as u8) {
            digits = digits + 1
        }

        if digits == 0 || digits >= 3 || digits >= n {
            return false
        }

        var k      = n - 1 - digits
        var slashes: usize = 0
        while slashes <= k && text[k - slashes] == ('\\' as u8) {
            slashes = slashes + 1
            if slashes > k {
                break
            }
        }

        return slashes % 2 == 1
    }

    /// Where \p seg's text starts: its prefix, else its opening quote.
    priv fn _segment_start(self, seg: unsafe *Immediate::StringData) -> SourceLocation {
        if seg->prefix.range.is_valid() {
            return seg->prefix.range.start
        }

        return seg->body.start.with_offset(-1)
    }

    /// Where \p seg's text ends: after its suffix, else its closing quote.
    priv fn _segment_end(self, seg: unsafe *Immediate::StringData) -> SourceLocation {
        if seg->suffix.range.is_valid() {
            return seg->suffix.range.end
        }

        return seg->body.end.with_offset(1)
    }

    /// `"..."_x`: the imported C++ `operator""_x(const char *, size_t)`, found
    /// the way C++ finds it for a literal at file scope (unqualified, so the
    /// global namespace and what the file imported). The literal is typed as
    /// the operator's return type and StringLowering makes it the call. Kairo
    /// has no spelling for declaring one, so an unknown suffix is SC074E.
    priv fn _type_string_udl(self, n: unsafe *StringLiteralExpr, sfx_tok: Token) -> unsafe *Type {
        var sfx = n->ctx->get_spelling(sfx_tok.range)
        if n->is_format() {
            self.dyn()->fail(
                n,
                DiagID::SC074E,
                f"a format string cannot take the literal suffix '{sfx}'",
            )

            return &null
        }

        var imm = self.dyn()->sc->imm_table()->intern_ident_copy("operator\"\"" + sfx)
        var r   = self.dyn()->sc->lookup.unqualified(
            unsafe (self.dyn()->sc->tu as unsafe *DeclContext),
            DeclName::ident(imm),
        )

        if r.found() {
            for var i: usize = 0; i < r.cell->size(); ++i {
                var f = dyn_cast<FunctionDecl>(r.cell->get(i))
                if f != &null && f->params.size() == 2 && f->return_type != &null {
                    n->udl_op = r.cell->get(i)
                    return f->return_type->canonical
                }
            }
        }

        self.dyn()->fail(
            n,
            DiagID::SC074E,
            f"unknown literal suffix '{sfx}': no literal operator with it is declared; import a C++ `operator\"\"{sfx}(const char *, size_t)`",
        )

        return &null
    }

    fn type_char_literal(self,
                         n:        unsafe *CharacterLiteralExpr,
                         expected: unsafe *Type) -> unsafe *Type {
        return self.dyn()->tu.builtin(BuiltinKind::Char)
    }

    fn type_bool_literal(self,
                         n:        unsafe *BooleanLiteralExpr,
                         expected: unsafe *Type) -> unsafe *Type {
        return self.dyn()->tu.builtin(BuiltinKind::Bool)
    }

    /// `null` needs a nullable expected type; `&null` a pointer (or nullable
    /// pointer). Neither has a type of its own to fall back on.
    fn type_null_literal(self,
                         n:           unsafe *NullLiteralExpr,
                         expected_in: unsafe *Type) -> unsafe *Type {
        // A C++ reference parameter (`push_back(const T?&)` of an imported
        // `vector<T?>`) binds the null's temporary: the null is a value of
        // the type referred to. Whether that type may bind there is the
        // conversion's question, asked after this one.
        var unsafe *expected = expected_in
        var unsafe *ec       = canon_unqual(expected_in)
        if ec != &null && (isa<CXXLValueRefType>(ec) || isa<CXXRValueRefType>(ec)) {
            expected = self.dyn()->tu.as_value(ec)
        }

        if n->is_ref {
            // Passed to C++ where a `std::nullptr_t` is wanted (a deduced
            // forwarding reference, or the parameter itself): `&null` is the
            // nullptr that type holds.
            if self.dyn()->tu.is_nullptr_t(expected) {
                return expected
            }

            // A raw function pointer (`unsafe fn(A) -> R`, every imported C
            // callback type) is a pointer that may hold the null address
            // (`run(&null, 3)` for a C `run(cb_t, int)`); `pointee` of a
            // function pointer is empty, so it is asked for by shape.
            var unsafe *fpt = canon_unqual(expected)
            if fpt != &null && isa<FunctionPointerType>(fpt) && cast<FunctionPointerType>(fpt)->is_raw {
                return expected
            }

            if self.dyn()->tu.pointee(self.dyn()->tu.strip_nullable(expected)) != &null {
                // A safe `*T` is never null (pointers.mdx), so `&null` has
                // nowhere to go in one: only a `*T?` (as that nullable's
                // null) or an `unsafe *T` holds it. A comparison operand is
                // not stored, so `p == &null` stays the comparison it is.
                var safe = self.dyn()->tu.nullable_inner(expected) == &null
                    && !self.dyn()->tu.is_unsafe_ptr(expected)
                // FIXME(builtin): Lib/builtin's string and FmtBuf still clear
                // their `*u8` data with `&null` (string.k, fmt_buf.k finish);
                // the builtin module still needs migrating, so it is not
                // held to the rule until then.
                var sc = self.dyn()->sc
                if sc->g != &null && sc->g->is_builtin_fid(sc->ctx->fid) {
                    safe = false
                }

                if safe && (unsafe (n as unsafe *Expr)) != self.dyn()->null_compared {
                    self._null_into_safe_pointer(n, expected)
                    return &null
                }

                return expected
            }

            self.dyn()->fail(
                n,
                DiagID::SC076E,
                "cannot infer the pointer type of '&null' here; annotate the target",
            )

            return &null
        }

        if self.dyn()->tu.nullable_inner(expected) != &null {
            return expected
        }

        self.dyn()->fail(
            n,
            DiagID::SC076E,
            "cannot infer the type of 'null' here; annotate the target with a nullable type",
        )

        return &null
    }

    /// `&null` typed into the safe pointer \p to. The slot it lands in is
    /// the innermost null target whose value \p n is: its declaration gets
    /// the note, and its written type the fix-it -- `*T?`, the pointer that
    /// may be absent. `unsafe *T` is named in the note rather than offered:
    /// it drops the tracking, which is not a choice a fix-it should make.
    priv fn _null_into_safe_pointer(self, n: unsafe *NullLiteralExpr, to: unsafe *Type) {
        var unsafe *e = unsafe (n as unsafe *Expr)
        if e->is_poisoned() {
            return
        }

        var ts = self.dyn()->tu.str(to)
        var b = self.dyn()->sc->diag->report(
            DiagID::SC259E,
            n->range.start,
            f"'&null' cannot be stored in '{ts}': a safe pointer is never null",
        )

        b.first(n->range, "the null address")
        var why = f"a pointer that may be absent is '{ts}?', and a raw pointer that may hold '&null' is 'unsafe {ts}'"
        var slot: unsafe *NullTarget = &null
        var i                        = self.dyn()->null_targets.size()
        while i > 0 {
            i -= 1
            if self._value_of(self.dyn()->null_targets[i].root, e) {
                slot = &self.dyn()->null_targets[i]
                break
            }
        }

        var w: *Type? = if (slot != &null) => (slot->written) else => &null
        if w != &null && w->range.is_valid() {
            var who = if (slot->owner == &null) => ("the slot")
                      else => f"'{self.dyn()->tu.decl_name(slot->owner)}'"
            var what = if (slot->owner != &null
                           && isa<FunctionDecl>(slot->owner)) => ("is declared to return")
                       else => "is declared"
            b.note(w->range.start, f"{who} {what} '{ts}' here; {why}")
            b.insert(w->range.end, "?", f"make the pointer nullable: '{ts}?'")
        } else {
            b.note(f"'{ts}' is a safe pointer, which always points at something; {why}")
        }

        b.emit()
        e->poison()
    }

    /// \p e is the value \p root produces, through parentheses, the arms
    /// of an `if` expression and the fallback of a `??` -- the shapes whose
    /// result IS one of their operands, so the operand lands in the slot.
    priv fn _value_of(self, root: *Expr, e: *Expr) -> bool {
        var r = self.dyn()->tu.strip_parens(root)
        if r == &null {
            return false
        }

        if r == e {
            return true
        }

        var ie = dyn_cast<IfExpr>(r)
        if ie != &null {
            if self._value_of(ie->then_expr, e) || self._value_of(ie->else_expr, e) {
                return true
            }

            for var j: usize = 0; j < ie->else_ifs.size(); ++j {
                if self._value_of(ie->else_ifs.get(j)->body, e) {
                    return true
                }
            }

            return false
        }

        var bo = dyn_cast<BinaryOperatorExpr>(r)
        if bo != &null && bo->op_token.kind == TokenKind::OpQuestionQuestion {
            return self._value_of(bo->rhs, e)
        }

        return false
    }

    fn type_list_literal(self, n: unsafe *ListLiteralExpr, expected: unsafe *Type) -> unsafe *Type {
        var ex                         = canon_unqual(self.dyn()->tu.strip_nullable(expected))
        var elem_expected              = self.dyn()->tu.container_elem(ex)
        var elem:         unsafe *Type = elem_expected
        var hole:         unsafe *Expr = &null
        for var i: usize = 0; i < n->elements.size(); ++i {
            var t = self.dyn()->type_of(n->elements[i], elem_expected)
            if t == &null {
                if hole == &null {
                    hole = n->elements[i]
                }

                continue
            }

            // An array element is an array initialized from this element:
            // a list literal, never a copy (reject_array_copy).
            if elem_expected != &null && self.reject_array_copy(n->elements[i], elem_expected) {
                continue
            }

            if elem_expected != &null {
                self.dyn()->check_convertible(n->elements[i], elem_expected)
                continue
            }

            var j = self.dyn()->conv.join(elem, t)
            if j == &null {
                self.dyn()->fail(
                    n->elements[i],
                    DiagID::SC077E,
                    f"list element of type '{self.dyn()->tu.str(t)}' does not match the earlier element type '{self.dyn()->tu.str(elem)}'",
                )

                self.dyn()->poison_only(n)
                return &null
            }

            elem = j
        }

        if hole != &null {
            self._lift_hole(n, hole)
            return &null
        }

        var count = n->elements.size()
        if elem == &null {
            if count == 0 {
                self.dyn()->fail(
                    n,
                    DiagID::SC078E,
                    "cannot infer the element type of an empty list; annotate the target",
                )
            }

            return &null
        }

        // `[T; N]`: the literal IS the array, element for element.
        if ex != &null && isa<FixedArrayType>(ex) && !cast<FixedArrayType>(ex)->is_incomplete {
            var at = cast<FixedArrayType>(ex)
            if count == 0 {
                self.dyn()->fail(n, DiagID::SC079E, "an array literal needs at least one element")
                return &null
            }

            // `[T; N]` over a value parameter: C++ checks it per instance.
            if at->extent_param == &null && at->size_bits != count {
                self.dyn()->fail(
                    n,
                    DiagID::SC079E,
                    f"array literal has {count} element(s), but '{self.dyn()->tu.str(ex)}' needs {at->size_bits}",
                )

                return &null
            }

            return ex
        }

        // `[T;]`: a view over a backing array ListLiteralLowering provides.
        if ex != &null && self.dyn()->tu.is_slice(ex) {
            if !self._bind_slice_ctor(n) {
                return &null
            }

            return ex
        }

        // `[T]`: an owner, built from that same view. Empty is the default ctor.
        if ex != &null && self.dyn()->tu.is_vector_like(ex) {
            if count == 0 {
                n->owner_ctor = self._lang_ctor(WellKnownType::Vector, 0, false)
            } else {
                if !self._bind_slice_ctor(n) {
                    return &null
                }

                n->owner_ctor = self._lang_ctor(WellKnownType::Vector, 1, true)
            }

            if n->owner_ctor == &null {
                self.dyn()->missing_lang_item(n, to_string(WellKnownType::Vector))
                return &null
            }

            return ex
        }

        // No container target: the literal's own type.
        if count == 0 {
            self.dyn()->fail(
                n,
                DiagID::SC078E,
                "cannot infer the type of an empty list here; annotate the target as '[T;]' or '[T]'",
            )

            return &null
        }

        return self.dyn()->sc->types->array(elem, count as u64)
    }

    priv fn _bind_slice_ctor(self, n: unsafe *ListLiteralExpr) -> bool {
        n->slice_ctor = self._lang_ctor(WellKnownType::Slice, 2, false)
        if n->slice_ctor == &null {
            self.dyn()->missing_lang_item(n, to_string(WellKnownType::Slice))
            return false
        }

        return true
    }

    /// A lang record's constructor BY SHAPE: \p nparams non-self parameters,
    /// and for \p from_slice the single one is a Slice. Found through the lang
    /// item, never by name.
    priv fn _lang_ctor(self, k: WellKnownType, nparams: usize, from_slice: bool) -> unsafe *Decl {
        return self.dyn()->tu.lang_ctor(k, nparams, from_slice)
    }

    priv fn _type_format_literal(self, n: *StringLiteralExpr, s: *Type) -> bool {
        // Every chained segment's holes: `"a" f"{x}"` keeps its hole
        // facts on the second segment, not on imm.
        if n->hole_count() != n->parts.size() {
            kairo::std::ice_fail(
                "LiteralTyping: lexer hole facts not parallel to the parser's parts",
            )
        }

        var fb = self.dyn()->sc->well_known->get(WellKnownType::FmtBuf)
        if fb == &null {
            self.dyn()->missing_lang_item(n, to_string(WellKnownType::FmtBuf))
            return false
        }

        n->fmt_ctor   = self._lang_ctor(WellKnownType::FmtBuf, 1, false)
        n->fmt_text   = self._lang_method(WellKnownType::FmtBuf, LangMembers::fmtbuf_text())
        n->fmt_finish = self._lang_method(WellKnownType::FmtBuf, LangMembers::fmtbuf_finish())
        n->fmt_len    = self._lang_method(WellKnownType::String, LangMembers::string_length())
        if n->fmt_ctor == &null
            || n->fmt_text == &null
            || n->fmt_finish == &null
            || n->fmt_len == &null {
            self.dyn()->missing_lang_item(n, to_string(WellKnownType::FmtBuf))
            return false
        }

        var ok  = true
        var out = cxx::std::vector<FormatHole>()
        for var i: usize = 0; i < n->parts.size(); ++i {
            var unsafe *e  = n->parts[i]
            var        t  = self.dyn()->type_of(e, &null)
            var        hs = n->hole_spec(i)
            if e->is_poisoned() {
                ok = false
                continue
            }

            if t == &null {
                // Untyped and not poisoned: a member result through a `: type`
                // parameter. Only the instance knows what it is.
                if !self._defer_hole(n, e, hs.spec, hs.doc, &out) {
                    ok = false
                }

                continue
            }

            // A nullable place the analysis proved is formatted as its value
            // (Compiler/Spec/Nullables.md#narrowed-reads). Unproven, it stays the nullable, which has no
            // formatter yet (SC081E below): not the nullness error, since
            // formatting a `T?` itself may well become legal.
            t = self.dyn()->value_if_proven(e, t)

            var h = FormatHole{}
            h.kind     = FormatKind::None
            h.spec     = 0
            h.put      = &null
            h.conv     = &null
            h.cast_to  = &null
            h.by_addr  = false
            h.doc      = hs.doc
            h.deferred = false

            var repr: unsafe *Decl = &null
            var conv: unsafe *Decl = &null
            if !self._classify_hole(e, t, &h, &repr, &conv) {
                ok = false
                continue
            }

            if h.deferred {
                if !self._defer_hole(n, e, hs.spec, hs.doc, &out) {
                    ok = false
                }

                continue
            }

            if !self._parse_spec(n, hs.spec, h.kind, t, &h.spec) {
                ok = false
                continue
            }

            // A record: user repr, then user `op as`, then the address form.
            // `?` skips `op as`: it asks for the repr form or nothing.
            if h.kind == FormatKind::None {
                var debug = (fmt_spec_flags(h.spec) & FMT_DEBUG) != 0
                if repr != &null {
                    h.conv = repr
                    h.kind = FormatKind::String
                } else if conv != &null && !debug {
                    h.conv = conv
                    h.kind = FormatKind::String
                } else {
                    h.kind    = FormatKind::Ptr
                    h.by_addr = true
                    h.cast_to = self.dyn()->tu.builtin(BuiltinKind::USize)
                }
            }

            // f256 / f512 / f8e4m3 / f8e5m2 format themselves: FmtBuf has no
            // put that names a library float's class (it would load them into
            // every program; f8's are in std), so the hole calls the class's fmt_put_ on the
            // value. Its lang item is bound: the file names the type, so it
            // imports the class's file (Preprocessor::_add_wide_floats).
            if h.kind == FormatKind::F256 || h.kind == FormatKind::F512
                || h.kind == FormatKind::F8E4M3 || h.kind == FormatKind::F8E5M2 {
                var wk = WellKnownType::F512
                if h.kind == FormatKind::F256 {
                    wk = WellKnownType::F256
                } else if h.kind == FormatKind::F8E4M3 {
                    wk = WellKnownType::F8E4M3
                } else if h.kind == FormatKind::F8E5M2 {
                    wk = WellKnownType::F8E5M2
                }

                h.put      = self._lang_method(wk, "fmt_put_")
                h.on_value = true
                if h.put == &null {
                    self.dyn()->missing_lang_item(n, to_string(wk))
                    ok = false
                    continue
                }

                out.push_back(h)
                continue
            }

            h.put = self._lang_method(WellKnownType::FmtBuf, fmt_put_name(h.kind))
            if h.put == &null {
                // FIXME(CONST-EVAL-FOLD): put_f80 is out of the builtin root until
                // it can be declared per target; every other row is always there.
                if h.kind == FormatKind::F80 {
                    self.dyn()->fail(
                        e,
                        DiagID::SC081E,
                        "an 'f80' value cannot be formatted yet; convert it with 'as f64' first",
                    )
                } else {
                    self.dyn()->missing_lang_item(n, to_string(WellKnownType::FmtBuf))
                }

                ok = false
                continue
            }

            out.push_back(h)
        }

        if !ok {
            return false
        }

        n->fmt_holes.from_buf(out.data(), out.size(), self.dyn()->sc->ctx)
        return true
    }

    /// A hole whose value's type is a generic body's: recorded deferred, its
    /// put left to the instance (FormatHole::deferred). The body is emitted
    /// once, as a C++ template, so the choice is C++'s at each instance
    /// (LowerTargets::fmt_dyn) -- as a duck member call is clang's -- and
    /// an instance whose value has no formatter is an error there. A spec
    /// is parsed per kind, which this hole does not have: refused.
    priv fn _defer_hole(self,
                        n:          *StringLiteralExpr,
                        e:          unsafe *Expr,
                        spec:       SourceRange,
                        doc:        SourceRange,
                        @inout out: cxx::std::vector<FormatHole>) -> bool {
        if spec.is_valid() {
            self.dyn()->fail(
                e,
                DiagID::SC080E,
                "a format spec on a value whose type is generic is not supported yet; format it without a spec, or convert it first",
            )

            return false
        }

        var h = FormatHole{}
        h.kind     = FormatKind::None
        h.spec     = 0
        h.put      = &null
        h.conv     = &null
        h.cast_to  = &null
        h.by_addr  = false
        h.doc      = doc
        h.deferred = true
        out.push_back(h)
        return true
    }

    /// The put row for a hole's value type. A record leaves `kind` as None
    /// with its candidates in \p repr / \p conv; the caller ranks them.
    /// A value whose type is a generic body's comes back `deferred`.
    priv fn _classify_hole(self,
                           e:    *Expr,
                           t:    *Type,
                           h:    *FormatHole,
                           repr: unsafe *(unsafe *Decl),
                           conv: unsafe *(unsafe *Decl)) -> bool {
        var v = self.dyn()->tu.as_value(t)
        if v == &null {
            return false
        }

        // A bounds-checked parameter formats through what its bounds grant
        // (Compiler/Spec/Generics.md#decisions): a `repr` or `op as` requirement returning string,
        // called through the witness like any other requirement.
        var cg = self.dyn()->tu.checked_head(v)
        if cg != &null {
            self._string_conv(v, repr, conv)
            // No bound grants a string: the instance's own type decides.
            if *repr == &null && *conv == &null {
                h->deferred = true
            }

            return true
        }

        if v->is_dependent() {
            h->deferred = true
            return true
        }

        if self.dyn()->tu.nullable_inner(v) != &null {
            self.dyn()->fail(
                e,
                DiagID::SC081E,
                f"a value of type '{self.dyn()->tu.str(v)}' has no formatter yet; test it and format the inner value",
            )

            return false
        }

        if self.dyn()->tu.pointee(v) != &null {
            h->kind    = FormatKind::Ptr
            h->cast_to = self.dyn()->tu.builtin(BuiltinKind::USize)
            return true
        }

        var bk = self.dyn()->tu.kind_of(v)
        // C's `char` prints its code, as u8 (0..=255 on every target, signed
        // char or not): it is a C character, and Kairo's text type is string.
        // The other C character types likewise print their code unsigned:
        // char8_t as u8, char16_t as u16, wchar_t as u32 (a 16-bit one
        // zero-extends, a signed 32-bit one reads as the same bits).
        if is_c_character(bk) {
            var ck = BuiltinKind::U8
            var fk = FormatKind::U8
            if bk == BuiltinKind::CChar16 {
                ck = BuiltinKind::U16
                fk = FormatKind::U16
            }

            if bk == BuiltinKind::CWChar {
                ck = BuiltinKind::U32
                fk = FormatKind::U32
            }

            h->kind    = fk
            h->cast_to = self.dyn()->tu.builtin(ck)
            return true
        }

        if bk != BuiltinKind::COUNT {
            var fk = format_kind_of(bk)
            if fk == FormatKind::COUNT {
                self.dyn()->fail(
                    e,
                    DiagID::SC081E,
                    f"a value of type '{self.dyn()->tu.str(v)}' cannot be formatted",
                )

                return false
            }

            h->kind = fk
            return true
        }

        if self.dyn()->tu.is_string(v) {
            h->kind = FormatKind::String
            return true
        }

        var d = self.dyn()->tu.record_decl(v)
        if d == &null {
            self.dyn()->fail(
                e,
                DiagID::SC081E,
                f"a value of type '{self.dyn()->tu.str(v)}' has no formatter",
            )

            return false
        }

        var en = dyn_cast<EnumDecl>(NameLookup::representative(d))
        if en != &null && !en->is_adt {
            // A plain enum prints its discriminant until the synthesized repr exists.
            var under: unsafe *Type = &null
            if en->underlying != &null && en->underlying->canonical != &null {
                under = canon_unqual(en->underlying->canonical)
            }

            if under == &null {
                under = self.dyn()->tu.builtin(BuiltinKind::U32)
            }

            h->kind    = format_kind_of(self.dyn()->tu.kind_of(under))
            h->cast_to = under
            return h->kind != FormatKind::COUNT
        }

        self._string_conv(v, repr, conv)
        return true // kind stays None; the caller ranks.
    }

    /// `fn repr(self) -> string` and `fn op as(self) -> string` on \p v, own
    /// members and extensions alike, in that order of preference. Through
    /// ExprTyper's MemberLookup, whose extension index is built once at
    /// construction.
    priv fn _string_conv(self,
                         v:    unsafe *Type,
                         repr: unsafe *(unsafe *Decl),
                         conv: unsafe *(unsafe *Decl)) {
        var s = self.dyn()->tu.string_type()
        // A bounds-checked parameter's members are its bounds' requirements.
        var scopes = cxx::std::vector<unsafe *Type>()
        if self.dyn()->tu.checked_head(v) != &null {
            scopes = Substitution(self.dyn()->sc).bound_ifaces(v)
        } else {
            scopes.push_back(v)
        }

        var imm   = self.dyn()->sc->imm_table()->intern_ident_copy(LangMembers::repr())
        var cands = cxx::std::vector<unsafe *Decl>()
        for var k: usize = 0; k < scopes.size(); ++k {
            self.dyn()->ml.lookup(scopes[k], DeclName::ident(imm), &cands)
        }

        for var i: usize = 0; i < cands.size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>(cands[i])
            if f == &null || !f->is_method() || f->is_operator {
                continue
            }

            if OperatorFacts::arity(f) != 0 || !self._returns(f, s) {
                continue
            }

            *repr = cands[i]
            break
        }

        cands.clear()
        for var k: usize = 0; k < scopes.size(); ++k {
            self.dyn()->ml.lookup(
                scopes[k],
                DeclName::op_name(TokenKind::KwAs, TokenKind::TkUnknown),
                &cands,
            )
        }

        for var i: usize = 0; i < cands.size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>(cands[i])
            if f == &null || !f->is_method() || !f->is_operator {
                continue
            }

            if OperatorFacts::arity(f) != 0 || !self._returns(f, s) {
                continue
            }

            *conv = cands[i]
            break
        }
    }

    priv fn _returns(self, f: *FunctionDecl, t: unsafe *Type) -> bool {
        if f->return_type == &null || f->return_type->canonical == &null {
            return false
        }

        return canon_unqual(f->return_type->canonical) == canon_unqual(t)
    }

    /// A lang record's method by NAME, spelled into that record's own TU.
    priv fn _lang_method(self, k: WellKnownType, const name: string) -> unsafe *Decl {
        var d = self.dyn()->sc->well_known->get(k)
        if d == &null {
            return &null
        }

        var body = self.dyn()->tu.pattern_of(NameLookup::representative(d))
        var dc   = NameLookup::context_of(body)
        if dc == &null {
            return &null
        }

        var imm  = self.dyn()->sc->imm_table()->intern_ident_copy(name)
        var cell = self.dyn()->sc->lookup.in_context(dc, DeclName::ident(imm), name)
        if !cell.found() {
            return &null
        }

        for var i: usize = 0; i < cell.cell->size(); ++i {
            var f = dyn_cast<FunctionDecl>(cell.cell->get(i))
            if f != &null && f->is_method() {
                return cell.cell->get(i)
            }
        }

        return &null
    }

    /// # format specs
    ///
    ///   spec := [[fill] align] ['+'] ['#'] ['0'] [width] ['.' precision] [type] | '?'
    ///   align := '<' | '>' | '^'      type := 'x' | 'X' | 'o' | 'b' | 'e' | 'E'
    ///
    /// Parsed here, packed into one word (LangItems::fmt_pack_spec), validated
    /// against the hole's kind. Reported at the spec's own bytes.

    priv fn _is_align(self, b: u8) -> bool {
        return b == ('<' as u8) || b == ('>' as u8) || b == ('^' as u8)
    }

    priv fn _align_code(self, b: u8) -> u64 {
        if b == ('<' as u8) {
            return FormatAlign::Left as u8
        }

        if b == ('>' as u8) {
            return FormatAlign::Right as u8
        }

        return FormatAlign::Center as u8
    }

    priv fn _spec_error(self,
                        n:             *StringLiteralExpr,
                        at:            SourceRange,
                        const spelled: string,
                        t:             *Type,
                        const why:     string) -> bool {
        self.dyn()->sc->diag->report(
            DiagID::SC036E,
            at.start,
            f"invalid format spec '{spelled}' for a value of type '{self.dyn()->tu.str(t)}': {why}",
        ).first(at)->emit()
        return false
    }

    priv fn _parse_spec(self,
                        n:    *StringLiteralExpr,
                        at:   SourceRange,
                        kind: FormatKind,
                        t:    *Type,
                        out:  unsafe *u64) -> bool {
        *out = 0
        if !at.is_valid() {
            return true
        }

        var view    = self.dyn()->sc->ctx->sm->get_view(at)
        var p       = view.data()
        var len     = view.size()
        var spelled = self.dyn()->sc->ctx->sm->get_text(at)

        var is_int = (kind as u8) >= (FormatKind::I8 as u8)
            && (kind as u8) <= (FormatKind::USize as u8)
        var is_float = (kind as u8) >= (FormatKind::F8E4M3 as u8)
            && (kind as u8) <= (FormatKind::F512 as u8)
        var is_text = kind == FormatKind::String
            || kind == FormatKind::Char
            || kind == FormatKind::Bool
        var is_rec = kind == FormatKind::None

        if len == 1 && p[0] == ('?' as u8) {
            *out = fmt_pack_spec(0, 0, 0, 0, 0, FMT_DEBUG)
            return true
        }

        if kind == FormatKind::Ptr {
            return self._spec_error(n, at, spelled, t, "a pointer takes no format spec")
        }

        var width:   u64   = 0
        var prec1:   u64   = 0
        var fill:    u64   = 0
        var align:   u64   = 0
        var base:    u64   = 0
        var flags:   u64   = 0
        var type_ch: u8    = 0
        var i:       usize = 0

        var first = UTF8View::decode_utf8(p, len)
        if first.len > 0 && first.len < len && self._is_align(p[first.len]) {
            fill  = (first.chr as u64)
            align = self._align_code(p[first.len])
            i     = first.len + 1
        } else if len > 0 && self._is_align(p[0]) {
            align = self._align_code(p[0])
            i     = 1
        }

        if i < len && p[i] == ('+' as u8) {
            flags |= (FMT_SIGN_PLUS)
            i += 1
        } else if i < len && p[i] == ('-' as u8) {
            return self._spec_error(n, at, spelled, t, "'-' is the default sign; remove it")
        }

        if i < len && p[i] == ('#' as u8) {
            flags |= (FMT_ALT)
            i += 1
        }

        if i < len && p[i] == ('0' as u8) {
            flags |= (FMT_ZERO)
            i += 1
        }

        while i < len && p[i] >= ('0' as u8) && p[i] <= ('9' as u8) {
            width = width * 10 + ((p[i] - ('0' as u8)) as u64)
            if width > 0xFFFF {
                return self._spec_error(n, at, spelled, t, "width is limited to 65535")
            }

            i += 1
        }

        if i < len && p[i] == ('.' as u8) {
            i += 1
            var digits: usize = 0
            var prec:   u64   = 0
            while i < len && p[i] >= ('0' as u8) && p[i] <= ('9' as u8) {
                prec = prec * 10 + ((p[i] - ('0' as u8)) as u64)
                if prec > 0xFFFE {
                    return self._spec_error(n, at, spelled, t, "precision is limited to 65534")
                }

                i += 1
                digits += 1
            }

            if digits == 0 {
                return self._spec_error(n, at, spelled, t, "'.' must be followed by a precision")
            }

            prec1 = prec + 1
        }

        if i < len {
            type_ch = p[i]
            match type_ch {
                case 0x78 /* 'x' */ {
                    base = 1
                } case 0x58 /* 'X' */ {
                    base = 1
                    flags |= (FMT_UPPER)
                } case 0x6f /* 'o' */ {
                    base = 2
                } case 0x62 /* 'b' */ {
                    base = 3
                } case 0x65 /* 'e' */ {
                    base = 1
                } case 0x45 /* 'E' */ {
                    base = 1
                    flags |= (FMT_UPPER)
                } default {
                    return self._spec_error(
                        n,
                        at,
                        spelled,
                        t,
                        f"'{spelled.subslice(i, spelled.size())}' is not a format type",
                    )
                }
            }

            i += 1
        }

        if i < len {
            return self._spec_error(
                n,
                at,
                spelled,
                t,
                "unexpected characters after the format type",
            )
        }

        // Per kind.
        if is_int {
            if prec1 != 0 {
                return self._spec_error(
                    n,
                    at,
                    spelled,
                    t,
                    "precision applies to floats and strings",
                )
            }

            if type_ch == ('e' as u8) || type_ch == ('E' as u8) {
                return self._spec_error(n, at, spelled, t, "'e' applies to floats")
            }
        } else if is_float {
            if type_ch == ('x' as u8)
                || type_ch == ('X' as u8)
                || type_ch == ('o' as u8)
                || type_ch == ('b' as u8) {
                return self._spec_error(n, at, spelled, t, "an integer base applies to integers")
            }

            if (flags & (FMT_ALT as u64)) != 0 {
                return self._spec_error(n, at, spelled, t, "'#' applies to integers")
            }
        } else if kind == FormatKind::Byte {
            if prec1 != 0
                || type_ch != 0
                || (flags & ((FMT_SIGN_PLUS as u64) | (FMT_ZERO as u64))) != 0 {
                return self._spec_error(
                    n,
                    at,
                    spelled,
                    t,
                    "a byte takes width, alignment and '#' only",
                )
            }
        } else if is_text || is_rec {
            if type_ch != 0
                || (flags & ((FMT_SIGN_PLUS as u64) | (FMT_ALT as u64) | (FMT_ZERO as u64))) != 0 {
                return self._spec_error(
                    n,
                    at,
                    spelled,
                    t,
                    "text takes width, alignment and precision only",
                )
            }

            if prec1 != 0 && kind != FormatKind::String && !is_rec {
                return self._spec_error(
                    n,
                    at,
                    spelled,
                    t,
                    "precision applies to floats and strings",
                )
            }
        }

        *out = fmt_pack_spec(width, prec1, fill, align, base, flags)
        return true
    }

    /// # list storage

    fn is_slice_literal(self, e_in: *Expr) -> bool {
        var e = self.dyn()->tu.strip_parens(e_in)
        if e == &null || !isa<ListLiteralExpr>(e) {
            return false
        }

        return e->type_ != &null && self.dyn()->tu.is_slice(e->type_)
    }

    /// A slice literal that directly initializes a `var` gets a backing array
    /// in that var's scope, and so does every slice literal nested in it.
    fn mark_list_storage(self, init: *Expr) {
        if !self.is_slice_literal(init) {
            return
        }

        var n = cast<ListLiteralExpr>(self.dyn()->tu.strip_parens(init))
        n->storage = ListStorage::Extended
        for var i: usize = 0; i < n->elements.size(); ++i {
            self.mark_list_storage(n->elements[i])
        }
    }

    /// The positions with no scope to extend a backing array into. A callee
    /// that RETAINS a slice argument is not decidable here; that is AMT's
    /// escape clause.
    fn reject_slice_literal(self, e: *Expr, const what: string) -> bool {
        if !self.is_slice_literal(e) {
            return false
        }

        self.dyn()->fail(
            self.dyn()->tu.strip_parens(e),
            DiagID::SC082E,
            f"a list literal {what} is a view of a temporary array and would outlive it; use '[T]' to own the elements, or bind the literal to a 'var' first",
        )

        return true
    }

    /// An array is initialized from a list literal and from nothing else:
    /// copying one is not an initialization C++ has. A variable's
    /// initializer and an aggregate initializer's field value both land
    /// here; true when \p value was rejected.
    fn reject_array_copy(self, value: *Expr, t: unsafe *Type) -> bool {
        var unsafe *c = canon_unqual(t)
        if c == &null || !isa<FixedArrayType>(c) {
            return false
        }

        var v = self.dyn()->tu.strip_parens(value)
        if v == &null || v->is_poisoned() || isa<ListLiteralExpr>(v) {
            return false
        }

        self.dyn()->fail(
            v,
            DiagID::SC083E,
            "an array is not copyable; initialize it from a list literal, or view the source through a slice or a pointer",
        )

        return true
    }

    fn type_set_literal(self, n: unsafe *SetLiteralExpr, expected: unsafe *Type) -> unsafe *Type {
        // `{}` parses as a set; against a map target it is the empty map.
        var target = self.dyn()->tu.strip_nullable(expected)
        if n->elements.size() == 0 && target != &null && self.dyn()->tu.is_map_like(target) {
            return canon_unqual(target)
        }

        var elem_expected = self.dyn()->tu.container_elem(self.dyn()->tu.strip_nullable(expected))
        var elem: unsafe *Type = elem_expected
        var hole: unsafe *Expr = &null
        for var i: usize = 0; i < n->elements.size(); ++i {
            var t = self.dyn()->type_of(n->elements[i], elem_expected)
            if t == &null {
                if hole == &null {
                    hole = n->elements[i]
                }

                continue
            }

            if elem_expected != &null {
                self.dyn()->check_convertible(n->elements[i], elem_expected)
                continue
            }

            var j = self.dyn()->conv.join(elem, t)
            if j == &null {
                self.dyn()->fail(n->elements[i], DiagID::SC077E, "set elements do not share a type")
                self.dyn()->poison_only(n)
                return &null
            }

            elem = j
        }

        if hole != &null {
            self._lift_hole(n, hole)
            return &null
        }

        if elem == &null {
            if n->elements.size() == 0 {
                self.dyn()->fail(
                    n,
                    DiagID::SC078E,
                    "cannot infer the element type of an empty set; annotate the target",
                )
            }

            return &null
        }

        return self.dyn()->tu.set_of(elem)
    }

    fn type_map_literal(self, n: unsafe *MapLiteralExpr, expected: unsafe *Type) -> unsafe *Type {
        var ek: unsafe *Type = &null
        var ev: unsafe *Type = &null
        self.dyn()->tu.map_key_value(
            self.dyn()->tu.strip_nullable(expected),
            unsafe &ek,
            unsafe &ev,
        )

        var k:    unsafe *Type = ek
        var v:    unsafe *Type = ev
        var hole: unsafe *Expr = &null
        for var i: usize = 0; i < n->entries.size(); ++i {
            var unsafe *en = n->entries.get(i)
            var        kt  = self.dyn()->type_of(en->key, ek)
            var        vt  = self.dyn()->type_of(en->value, ev)
            if kt == &null && hole == &null {
                hole = en->key
            }

            if vt == &null && hole == &null {
                hole = en->value
            }

            if kt == &null || vt == &null {
                continue
            }

            if ek != &null {
                self.dyn()->check_convertible(en->key, ek)
            } else if kt != &null {
                var j = self.dyn()->conv.join(k, kt)
                if j == &null {
                    self.dyn()->fail(en->key, DiagID::SC077E, "map keys do not share a type")
                    self.dyn()->poison_only(n)
                    return &null
                }

                k = j
            }

            if ev != &null {
                self.dyn()->check_convertible(en->value, ev)
            } else if vt != &null {
                var j = self.dyn()->conv.join(v, vt)
                if j == &null {
                    self.dyn()->fail(en->value, DiagID::SC077E, "map values do not share a type")
                    self.dyn()->poison_only(n)
                    return &null
                }

                v = j
            }
        }

        if hole != &null {
            self._lift_hole(n, hole)
            return &null
        }

        if k == &null || v == &null {
            if n->entries.size() == 0 {
                self.dyn()->fail(
                    n,
                    DiagID::SC078E,
                    "cannot infer the key and value types of an empty map; annotate the target",
                )
            }

            return &null
        }

        // ListLiteralLowering builds the entries as `(K, V)` tuples: mint the
        // Tuple2 instance here, while instances are still being registered.
        if n->entries.size() > 0 {
            var kv = cxx::std::vector<unsafe *Type>()
            kv.push_back(k)
            kv.push_back(v)
            self.dyn()->tu.tuple_of(unsafe &kv)
        }

        return self.dyn()->tu.map_of(k, v)
    }

    /// An aggregate literal whose element came back untyped takes the
    /// element's outcome: poisoned with it, or unknown with it. Returning null
    /// without one of those leaves the literal in no terminal state, which
    /// finish() treats as a typer bug. A child that is neither (a type- or
    /// module-denoting expr used as a value) has no diagnostic of its own, so
    /// it gets one here.
    fn _lift_hole(self, n: unsafe *Expr, child: unsafe *Expr) {
        if self.dyn()->propagate(n, child) {
            return
        }

        self.dyn()->fail(child, DiagID::SC077E, "this element has no value type")
        self.dyn()->poison_only(n)
    }

    fn type_tuple_literal(self,
                          n:        unsafe *TupleLiteralExpr,
                          expected: unsafe *Type) -> unsafe *Type {
        var ex = canon_unqual(self.dyn()->tu.strip_nullable(expected))
        // An expected tuple of the same arity types each element; any other
        // expectation is left for the conversion check at the use.
        var have_expected = ex != &null
            && self.dyn()->tu.is_tuple(ex)
            && self.dyn()->tu.tuple_arity(ex) == n->elements.size()
        var ex_elems              = self.dyn()->tu.tuple_elems(ex)
        var elems                 = cxx::std::vector<*Type>()
        var hole:    unsafe *Expr = &null
        for var i: usize = 0; i < n->elements.size(); ++i {
            var e_exp: unsafe *Type = if (have_expected) => (ex_elems[i]) else => &null
            var t                   = self.dyn()->type_of(n->elements[i], e_exp)
            if t == &null {
                if hole == &null {
                    hole = n->elements[i]
                }

                continue
            }

            if e_exp != &null {
                self.dyn()->check_convertible(n->elements[i], e_exp)
            }

            // A tuple element is a value: an imported `T&`/`T&&` result
            // (`(d, cxx::std::move(c))`) is a tuple of the T it refers to,
            // not of a reference type that no `(A, T)` target accepts.
            var ec = canon_unqual(t)
            if ec != &null && (isa<CXXLValueRefType>(ec) || isa<CXXRValueRefType>(ec)) {
                t = self.dyn()->tu.as_value(ec)
            }

            elems.push_back(t)
        }

        if hole != &null {
            self._lift_hole(n, hole)
            return &null
        }

        var t = self.dyn()->tu.tuple_of(&elems)
        if t == &null {
            self.dyn()->missing_lang_item(n, tuple_record_name(elems.size()))
            return &null
        }

        return t
    }
}
