/// --- The Kairo Project ---------------------- Sema/Lower/LowerSynth.k --- ///
///
///   \brief What every lowering mints: identifier tokens interned into THIS
///          file's table, integer literals with a fresh Immediate::IntData
///          slot, byte literals over decoded text with a fresh StringData
///          slot, fresh `__kairo_` locals and the names that read them,
///          member calls, statement expressions, and the purity test
///          SequenceLowering orders arguments by.
///
///   One copy. Three passes each carried their own `_ident_token`, and the
///   `Token` invariant (16 bytes, an imm index into the owning file's table,
///   RESOLUTION.md hard invariant #2) is the kind of rule that drifts when it
///   is written in three places.
///
///   Held by value on each pass, so counters are per pass; passes use
///   different name hints (`arg`, `tmp`, `lhs`, `sum`, `fmt`) and never
///   collide.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/UTF8Decode.hh";
import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import AST::LangItems::*;
import AST::Visitor::ASTWriter::*;
import AST::Node::Base::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;
import Lexer::Immediate::*;
import Location::SourceManager::*;
import Location::SourceRange::*;
import Memory::MemoryBuffer::*;
import Token::Token::*;
import Token::TokenKind::*;

class LowerSynth {
    pub var sc: *SemaContext;
    priv var _counter: u32 = 0;

    fn LowerSynth(self) { self.sc = &null; }
    fn LowerSynth(self, sc: *SemaContext) { self.sc = sc; }

    /// An identifier token for a name this pass invented.
    fn ident(self, range: SourceRange, spelling: string) -> Token {
        var t = Token();
        t.kind  = TokenKind::LitIdentifier;
        t.range = range;
        t.imm   = self.sc->imm_table()->intern_ident_copy(spelling);
        return t;
    }

    /// `__kairo_<hint>K`, unique within this pass.
    fn fresh(self, range: SourceRange, hint: string) -> Token {
        var t = self.ident(range, LowerTargets::reserved_prefix() + hint + f"{self._counter}");
        self._counter += 1;
        return t;
    }

    /// A punctuator token with no source bytes behind it (the `=` of a minted
    /// assignment). TokenSink creates it from the kind alone.
    fn punct(self, range: SourceRange, kind: TokenKind) -> Token {
        var t = Token();
        t.kind  = kind;
        t.range = range;
        return t;
    }

    /// An integer literal typed \p kind, its IntData slot minted and written
    /// straight in: no source text, so EmitIR spells it from the value.
    fn int_literal(self, range: SourceRange, value: u64, kind: BuiltinKind) -> *Expr {
        var tbl = self.sc->imm_table();
        var idx = tbl->create::<Immediate::IntData>();
        var d   = tbl->get::<Immediate::IntData>(idx);
        d->value_lo = value;
        d->value_hi = 0;
        d->bits     = 0;
        d->base     = 10;
        d->flags    = 0;

        var t = Token();
        t.kind  = TokenKind::LitInt;
        t.range = range;
        t.imm   = idx;

        var lit = IntegerLiteralExpr::create(self.sc->ctx, range, t);
        lit->type_          = self.sc->builtin(kind);
        lit->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(lit);
    }

    /// A string literal over BYTES this pass minted -- a decoded body -- typed
    /// \p ty (a pointer type; EmitIR spells it as a C++ literal from the
    /// bytes). The token carries a fresh StringData slot whose owned text is
    /// the bytes.
    fn bytes_literal(self, range: SourceRange, bytes: *vec::<u8>, ty: *Type) -> *Expr {
        var tbl = self.sc->imm_table();
        var idx = tbl->intern_bytes_copy(self._bytes_ptr(bytes), bytes->size());

        var t = Token();
        t.kind  = TokenKind::LitString;
        t.range = range;
        t.imm   = idx;

        var lit = StringLiteralExpr::create(self.sc->ctx, range, t, StringLiteralExpr::StringKind::Plain);
        lit->imm            = tbl->get::<Immediate::StringData>(idx);
        lit->type_          = ty;
        lit->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(lit);
    }

    /// `var __kairo_<hint>K: <ty> = <init>`. The caller wraps it in a DeclStmt
    /// and places it; the decl is the identity every use_of() binds to.
    fn local(self, range: SourceRange, hint: string, ty: *Type, init: *Expr) -> *VariableDecl {
        var vd    = VariableDecl::create(self.sc->ctx, range, self.fresh(range, hint), StorageClass::Var);
        vd->type_ = ty;
        vd->init  = init;
        return vd;
    }

    /// A read of a local this pass minted. One node per use: a node has one
    /// parent, and two parents sharing one is a rewrite waiting to happen.
    fn use_of(self, vd: *VariableDecl, range: SourceRange, cat: Expr::ValueCategory) -> *Expr {
        var use = NamedIdentExpr::create(self.sc->ctx, range, vd->name);
        use->resolved_decl  = static_cast::<*Decl>(vd);
        use->type_          = vd->type_;
        use->value_category = cat;
        return static_cast::<*Expr>(use);
    }

    /// An explicit cast to the canonical \p to. Default renders `static_cast`,
    /// Unsafe `reinterpret_cast`. Not `cast`: a member by that name hides
    /// Casting.k's `cast::<T>` for every method of this class.
    fn cast_to(self, range: SourceRange, operand: *Expr, to: *Type, mode: CastMode) -> *Expr {
        var c = TypeCastExpr::create(self.sc->ctx, range, operand, to, mode == CastMode::Unsafe, mode);
        c->type_          = to;
        c->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(c);
    }

    /// `&e`, typed `*T` for an \p e of T.
    fn addr_of(self, e: *Expr) -> *Expr {
        var pt = self.sc->types->pointer(canon_unqual(e->type_));
        var u  = UnaryOperatorExpr::create(self.sc->ctx, e->range, e, self.punct(e->range, TokenKind::OpAmp),
                                           UnaryOperatorExpr::Fix::Prefix);
        u->type_          = pt;
        u->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(u);
    }

    /// `base.<field>`, an lvalue of \p ty. The step names the FieldDecl; the
    /// token spells it in this file.
    fn field_of(self, range: SourceRange, base: *Expr, field: *Decl, ty: *Type) -> *Expr {
        var tu = TypeUtil(self.sc);
        var chain = ChainExpr::create(self.sc->ctx, range, base);
        var steps = ListBuilder::<ChainExpr::Step>(self.sc->ctx);
        var st = ChainExpr::Step();
        st.name          = NamedIdentExpr::create(self.sc->ctx, range, self.ident(range, tu.decl_name(field)));
        st.name->resolved_decl = field;
        st.target        = ChainExpr::StepTarget::Name;
        st.range         = range;
        st.access_kind   = ChainExpr::AccessKind::Dot;
        st.resolved_decl = field;
        st.resolved_type = ty;
        steps.push(st);
        steps.freeze_into(&(chain->steps));
        chain->type_          = ty;
        chain->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Expr>(chain);
    }

    /// `recv.<method>(args)` typed \p ty. An operator method (`op as`) gets
    /// an Operator step spelled from the decl; a named one a Name step whose
    /// token spells the name in this file. Same shape OperatorLowering mints.
    fn member_call(self, range: SourceRange, recv: *Expr, method: *Decl, args: *ListBuilder::<*Expr>, ty: *Type) -> *Expr {
        var tu = TypeUtil(self.sc);
        var f  = dyn_cast::<FunctionDecl>(method);
        ICE_IF(f == &null, "LowerSynth::member_call: method is not a function");

        var chain = ChainExpr::create(self.sc->ctx, range, recv);
        var steps = ListBuilder::<ChainExpr::Step>(self.sc->ctx);
        var st = ChainExpr::Step();
        st.name          = &null;
        st.range         = range;
        st.access_kind   = ChainExpr::AccessKind::Dot;
        st.resolved_decl = method;
        st.resolved_type = &null;
        if f->is_operator {
            st.target = ChainExpr::StepTarget::Operator;
            var toks = ListBuilder::<Token>(self.sc->ctx);
            toks.push(self.punct(range, f->op_token[0].kind));
            toks.freeze_into(&(st.op_tokens));
        } else {
            st.target = ChainExpr::StepTarget::Name;
            st.name   = NamedIdentExpr::create(self.sc->ctx, range, self.ident(range, tu.decl_name(method)));
            st.name->resolved_decl = method;
        }
        steps.push(st);
        steps.freeze_into(&(chain->steps));

        var call = CallExpr::create(self.sc->ctx, range, static_cast::<*Expr>(chain));
        args->freeze_into(&(call->args));
        call->type_          = ty;
        call->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(call);
    }

    /// A constructor call typed \p ty. The callee names the ctor decl; EmitIR
    /// spells the TYPE from the call's own canonical, never from this token.
    fn ctor_call(self, range: SourceRange, ctor: *Decl, name: string, args: *ListBuilder::<*Expr>, ty: *Type) -> *Expr {
        var callee = NamedIdentExpr::create(self.sc->ctx, range, self.ident(range, name));
        callee->resolved_decl = ctor;
        var call = CallExpr::create(self.sc->ctx, range, static_cast::<*Expr>(callee));
        args->freeze_into(&(call->args));
        call->type_          = ty;
        call->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(call);
    }

    /// `({ stmts })` in place of \p orig, a prvalue of \p ty.
    fn stmt_expr(self, orig: *Expr, stmts: *ListBuilder::<*Stmt>, ty: *Type) -> *Expr {
        var body = CompoundStmt::create(self.sc->ctx, orig->range);
        stmts->freeze_into(&(body->body));
        var se = StmtExpr::create(self.sc->ctx, orig->range, body);
        se->adopt_sema(orig);
        se->type_          = ty;
        se->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(se);
    }

    // --- text ------------------------------------------------------------------------

    /// The bytes of \p range decoded: every escape the lexer accepts, into
    /// UTF-8. \p raw copies verbatim. False for an escape the lexer accepted
    /// and this does not know; the caller ICEs, since the two must agree.
    fn decode_text(self, range: SourceRange, raw: bool, out: *vec::<u8>) -> bool {
        if !range.is_valid() { return true; }
        var view = self.sc->ctx->sm->get_view(range);
        var p = view.data();
        var n = view.size();
        var i: usize = 0;
        while i < n {
            var b = p[i];
            if raw || (b != 0x5c) { out->push_back(b); i += 1; continue; }
            i += 1;
            if i >= n { return false; }
            var e = p[i];
            i += 1;
            switch e {
                case 'n'  { out->push_back(0x0a); }
                case 'r'  { out->push_back(0x0d); }
                case 't'  { out->push_back(0x09); }
                case 'v'  { out->push_back(0x0b); }
                case 'f'  { out->push_back(0x0c); }
                case 'a'  { out->push_back(0x07); }
                case 'b'  { out->push_back(0x08); }
                case '\x27' { out->push_back(0x27); }
                case '\x22'  { out->push_back(0x22); }
                case '\\' { out->push_back(0x5c); }
                case '{'  { out->push_back(0x7b); }
                case '}'  { out->push_back(0x7d); }
                case 'x' {
                    if i + 2 > n { return false; }
                    var cp = (LowerSynth::_hex(p[i]) << 4) | LowerSynth::_hex(p[i + 1]);
                    i += 2;
                    LowerSynth::push_utf8(cp, out);
                }
                case 'u' {
                    if i + 4 > n { return false; }
                    var cp: u32 = 0;
                    for var k: usize = 0; k < 4; ++k { cp = (cp << 4) | LowerSynth::_hex(p[i + k]); }
                    i += 4;
                    LowerSynth::push_utf8(cp, out);
                }
                case 'U' {
                    if i + 8 > n { return false; }
                    var cp: u32 = 0;
                    for var k: usize = 0; k < 8; ++k { cp = (cp << 4) | LowerSynth::_hex(p[i + k]); }
                    i += 8;
                    LowerSynth::push_utf8(cp, out);
                }
                case '0': case '1': case '2': case '3': case '4': case '5': case '6': case '7' {
                    var cp: u32 = static_cast::<u32>(e - '0');
                    var digits: usize = 1;
                    while (i < n) && (digits < 3) && (p[i] >= '0') && (p[i] <= '7') {
                        cp = (cp << 3) | static_cast::<u32>(p[i] - '0');
                        i += 1;
                        digits += 1;
                    }
                    LowerSynth::push_utf8(cp, out);
                }
                default { return false; }
            }
        }
        return true;
    }

    /// The raw bytes of \p range, no decoding.
    fn copy_text(self, range: SourceRange, out: *vec::<u8>) {
        if !range.is_valid() { return; }
        var view = self.sc->ctx->sm->get_view(range);
        var p = view.data();
        for var i: usize = 0; i < view.size(); ++i { out->push_back(p[i]); }
    }

    /// A compiler string (wide) as UTF-8 bytes.
    static fn push_string(s: string, out: *vec::<u8>) {
        var ns = std::string_to_nstring(s);
        var r  = reinterpret_cast::<std::ConstPtr::<u8>>(ns.raw());
        for var i: usize = 0; i < ns.size(); ++i { out->push_back(r[i]); }
    }

    static fn push_utf8(cp: u32, out: *vec::<u8>) {
        if cp < 0x80 { out->push_back(static_cast::<u8>(cp)); return; }
        if cp < 0x800 {
            out->push_back(static_cast::<u8>(0xC0 | (cp >> 6)));
            out->push_back(static_cast::<u8>(0x80 | (cp & 0x3F)));
            return;
        }
        if cp < 0x10000 {
            out->push_back(static_cast::<u8>(0xE0 | (cp >> 12)));
            out->push_back(static_cast::<u8>(0x80 | ((cp >> 6) & 0x3F)));
            out->push_back(static_cast::<u8>(0x80 | (cp & 0x3F)));
            return;
        }
        out->push_back(static_cast::<u8>(0xF0 | (cp >> 18)));
        out->push_back(static_cast::<u8>(0x80 | ((cp >> 12) & 0x3F)));
        out->push_back(static_cast::<u8>(0x80 | ((cp >> 6) & 0x3F)));
        out->push_back(static_cast::<u8>(0x80 | (cp & 0x3F)));
    }

    /// Codepoints in \p bytes: every byte that is not a continuation byte.
    ///
    /// Requires valid UTF-8, which SourceManager::validate_utf8 (source bytes)
    /// plus decode_text's escape encoding (every escape is written as a full
    /// UTF-8 sequence) guarantee; on anything else the count is wrong, not an
    /// error. Debug builds re-decode \p bytes to catch a path that bypassed
    /// validation.
    static fn cp_count(bytes: *vec::<u8>) -> usize {
        const eval if defined(DEBUG) {
            const base: std::ConstPtr::<u8> = reinterpret_cast::<std::ConstPtr::<u8>>(bytes->data());
            var i: usize = 0;
            while i < bytes->size() {
                var d = decode_utf8_lut(base + i, bytes->size() - i);
                ICE_IF(!d.ok, "cp_count: invalid UTF-8 reached lowering; SourceManager validation bypassed");
                i += d.len;
            }
        }
        var cp: usize = 0;
        for var i: usize = 0; i < bytes->size(); ++i { if ((*bytes)[i] & 0xC0) != 0x80 { cp += 1; } }
        return cp;
    }

    priv static fn _hex(b: u8) -> u32 {
        if (b >= '0') && (b <= '9') { return static_cast::<u32>(b - '0'); }
        if (b >= 'a') && (b <= 'f') { return static_cast::<u32>(b - 'a' + 10); }
        if (b >= 'A') && (b <= 'F') { return static_cast::<u32>(b - 'A' + 10); }
        return 0;   // the lexer validated the digit; unreachable.
    }

    /// An empty vec may have no buffer; the interner still wants a pointer.
    priv fn _bytes_ptr(self, bytes: *vec::<u8>) -> std::ConstPtr::<u8> {
        static var _empty: u8 = 0;
        if bytes->size() == 0 { return &_empty; }
        return reinterpret_cast::<std::ConstPtr::<u8>>(bytes->data());
    }

    /// No side effect and no dependence on one: reading \p e before or after
    /// another operand changes nothing. Conservative: anything not listed is
    /// impure. SequenceLowering orders by it; OperatorLowering decides by it
    /// whether a compound assignment's left side is bound once first.
    static fn pure(e: *Expr) -> bool {
        if e == &null { return true; }
        switch e->kind {
            case ExprKind::IntegerLiteralExpr   { return true; }
            case ExprKind::FloatingLiteralExpr  { return true; }
            case ExprKind::CharacterLiteralExpr { return true; }
            case ExprKind::BooleanLiteralExpr   { return true; }
            case ExprKind::NullLiteralExpr      { return true; }
            case ExprKind::StringLiteralExpr    { return !cast::<StringLiteralExpr>(e)->is_format(); }
            case ExprKind::NamedIdentExpr       { return true; }
            case ExprKind::SizeOfExpr           { return true; }
            case ExprKind::AlignOfExpr          { return true; }
            case ExprKind::ParenExpr            { return LowerSynth::pure(cast::<ParenExpr>(e)->inner); }
            case ExprKind::UnsafeExpr           { return LowerSynth::pure(cast::<UnsafeExpr>(e)->operand); }
            case ExprKind::ImplicitBoundaryCastExpr { return LowerSynth::pure(cast::<ImplicitBoundaryCastExpr>(e)->original); }
            case ExprKind::ChainExpr {
                // A field path off a pure base. An operator step is a call
                // (only as a callee, which never reaches here as an operand).
                var c = cast::<ChainExpr>(e);
                for var i: usize = 0; i < c->steps.size(); ++i {
                    var st = c->steps.get(i);
                    if st->is_operator() { return false; }
                    if (st->access_kind == ChainExpr::AccessKind::QuestionDot)
                    || (st->access_kind == ChainExpr::AccessKind::QuestionArrow) { return false; }
                }
                return LowerSynth::pure(c->base);
            }
            case ExprKind::UnaryOperatorExpr {
                var u = cast::<UnaryOperatorExpr>(e);
                if u->resolved_op != &null { return false; }
                var k = u->op_token.kind;
                if (k == TokenKind::OpPlusPlus) || (k == TokenKind::OpMinusMinus) { return false; }
                return LowerSynth::pure(u->operand);
            }
            case ExprKind::BinaryOperatorExpr {
                var b = cast::<BinaryOperatorExpr>(e);
                if b->resolved_op != &null { return false; }
                return LowerSynth::pure(b->lhs) && LowerSynth::pure(b->rhs);
            }
            case ExprKind::SubscriptExpr {
                var s = cast::<SubscriptExpr>(e);
                if s->resolved_op != &null { return false; }
                return LowerSynth::pure(s->base) && LowerSynth::pure(s->index);
            }
            case ExprKind::TypeCastExpr {
                var c = cast::<TypeCastExpr>(e);
                if (c->resolved_op != &null) || (c->resolved_ctor != &null) { return false; }
                return LowerSynth::pure(c->operand);
            }
            case ExprKind::ListLiteralExpr {
                var l = cast::<ListLiteralExpr>(e);
                for var i: usize = 0; i < l->elements.size(); ++i { if !LowerSynth::pure(l->elements[i]) { return false; } }
                return true;
            }
            default { return false; }   // calls, assignment, if-expr, closures, ...
        }
    }
}