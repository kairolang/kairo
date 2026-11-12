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
///   \par Deferred holes
///     A hole whose value's type is a generic body's (FormatHole::deferred:
///     a `T`, or a member result through a `: type` parameter) is bound by
///     forwarding reference and put by `::__kairo_fmt_put(buf, arg, name,
///     len, 0)` (CallExpr::fmt_dyn), the preamble template that picks the
///     put at each instance.
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Kind::ExprKind::to_string
import AST::LangItems::{
    FormatKind,
    LowerTargets,
    WellKnownType,
    fmt_spec_base,
    fmt_spec_fill,
    fmt_spec_prec1,
    fmt_spec_width,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    QUAL_CONST,
}
import AST::Node::Declarations::VariableDecl
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    CallExpr,
    CastMode,
    ParenExpr,
}
import AST::Node::PrimaryExpressions::{
    FormatHole,
    NamedIdentExpr,
    StringLiteralExpr,
}
import AST::Node::Statements::{
    DeclStmt,
    ExpressionStmt,
}
import AST::Visitor::ASTWriter::{
    ASTWriter,
    ListBuilder,
}
import Lexer::Immediate::Immediate
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Sema::Lower::LowerStep::LowerStep
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

pub class FStringLowering derives ASTWriter<FStringLowering> {
    pub var  sc:    unsafe *SemaContext
    priv var tu:    TypeUtil
    priv var synth: LowerSynth

    fn FStringLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.tu    = TypeUtil(sc)
        self.synth = LowerSynth(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        self.sc->begin_lower(LowerStep::FString)
        if self.sc->tu == &null {
            return
        }

        ASTWriter<FStringLowering>::run(self, self.sc->tu)
    }

    /// # the rewrite

    fn transform_string_literal_expr(self, n: unsafe *StringLiteralExpr) -> unsafe *Expr {
        // Holes first: an f-string inside a hole lowers inside its parent.
        var unsafe *out = ASTWriter<FStringLowering>::transform_string_literal_expr(self, n)
        if !n->is_format() {
            return out
        }

        if n->is_poisoned() || n->type_ == &null {
            return out
        }

        if n->imm == &null {
            kairo::std::ice_fail("FStringLowering: f-string with no immediate data")
        }

        if n->parts.size() == 0 {
            return self._retype_plain(n)
        }

        if n->fmt_holes.size() != n->parts.size() {
            kairo::std::ice_fail(
                "FStringLowering: hole facts not parallel to parts; LiteralTyping must record one per hole",
            )
        }

        if n->fmt_ctor == &null
            || n->fmt_text == &null
            || n->fmt_finish == &null
            || n->fmt_len == &null {
            kairo::std::ice_fail(
                "FStringLowering: FmtBuf members unbound; LiteralTyping must bind them",
            )
        }

        var unsafe *str_t  = self.tu.string_type()
        var        no_args = cxx::std::vector<unsafe *Type>()
        var unsafe *buf_t  = self.tu.lang_record(WellKnownType::FmtBuf, unsafe &no_args)
        if str_t == &null || buf_t == &null {
            kairo::std::ice_fail("FStringLowering: string / FmtBuf lang items unbound")
        }

        var unsafe *usize_t = self.sc->builtin(BuiltinKind::USize)

        var stmts      = self.list_builder<unsafe *Stmt>()
        var args       = cxx::std::vector<unsafe *Expr>() // per hole: what the put reads.
        var lens       = cxx::std::vector<unsafe *VariableDecl>() // the string locals whose `len` joins the bound.
        var bound: u64 = 0

        // 1. Bind, in source order.
        for var i: usize = 0; i < n->parts.size(); ++i {
            var unsafe *h                = n->fmt_holes.get(i)
            var unsafe *e                = n->parts[i]
            var        at                = e->range
            var        arg: unsafe *Expr = &null

            if h->deferred {
                // A generic body's value: bound by forwarding reference, in
                // source order like every other impure hole -- its type is
                // the instance's, so it is never copied and never named.
                var unsafe *vd = self.synth.local(at, "arg", &null, e)
                vd->place_ref = true
                stmts.push(
                    unsafe (DeclStmt::create(self.ctx, at, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
                )

                arg = self.synth.use_of(vd, at, Expr::ValueCategory::LValue)
            } else if h->conv != &null {
                // `(e).repr()` / `(e).op as()`: a string, bound.
                var unsafe *recv = ParenExpr::create(self.ctx, at, e)
                recv->adopt_sema(e)
                var        none  = self.list_builder<unsafe *Expr>()
                var unsafe *call = self.synth.member_call(at, recv, h->conv, &none, str_t)
                var unsafe *vd   = self.synth.local(at, "arg", str_t, call)
                stmts.push(
                    unsafe (DeclStmt::create(self.ctx, at, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
                )

                lens.push_back(vd)
                arg = self.synth.use_of(vd, at, Expr::ValueCategory::LValue)
            } else if h->kind == FormatKind::String {
                // Read twice (its len, then its bytes): one local.
                var unsafe *vd = self.synth.local(at, "arg", str_t, e)
                stmts.push(
                    unsafe (DeclStmt::create(self.ctx, at, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
                )

                lens.push_back(vd)
                arg = self.synth.use_of(vd, at, Expr::ValueCategory::LValue)
            } else if h->by_addr {
                // The value's address: its own if it has one, a local's if not.
                var unsafe *obj = e
                if !e->is_lvalue() {
                    var unsafe *vd = self.synth.local(at, "arg", self.tu.as_value(e->type_), e)
                    stmts.push(
                        unsafe (DeclStmt::create(self.ctx, at, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
                    )

                    obj = self.synth.use_of(vd, at, Expr::ValueCategory::LValue)
                }

                arg = self.synth.cast_to(at, self.synth.addr_of(obj), usize_t, CastMode::Unsafe)
            } else {
                arg = e
                if !LowerSynth::pure(e) {
                    var unsafe *vd = self.synth.local(at, "arg", self.tu.as_value(e->type_), e)
                    stmts.push(
                        unsafe (DeclStmt::create(self.ctx, at, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
                    )

                    arg = self.synth.use_of(vd, at, Expr::ValueCategory::LValue)
                }

                if h->cast_to != &null {
                    // A pointer to usize is a reinterpretation; an enum to its
                    // underlying integer is a static_cast.
                    var mode = if (h->kind == FormatKind::Ptr) => (CastMode::Unsafe)
                               else => CastMode::Default
                    arg = self.synth.cast_to(at, arg, h->cast_to, mode)
                }
            }

            args.push_back(arg)
            bound += self._max_bytes(h, e)
        }

        // 2. The buffer, sized once: the static bound plus every string's len.
        var text = cxx::std::vector<u8>()
        self._collect_text(n, unsafe &text, unsafe &bound) // adds every literal byte to the bound too.
        var cap: unsafe *Expr = self.synth.int_literal(n->range, bound, BuiltinKind::USize)
        for var i: usize = 0; i < lens.size(); ++i {
            var none = self.list_builder<unsafe *Expr>()
            var unsafe *len = self.synth.member_call(
                n->range,
                self.synth.use_of(lens[i], n->range, Expr::ValueCategory::LValue),
                n->fmt_len,
                &none,
                usize_t,
            )

            var unsafe *sum = BinaryOperatorExpr::create(
                self.ctx,
                n->range,
                cap,
                len,
                self.synth.punct(n->range, TokenKind::OpPlus),
            )

            sum->type_          = usize_t
            sum->value_category = Expr::ValueCategory::RValue
            cap                 = sum
        }

        var cargs = self.list_builder<unsafe *Expr>()
        cargs.push(cap)
        var unsafe *buf = self.synth.local(
            n->range,
            "fmt",
            buf_t,
            self.synth.ctor_call(
                n->range,
                n->fmt_ctor,
                to_string(WellKnownType::FmtBuf),
                &cargs,
                buf_t,
            ),
        )

        stmts.push(
            unsafe (DeclStmt::create(self.ctx, n->range, unsafe (buf as unsafe *Decl)) as unsafe *Stmt),
        )

        // 3. Text and puts, in order.
        text.clear()
        for var i: usize = 0; i < n->parts.size(); ++i {
            var unsafe *h = n->fmt_holes.get(i)
            var unsafe *e = n->parts[i]
            self._text_before(n, i, unsafe &text)
            self._flush_text(n, buf, unsafe &text, &stmts)

            if h->deferred {
                stmts.push(
                    ExpressionStmt::create(
                        self.ctx,
                        e->range,
                        self._deferred_put(buf, args[i], h, e),
                    ),
                )

                continue
            }

            // f256 / f512: `v.fmt_put_(&fmt, spec)`, the class's own put
            // (FormatHole::on_value). C++ spells the builtin as the class,
            // so the value is a receiver of it there.
            if h->on_value {
                var vargs = self.list_builder<unsafe *Expr>()
                vargs.push(
                    self.synth.addr_of(
                        self.synth.use_of(buf, e->range, Expr::ValueCategory::LValue),
                    ),
                )

                vargs.push(self.synth.int_literal(e->range, h->spec, BuiltinKind::U64))
                var unsafe *vput = self.synth.member_call(
                    e->range,
                    args[i],
                    h->put,
                    &vargs,
                    self.sc->builtin(BuiltinKind::Void),
                )

                stmts.push(ExpressionStmt::create(self.ctx, e->range, vput))
                continue
            }

            var pargs = self.list_builder<unsafe *Expr>()
            pargs.push(args[i])
            if h->kind == FormatKind::Ptr {
                var name = cxx::std::vector<u8>()
                LowerSynth::push_string(self._ptr_name(h, e), &name)
                pargs.push(self._bytes_arg(e->range, unsafe &name))
                pargs.push(self.synth.int_literal(e->range, name.size() as u64, BuiltinKind::USize))
            }

            pargs.push(self.synth.int_literal(e->range, h->spec, BuiltinKind::U64))
            var unsafe *put = self.synth.member_call(
                e->range,
                self.synth.use_of(buf, e->range, Expr::ValueCategory::LValue),
                h->put,
                &pargs,
                self.sc->builtin(BuiltinKind::Void),
            )

            stmts.push(ExpressionStmt::create(self.ctx, e->range, put))
        }

        self._text_after(n, unsafe &text, true)
        self._flush_text(n, buf, unsafe &text, &stmts)

        // 4. The value.
        var fargs = self.list_builder<unsafe *Expr>()
        var unsafe *fin = self.synth.member_call(
            n->range,
            self.synth.use_of(buf, n->range, Expr::ValueCategory::LValue),
            n->fmt_finish,
            &fargs,
            str_t,
        )

        stmts.push(ExpressionStmt::create(self.ctx, n->range, fin))
        return self.synth.stmt_expr(unsafe (n as unsafe *Expr), &stmts, n->type_)
    }

    /// `::__kairo_fmt_put(buf, arg, name, len, 0)` for a deferred hole
    /// (FormatHole::deferred): C++ picks the put at each instance
    /// (LowerTargets::fmt_dyn). The name is what an address print shows: the
    /// type as the body spells it, when it has one.
    priv fn _deferred_put(self,
                          buf: unsafe *VariableDecl,
                          arg: unsafe *Expr,
                          h:   unsafe *FormatHole,
                          e:   unsafe *Expr) -> unsafe *Expr {
        var at   = e->range
        var name = cxx::std::vector<u8>()
        var spelled = if (e->type_ == &null) => ("value")
                      else => self.tu.str(self.tu.as_value(e->type_))
        LowerSynth::push_string(spelled, &name)
        var cargs = self.list_builder<unsafe *Expr>()
        cargs.push(self.synth.use_of(buf, at, Expr::ValueCategory::LValue))
        cargs.push(arg)
        cargs.push(self._bytes_arg(at, unsafe &name))
        cargs.push(self.synth.int_literal(at, name.size() as u64, BuiltinKind::USize))
        cargs.push(self.synth.int_literal(at, h->spec, BuiltinKind::U64))
        var unsafe *callee = NamedIdentExpr::create(
            self.ctx,
            at,
            self.synth.ident(at, LowerTargets::fmt_dyn()),
        )

        var unsafe *call = CallExpr::create(self.ctx, at, callee)
        cargs.freeze_into(&call->args)
        call->fmt_dyn        = true
        call->type_          = self.sc->builtin(BuiltinKind::Void)
        call->value_category = Expr::ValueCategory::RValue
        return call
    }

    /// `f"plain"`: a literal with a prefix it no longer needs. StringLowering
    /// decodes it (`\{` included, unconditionally).
    priv fn _retype_plain(self, n: unsafe *StringLiteralExpr) -> unsafe *Expr {
        // Format dropped, Raw kept: the set without its Format bit.
        n->string_kind.clear(StringLiteralExpr::StringKind::Format)
        return n
    }

    /// # text

    /// `__kairo_fmtK.text("..." as unsafe *const u8, n, cp)` for the pending
    /// bytes, if any.
    priv fn _flush_text(self,
                        n:     unsafe *StringLiteralExpr,
                        buf:   unsafe *VariableDecl,
                        text:  unsafe *cxx::std::vector<u8>,
                        stmts: *ListBuilder<unsafe *Stmt>) {
        if text->size() == 0 {
            return
        }

        var args = self.list_builder<unsafe *Expr>()
        args.push(self._bytes_arg(n->range, text))
        args.push(self.synth.int_literal(n->range, text->size() as u64, BuiltinKind::USize))
        args.push(
            self.synth.int_literal(
                n->range,
                LowerSynth::cp_count(*text) as u64,
                BuiltinKind::USize,
            ),
        )

        var unsafe *call = self.synth.member_call(
            n->range,
            self.synth.use_of(buf, n->range, Expr::ValueCategory::LValue),
            n->fmt_text,
            &args,
            self.sc->builtin(BuiltinKind::Void),
        )

        stmts->push(ExpressionStmt::create(self.ctx, n->range, call))
        text->clear()
    }

    /// A byte literal as a `*const u8` argument: the C++ literal is
    /// `const char*`, the parameter is `const unsigned char*`.
    priv fn _bytes_arg(self, at: SourceRange, bytes: unsafe *cxx::std::vector<u8>) -> unsafe *Expr {
        var unsafe *pu8 = self.sc->types->pointer(
            self.sc->types->qualified(self.sc->builtin(BuiltinKind::U8), QUAL_CONST),
        )

        return self.synth.cast_to(
            at,
            self.synth.bytes_literal(at, bytes, pu8),
            pu8,
            CastMode::Unsafe,
        )
    }

    /// # holes across a chain
    ///
    ///   Adjacent literals join whatever their prefixes, so a hole can
    ///   sit in any segment of the chain: `"a" f"b{x}" r"\c" f"{y}"`. Each
    ///   segment's text is decoded under its own prefix (its Raw bit), and
    ///   the segments with no hole are text whole.

    /// Hole \p i's segment; \p k becomes its index within that segment.
    priv fn _seg(self, n: unsafe *StringLiteralExpr, i: usize, @inout k: usize) -> unsafe *Immediate::StringData {
        k = n->hole_index(i)
        var unsafe *seg = n->hole_segment(i)
        if seg == &null {
            kairo::std::ice_fail(
                "FStringLowering: a part with no hole in the chain; the parser must push one per hole",
            )
        }

        return seg
    }

    /// Raw offset of hole \p k's `{` in \p seg.
    priv fn _open(self, seg: unsafe *Immediate::StringData, k: usize) -> u32 {
        var r = (*(seg->exprs.begin() + k)).1
        return r.start.raw() - 1
    }

    /// Raw offset of hole \p k's `}` in \p seg: past the spec, the doc text,
    /// or the expression, whichever the hole has.
    priv fn _close(self, seg: unsafe *Immediate::StringData, k: usize) -> u32 {
        var *hs = &seg->holes[k]
        if hs->spec.is_valid() {
            return hs->spec.end.raw()
        }

        if hs->doc.is_valid() {
            return hs->doc.end.raw()
        }

        return (*(seg->exprs.begin() + k)).1.end.raw()
    }

    priv fn _range(self, a: u32, b: u32) -> SourceRange {
        if b <= a {
            return SourceRange::invalid()
        }

        return SourceRange::from_bounds(SourceLocation::from_raw(a), SourceLocation::from_raw(b))
    }

    /// The literal bytes before hole \p i, decoded, then the hole's own
    /// `{x=}` text, verbatim. When the hole opens a segment, the bytes before
    /// it are the rest of the previous hole's segment and every segment
    /// between, whole.
    priv fn _text_before(self,
                         n:   unsafe *StringLiteralExpr,
                         i:   usize,
                         out: unsafe *cxx::std::vector<u8>) {
        var        k: usize = 0
        var unsafe *seg     = self._seg(n, i, &k)
        var        from     = seg->body.start.raw()
        if k > 0 {
            from = self._close(seg, k - 1) + 1
        } else {
            var unsafe *s = n->imm
            if i > 0 {
                var pk: usize = 0
                s = self._seg(n, i - 1, &pk)
                self._decode(n, s, self._range(self._close(s, pk) + 1, s->body.end.raw()), out)
                s = n->next_segment(s)
            }

            while s != &null && s != seg {
                self._decode_whole(n, s, out)
                s = n->next_segment(s)
            }
        }

        self._decode(n, seg, self._range(from, self._open(seg, k)), out)
        self.synth.copy_text(seg->holes[k].doc, &*out)
    }

    /// The bytes after the last hole, then every segment after its own. With
    /// \p consume the chain is spent (one FmtBuf now holds it all).
    priv fn _text_after(self,
                        n:       unsafe *StringLiteralExpr,
                        out:     unsafe *cxx::std::vector<u8>,
                        consume: bool) {
        var        k: usize = 0
        var unsafe *seg     = self._seg(n, n->parts.size() - 1, &k)
        self._decode(n, seg, self._range(self._close(seg, k) + 1, seg->body.end.raw()), out)

        var unsafe *s = n->next_segment(seg)
        while s != &null {
            self._decode_whole(n, s, out)
            s = n->next_segment(s)
        }

        if consume {
            n->imm->next = u32::MAX
        }
    }

    /// \p seg's Raw bit: the node's for the first segment (its kind is the
    /// head's), the segment's own prefix for every other.
    priv fn _raw(self, n: unsafe *StringLiteralExpr, seg: unsafe *Immediate::StringData) -> bool {
        if seg == n->imm {
            return n->is_raw()
        }

        return seg->prefix_kind.has(Immediate::TextPrefixKind::Raw)
    }

    priv fn _decode(self,
                    n:   unsafe *StringLiteralExpr,
                    seg: unsafe *Immediate::StringData,
                    r:   SourceRange,
                    out: unsafe *cxx::std::vector<u8>) {
        if !self.synth.decode_text(r, self._raw(n, seg), out) {
            kairo::std::ice_fail(
                "FStringLowering: escape the lexer accepted but the decoder does not know; keep Lexer::is_valid_escape and LowerSynth::decode_text in step",
            )
        }
    }

    /// A segment with no hole, all of it: owned text as is, else its body.
    priv fn _decode_whole(self,
                          n:   unsafe *StringLiteralExpr,
                          seg: unsafe *Immediate::StringData,
                          out: unsafe *cxx::std::vector<u8>) {
        if seg->has_owned_text() {
            for var i: usize = 0; i < (seg->owned_len as usize); ++i {
                out->push_back(seg->owned_ptr[i])
            }

            return
        }

        self._decode(n, seg, seg->body, out)
    }

    /// Every literal byte of the f-string, for the bound: exactly the text
    /// step 3 emits. The text itself is re-derived there; the bytes here are
    /// counted only, and the chain is not spent.
    priv fn _collect_text(self,
                          n:       unsafe *StringLiteralExpr,
                          scratch: unsafe *cxx::std::vector<u8>,
                          bound:   unsafe *u64) {
        for var i: usize = 0; i < n->parts.size(); ++i {
            self._text_before(n, i, scratch)
        }

        self._text_after(n, scratch, false)
        *bound += (scratch->size() as u64)
        scratch->clear()
    }

    /// # the bound

    /// The pointee's spelling for `{p}`, the value's for the address form.
    priv fn _ptr_name(self, h: unsafe *FormatHole, e: unsafe *Expr) -> string {
        var unsafe *v = self.tu.as_value(e->type_)
        if h->by_addr {
            return self.tu.str(v)
        }

        return self.tu.str(self.tu.pointee(v))
    }

    /// The most bytes this hole can print. Wider than any output, never
    /// narrower: the puts still check, but a taken check is a realloc.
    priv fn _max_bytes(self, h: unsafe *FormatHole, e: unsafe *Expr) -> u64 {
        var width: u64 = fmt_spec_width(h->spec)
        var prec1: u64 = fmt_spec_prec1(h->spec)
        var fill:  u64 = fmt_spec_fill(h->spec)
        var base:  u64 = fmt_spec_base(h->spec)
        var m:     u64 = 0
        // The instance's: a guess. A short buffer only grows.
        if h->deferred {
            return 32
        }

        match h->kind {
            case FormatKind::Bool {
                m = 5
            } case FormatKind::Char { // quoted, escaped.
                m = 6
            } case FormatKind::Byte {
                m = 4
            } case FormatKind::String { // the quotes of `?`; bytes are runtime.
                m = 2
            } case FormatKind::Ptr {
                m = (self._ptr_name(h, e).size() as u64) + 22
            } case FormatKind::I8, FormatKind::U8 {
                m = self._int_max(8, base)
            } case FormatKind::I16, FormatKind::U16 {
                m = self._int_max(16, base)
            } case FormatKind::I32, FormatKind::U32 {
                m = self._int_max(32, base)
            } case FormatKind::I64, FormatKind::U64 {
                m = self._int_max(64, base)
            } case FormatKind::ISize, FormatKind::USize {
                m = self._int_max(64, base)
            } case FormatKind::I128, FormatKind::U128 {
                m = self._int_max(128, base)
            } case FormatKind::I256, FormatKind::U256 {
                m = self._int_max(256, base)
            } case FormatKind::I512, FormatKind::U512 {
                m = self._int_max(512, base)
            } default {
                // Every float: `%.*Lg` / `%.*Le` of an f80 at precision p.
                var p: u64 = if (prec1 != 0) => (prec1 - 1) else => 6
                m = p + 16
            }
        }

        // Width pads in codepoints; a multibyte fill is up to four bytes each.
        var fill_bytes: u64 = 1
        if fill >= 0x10000 {
            fill_bytes = 4
        } else if fill >= 0x800 {
            fill_bytes = 3
        } else if fill >= 0x80 {
            fill_bytes = 2
        }

        var padded = width * fill_bytes
        return if (padded > m) => (padded) else => m
    }

    /// Digits plus sign plus `0x`: base 10 from the width's decimal digit
    /// count, bases 2/8/16 from bits.
    priv fn _int_max(self, bits: u64, base: u64) -> u64 {
        if base == 1 {
            return bits / 4 + 3
        }

        if base == 2 {
            return (bits + 2) / 3 + 3
        }

        if base == 3 {
            return bits + 3
        }

        match bits {
            case 8 {
                return 4
            } case 16 {
                return 6
            } case 32 {
                return 11
            } case 64 {
                return 21
            } case 128 {
                return 40
            } case 256 {
                return 79
            } default {
                return 156
            }
        }
    }
}
