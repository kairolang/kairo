/// --- The Kairo Project ---------------------- Sema/Lower/LowerSynth.k --- ///
///
/// What every lowering mints: identifier tokens interned into THIS
/// file's table, integer literals with a fresh Immediate::IntData
/// slot, byte literals over decoded text with a fresh StringData
/// slot, fresh `__kairo_` locals and the names that read them,
/// member and free-function calls, statement expressions, and
/// the purity test SequenceLowering orders arguments by.
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

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::decl_pattern
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
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    AdtRole,
    ClassDecl,
    EnumDecl,
    FieldDecl,
    FunctionDecl,
    StorageClass,
    StructDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    CallExpr,
    CastMode,
    ImplicitBoundaryCastExpr,
    ListLiteralExpr,
    ListStorage,
    NamedInitializerExpr,
    ParenExpr,
    StmtExpr,
    SubscriptExpr,
    TypeCastExpr,
    UnaryOperatorExpr,
    UnsafeExpr,
    VariantInitExpr,
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
import Lexer::Immediate::{
    Immediate,
    string_chain_bytes,
}
import Location::SourceRange::SourceRange
import Native::UTF8Decode::decode_utf8_lut
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
        var t = self.ident(
            range,
            LowerTargets::reserved_prefix() + hint + f"{self._counter}",
        )

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

    /// An integer literal typed `kind`, its IntData slot minted and written
    /// straight in: no source text, so EmitIR spells it from the value.
    fn int_literal(self, range: SourceRange, value: u64, kind: BuiltinKind) -> unsafe *Expr {
        var unsafe *tbl = self.sc->imm_table()
        var        idx  = tbl->create<Immediate::IntData>()
        var unsafe *d   = tbl->get<Immediate::IntData>(idx)
        d->value_lo = value
        d->value_hi = 0
        d->bits     = 0
        d->base     = 10
        d->assign_flags(FlagSet<Immediate::IntFlags, u8>())

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
    /// `ty` (a pointer type; EmitIR spells it as a C++ literal from the
    /// bytes). The token carries a fresh StringData slot whose owned text is
    /// the bytes.
    fn bytes_literal(self,
                     range: SourceRange,
                     bytes: unsafe *cxx::std::vector<u8>,
                     ty:    unsafe *Type) -> unsafe *Expr {
        var unsafe *tbl = self.sc->imm_table()
        var idx = tbl->intern_bytes_copy(self._bytes_ptr(*bytes), bytes->size())

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

    /// local(), placed: its DeclStmt pushed on `stmts`. The bind-once step
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

    /// An explicit cast to the canonical `to`. Default renders `static_cast`,
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

    /// A value of canonical type `c` is a C++ class object: a class, struct,
    /// union or ADT enum. An enum with no payload is a C++ `enum class`, an
    /// integer that copies as cheaply as it moves.
    fn is_class_value(self, c: unsafe *Type) -> bool {
        if c == &null || !isa<RecordType>(c) {
            return false
        }

        var unsafe *en = dyn_cast<EnumDecl>(
            decl_pattern(cast<RecordType>(c)->decl),
        )

        return en == &null || en->is_adt
    }

    /// `e` as an rvalue of `t`: `static_cast<T &&>(e)`, the move out of a
    /// place nothing reads again.
    fn rref(self, at: SourceRange, e: unsafe *Expr, t: unsafe *Type) -> unsafe *Expr {
        return self.cast_to(
            at,
            e,
            self.sc->types->cxx_rref(t),
            CastMode::Default,
        )
    }

    /// `l <k> r`, typed bool: a comparison or a logical operator.
    fn bool_binary(self,
                   at: SourceRange,
                   l:  unsafe *Expr,
                   r:  unsafe *Expr,
                   k:  TokenKind) -> unsafe *Expr {
        var unsafe *b = BinaryOperatorExpr::create(
            self.sc->ctx,
            at,
            l,
            r,
            self.punct(at, k),
        )

        b->type_          = self.sc->builtin(BuiltinKind::Bool)
        b->value_category = Expr::ValueCategory::RValue
        return b
    }

    /// `!e`, typed bool.
    fn logical_not(self, at: SourceRange, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *u = UnaryOperatorExpr::create(
            self.sc->ctx,
            at,
            e,
            self.punct(at, TokenKind::OpExclaim),
            UnaryOperatorExpr::Fix::Prefix,
        )

        u->type_          = self.sc->builtin(BuiltinKind::Bool)
        u->value_category = Expr::ValueCategory::RValue
        return u
    }

    /// `*e`, an lvalue of `t`.
    fn deref(self, at: SourceRange, e: unsafe *Expr, t: unsafe *Type) -> unsafe *Expr {
        var unsafe *u = UnaryOperatorExpr::create(
            self.sc->ctx,
            at,
            e,
            self.punct(at, TokenKind::OpStar),
            UnaryOperatorExpr::Fix::Prefix,
        )

        u->type_          = t
        u->value_category = Expr::ValueCategory::LValue
        return u
    }

    /// `{ stmts }`.
    fn block(self,
             at:          SourceRange,
             const stmts: cxx::std::vector<unsafe *Stmt>) -> unsafe *CompoundStmt {
        var unsafe *blk = CompoundStmt::create(self.sc->ctx, at)
        var        lb   = ListBuilder<unsafe *Stmt>(self.sc->ctx)
        for var i: usize = 0; i < stmts.size(); ++i {
            lb.push(stmts[i])
        }

        lb.freeze_into(&blk->body)
        return blk
    }

    /// What a call of `f` yields, read from the decl: `!` for a function
    /// that does not return, `void` for one that declares no result.
    fn result_type(self, f: unsafe *FunctionDecl) -> unsafe *Type {
        if f->is_noreturn {
            return self.sc->builtin(BuiltinKind::Never)
        }

        if f->return_type == &null {
            return self.sc->builtin(BuiltinKind::Void)
        }

        return f->return_type->canonical
    }

    /// A slice literal bound to a local lives to the end of the local's
    /// block, as one bound to a `var` does (LiteralTyping::mark_list_storage):
    /// its backing array, and that of every slice literal nested in it, is
    /// marked Extended.
    fn mark_extended(self, e_in: unsafe *Expr) {
        var        tu = TypeUtil(self.sc)
        var unsafe *e = tu.strip_parens(e_in)
        if e == &null || !isa<ListLiteralExpr>(e) {
            return
        }

        var unsafe *l = cast<ListLiteralExpr>(e)
        if l->type_ == &null || !tu.is_slice(l->type_) {
            return
        }

        l->storage = ListStorage::Extended
        for var i: usize = 0; i < l->elements.size(); ++i {
            self.mark_extended(l->elements[i])
        }
    }

    /// `n` names its fields in an order other than the one its struct or
    /// class declares them in. False when that cannot be told: no record
    /// type, or a field that names no declared field.
    fn out_of_order(self, n: unsafe *NamedInitializerExpr) -> bool {
        var unsafe *rt = dyn_cast<RecordType>(canon_unqual(n->type_))
        if rt == &null || rt->decl == &null {
            return false
        }

        var unsafe *rd                                                = rt->decl
        var        decl_fields: unsafe *FrozenList<unsafe *FieldDecl> = &null
        if isa<StructDecl>(rd) {
            decl_fields = unsafe &cast<StructDecl>(rd)->fields
        } else if isa<ClassDecl>(rd) {
            decl_fields = unsafe &cast<ClassDecl>(rd)->fields
        }

        if decl_fields == &null {
            return false
        }

        // Each written field's declaration position; written order is
        // declaration order when those rise.
        var in_order       = true
        var prev:    usize = 0
        var any            = false
        for var i: usize = 0; i < n->fields.size(); ++i {
            var nm = self.sc->ctx->get_spelling(n->fields.get(i)->name)
            var at = usize::MAX
            for var j: usize = 0; j < decl_fields->size(); ++j {
                var unsafe *fd = (*decl_fields)[j]
                if fd != &null && self.sc->ctx->get_spelling(fd->name) == nm {
                    at = j
                    break
                }
            }

            if at == usize::MAX {
                return false
            }

            if any && at < prev {
                in_order = false
            }

            prev = at
            any  = true
        }

        return !in_order
    }

    /// `n`'s field indices in the order the fields were written.
    fn written_order(self, n: unsafe *VariantInitExpr) -> cxx::std::vector<usize> {
        var out   = cxx::std::vector<usize>()
        var count = n->fields.size()
        for var k: usize = 0; k < count; ++k {
            for var i: usize = 0; i < count; ++i {
                if (n->source_order[i] as usize) == k {
                    out.push_back(i)
                }
            }
        }

        return out
    }

    /// `({ stmts; n })` with `n` rebuilt over `bound`, one value per field
    /// in declaration order. `stmts` computed them in the order written,
    /// so the written order of `n` is declaration order from here on.
    fn variant_over(self,
                    n:            unsafe *VariantInitExpr,
                    const bound:  cxx::std::vector<unsafe *Expr>,
                    @inout stmts: ListBuilder<unsafe *Stmt>) -> unsafe *Expr {
        var fields = ListBuilder<unsafe *Expr>(self.sc->ctx)
        var order  = ListBuilder<u32>(self.sc->ctx)
        for var i: usize = 0; i < bound.size(); ++i {
            fields.push(bound[i])
            order.push(i as u32)
        }

        fields.freeze_into(&n->fields)
        order.freeze_into(&n->source_order)
        stmts.push(
            unsafe (ExpressionStmt::create(self.sc->ctx, n->range, unsafe (n as unsafe *Expr)) as unsafe *Stmt),
        )

        return self.stmt_expr(unsafe (n as unsafe *Expr), &stmts, n->type_)
    }

    /// `&e`, typed `*T` for an `e` of T. A C++ `T&` (an `operator*` result)
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

    /// `base.<field>`, an lvalue of `ty`. The step names the FieldDecl; the
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

    /// `recv.<method>(args)` typed `ty`. An operator method (`op as`) gets
    /// an Operator step spelled from the decl; a named one a Name step whose
    /// token spells the name in this file. Same shape OperatorLowering mints.
    ///
    /// `ordered`: the caller knows the order of the operands is
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
            kairo::std::ice_fail(
                "LowerSynth::member_call: method is not a function",
            )
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

    /// `init` converted to the type written on binder `vd` through the
    /// extension's `@implicit op as` StmtTyping found for it
    /// (SemaContext::binder_convs); `init` itself for any other binder.
    fn binder_converted(self, vd: unsafe *VariableDecl, init: unsafe *Expr) -> unsafe *Expr {
        var key = vd as usize as u64
        var it  = self.sc->binder_convs.find(key)
        if it == self.sc->binder_convs.end() || init == &null {
            return init
        }

        var        args = ListBuilder<unsafe *Expr>(self.sc->ctx)
        var unsafe *cv  = unsafe (it->second as unsafe *Decl)
        var unsafe *call = self.member_call(
            init->range,
            init,
            cv,
            &args,
            canon_unqual(vd->type_),
        )

        var ii = self.sc->binder_conv_instances.find(key)
        if ii != self.sc->binder_conv_instances.end() && isa<CallExpr>(call) {
            cast<CallExpr>(call)->instance = ii->second
        }

        return call
    }

    /// A constructor call typed `ty`. The callee names the ctor decl; EmitIR
    /// spells the TYPE from the call's own canonical, never from this token.
    /// `ordered` as member_call's.
    fn ctor_call(self,
                 range:       SourceRange,
                 ctor:        unsafe *Decl,
                 const name:  string,
                 @inout args: ListBuilder<unsafe *Expr>,
                 ty:          unsafe *Type,
                 ordered:     bool = false) -> unsafe *Expr {
        var unsafe *callee = NamedIdentExpr::create(
            self.sc->ctx,
            range,
            self.ident(range, name),
        )

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
        if self.sc == &null || !self.sc->sequenced() {
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

    /// `f(args)`, a call of the free function `f` (a lang item a lowering
    /// calls) typed `ty`: the node shape of ctor_call, the callee naming
    /// `f` by its own name.
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
    /// §2.8). `text` is the whole message -- what failed and its
    /// file:line:col -- because nothing may be formatted at crash time: the
    /// runtime writes these bytes and a newline and aborts. No newline here;
    /// the runtime owns it. `who` names the calling pass in the ICE.
    fn crash_call(self, range: SourceRange, const text: string, const who: string) -> unsafe *Expr {
        var unsafe *d = self.sc->well_known->get(WellKnownType::UnwrapFailed)
        if d == &null {
            kairo::std::ice_fail(
                who.copy() + ": the '" + to_string(
                    WellKnownType::UnwrapFailed,
                ) + "' lang item is unbound; Lib/builtin/module.k declares it",
            )
        }

        var unsafe *f = dyn_cast<FunctionDecl>(NameLookup::representative(d))
        if f == &null {
            kairo::std::ice_fail(
                who.copy() + ": the '" + to_string(
                    WellKnownType::UnwrapFailed,
                ) + "' lang item is not a function",
            )
        }

        var bytes = cxx::std::vector<u8>()
        LowerSynth::push_string(text, &bytes)
        var unsafe *u8t = self.sc->types->qualified(
            self.sc->builtin(BuiltinKind::U8),
            QUAL_CONST,
        )

        var unsafe *pu8 = self.sc->types->pointer(u8t)
        var unsafe *lit = self.bytes_literal(range, unsafe &bytes, pu8)
        var        args = ListBuilder<unsafe *Expr>(self.sc->ctx)
        args.push(self.cast_to(range, lit, pu8, CastMode::Unsafe)) // `"..."` is const char*; the parameter is const unsigned char*.
        args.push(
            self.int_literal(range, bytes.size() as u64, BuiltinKind::USize),
        )

        return self.free_call(
            range,
            f,
            unsafe &args,
            self.sc->builtin(BuiltinKind::Never),
        )
    }

    /// `if cond { <call> }`, `call` a `-> !` call (crash_call's).
    fn crash_if(self, range: SourceRange, cond: unsafe *Expr, call: unsafe *Expr) -> unsafe *Stmt {
        var unsafe *blk = CompoundStmt::create(self.sc->ctx, range)
        var        body = ListBuilder<unsafe *Stmt>(self.sc->ctx)
        body.push(ExpressionStmt::create(self.sc->ctx, range, call))
        body.freeze_into(&blk->body)
        return ConditionalStmt::create(self.sc->ctx, range, cond, blk, &null)
    }

    /// `({ stmts })` in place of `orig`, a prvalue of `ty`.
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

    /// The extent C++ gives string literal `sl` as `const char[N]`: its
    /// decoded bytes, every chained part, plus the terminator. 0 when
    /// an escape does not decode, which the caller reads as "no literal".
    /// Typing needs it before StringLowering has built the bytes.
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

        var out = cxx::std::vector<u8>()
        if !string_chain_bytes(tbl, self.sc->ctx->sm, sl->imm, unsafe &out) {
            return 0
        }

        return (out.size() as u64) + 1
    }

    /// The bytes of `range` decoded: every escape the lexer accepts, into
    /// UTF-8 (Immediate::decode_escapes). `raw` copies verbatim. False for
    /// an escape that is not whole, which the lexer has already rejected; the
    /// caller ICEs.
    fn decode_text(self, range: SourceRange, raw: bool, out: unsafe *cxx::std::vector<u8>) -> bool {
        if !range.is_valid() {
            return true
        }

        var view = self.sc->ctx->sm->get_view(range)
        return Immediate::decode_escapes(
            view.data(),
            view.size(),
            raw,
            false,
            out,
        )
    }

    /// The raw bytes of `range`, no decoding.
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
        var unsafe *r = unsafe (s.data() as kairo::std::ConstPtr<u8>) // raw is const: no working copy
        for var i: usize = 0; i < s.size(); ++i {
            out.push_back(r[i])
        }
    }

    /// Codepoints in `bytes`: every byte that is not a continuation byte.
    ///
    /// Requires valid UTF-8, which SourceManager::validate_utf8 (source bytes)
    /// plus decode_escapes' encoding (every escape is written as a full
    /// UTF-8 sequence) guarantee; on anything else the count is wrong, not an
    /// error. Debug builds re-decode `bytes` to catch a path that bypassed
    /// validation.
    static fn cp_count(const bytes: cxx::std::vector<u8>) -> usize {
        eval if defined!(DEBUG) {
            const base: kairo::std::ConstPtr<u8> = unsafe (bytes.data() as kairo::std::ConstPtr<u8>)
            var off: usize = 0
            while off < bytes.size() {
                var d = decode_utf8_lut(base + off, bytes.size() - off)
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

    /// An empty vec may have no buffer; the interner still wants a pointer.
    priv fn _bytes_ptr(self, const bytes: cxx::std::vector<u8>) -> kairo::std::ConstPtr<u8> {
        static _empty: u8 = 0
        if bytes.size() == 0 {
            return unsafe &_empty
        }

        return unsafe (bytes.data() as kairo::std::ConstPtr<u8>)
    }

    /// No side effect and no dependence on one: reading `e` before or after
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

    /// `e` is `recv.m()` with m a pure accessor (is_pure_accessor) and no
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

    /// `d` is one of the pure accessors (PureAccessors), by identity: the
    /// Null layout's IsNull / ValueRef / ValueCref members (roles only
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

        var tu = TypeUtil(self.sc)
        for var i: usize = 0; i < PureAccessors::string_count(); ++i {
            var unsafe *m = tu.lang_member(
                WellKnownType::String,
                PureAccessors::string_member(i, self.sc->well_known->two_word()),
                true,
            )

            if m != &null {
                self._acc.push_back(m)
            }
        }
    }

    /// The one walk behind pure() and pure_read(): `acc` null is the
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
                return LowerSynth::_pure(
                    cast<ImplicitBoundaryCastExpr>(e)->original,
                    acc,
                )
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
