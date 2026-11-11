/// --- The Kairo Project ---------------------- Sema/Lower/LowerSynth.k --- ///
///
///   \brief What every lowering mints: identifier tokens interned into THIS
///          file's table, integer literals with a fresh Immediate::IntData
///          slot, byte literals over decoded text with a fresh StringData
///          slot, fresh `__kairo_` locals and the names that read them,
///          member and free-function calls, statement expressions, and
///          the purity test SequenceLowering orders arguments by.
///
///   One copy. Three passes each carried their own `_ident_token`, and the
///   `Token` invariant (16 bytes, an imm index into the owning file's table,
///   Compiler/Spec/Pipeline.md hard invariant #2) is the kind of rule that drifts when it
///   is written in three places.
///
///   Held by value on each pass, so counters are per pass; passes use
///   different name hints (`arg`, `tmp`, `lhs`, `sum`, `fmt`) and never
///   collide.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/UTF8Decode.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::SymbolTable::DeclName
import AST::Kind::ExprKind::{
    ExprKind,
    to_string,
}
import AST::LangItems::{
    LowerTargets,
    PureAccessors,
    WellKnownType,
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
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    AdtRole,
    FunctionDecl,
    StorageClass,
    VariableDecl,
}
import AST::Node::Expressions::{
    BinaryOperatorExpr, CallExpr,        CastMode,      ImplicitBoundaryCastExpr, ListLiteralExpr,
    ParenExpr,          StmtExpr,        SubscriptExpr, TypeCastExpr,             UnaryOperatorExpr,
    UnsafeExpr,         VariantInitExpr,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    ChainExpr,
    IntegerLiteralExpr,
    NamedIdentExpr,
    StringLiteralExpr,
}
import AST::Node::Statements::{
    CompoundStmt,
    ConditionalStmt,
    DeclStmt,
    ExpressionStmt,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
}
import AST::Visitor::ASTWriter::ListBuilder
import Codegen::CodegenICE::codegen_ice
import Lexer::Immediate::Immediate
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil
import Support::FlagSet::FlagSet
import Token::Token::Token
import Token::TokenKind::TokenKind

pub class LowerSynth {
    pub var  sc:       unsafe *SemaContext
    priv var _counter: u32                 = 0

    fn LowerSynth(self) {
        self.sc = &null
    }

    fn LowerSynth(self, sc: unsafe *SemaContext) {
        self.sc = sc
    }

    /// An identifier token for a name this pass invented.
    fn ident(self, range: SourceRange, const spelling: string) -> Token {
        var t = Token()
        t.kind  = TokenKind::LitIdentifier
        t.range = range
        t.imm   = self.sc->imm_table()->intern_ident_copy(spelling)
        return t
    }

    /// `__kairo_<hint>K`, unique within this pass.
    fn fresh(self, range: SourceRange, const hint: string) -> Token {
        var t = self.ident(range, LowerTargets::reserved_prefix() + hint + f"{self._counter}")
        self._counter += 1
        return t
    }

    /// A punctuator token with no source bytes behind it (the `=` of a minted
    /// assignment). TokenSink creates it from the kind alone.
    fn punct(self, range: SourceRange, kind: TokenKind) -> Token {
        var t = Token()
        t.kind  = kind
        t.range = range
        return t
    }

    /// An integer literal typed \p kind, its IntData slot minted and written
    /// straight in: no source text, so EmitIR spells it from the value.
    fn int_literal(self, range: SourceRange, value: u64, kind: BuiltinKind) -> unsafe *Expr {
        var unsafe *tbl = self.sc->imm_table()
        var        idx  = tbl->create<Immediate::IntData>()
        var unsafe *d   = tbl->get<Immediate::IntData>(idx)
        d->value_lo = value
        d->value_hi = 0
        d->bits     = 0
        d->base     = 10
        d->flags    = 0

        var t = Token()
        t.kind  = TokenKind::LitInt
        t.range = range
        t.imm   = idx

        var unsafe *lit = IntegerLiteralExpr::create(self.sc->ctx, range, t)
        lit->type_          = self.sc->builtin(kind)
        lit->value_category = Expr::ValueCategory::RValue
        return lit
    }

    /// `true` / `false`, typed bool.
    fn bool_literal(self, range: SourceRange, value: bool) -> unsafe *Expr {
        var unsafe *b = BooleanLiteralExpr::create(self.sc->ctx, range, value)
        b->type_          = self.sc->builtin(BuiltinKind::Bool)
        b->value_category = Expr::ValueCategory::RValue
        return b
    }

    /// A string literal over BYTES this pass minted -- a decoded body -- typed
    /// \p ty (a pointer type; EmitIR spells it as a C++ literal from the
    /// bytes). The token carries a fresh StringData slot whose owned text is
    /// the bytes.
    fn bytes_literal(self,
                     range: SourceRange,
                     bytes: unsafe *cxx::std::vector<u8>,
                     ty:    unsafe *Type) -> unsafe *Expr {
        var unsafe *tbl = self.sc->imm_table()
        var        idx  = tbl->intern_bytes_copy(self._bytes_ptr(*bytes), bytes->size())

        var t = Token()
        t.kind  = TokenKind::LitString
        t.range = range
        t.imm   = idx

        var unsafe *lit = StringLiteralExpr::create(
            self.sc->ctx,
            range,
            t,
            FlagSet<StringLiteralExpr::StringKind, u8>(),
        )

        lit->imm            = tbl->get<Immediate::StringData>(idx)
        lit->type_          = ty
        lit->value_category = Expr::ValueCategory::RValue
        return lit
    }

    /// `var __kairo_<hint>K: <ty> = <init>`. The caller wraps it in a DeclStmt
    /// and places it; the decl is the identity every use_of() binds to.
    fn local(self,
             range:      SourceRange,
             const hint: string,
             ty:         unsafe *Type,
             init:       unsafe *Expr) -> unsafe *VariableDecl {
        var unsafe *vd = VariableDecl::create(
            self.sc->ctx,
            range,
            self.fresh(range, hint),
            StorageClass::Var,
        )

        vd->type_ = ty
        vd->init  = init
        return vd
    }

    /// local(), placed: its DeclStmt pushed on \p stmts. The bind-once step
    /// of an expansion that reads an operand more than once.
    fn bind(self,
            range:      SourceRange,
            const hint: string,
            ty:         unsafe *Type,
            init:       unsafe *Expr,
            stmts:      unsafe *ListBuilder<unsafe *Stmt>) -> unsafe *VariableDecl {
        var unsafe *vd = self.local(range, hint, ty, init)
        stmts->push(
            unsafe (DeclStmt::create(self.sc->ctx, range, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
        )

        return vd
    }

    /// A read of a local this pass minted. One node per use: a node has one
    /// parent, and two parents sharing one is a rewrite waiting to happen.
    fn use_of(self,
              vd:    unsafe *VariableDecl,
              range: SourceRange,
              cat:   Expr::ValueCategory) -> unsafe *Expr {
        var unsafe *use = NamedIdentExpr::create(self.sc->ctx, range, vd->name)
        use->resolved_decl  = vd
        use->type_          = vd->type_
        use->value_category = cat
        return use
    }

    /// An explicit cast to the canonical \p to. Default renders `static_cast`,
    /// Unsafe `reinterpret_cast`. Not `cast`: a member by that name hides
    /// Casting.k's `cast::<T>` for every method of this class.
    fn cast_to(self,
               range:   SourceRange,
               operand: unsafe *Expr,
               to:      unsafe *Type,
               mode:    CastMode) -> unsafe *Expr {
        var unsafe *c = TypeCastExpr::create(
            self.sc->ctx,
            range,
            operand,
            to,
            mode == CastMode::Unsafe,
            mode,
        )

        c->type_          = to
        c->value_category = Expr::ValueCategory::RValue
        return c
    }

    /// `&e`, typed `*T` for an \p e of T. A C++ `T&` (an `operator*` result)
    /// names its referee, as OperatorTyping's `&` reads it: `*T`, never a
    /// pointer to a reference.
    fn addr_of(self, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *t = e->type_
        if t != &null && isa<CXXLValueRefType>(t) {
            t = cast<CXXLValueRefType>(t)->referee
        } else if t != &null && isa<CXXRValueRefType>(t) {
            t = cast<CXXRValueRefType>(t)->referee
        }

        var unsafe *pt = self.sc->types->pointer(canon_unqual(t))
        var unsafe *u = UnaryOperatorExpr::create(
            self.sc->ctx,
            e->range,
            e,
            self.punct(e->range, TokenKind::OpAmp),
            UnaryOperatorExpr::Fix::Prefix,
        )

        u->type_          = pt
        u->value_category = Expr::ValueCategory::RValue
        return u
    }

    /// `base.<field>`, an lvalue of \p ty. The step names the FieldDecl; the
    /// token spells it in this file.
    fn field_of(self,
                range: SourceRange,
                base:  unsafe *Expr,
                field: unsafe *Decl,
                ty:    unsafe *Type) -> unsafe *Expr {
        var        tu     = TypeUtil(self.sc)
        var unsafe *chain = ChainExpr::create(self.sc->ctx, range, base)
        var        steps  = ListBuilder<ChainExpr::Step>(self.sc->ctx)
        var        st     = ChainExpr::Step()
        st.name = NamedIdentExpr::create(
            self.sc->ctx,
            range,
            self.ident(range, tu.decl_name(field)),
        )

        st.name->resolved_decl = field
        st.target              = ChainExpr::StepTarget::Name
        st.range               = range
        st.access_kind         = ChainExpr::AccessKind::Dot
        st.resolved_decl       = field
        st.resolved_type       = ty
        steps.push(st)
        steps.freeze_into(&chain->steps)
        chain->type_          = ty
        chain->value_category = Expr::ValueCategory::LValue
        return chain
    }

    /// `recv.<method>(args)` typed \p ty. An operator method (`op as`) gets
    /// an Operator step spelled from the decl; a named one a Name step whose
    /// token spells the name in this file. Same shape OperatorLowering mints.
    ///
    /// \p ordered: the caller knows the order of the operands is
    /// unobservable (see _mint_check); only read once SequenceLowering ran.
    fn member_call(self,
                   range:       SourceRange,
                   recv:        unsafe *Expr,
                   method:      unsafe *Decl,
                   @inout args: ListBuilder<unsafe *Expr>,
                   ty:          unsafe *Type,
                   ordered:     bool = false) -> unsafe *Expr {
        var        tu = TypeUtil(self.sc)
        var unsafe *f = dyn_cast<FunctionDecl>(method)
        if f == &null {
            kairo::std::ice_fail("LowerSynth::member_call: method is not a function")
        }

        var unsafe *chain = ChainExpr::create(self.sc->ctx, range, recv)
        var        steps  = ListBuilder<ChainExpr::Step>(self.sc->ctx)
        var        st     = ChainExpr::Step()
        st.name          = &null
        st.range         = range
        st.access_kind   = ChainExpr::AccessKind::Dot
        st.resolved_decl = method
        st.resolved_type = &null
        if f->is_operator {
            st.target = ChainExpr::StepTarget::Operator
            var toks = ListBuilder<Token>(self.sc->ctx)
            toks.push(self.punct(range, f->op_token[0].kind))
            toks.freeze_into(&st.op_tokens)
        } else {
            st.target = ChainExpr::StepTarget::Name
            st.name = NamedIdentExpr::create(
                self.sc->ctx,
                range,
                self.ident(range, tu.decl_name(method)),
            )

            st.name->resolved_decl = method
        }

        steps.push(st)
        steps.freeze_into(&chain->steps)

        var unsafe *call = CallExpr::create(self.sc->ctx, range, chain)
        args.freeze_into(&call->args)
        call->type_          = ty
        call->value_category = Expr::ValueCategory::RValue
        if !ordered {
            self._mint_check(call, recv, "member_call")
        }

        return call
    }

    /// A constructor call typed \p ty. The callee names the ctor decl; EmitIR
    /// spells the TYPE from the call's own canonical, never from this token.
    /// \p ordered as member_call's.
    fn ctor_call(self,
                 range:       SourceRange,
                 ctor:        unsafe *Decl,
                 const name:  string,
                 @inout args: ListBuilder<unsafe *Expr>,
                 ty:          unsafe *Type,
                 ordered:     bool = false) -> unsafe *Expr {
        var unsafe *callee = NamedIdentExpr::create(self.sc->ctx, range, self.ident(range, name))
        callee->resolved_decl = ctor
        var unsafe *call = CallExpr::create(self.sc->ctx, range, callee)
        args.freeze_into(&call->args)
        call->type_          = ty
        call->value_category = Expr::ValueCategory::RValue
        if !ordered {
            self._mint_check(call, &null, "ctor_call")
        }

        return call
    }

    /// The mint-time half of the evaluation-order invariant (Compiler/Spec/Codegen.md,
    /// "Integer arithmetic and evaluation order"). SequenceLowering wrote
    /// Kairo's left-to-right order into the tree; a pass after it that
    /// mints a call whose arguments C++ leaves unsequenced, two or more of
    /// them with an effect, would undo that silently. Judged on the node
    /// being built only -- the operands as they are now -- so it has no
    /// false positives; a caller whose operands cannot observe each other
    /// (fresh locals, say) passes `ordered` and says why. Before
    /// SequenceLowering it checks nothing: that pass orders what is minted
    /// ahead of it.
    priv fn _mint_check(self, call: unsafe *CallExpr, recv: unsafe *Expr, const who: string) {
        if self.sc == &null || !self.sc->sequenced {
            return
        }

        var effects: u32 = 0
        if recv != &null && !self.pure_read(recv) {
            effects += 1
        }

        for var i: usize = 0; i < call->args.size(); ++i {
            if !self.pure_read(call->args[i]) {
                effects += 1
            }
        }

        if effects < (2 as u32) {
            return
        }

        var msg = f"LowerSynth::{who}: a call minted after SequenceLowering has {effects} operands with an effect, in an order C++ leaves unspecified; bind them in order first, or pass `ordered` where the order cannot be observed"
        codegen_ice(self.sc->ctx, call->range, msg) // I003E at the call, then the ICE.
    }

    /// `f(args)`, a call of the free function \p f (a lang item a lowering
    /// calls) typed \p ty: the node shape of ctor_call, the callee naming
    /// \p f by its own name.
    fn free_call(self,
                 range:   SourceRange,
                 f:       unsafe *Decl,
                 args:    unsafe *ListBuilder<unsafe *Expr>,
                 ty:      unsafe *Type,
                 ordered: bool = false) -> unsafe *Expr {
        var tu = TypeUtil(self.sc)
        return self.ctor_call(range, f, tu.decl_name(f), &*args, ty, ordered)
    }

    /// `unwrap_failed("<text>", <len>)`, typed `!`: the crash family's one
    /// compiler entry (the UnwrapFailed lang item over rt/crash.c, Compiler/Spec/Panic.md
    /// §2.8). \p text is the whole message -- what failed and its
    /// file:line:col -- because nothing may be formatted at crash time: the
    /// runtime writes these bytes and a newline and aborts. No newline here;
    /// the runtime owns it. \p who names the calling pass in the ICE.
    fn crash_call(self, range: SourceRange, const text: string, const who: string) -> unsafe *Expr {
        var unsafe *d = self.sc->well_known->get(WellKnownType::UnwrapFailed)
        if d == &null {
            kairo::std::ice_fail(
                who + ": the '" + to_string(
                    WellKnownType::UnwrapFailed,
                ) + "' lang item is unbound; Lib/builtin/module.k declares it",
            )
        }

        var unsafe *f = dyn_cast<FunctionDecl>(NameLookup::representative(d))
        if f == &null {
            kairo::std::ice_fail(
                who + ": the '" + to_string(
                    WellKnownType::UnwrapFailed,
                ) + "' lang item is not a function",
            )
        }

        var bytes = cxx::std::vector<u8>()
        LowerSynth::push_string(text, &bytes)
        var unsafe *u8t = self.sc->types->qualified(self.sc->builtin(BuiltinKind::U8), QUAL_CONST)
        var unsafe *pu8 = self.sc->types->pointer(u8t)
        var unsafe *lit = self.bytes_literal(range, unsafe &bytes, pu8)
        var        args = ListBuilder<unsafe *Expr>(self.sc->ctx)
        args.push(self.cast_to(range, lit, pu8, CastMode::Unsafe)) // `"..."` is const char*; the parameter is const unsigned char*.
        args.push(self.int_literal(range, bytes.size() as u64, BuiltinKind::USize))
        return self.free_call(range, f, unsafe &args, self.sc->builtin(BuiltinKind::Never))
    }

    /// `if cond { <call> }`, \p call a `-> !` call (crash_call's).
    fn crash_if(self, range: SourceRange, cond: unsafe *Expr, call: unsafe *Expr) -> unsafe *Stmt {
        var unsafe *blk = CompoundStmt::create(self.sc->ctx, range)
        var        body = ListBuilder<unsafe *Stmt>(self.sc->ctx)
        body.push(ExpressionStmt::create(self.sc->ctx, range, call))
        body.freeze_into(&blk->body)
        return ConditionalStmt::create(self.sc->ctx, range, cond, blk, &null)
    }

    /// `({ stmts })` in place of \p orig, a prvalue of \p ty.
    fn stmt_expr(self,
                 orig:         unsafe *Expr,
                 @inout stmts: ListBuilder<unsafe *Stmt>,
                 ty:           unsafe *Type) -> unsafe *Expr {
        var unsafe *body = CompoundStmt::create(self.sc->ctx, orig->range)
        stmts.freeze_into(&body->body)
        var unsafe *se = StmtExpr::create(self.sc->ctx, orig->range, body)
        se->adopt_sema(orig)
        se->type_          = ty
        se->value_category = Expr::ValueCategory::RValue
        return se
    }

    /// # text

    /// The extent C++ gives string literal \p sl as `const char[N]`: its
    /// decoded bytes, every chained part, plus the terminator (P835). 0 when
    /// an escape does not decode, which the caller reads as "no literal".
    /// Typing needs it before StringLowering has built the bytes, so it
    /// decodes the chain as StringLowering::_collect does.
    fn c_literal_extent(self, sl: unsafe *StringLiteralExpr) -> u64 {
        if sl == &null {
            return 0
        }

        // The writing file's table: a literal from an imported macro's body
        // chains through that file's table, not ours.
        var unsafe *tbl = self.sc->imm_table()
        if sl->ctx != &null {
            tbl = sl->ctx->get_payload_table(sl->token)
        }

        var        out = cxx::std::vector<u8>()
        var unsafe *seg = sl->imm
        var        raw  = sl->is_raw()
        while seg != &null {
            if seg->has_owned_text() {
                for var i: usize = 0; i < (seg->owned_len as usize); ++i {
                    out.push_back(seg->owned_ptr[i])
                }
            } else if !self.decode_text(seg->body, raw, unsafe &out) {
                return 0
            }

            if seg->next == u32::MAX || tbl == &null {
                break
            }

            seg = tbl->get<Immediate::StringData>(seg->next)
            raw = seg->prefix_kind.has(Immediate::TextPrefixKind::Raw)
        }

        return (out.size() as u64) + 1
    }

    /// The bytes of \p range decoded: every escape the lexer accepts, into
    /// UTF-8. \p raw copies verbatim. False for an escape the lexer accepted
    /// and this does not know; the caller ICEs, since the two must agree.
    fn decode_text(self, range: SourceRange, raw: bool, out: unsafe *cxx::std::vector<u8>) -> bool {
        if !range.is_valid() {
            return true
        }

        var        view       = self.sc->ctx->sm->get_view(range)
        var unsafe *p         = view.data()
        var        n          = view.size()
        var        i:   usize = 0
        while i < n {
            var b = p[i]
            if raw || b != 0x5c {
                out->push_back(b)
                i += 1
                continue
            }

            i += 1
            if i >= n {
                return false
            }

            var e = p[i]
            i += 1
            match e {
                case 0x6e /* 'n' */ {
                    out->push_back(0x0a)
                } case 0x72 /* 'r' */ {
                    out->push_back(0x0d)
                } case 0x74 /* 't' */ {
                    out->push_back(0x09)
                } case 0x76 /* 'v' */ {
                    out->push_back(0x0b)
                } case 0x66 /* 'f' */ {
                    out->push_back(0x0c)
                } case 0x61 /* 'a' */ {
                    out->push_back(0x07)
                } case 0x62 /* 'b' */ {
                    out->push_back(0x08)
                } case 0x27 /* '\x27' */ {
                    out->push_back(0x27)
                } case 0x22 /* '\x22' */ {
                    out->push_back(0x22)
                } case 0x5c /* '\\' */ {
                    out->push_back(0x5c)
                } case 0x7b /* '{' */ {
                    out->push_back(0x7b)
                } case 0x7d /* '}' */ {
                    out->push_back(0x7d)
                } case 0x78 /* 'x' */ {
                    if i + 2 > n {
                        return false
                    }

                    var cp = LowerSynth::_hex(p[i]) << 4 | LowerSynth::_hex(p[i + 1])
                    i += 2
                    LowerSynth::push_utf8(cp, &*out)
                } case 0x75 /* 'u' */ {
                    if i + 4 > n {
                        return false
                    }

                    var cp: u32 = 0
                    for var k: usize = 0; k < 4; ++k {
                        cp = cp << 4 | LowerSynth::_hex(p[i + k])
                    }

                    i += 4
                    LowerSynth::push_utf8(cp, &*out)
                } case 0x55 /* 'U' */ {
                    if i + 8 > n {
                        return false
                    }

                    var cp: u32 = 0
                    for var k: usize = 0; k < 8; ++k {
                        cp = cp << 4 | LowerSynth::_hex(p[i + k])
                    }

                    i += 8
                    LowerSynth::push_utf8(cp, &*out)
                } case 0x30 /* '0' */, 0x31 /* '1' */, 0x32 /* '2' */, 0x33 /* '3' */, 0x34 /* '4' */, 0x35 /* '5' */, 0x36 /* '6' */, 0x37 /* '7' */ {
                    var cp:     u32   = e - ('0' as u8)
                    var digits: usize = 1
                    while i < n && digits < 3 && p[i] >= ('0' as u8) && p[i] <= ('7' as u8) {
                        cp = cp << 3 | ((p[i] - ('0' as u8)) as u32)
                        i += 1
                        digits += 1
                    }

                    LowerSynth::push_utf8(cp, &*out)
                } default {
                    return false
                }
            }
        }

        return true
    }

    /// The raw bytes of \p range, no decoding.
    fn copy_text(self, range: SourceRange, @inout out: cxx::std::vector<u8>) {
        if !range.is_valid() {
            return
        }

        var        view = self.sc->ctx->sm->get_view(range)
        var unsafe *p   = view.data()
        for var i: usize = 0; i < view.size(); ++i {
            out.push_back(p[i])
        }
    }

    /// A compiler string (wide) as UTF-8 bytes.
    static fn push_string(const s: string, @inout out: cxx::std::vector<u8>) {
        var unsafe *r = unsafe (s.raw() as kairo::std::ConstPtr<u8>) // raw is const: no working copy
        for var i: usize = 0; i < s.size(); ++i {
            out.push_back(r[i])
        }
    }

    static fn push_utf8(cp: u32, @inout out: cxx::std::vector<u8>) {
        if cp < 0x80 {
            out.push_back(cp as u8)
            return
        }

        if cp < 0x800 {
            out.push_back((0xC0 | cp >> 6) as u8)
            out.push_back((0x80 | cp & 0x3F) as u8)
            return
        }

        if cp < 0x10000 {
            out.push_back((0xE0 | cp >> 12) as u8)
            out.push_back((0x80 | cp >> 6 & 0x3F) as u8)
            out.push_back((0x80 | cp & 0x3F) as u8)
            return
        }

        out.push_back((0xF0 | cp >> 18) as u8)
        out.push_back((0x80 | cp >> 12 & 0x3F) as u8)
        out.push_back((0x80 | cp >> 6 & 0x3F) as u8)
        out.push_back((0x80 | cp & 0x3F) as u8)
    }

    /// Codepoints in \p bytes: every byte that is not a continuation byte.
    ///
    /// Requires valid UTF-8, which SourceManager::validate_utf8 (source bytes)
    /// plus decode_text's escape encoding (every escape is written as a full
    /// UTF-8 sequence) guarantee; on anything else the count is wrong, not an
    /// error. Debug builds re-decode \p bytes to catch a path that bypassed
    /// validation.
    static fn cp_count(const bytes: cxx::std::vector<u8>) -> usize {
        eval if defined!(DEBUG) {
            const base: kairo::std::ConstPtr<u8> = unsafe (bytes.data() as kairo::std::ConstPtr<u8>)
            var   off:  usize                    = 0
            while off < bytes.size() {
                var d = kairo::decode_utf8_lut(base + off, bytes.size() - off)
                if !d.ok {
                    kairo::std::ice_fail(
                        "cp_count: invalid UTF-8 reached lowering; SourceManager validation bypassed",
                    )
                }

                off += (d.len as usize)
            }
        }

        var cp: usize = 0
        for var i: usize = 0; i < bytes.size(); ++i {
            if ((bytes)[i] & 0xC0) != 0x80 {
                cp += 1
            }
        }

        return cp
    }

    priv static fn _hex(b: u8) -> u32 {
        if b >= ('0' as u8) && b <= ('9' as u8) {
            return b - ('0' as u8)
        }

        if b >= ('a' as u8) && b <= ('f' as u8) {
            return b - ('a' as u8) + 10
        }

        if b >= ('A' as u8) && b <= ('F' as u8) {
            return b - ('A' as u8) + 10
        }

        return 0 // the lexer validated the digit; unreachable.
    }

    /// An empty vec may have no buffer; the interner still wants a pointer.
    priv fn _bytes_ptr(self, const bytes: cxx::std::vector<u8>) -> kairo::std::ConstPtr<u8> {
        static _empty: u8 = 0
        if bytes.size() == 0 {
            return unsafe &_empty
        }

        return unsafe (bytes.data() as kairo::std::ConstPtr<u8>)
    }

    /// No side effect and no dependence on one: reading \p e before or after
    /// another operand changes nothing. Conservative: anything not listed is
    /// impure. SequenceLowering orders by it; OperatorLowering decides by it
    /// whether a compound assignment's left side is bound once first.
    static fn pure(e: unsafe *Expr) -> bool {
        return LowerSynth::_pure(e, &null)
    }

    /// pure(), except that a call of a pure accessor (PureAccessors: a
    /// lang item's getter that writes nothing) on a pure receiver counts as
    /// no effect. For binding decisions only (SequenceLowering, its post-pass
    /// check): such a call still READS state, so it is never moved past a
    /// write (SequenceLowering::_reads_state stays true for it). Not for a
    /// pass that re-evaluates a "pure" path at a later time (IterLowering's
    /// array base, CoalesceLowering's second read): `__value()` is unchecked.
    fn pure_read(self, e: unsafe *Expr) -> bool {
        return LowerSynth::_pure(e, &self)
    }

    /// \p e is `recv.m()` with m a pure accessor (is_pure_accessor) and no
    /// arguments; null otherwise, else the receiver.
    fn accessor_receiver(self, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *c = dyn_cast<CallExpr>(e)
        if c == &null || c->args.size() != 0 || c->callee == &null {
            return &null
        }

        var unsafe *ch = dyn_cast<ChainExpr>(c->callee)
        if ch == &null || ch->base == &null || ch->steps.size() != 1 {
            return &null
        }

        var unsafe *st = ch->steps.get(0)
        if st->access_kind != ChainExpr::AccessKind::Dot
            && st->access_kind != ChainExpr::AccessKind::Arrow {
            return &null
        }

        if !self.is_pure_accessor(st->resolved_decl) {
            return &null
        }

        return ch->base
    }

    /// \p d is one of the pure accessors (PureAccessors), by identity: the
    /// Nullable layout's IsNull / ValueRef / ValueCref members (roles only
    /// that lang item's record carries, AdtRole), any ADT layout's
    /// `__kairo_which()` (AdtRole::Which), or one of string's
    /// PureAccessors::string_member, looked up once in the String lang item.
    fn is_pure_accessor(self, d: unsafe *Decl) -> bool {
        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f == &null {
            return false
        }

        if f->adt_role == AdtRole::IsNull
            || f->adt_role == AdtRole::ValueRef
            || f->adt_role == AdtRole::ValueCref {
            return true
        }

        if f->adt_role == AdtRole::Which {
            return true
        }

        if !self._acc_ready {
            self._resolve_accessors()
        }

        for var i: usize = 0; i < self._acc.size(); ++i {
            if self._acc[i] == d {
                return true
            }
        }

        return false
    }

    priv var _acc:       cxx::std::vector<unsafe *Decl>
    priv var _acc_ready: bool                           = false

    priv fn _resolve_accessors(self) {
        self._acc_ready = true
        if self.sc == &null || self.sc->well_known == &null {
            return
        }

        var unsafe *sd = self.sc->well_known->get(WellKnownType::String)
        if sd == &null {
            return
        }

        var        tu  = TypeUtil(self.sc)
        var unsafe *dc = NameLookup::context_of(tu.pattern_of(NameLookup::representative(sd)))
        if dc == &null {
            return
        }

        for var i: usize = 0; i < PureAccessors::string_count(); ++i {
            var nm   = PureAccessors::string_member(i)
            var imm  = self.sc->imm_table()->intern_ident_copy(nm)
            var cell = self.sc->lookup.in_context(dc, DeclName::ident(imm), nm)
            if !cell.found() {
                continue
            }

            for var k: usize = 0; k < cell.cell->size(); ++k {
                var unsafe *m = dyn_cast<FunctionDecl>(cell.cell->get(k))
                if m != &null && m->is_method() {
                    self._acc.push_back(cell.cell->get(k))
                }
            }
        }
    }

    /// The one walk behind pure() and pure_read(): \p acc null is the
    /// strict test, non-null admits its pure accessors.
    priv static fn _pure(e: unsafe *Expr, acc: *LowerSynth?) -> bool {
        if e == &null {
            return true
        }

        match e->kind {
            case ExprKind::IntegerLiteralExpr {
                return true
            } case ExprKind::FloatingLiteralExpr {
                return true
            } case ExprKind::CharacterLiteralExpr {
                return true
            } case ExprKind::BooleanLiteralExpr {
                return true
            } case ExprKind::NullLiteralExpr {
                return true
            } case ExprKind::StringLiteralExpr {
                return !cast<StringLiteralExpr>(e)->is_format()
            } case ExprKind::NamedIdentExpr {
                return true
            } case ExprKind::SizeOfExpr {
                return true
            } case ExprKind::AlignOfExpr {
                return true
            } case ExprKind::TypeTraitExpr {
                return true
            } case ExprKind::ParenExpr {
                return LowerSynth::_pure(cast<ParenExpr>(e)->inner, acc)
            } case ExprKind::UnsafeExpr {
                return LowerSynth::_pure(cast<UnsafeExpr>(e)->operand, acc)
            } case ExprKind::ImplicitBoundaryCastExpr {
                return LowerSynth::_pure(cast<ImplicitBoundaryCastExpr>(e)->original, acc)
            } case ExprKind::ChainExpr {
                // A field path off a pure base. An operator step is a call
                // (only as a callee, which never reaches here as an operand).
                var unsafe *c = cast<ChainExpr>(e)
                for var i: usize = 0; i < c->steps.size(); ++i {
                    var unsafe *st = c->steps.get(i)
                    if st->is_operator() {
                        return false
                    }

                    if st->access_kind == ChainExpr::AccessKind::QuestionDot
                        || st->access_kind == ChainExpr::AccessKind::QuestionArrow {
                        return false
                    }
                }

                return LowerSynth::_pure(c->base, acc)
            } case ExprKind::UnaryOperatorExpr {
                var unsafe *u = cast<UnaryOperatorExpr>(e)
                if u->resolved_op != &null {
                    return false
                }

                var k = u->op_token.kind
                if k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus {
                    return false
                }

                return LowerSynth::_pure(u->operand, acc)
            } case ExprKind::BinaryOperatorExpr {
                var unsafe *b = cast<BinaryOperatorExpr>(e)
                if b->resolved_op != &null {
                    return false
                }

                return LowerSynth::_pure(b->lhs, acc) && LowerSynth::_pure(b->rhs, acc)
            } case ExprKind::SubscriptExpr {
                var unsafe *s = cast<SubscriptExpr>(e)
                if s->resolved_op != &null {
                    return false
                }

                return LowerSynth::_pure(s->base, acc) && LowerSynth::_pure(s->index, acc)
            } case ExprKind::TypeCastExpr {
                var unsafe *c = cast<TypeCastExpr>(e)
                if c->resolved_op != &null || c->resolved_ctor != &null {
                    return false
                }

                return LowerSynth::_pure(c->operand, acc)
            } case ExprKind::ListLiteralExpr {
                var unsafe *l = cast<ListLiteralExpr>(e)
                for var i: usize = 0; i < l->elements.size(); ++i {
                    if !LowerSynth::_pure(l->elements[i], acc) {
                        return false
                    }
                }

                return true
            } case ExprKind::VariantInitExpr {
                // As pure as its fields: a variant without a payload runs
                // nothing.
                var unsafe *v = cast<VariantInitExpr>(e)
                for var i: usize = 0; i < v->fields.size(); ++i {
                    if !LowerSynth::_pure(v->fields[i], acc) {
                        return false
                    }
                }

                return true
            } case ExprKind::CallExpr {
                if acc == &null {
                    return false
                }

                var unsafe *r = acc->accessor_receiver(e)
                return r != &null && LowerSynth::_pure(r, acc)
            } default { // calls, assignment, if-expr, closures, ...
                return false
            }
        }
    }
}
