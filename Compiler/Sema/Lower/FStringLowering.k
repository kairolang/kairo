/// --- The Kairo Project ----------------- Sema/Lower/FStringLowering.k --- ///
///
///   \brief Every f-string becomes one FmtBuf and straight-line puts.
///
///   \detail
///       f"x={x:>4} v={v}"        // x: i32, v: Vec2 with a user `repr`
///     ->
///       ({
///           var __kairo_arg0 = (v).repr()
///           var __kairo_fmt0 = FmtBuf(16 + __kairo_arg0.len)
///           __kairo_fmt0.text("x=" as unsafe *const u8, 2, 2)
///           __kairo_fmt0.put_i32(x, 0x0400000000000004)
///           __kairo_fmt0.text(" v=" as unsafe *const u8, 3, 3)
///           __kairo_fmt0.put_str(__kairo_arg0, 0)
///           __kairo_fmt0.finish()
///       })
///
///     Every fact the compiler knows is a constant at the call: the text
///     bytes and their counts, the packed spec, the capacity bound (the
///     literal bytes plus each kind's widest print, plus each string's `len`
///     read at run time). Nothing is dispatched on and nothing is parsed.
///
///     X decided everything (`fmt_holes`): the put for each hole, the
///     conversion applied first, the cast, the spec. This pass mints.
///
///   \par Order
///     A hole that is impure, converted, a string, or an address-printed
///     prvalue is bound to a `__kairo_argN` local first, in source order; a
///     pure primitive is read in place. So `f"{a()}{b()}"` calls a, then b,
///     and `f"{v}"` on a prvalue record has an address to print.
///
///   \par Postcondition
///     No StringLiteralExpr with is_format() reaches StringLowering or
///     codegen. An f-string with no holes is retyped as a plain literal and
///     left for StringLowering.
///
///   Phase: LOWER, after OperatorLowering, before StringLowering.
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
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;
import Lexer::Immediate::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceLocation::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_FStringLowering ASTWriter<FStringLowering>
");

class FStringLowering derives ASTWriter::<FStringLowering> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var synth: LowerSynth;

    fn FStringLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_FStringLowering::run(self.sc->tu);
    }

    // --- the rewrite ----------------------------------------------------------

    fn transform_string_literal_expr(self, n: *StringLiteralExpr) -> *Expr {
        // Holes first: an f-string inside a hole lowers inside its parent.
        var out = ASTWriter_FStringLowering::transform_string_literal_expr(n);
        if !n->is_format() { return out; }
        if n->is_poisoned() || (n->type_ == &null) { return out; }
        ICE_IF(n->imm == &null, "FStringLowering: f-string with no immediate data");

        if n->parts.size() == 0 { return self._retype_plain(n); }

        ICE_IF(n->fmt_holes.size() != n->parts.size(), "FStringLowering: hole facts not parallel to parts; LiteralTyping must record one per hole");
        ICE_IF((n->fmt_ctor == &null) || (n->fmt_text == &null) || (n->fmt_finish == &null) || (n->fmt_len == &null),
            "FStringLowering: FmtBuf members unbound; LiteralTyping must bind them");

        var str_t = self.tu.string_type();
        var no_args = vec::<*Type>();
        var buf_t = self.tu.lang_record(WellKnownType::FmtBuf, &no_args);
        ICE_IF((str_t == &null) || (buf_t == &null), "FStringLowering: string / FmtBuf lang items unbound");
        var usize_t = self.sc->builtin(BuiltinKind::USize);

        var stmts = self.list_builder::<*Stmt>();
        var args  = vec::<*Expr>();            // per hole: what the put reads.
        var lens  = vec::<*VariableDecl>();    // the string locals whose `len` joins the bound.
        var bound: u64 = 0;

        // 1. Bind, in source order.
        for var i: usize = 0; i < n->parts.size(); ++i {
            var h = n->fmt_holes.get(i);
            var e = n->parts[i];
            var at = e->range;
            var arg: *Expr = &null;

            if h->conv != &null {
                // `(e).repr()` / `(e).op as()`: a string, bound.
                var recv = ParenExpr::create(self.ctx, at, e);
                recv->adopt_sema(e);
                var none = self.list_builder::<*Expr>();
                var call = self.synth.member_call(at, static_cast::<*Expr>(recv), h->conv, &none, str_t);
                var vd = self.synth.local(at, "arg", str_t, call);
                stmts.push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, at, static_cast::<*Decl>(vd))));
                lens.push_back(vd);
                arg = self.synth.use_of(vd, at, Expr::ValueCategory::LValue);
            } else if h->kind == FormatKind::String {
                // Read twice (its len, then its bytes): one local.
                var vd = self.synth.local(at, "arg", str_t, e);
                stmts.push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, at, static_cast::<*Decl>(vd))));
                lens.push_back(vd);
                arg = self.synth.use_of(vd, at, Expr::ValueCategory::LValue);
            } else if h->by_addr {
                // The value's address: its own if it has one, a local's if not.
                var obj = e;
                if !e->is_lvalue() {
                    var vd = self.synth.local(at, "arg", self.tu.as_value(e->type_), e);
                    stmts.push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, at, static_cast::<*Decl>(vd))));
                    obj = self.synth.use_of(vd, at, Expr::ValueCategory::LValue);
                }
                arg = self.synth.cast_to(at, self.synth.addr_of(obj), usize_t, CastMode::Unsafe);
            } else {
                arg = e;
                if !LowerSynth::pure(e) {
                    var vd = self.synth.local(at, "arg", self.tu.as_value(e->type_), e);
                    stmts.push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, at, static_cast::<*Decl>(vd))));
                    arg = self.synth.use_of(vd, at, Expr::ValueCategory::LValue);
                }
                if h->cast_to != &null {
                    // A pointer to usize is a reinterpretation; an enum to its
                    // underlying integer is a static_cast.
                    var mode = (CastMode::Unsafe) if (h->kind == FormatKind::Ptr) else (CastMode::Default);
                    arg = self.synth.cast_to(at, arg, h->cast_to, mode);
                }
            }
            args.push_back(arg);
            bound += self._max_bytes(h, e);
        }

        // 2. The buffer, sized once: the static bound plus every string's len.
        var text = vec::<u8>();
        self._collect_text(n, &text, &bound);   // adds every literal byte to the bound too.
        var cap: *Expr = self.synth.int_literal(n->range, bound, BuiltinKind::USize);
        for var i: usize = 0; i < lens.size(); ++i {
            var len = self.synth.field_of(n->range, self.synth.use_of(lens[i], n->range, Expr::ValueCategory::LValue), n->fmt_len, usize_t);
            var sum = BinaryOperatorExpr::create(self.ctx, n->range, cap, len, self.synth.punct(n->range, TokenKind::OpPlus));
            sum->type_          = usize_t;
            sum->value_category = Expr::ValueCategory::RValue;
            cap = static_cast::<*Expr>(sum);
        }
        var cargs = self.list_builder::<*Expr>();
        cargs.push(cap);
        var buf = self.synth.local(n->range, "fmt", buf_t, self.synth.ctor_call(n->range, n->fmt_ctor, to_string(WellKnownType::FmtBuf), &cargs, buf_t));
        stmts.push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, n->range, static_cast::<*Decl>(buf))));

        // 3. Text and puts, in order.
        text.clear();
        for var i: usize = 0; i < n->parts.size(); ++i {
            var h = n->fmt_holes.get(i);
            var e = n->parts[i];
            self._text_before(n, i, &text);
            self._flush_text(n, buf, &text, &stmts);

            var pargs = self.list_builder::<*Expr>();
            pargs.push(args[i]);
            if h->kind == FormatKind::Ptr {
                var name = vec::<u8>();
                LowerSynth::push_string(self._ptr_name(h, e), &name);
                pargs.push(self._bytes_arg(e->range, &name));
                pargs.push(self.synth.int_literal(e->range, static_cast::<u64>(name.size()), BuiltinKind::USize));
            }
            pargs.push(self.synth.int_literal(e->range, h->spec, BuiltinKind::U64));
            var put = self.synth.member_call(e->range, self.synth.use_of(buf, e->range, Expr::ValueCategory::LValue), h->put, &pargs, self.sc->builtin(BuiltinKind::Void));
            stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, e->range, put)));
        }
        self._text_after(n, &text);
        self._flush_text(n, buf, &text, &stmts);

        // 4. The value.
        var fargs = self.list_builder::<*Expr>();
        var fin = self.synth.member_call(n->range, self.synth.use_of(buf, n->range, Expr::ValueCategory::LValue), n->fmt_finish, &fargs, str_t);
        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, fin)));
        return self.synth.stmt_expr(static_cast::<*Expr>(n), &stmts, n->type_);
    }

    /// `f"plain"`: a literal with a prefix it no longer needs. StringLowering
    /// decodes it (`\{` included, unconditionally).
    priv fn _retype_plain(self, n: *StringLiteralExpr) -> *Expr {
        n->string_kind = (StringLiteralExpr::StringKind::Raw) if (n->is_raw()) else (StringLiteralExpr::StringKind::Plain);
        return static_cast::<*Expr>(n);
    }

    // --- text -------------------------------------------------------------------------

    /// `__kairo_fmtK.text("..." as unsafe *const u8, n, cp)` for the pending
    /// bytes, if any.
    priv fn _flush_text(self, n: *StringLiteralExpr, buf: *VariableDecl, text: *vec::<u8>, stmts: *ListBuilder::<*Stmt>) {
        if text->size() == 0 { return; }
        var args = self.list_builder::<*Expr>();
        args.push(self._bytes_arg(n->range, text));
        args.push(self.synth.int_literal(n->range, static_cast::<u64>(text->size()), BuiltinKind::USize));
        args.push(self.synth.int_literal(n->range, static_cast::<u64>(LowerSynth::cp_count(text)), BuiltinKind::USize));
        var call = self.synth.member_call(n->range, self.synth.use_of(buf, n->range, Expr::ValueCategory::LValue), n->fmt_text, &args, self.sc->builtin(BuiltinKind::Void));
        stmts->push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, call)));
        text->clear();
    }

    /// A byte literal as a `*const u8` argument: the C++ literal is
    /// `const char*`, the parameter is `const unsigned char*`.
    priv fn _bytes_arg(self, at: SourceRange, bytes: *vec::<u8>) -> *Expr {
        var pu8 = self.sc->types->pointer(self.sc->types->qualified(self.sc->builtin(BuiltinKind::U8), QUAL_CONST()));
        return self.synth.cast_to(at, self.synth.bytes_literal(at, bytes, pu8), pu8, CastMode::Unsafe);
    }

    /// Raw offset of hole \p i's `{`.
    priv fn _open(self, n: *StringLiteralExpr, i: usize) -> u32 {
        var r = libcxx::get::<1>((*(n->imm->exprs.begin() + i)));
        return r.start.raw() - 1;
    }

    /// Raw offset of hole \p i's `}`: past the spec, the doc text, or the
    /// expression, whichever the hole has.
    priv fn _close(self, n: *StringLiteralExpr, i: usize) -> u32 {
        var hs = &(n->imm->holes[i]);
        if hs->spec.is_valid() { return hs->spec.end.raw(); }
        if hs->doc.is_valid()  { return hs->doc.end.raw(); }
        return libcxx::get::<1>((*(n->imm->exprs.begin() + i))).end.raw();
    }

    priv fn _range(self, a: u32, b: u32) -> SourceRange {
        if b <= a { return SourceRange::invalid(); }
        return SourceRange::from_bounds(SourceLocation::from_raw(a), SourceLocation::from_raw(b));
    }

    /// The literal bytes before hole \p i, decoded, then the hole's own
    /// `{x=}` text, verbatim.
    priv fn _text_before(self, n: *StringLiteralExpr, i: usize, out: *vec::<u8>) {
        var from = (n->imm->body.start.raw()) if (i == 0) else (self._close(n, i - 1) + 1);
        self._decode(n, self._range(from, self._open(n, i)), out);
        self.synth.copy_text(n->imm->holes[i].doc, out);
    }

    /// The bytes after the last hole, then every chained part.
    priv fn _text_after(self, n: *StringLiteralExpr, out: *vec::<u8>) {
        var last = n->parts.size() - 1;
        self._decode(n, self._range(self._close(n, last) + 1, n->imm->body.end.raw()), out);

        var tbl = self.sc->imm_table();
        var idx = n->imm->next;
        while idx != u32(-1) {
            var seg = tbl->get::<Immediate::StringData>(idx);
            var raw = (static_cast::<u8>(seg->prefix_kind) & static_cast::<u8>(Immediate::TextPrefixKind::Raw)) != 0;
            if seg->has_owned_text() {
                for var k: usize = 0; k < static_cast::<usize>(seg->owned_len); ++k { out->push_back(seg->owned_ptr[k]); }
            } else {
                ICE_IF(!self.synth.decode_text(seg->body, raw, out), "FStringLowering: escape the lexer accepted but the decoder does not know; keep Lexer::is_valid_escape and LowerSynth::decode_text in step");
            }
            idx = seg->next;
        }
        n->imm->next = u32(-1);
    }

    priv fn _decode(self, n: *StringLiteralExpr, r: SourceRange, out: *vec::<u8>) {
        ICE_IF(!self.synth.decode_text(r, n->is_raw(), out), "FStringLowering: escape the lexer accepted but the decoder does not know; keep Lexer::is_valid_escape and LowerSynth::decode_text in step");
    }

    /// Every literal byte of the f-string, for the bound. The text itself is
    /// re-derived per segment in step 3; the bytes here are counted only.
    priv fn _collect_text(self, n: *StringLiteralExpr, scratch: *vec::<u8>, bound: *u64) {
        for var i: usize = 0; i < n->parts.size(); ++i { self._text_before(n, i, scratch); }
        // _text_after consumes the chain; count it without consuming here.
        var last = n->parts.size() - 1;
        self._decode(n, self._range(self._close(n, last) + 1, n->imm->body.end.raw()), scratch);
        var tbl = self.sc->imm_table();
        var idx = n->imm->next;
        while idx != u32(-1) {
            var seg = tbl->get::<Immediate::StringData>(idx);
            (*bound) += static_cast::<u64>(seg->body.end.raw() - seg->body.start.raw());   // an over-estimate: escapes shrink.
            idx = seg->next;
        }
        (*bound) += static_cast::<u64>(scratch->size());
        scratch->clear();
    }

    // --- the bound -------------------------------------------------------------------

    /// The pointee's spelling for `{p}`, the value's for the address form.
    priv fn _ptr_name(self, h: *FormatHole, e: *Expr) -> string {
        var v = self.tu.as_value(e->type_);
        if h->by_addr { return self.tu.str(v); }
        return self.tu.str(self.tu.pointee(v));
    }

    /// The most bytes this hole can print. Wider than any output, never
    /// narrower: the puts still check, but a taken check is a realloc.
    priv fn _max_bytes(self, h: *FormatHole, e: *Expr) -> u64 {
        var width: u64 = h->spec & 0xFFFF;
        var prec1: u64 = (h->spec >> 16) & 0xFFFF;
        var fill:  u64 = (h->spec >> 32) & 0x1FFFFF;
        var base:  u64 = (h->spec >> 55) & 3;
        var m: u64 = 0;
        switch h->kind {
            case FormatKind::Bool   { m = 5; }
            case FormatKind::Char   { m = 6; }        // quoted, escaped.
            case FormatKind::Byte   { m = 4; }
            case FormatKind::String { m = 2; }        // the quotes of `?`; bytes are runtime.
            case FormatKind::Ptr    { m = static_cast::<u64>(std::string_to_nstring(self._ptr_name(h, e)).size()) + 22; }
            case FormatKind::I8:    case FormatKind::U8     { m = self._int_max(8, base);   }
            case FormatKind::I16:   case FormatKind::U16    { m = self._int_max(16, base);  }
            case FormatKind::I32:   case FormatKind::U32    { m = self._int_max(32, base);  }
            case FormatKind::I64:   case FormatKind::U64    { m = self._int_max(64, base);  }
            case FormatKind::ISize: case FormatKind::USize  { m = self._int_max(64, base);  }
            case FormatKind::I128:  case FormatKind::U128   { m = self._int_max(128, base); }
            case FormatKind::I256:  case FormatKind::U256   { m = self._int_max(256, base); }
            case FormatKind::I512:  case FormatKind::U512   { m = self._int_max(512, base); }
            default {
                // Every float: `%.*Lg` / `%.*Le` of an f80 at precision p.
                var p: u64 = (prec1 - 1) if (prec1 != 0) else (6);
                m = p + 16;
            }
        }
        // Width pads in codepoints; a multibyte fill is up to four bytes each.
        var fill_bytes: u64 = 1;
        if fill >= 0x10000 { fill_bytes = 4; } else if fill >= 0x800 { fill_bytes = 3; } else if fill >= 0x80 { fill_bytes = 2; }
        var padded = width * fill_bytes;
        return (padded) if (padded > m) else (m);
    }

    /// Digits plus sign plus `0x`: base 10 from the width's decimal digit
    /// count, bases 2/8/16 from bits.
    priv fn _int_max(self, bits: u64, base: u64) -> u64 {
        if base == 1 { return bits / 4 + 3; }
        if base == 2 { return (bits + 2) / 3 + 3; }
        if base == 3 { return bits + 3; }
        switch bits {
            case 8   { return 4;   }
            case 16  { return 6;   }
            case 32  { return 11;  }
            case 64  { return 21;  }
            case 128 { return 40;  }
            case 256 { return 79;  }
            default  { return 156; }
        }
    }
}

__inline_cpp("
#undef ASTWriter_FStringLowering
");