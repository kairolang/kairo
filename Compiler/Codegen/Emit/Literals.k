/// --- The Kairo Project ---------------------- Codegen/Emit/Literals.k --- ///
///
///   EmitIR, part: literals and initializers. Integer, floating and string
///   literals in the C++ spelling that keeps their exact value and type,
///   initializer lists, named and anonymous initializers, and variant
///   construction.
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
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/Shims.hh"
ffi "c++" import "clang/Basic/TokenKinds.h"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::DeclFacts::{
    decl_fields,
    decl_is_instance,
    decl_methods,
    decl_pattern,
}
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    BuiltinKind,
    BuiltinType,
    RecordType,
    builtin_info,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    AdtCtorForm,
    EnumDecl,
}
import AST::Node::Expressions::{
    InitField,
    InitListExpr,
    ParenExpr,
    UnaryOperatorExpr,
    VariantInitExpr,
}
import AST::Node::PrimaryExpressions::{
    FloatingLiteralExpr,
    IntegerLiteralExpr,
    StringLiteralExpr,
}
import AST::Node::Types::{
    FixedArrayType,
    GenericParamType,
    PointerType,
}
import AST::PrimitiveLimits::{
    PrimLimit,
    PrimitiveLimits,
}
import Codegen::Emit::Convert
import Codegen::Emit::Decls
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Spell::Spell::Speller
import Lexer::Immediate::Immediate
import Location::SourceRange::SourceRange
import Support::Escape::c_string_literal
import Token::TokenKind::TokenKind

extend EmitIR {
    /// What reaches here is the BYTE literal StringLowering or FStringLowering
    /// minted, typed as a pointer, spelled from its decoded bytes. Octal for
    /// every byte outside printable ASCII: C++'s `\x` is greedy, octal is not.
    prot fn _string(self, n: unsafe *StringLiteralExpr) {
        if n->is_format() {
            self._ice(n->range, "EmitIR: f-string; FStringLowering owns it")
        }

        if n->has_next() {
            self._ice(
                n->range,
                "EmitIR: multi-part string literal; StringLowering owns it",
            )
        }

        var unsafe *c = canon_unqual(n->type_)
        if c == &null || c->kind != TypeKind::PointerType {
            self._ice(
                n->range,
                "EmitIR: string literal typed `string`; StringLowering owns it",
            )
        }

        if n->imm == &null || !n->imm->has_owned_text() {
            self._ice(
                n->range,
                "EmitIR: byte literal with no minted bytes; LowerSynth::bytes_literal owns it",
            )
        }

        var unsafe *p  = n->imm->owned_ptr
        var        len = (n->imm->owned_len as usize)
        // Read at compile time (Compiler/Spec/Eval.md#strings-at-compile-time): the bytes as template
        // arguments of `__kairo_estr`, a `const unsigned char` array with the
        // NUL appended, which needs no cast to reach the string's `data`.
        // A string literal of the two-word library: the bytes member of its
        // read-only object, which InterfaceEmitter defined at global scope
        // ahead of every body (EmitPlan::big_strs collected it).
        if n->lit_header {
            self._cg->sink->spell(
                n->range,
                "::" + LowerTargets::lit_str(
                    LowerTargets::eval_str_hash(p, len),
                    len,
                ) + "." + LowerTargets::lit_str_bytes(),
            )

            return
        }

        if n->const_eval {
            // A long one is a named array instead (Compiler/Spec/Eval.md#value-nodes), which
            // InterfaceEmitter defined at global scope ahead of every body
            // (EmitPlan::big_strs collected it from this body).
            if len > LowerTargets::eval_str_inline_max() {
                self._cg->sink->spell(
                    n->range,
                    "::" + LowerTargets::eval_str_hashed(
                        LowerTargets::eval_str_hash(p, len),
                        len,
                    ),
                )

                return
            }

            var t = "::" + LowerTargets::eval_str() + "<"
            for var i: usize = 0; i < len; ++i {
                if i > 0 {
                    t += ", "
                }

                t += f"{(p[i] as u32)}"
            }

            t += ">"
            self._cg->sink->spell(n->range, t)
            return
        }

        var s     = c_string_literal(p, len)
        var cxx_v = s.copy()
        self._cg->sink->create_str(n->token, &cxx_v)
    }

    /// Same rule for a numeric constant: a minted IntData carries no source
    /// body, so it is spelled from its value instead of borrowed.
    ///
    /// The table is the owning file's too. Reading this TU's instead found
    /// some other IntData (or none) for a foreign inline body's minted
    /// constant, and the fallback below then borrowed whatever bytes the
    /// token's range covered -- `"true"` spelled as a numeric constant.
    ///
    /// A SUFFIXED literal is spelled exactly typed, `static_cast<T>(v)`: the
    /// suffix is a declaration (`1u8` is a u8 wherever it stands), and C++
    /// re-reads a bare `1` as an int -- an overload set, a deduced template
    /// argument or `auto` then picks a different entity than Sema did.
    ///
    /// The others borrow their bytes unless C++ cannot read them: a `_`
    /// separator (a user-defined-literal suffix to clang), the `0o` prefix
    /// (C++ octal is a bare leading 0), or a top-bit value (too large for a
    /// signed literal; ULL). Those are respelled from the value, untyped, so
    /// the contextual type still converts them where it did.
    ///
    /// A value of 2^64 or more is never borrowed either: C++ has no integer
    /// literal wider than unsigned long long, so clang rejects the bytes
    /// whatever the target type. _int_text builds it from its halves.
    prot fn _int_lit(self, n: unsafe *IntegerLiteralExpr) {
        var t = n->token
        if n->is_big() {
            self._ice(
                t.range,
                "EmitIR: integer literal wider than 128 bits; limb composition is not emitted yet",
            )
        }

        var hi = n->get_value_hi()
        if hi != 0 {
            if n->type_ == &null {
                self._ice(
                    t.range,
                    "EmitIR: untyped wide integer literal reached codegen; ExprTyper gate failure",
                )
            }

            self._cg->sink->spell(
                t.range,
                self._int_text(n->type_, hi, n->get_value_lo(), false),
            )

            return
        }

        // A literal from a macro body (or a literal macro argument) is a
        // wrapped token: its imm is the expansion record and its range the
        // invocation, so neither indexes the payload nor covers the digits
        // (`seven!()` borrowed as a numeric constant). The node's own imm,
        // attached from the writing file's table at parse, is the payload;
        // the digits are spelled from the value.
        var wrapped = (t.kind as u32) == (TokenKind::TkMacroExpand as u32)
        var d: unsafe *Immediate::IntData = &null
        if wrapped {
            d = n->imm
        } else {
            var unsafe *tbl = self._cg->ctx->tcm->get_imm_table_for_fid(
                self._owning_fid(),
            )

            if tbl == &null {
                self._ice(
                    t.range,
                    "EmitIR: no immediate table for the file that owns this body",
                )
            }

            d = tbl->get<Immediate::IntData>(t.imm)
        }

        if d == &null && wrapped {
            self._ice(
                t.range,
                "EmitIR: a macro-expanded integer literal has no immediate data",
            )
        }

        if d == &null {
            self._cg->sink->synth(t, clang::tok::numeric_constant)
            return
        }

        // A literal Sema typed `byte` from context is an `enum class`
        // in C++, which no int converts to implicitly: it takes the explicit
        // cast spelling `0xFF as byte` gets, or clang rejects the init.
        var is_byte = false
        if n->type_ != &null {
            var unsafe *bc = canon_unqual(n->type_)
            if bc != &null && isa<BuiltinType>(bc) {
                is_byte = cast<BuiltinType>(bc)->builtin == BuiltinKind::Byte
            }
        }

        // A Kairo suffix (`0xFFu8`).
        var suffixed = d->has_flag(Immediate::IntFlags::HasSuffix) || is_byte
        if suffixed && n->type_ != &null {
            self._cg->sink->spell(
                t.range,
                self._int_text(n->type_, 0, d->value_lo, false),
            )

            return
        }

        if wrapped
            || !d->body.is_valid()
            || suffixed
            || d->value_lo >> 63 != 0
            || !self._int_bytes_are_cxx(d) {
            var cxx_v = self._int_text(&null, 0, d->value_lo, false)
            self._cg->sink->create_int(t.range, &cxx_v)
            return
        }

        self._cg->sink->synth(t, clang::tok::numeric_constant)
    }

    /// Whether a literal's own bytes are a C++ integer literal: no `_`
    /// separator and no `0o` prefix. Hex and binary prefixes are C++'s too.
    priv fn _int_bytes_are_cxx(self, d: unsafe *Immediate::IntData) -> bool {
        var unsafe *sm  = self._cg->ctx->sm
        var        body = sm->get_text(d->body)
        for var i: usize = 0; i < body.size(); ++i {
            if body.data()[i] == ('_' as u8) {
                return false
            }
        }

        if d->has_flag(Immediate::IntFlags::HasPrefix) && d->prefix.is_valid() {
            var pre = sm->get_text(d->prefix)
            if pre.size() == 2 && (pre.data()[1] == ('o' as u8) || pre.data()[1] == ('O' as u8)) {
                return false
            }
        }

        return true
    }

    /// The C++ for the integer `hi:lo` (negated when `neg`), cast to `ty`
    /// when one is given. Every piece is a literal C++ reads at its full
    /// width: a magnitude of 2^64 or more is composed in `unsigned
    /// __int128` (multiplication, not `<<`: spell() fuses `<<` only after
    /// `operator`), and a negative one is negated where that cannot
    /// overflow -- `-2^63` as `(-9223372036854775807LL - 1)`, anything wider
    /// in the unsigned 128-bit type, whose wrap the cast turns back into the
    /// signed value. Negating the magnitude in the target type instead is
    /// the signed overflow clang reported for the i128 minimum.
    prot fn _int_text(self, ty: unsafe *Type, hi: u64, lo: u64, neg: bool) -> string {
        var one: u64 = 1
        var top      = one << 63
        var v        = ""
        var wide     = builtin_info(BuiltinKind::U128)->cxx.copy()
        if hi != 0 {
            v = "static_cast<" + wide + f">({hi}ULL) * 4294967296ULL * 4294967296ULL + {lo}ULL"
            if neg {
                v = "static_cast<" + wide + ">(0) - (" + v + ")"
            }
        } else if neg {
            if lo < top {
                v = f"-{lo}"
            } else if lo == top {
                v = "(-9223372036854775807LL - 1)"
            } else {
                v = "static_cast<" + wide + f">(0) - {lo}ULL"
            }
        } else {
            v = f"{lo}"
            if lo >> 63 != 0 {
                v += "ULL"
            }
        }

        if ty == &null {
            return v
        }

        return f"(static_cast<{self._spell._type(ty)}>({v}))"
    }

    /// `-L` for an integer literal L that is suffixed or 2^63 or more: the
    /// negated value itself, exactly typed, instead of a negation C++ does
    /// in its own type. `-128i8` negated after the cast is the int 128, and
    /// initializing an i8 with it is a constant-conversion warning; the i64
    /// and i128 minimums overflow outright. Null when `n` is not that.
    prot fn _negated_int_lit(self, n: unsafe *UnaryOperatorExpr) -> unsafe *IntegerLiteralExpr {
        if !n->is_prefix() || n->op_token.kind != TokenKind::OpMinus {
            return &null
        }

        var unsafe *opnd = n->operand
        while opnd != &null && isa<ParenExpr>(opnd) {
            opnd = cast<ParenExpr>(opnd)->inner
        }

        if opnd == &null || !isa<IntegerLiteralExpr>(opnd) {
            return &null
        }

        var unsafe *lit = cast<IntegerLiteralExpr>(opnd)
        if lit->imm == &null || lit->is_big() || lit->type_ == &null {
            return &null
        }

        var unsafe *c = canon_unqual(lit->type_)
        if c == &null || !isa<BuiltinType>(c) {
            return &null
        }

        var *info = cast<BuiltinType>(c)->info()
        if !info->is_integer() || !info->is_signed() {
            return &null
        }

        if lit->has_suffix() || lit->get_value_hi() != 0 || lit->get_value_lo() >> 63 != 0 {
            return lit
        }

        return &null
    }

    /// A float literal, spelled so clang parses it AT its Kairo type: the
    /// source digits (separators dropped) with the C++ suffix of that type.
    /// The decimal text is re-read, never printed from value_ieee, so the
    /// rounding is clang's correctly-rounded one per format. The borrowed
    /// bytes of `1.5f32` were "invalid suffix 'f32'", and an unsuffixed
    /// `var q: f128 = 0.1` was the double 0.1 widened, 0.10000000000000000555.
    ///
    ///   f16 `f16`, f32 `f`, f64 none, f80 `L`, f128 `Q`
    ///   bf16 has no literal suffix: `static_cast<__bf16>(<digits>f)`.
    ///   f256 / f512 are library classes: their parser (_wide_float_lit).
    ///   f8* are library classes too: their encoding, rounded here (_f8_lit).
    ///
    /// An unsuffixed f64 literal with no separator keeps its own bytes.
    prot fn _float_lit(self, n: unsafe *FloatingLiteralExpr) {
        var t = n->token
        // A primitive's limit (`f32::MAX`, `f64::NAN`): no digits behind it.
        if n->limit != (0 as u8) {
            var unsafe *c0 = canon_unqual(n->type_)
            if c0 == &null || !isa<BuiltinType>(c0) {
                self._ice(
                    t.range,
                    "EmitIR: a primitive limit literal is not typed as its builtin",
                )
            }

            var text = PrimitiveLimits::float_cxx(
                cast<BuiltinType>(c0)->builtin,
                n->limit as PrimLimit,
            )

            if text == "" {
                self._ice(
                    t.range,
                    "EmitIR: a primitive limit literal names no float limit",
                )
            }

            self._cg->sink->spell(t.range, text)
            return
        }

        // A macro-wrapped literal: payload from the node, digits rebuilt from
        // the body below (never borrowed from the invocation's range), as in
        // _int_lit.
        var wrapped = (t.kind as u32) == (TokenKind::TkMacroExpand as u32)
        var d: unsafe *Immediate::FloatData = &null
        if wrapped {
            d = n->imm
            if d == &null || !d->body.is_valid() {
                self._ice(
                    t.range,
                    "EmitIR: a macro-expanded float literal has no immediate data",
                )
            }
        } else {
            var unsafe *tbl = self._cg->ctx->tcm->get_imm_table_for_fid(
                self._owning_fid(),
            )

            if tbl != &null {
                d = tbl->get<Immediate::FloatData>(t.imm)
            }
        }

        if d == &null || !d->body.is_valid() {
            self._cg->sink->synth(t, clang::tok::numeric_constant)
            return
        }

        var        k  = BuiltinKind::COUNT
        var unsafe *c = canon_unqual(n->type_)
        if c != &null && isa<BuiltinType>(c) {
            k = cast<BuiltinType>(c)->builtin
        }

        var unsafe *sm    = self._cg->ctx->sm
        var        body   = sm->get_text(d->body)
        var        hex    = d->has_flag(Immediate::FloatFlags::IsHex)
        var        digits = ""
        var        sep    = false
        var        point  = false
        for var i: usize = 0; i < body.size(); ++i {
            var ch = body.data()[i]
            if ch == ('_' as u8) {
                sep = true
                continue
            }

            if ch == ('.' as u8) {
                point = true
            }

            if !hex && (ch == ('e' as u8) || ch == ('E' as u8)) {
                point = true
            }

            if hex && (ch == ('p' as u8) || ch == ('P' as u8)) {
                point = true
            }

            digits.push(ch)
        }

        var suffixed = d->has_flag(Immediate::FloatFlags::HasSuffix)
        if !wrapped && !suffixed && !sep && (k == BuiltinKind::F64 || k == BuiltinKind::COUNT) {
            self._cg->sink->synth(t, clang::tok::numeric_constant)
            return
        }

        // `5f32` is a float in Kairo; `5f` is not a C++ floating literal,
        // and a hex one needs its binary exponent.
        if hex {
            var pre = "0x"
            if d->prefix.is_valid() {
                pre = sm->get_text(d->prefix)
            }

            digits = pre + digits
            if !point {
                digits += "p0"
            }
        } else if !point {
            digits += ".0"
        }

        match k {
            case BuiltinKind::F16 {
                digits += "f16"
            } case BuiltinKind::F32 {
                digits += "f"
            } case BuiltinKind::F80 {
                digits += "L"
            } case BuiltinKind::F128 {
                digits += "Q"
            } case BuiltinKind::BF16 {
                digits += "f"
                self._cg->sink->spell(
                    t.range,
                    f"static_cast<{self._spell._type(n->type_)}>(",
                )

                self._cg->sink->create_int(t.range, &digits)
                self._cg->sink->spell(t.range, ")")
                return
            } case BuiltinKind::F256 {
                self._wide_float_lit(t.range, n->type_, &digits)
                return
            } case BuiltinKind::F512 {
                self._wide_float_lit(t.range, n->type_, &digits)
                return
            } case BuiltinKind::F8E4M3 {
                self._f8_lit(t.range, n->type_, &digits, false)
                return
            } case BuiltinKind::F8E5M2 {
                self._f8_lit(t.range, n->type_, &digits, true)
                return
            } default { }
        }

        self._cg->sink->create_int(t.range, &digits)
    }

    /// An f256 / f512 literal: no C++ literal has the precision, so the
    /// digits go to the class's parser, `F256::lit_("<digits>", n)`, which
    /// rounds them once from the decimal (or hex) text, exactly as clang
    /// rounds a `1.5Q`. A call at run time, not a constant.
    priv fn _wide_float_lit(self, at: SourceRange, ty: unsafe *Type, digits: *string) {
        var text = self._spell._type(ty) + "::lit_(\"" + *digits + "\", "
        text += f"{digits->size()})"
        self._cg->sink->spell(at, text)
    }

    /// An f8e4m3 / f8e5m2 literal: its class's `from_bits(b)`, the
    /// encoding rounded once from the digits at compile time
    /// (kairo::f8_literal_bits, APFloat). A double literal, which the class
    /// converts from, would round twice: to f64, then to the format.
    priv fn _f8_lit(self, at: SourceRange, ty: unsafe *Type, digits: *string, e5m2: bool) {
        var b: i32 = 0
        unsafe {
            b = kairo::f8_literal_bits(
                unsafe (digits->data() as unsafe *const u8),
                digits->size(),
                e5m2,
            ) as i32
        }

        if b < 0 {
            self._ice(
                at,
                "EmitIR: an f8 literal whose digits APFloat does not read",
            )
        }

        self._cg->sink->spell(at, self._spell._type(ty) + f"::from_bits({b})")
    }

    /// A braced-init-list of array type. `bare` is the declarator form:
    /// `= { a, b }` on a variable, and an array nested directly inside another
    /// (C++ cannot initialize an array element from an array prvalue).
    /// Everywhere else it is the array PRVALUE `::__kairo_array<T, N>{ a, b }`,
    /// alive until the end of the full-expression. Valid C++17; GCC rejects the
    /// decay of one ("taking address of temporary array"), clang does not, and
    /// bodies only ever go through clang.
    prot fn _init_list(self, n: unsafe *InitListExpr, bare: bool) {
        if n->type_ == &null {
            self._ice(
                n->range,
                "EmitIR: untyped init list reached codegen; ListLiteralLowering must type it",
            )
        }

        var unsafe *c = canon_unqual(n->type_)
        if c == &null || c->kind != TypeKind::FixedArrayType {
            self._ice(
                n->range,
                "EmitIR: init list that is not an array; the initializer_list constructor form is not written yet",
            )
        }

        var unsafe *at   = cast<FixedArrayType>(c)
        var unsafe *elem = at->element

        if bare {
            self._cg->sink->spell(n->range, "{")
        } else {
            var ext = if (at->extent_param != &null) => (self._spell._type(
                          at->extent_param,
                      ))
                      else => f"{at->size_bits}"
            self._cg->sink->spell(
                n->range,
                "::" + LowerTargets::array_alias() + "<" + self._spell._type(
                    elem,
                ) + ", " + ext + ">{",
            )
        }

        for var i: usize = 0; i < n->elements.size(); ++i {
            if i > 0 {
                self._cg->sink->spell(n->range, ",")
            }

            var unsafe *el = n->elements[i]
            if isa<InitListExpr>(el) {
                self._init_list(cast<InitListExpr>(el), true)
            } else {
                self._value(el, elem)
            }
        }

        self._cg->sink->spell(n->range, "}")
    }

    /// `T{ .a = x, .b = y }` in declaration order. Designated init needs an
    /// aggregate; a record with a user constructor is a ctor call and is
    /// OperatorLowering/CopyMoveLowering's to rewrite.
    prot fn _init(self, e: unsafe *Expr, fields: FrozenList<InitField>) {
        // A dependent initializer whose head X could name is typed with the
        // dependent record (ControlTyping::_init_fields); reaching here
        // untyped AND dependent means that path fell back to unknown.
        if e->type_ == &null && e->is_instantiation_dependent() {
            self._ice_untyped(
                e,
                "EmitIR: dependent initializer reached codegen untyped; ExprTyper's named-initializer path (ControlTyping::type_named_init / _init_fields) left it unknown instead of typing it with the dependent record",
            )
        }

        if e->type_ == &null {
            self._ice_untyped(
                e,
                "EmitIR: untyped initializer reached codegen; ExprTyper gate failure",
            )
        }

        var unsafe *c = canon_unqual(e->type_)
        // `T::Node { }`: ControlTyping admits it with no fields only, through
        // a constructor bound; C++ value-initializes the witness's member type.
        if c->kind == TypeKind::AssocType {
            self._cg->sink->spell(e->range, self._spell._type(e->type_) + "{}")
            return
        }

        if c->kind != TypeKind::RecordType {
            self._ice(e->range, "EmitIR: initializer of a non-record type")
        }

        var unsafe *rd     = Speller::rep(cast<RecordType>(c)->decl)
        var unsafe *layout = self._layout_of(rd)
        if self._has_user_ctor(layout) {
            self._ice(
                e->range,
                "EmitIR: initializer on a record with a constructor; must be lowered to a ctor call",
            )
        }

        self._cg->sink->spell(e->range, self._spell._type(e->type_) + "{")
        // Declaration order: C++ designated initializers may not reorder.
        var lfields = decl_fields(layout)
        var first   = true
        for var fi: usize = 0; fi < lfields.size(); ++fi {
            var unsafe *fd = lfields[fi]
            if fd == &null {
                continue
            }

            var fname = self._spell.leaf(unsafe (fd as unsafe *Decl))
            for var i: usize = 0; i < fields.size(); ++i {
                var unsafe *f = fields.get(i)
                if self._spell.tok_name(f->name, self._owning_fid()) != fname {
                    continue
                }

                if !first {
                    self._cg->sink->spell(f->range, ",")
                }

                first = false
                self._cg->sink->spell(f->range, "." + fname + " =")
                // An array member takes bare braces, as a declarator does
                // (_var_decl): C++ cannot initialize one from the
                // `__kairo_array<T, N>{...}` prvalue _value would spell.
                var fc: unsafe *Type = &null
                if fd->type_ != &null && fd->type_->canonical != &null {
                    fc = canon_unqual(fd->type_->canonical)
                }

                var unsafe *il = dyn_cast<InitListExpr>(f->value)
                if il != &null && fc != &null && fc->kind == TypeKind::FixedArrayType {
                    self._init_list(il, true)
                } else {
                    self._value(f->value, fd->type_)
                }
            }
        }

        self._cg->sink->spell(e->range, "}")
    }

    /// An ADT variant built in place: the enum's tagged constructor,
    /// `T(::__kairo_vt<I>{})` for a variant without a payload, the field
    /// constructor `T{::__kairo_vt<I>{}, f0, f1}` where the variant's
    /// AdtCtorForm gives one, and otherwise
    ///
    ///   T(::__kairo_vt<I>{}, [&]() noexcept -> P { return { f0, f1 }; })
    ///
    /// with P the variant's payload struct named through T. The union member
    /// is initialized from the lambda's prvalue, so the payload is built in
    /// place: no copy or move is asked of it. The fields are in declaration
    /// order, which a braced list runs left to right; where the written order
    /// differs and matters, SequenceLowering has bound them to locals.
    prot fn _variant_init(self, n: unsafe *VariantInitExpr) {
        if n->type_ == &null {
            self._ice(
                n->range,
                "EmitIR: untyped variant construction reached codegen; ControlTyping types it",
            )
        }

        var unsafe *en = dyn_cast<EnumDecl>(n->en)
        if en == &null {
            self._ice(n->range, "EmitIR: variant construction with no enum")
        }

        if !en->is_adt {
            self._ice(
                n->range,
                "EmitIR: VariantInitExpr of a plain enum; VariantInitLowering spells a plain variant as its enumerator",
            )
        }

        var unsafe *v = en->variants[n->variant as usize]
        var        t  = self._spell._type(n->type_)
        var tag = "::" + LowerTargets::adt_variant_tag() + "<" + f"{n->variant}" + ">{}"
        if v->payload.size() == 0 {
            self._cg->sink->spell(n->range, t + "(" + tag + ")")
            return
        }

        // The field constructor, braced: a braced list runs its clauses left
        // to right even when it calls a constructor, so the payload's order
        // is the lambda form's (SequenceLowering's contract).
        if v->adt_ctor == AdtCtorForm::Fields || v->adt_ctor == AdtCtorForm::Both && n->field_ctor {
            self._cg->sink->spell(n->range, t + "{" + tag)
            for var i: usize = 0; i < n->fields.size(); ++i {
                self._cg->sink->spell(n->range, ",")
                // One field of a builtin type that names no parameter: the
                // generic ADT's lambda form `(tag, F&&)` is the better match
                // for an argument C++ sees at another type (the literal `7`
                // for a `u8`), and then calls it. EnumLayoutLowering writes
                // that conversion where the field's type is a parameter's;
                // here the field's own type is spelled.
                var unsafe *ft = v->payload[i]->type_
                if n->fields.size() == 1
                    && ft != &null
                    && ft->canonical != &null
                    && !ft->is_dependent()
                    && isa<BuiltinType>(canon_unqual(ft->canonical)) {
                    self._cast_to(ft, n->fields[i], "static_cast")
                } else {
                    self._value(n->fields[i], ft)
                }
            }

            self._cg->sink->spell(n->range, "}")
            return
        }

        var leaf = LowerTargets::adt_payload_type(
            self._spell.leaf(unsafe (v as unsafe *Decl)),
        )

        var pt = self._spell.dependent_member_type(n->type_, leaf)
        // A pack-expanded variant's element K: the constructor takes the
        // variant's tag, then K's, and the payload is the member template at
        // the element (InterfaceEmitter writes both). Always at a concrete
        // instance (ControlTyping refuses a dependent one).
        if n->pack_index >= 0 {
            if n->pack_elem == &null {
                self._ice(
                    n->range,
                    "EmitIR: a pack-expanded variant built with no element type; VariantInitLowering records it",
                )
            }

            var el = self._spell._type(n->pack_elem)
            if n->type_->is_dependent() || n->type_->is_instantiation_dependent() {
                // An error built at a dependent panic result (a generic body,
                // Compiler/Spec/Panic.md#generic-bodies): its place in the set is the one C++ ordered
                // at the instance, `__kairo_pidx<E>`, never Sema's.
                tag += ", ::" + LowerTargets::adt_variant_tag() + "<::" + LowerTargets::panic_elem_index() + "<" + el + ">(static_cast<" + t + "*>(nullptr))>{}"
                pt = "typename " + t + "::template " + leaf + "<" + el + ">"
            } else {
                tag += ", ::" + LowerTargets::adt_variant_tag() + "<" + f"{n->pack_index}" + ">{}"
                pt = t.copy() + "::" + leaf + "<" + el + ">"
            }

            // A site slot's pack constructor takes the site id (Compiler/Spec/Panic.md
            // §1.4; InterfaceEmitter writes it): 0 for none.
            if en->adt_site_field != &null {
                tag += ", " + f"{n->site}" + "u"
            }
        }

        // noexcept unless -funwind, as the constructor it is passed to is
        // (InterfaceEmitter::_adt_noexcept): the lambda is a Kairo frame.
        var nx = if (self._cg->opts.unwind) => ("") else => " noexcept"
        self._cg->sink->spell(
            n->range,
            t + "(" + tag + ", [&]()" + nx + " -> " + pt + " { return {",
        )

        for var i: usize = 0; i < n->fields.size(); ++i {
            if i > 0 {
                self._cg->sink->spell(n->range, ",")
            }

            var unsafe *fd = v->payload[i]
            var unsafe *f  = n->fields[i]
            // An array member takes bare braces, as in _init.
            var fc: unsafe *Type = &null
            if fd->type_ != &null && fd->type_->canonical != &null {
                fc = canon_unqual(fd->type_->canonical)
            }

            var unsafe *il = dyn_cast<InitListExpr>(f)
            var unsafe *pg = dyn_cast<GenericParamType>(fc)
            if il != &null && fc != &null && fc->kind == TypeKind::FixedArrayType {
                self._init_list(il, true)
            } else if n->pack_index >= 0 && pg != &null && pg->is_pack {
                self._value(f, n->pack_elem) // the pack field holds the element.
            } else {
                self._value(f, fd->type_)
            }
        }

        self._cg->sink->spell(n->range, "}; })")
    }

    /// The declaration whose members an instance's C++ has: the partial
    /// specialization the registry selected for it (InstanceEntry::pattern,
    /// the same body Sema typed the instance against), else the primary.
    /// Reading the primary for a partial's instance dropped every field of
    /// an initializer the partial declares (`Store<*i64> { wide: p }`
    /// emitted `{}`).
    priv fn _layout_of(self, d: unsafe *Decl) -> unsafe *Decl {
        if decl_is_instance(d) {
            var unsafe *e = self._cg->instances->entry_of(d)
            if e != &null && e->pattern != &null {
                return Speller::rep(e->pattern)
            }

            return Speller::rep(decl_pattern(d))
        }

        return d
    }

    priv fn _has_user_ctor(self, d: unsafe *Decl) -> bool {
        var ms = decl_methods(d)
        var nm = self._spell.leaf(d)
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m != &null && !m->is_operator && self._spell.leaf(m) == nm {
                return true
            }
        }

        return false
    }
}
