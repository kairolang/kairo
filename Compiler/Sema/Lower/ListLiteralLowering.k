/// --- The Kairo Project -------------- Sema/Lower/ListLiteralLowering.k --- ///
///
///   \brief Give every slice-typed list literal an array to point at.
///
///   \detail
///     `[1, 2, 3]` is a SLICE: a view of the elements as written (§5). A view
///     needs storage, and C++ accepts a brace list only as a declarator's
///     initializer -- never as an argument, a return value, or an operand. So
///     the storage is hoisted and the literal becomes a construction over it:
///
///       f([1, 2, 3])
///     ->
///       var __kairo_tmp0: [i32; 3] = [1, 2, 3];      // spliced BEFORE the stmt
///       f(Slice(&__kairo_tmp0, 3))
///
///     A literal whose type is already `[T; N]` is left alone: it IS the
///     declarator's initializer, which is the one position a brace list is
///     legal in, and EmitIR emits it as one.
///
///   \par Where it splices
///     ExpressionStmt, DeclStmt and ReturnStmt: the three statement forms that
///     can be preceded by a declaration in the same block. A literal reached
///     from a condition or a loop header has nowhere to hoist TO -- the temp
///     would fall out of scope, or be evaluated on the wrong iteration -- so
///     that ICEs rather than emitting something subtly wrong.
///
///   \par Postcondition
///     No slice-typed ListLiteralExpr reaches codegen. Set and map literals
///     have no lowering at all yet and ICE by name.
///
///   Phase: LOWER, after OperatorLowering.
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
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Context::CanonicalTypes::*;
import AST::Node::CanonicalNodes::*;
import AST::Kind::ExprKind::*;
import Lexer::Immediate::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_ListLiteralLowering ASTWriter<ListLiteralLowering>
");

class ListLiteralLowering derives ASTWriter::<ListLiteralLowering> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;

    /// Declarations hoisted out of the statement currently being rewritten,
    /// in the order they must run. Drained by whichever statement transform
    /// opened the window.
    priv var _pending: vec::<*Stmt>;

    /// False everywhere a hoist has nowhere to go (conditions, loop headers).
    /// A literal reached with this false is an ICE, not a silent miscompile.
    priv var _can_hoist: bool = false;

    priv var _counter: u32 = 0;

    fn ListLiteralLowering(self, sc: *SemaContext) {
        self.sc  = sc;
        self.ctx = sc->ctx;
        self.tu  = TypeUtil(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_ListLiteralLowering::run(self.sc->tu);
    }

    // --- the three statements a hoist can precede -----------------------------

    fn transform_expression_stmt(self, n: *ExpressionStmt) -> vec::<*Stmt> {
        var mark = self._open();
        var body = ASTWriter_ListLiteralLowering::transform_expression_stmt(n);
        return self._close(mark, body);
    }

    fn transform_decl_stmt(self, n: *DeclStmt) -> vec::<*Stmt> {
        var mark = self._open();
        var body = ASTWriter_ListLiteralLowering::transform_decl_stmt(n);
        return self._close(mark, body);
    }

    fn transform_return_stmt(self, n: *ReturnStmt) -> vec::<*Stmt> {
        var mark = self._open();
        var body = ASTWriter_ListLiteralLowering::transform_return_stmt(n);
        return self._close(mark, body);
    }

    /// Open the hoist window for one statement. Returns the pending mark: a
    /// statement drains only what IT added, because statements nest (a
    /// DeclStmt inside a compound inside an ExpressionStmt's operand) and an
    /// inner one must not carry an outer one's temps into its own list.
    priv fn _open(self) -> usize {
        self._can_hoist = true;
        return self._pending.size();
    }

    /// Splice this statement's temps in FRONT of it, in the order they were
    /// created, and close the window behind them.
    priv fn _close(self, mark: usize, body: vec::<*Stmt>) -> vec::<*Stmt> {
        var out = vec::<*Stmt>();
        for var i: usize = mark; i < self._pending.size(); ++i { out.push_back(self._pending[i]); }
        for var i: usize = 0; i < body.size(); ++i { out.push_back(body[i]); }
        while self._pending.size() > mark { self._pending.pop_back(); }
        self._can_hoist = (mark > 0);
        return out;
    }

    // --- the rewrite ----------------------------------------------------------

    fn transform_list_literal_expr(self, n: *ListLiteralExpr) -> *Expr {
        // The window belongs to the enclosing STATEMENT, not to this node: a
        // nested literal hoists into the same place its parent does.
        var saved_hoist = self._can_hoist;
        var out = ASTWriter_ListLiteralLowering::transform_list_literal_expr(n);

        if n->type_ == &null { return out; }
        var c = canon_unqual(n->type_);
        if c == &null { return out; }

        // `[T; N]`: already a declarator's initializer. EmitIR emits the braces.
        if isa::<FixedArrayType>(c) { return out; }

        // Anything else must be the Slice lang record; a list literal has no
        // third type after LiteralTyping.
        ICE_IF(!self.tu.is_slice(n->type_),
            "ListLiteralLowering: list literal is neither an array nor a slice; LiteralTyping invariant violation");

        ICE_IF(!saved_hoist,
            "ListLiteralLowering: list literal in a condition or loop header needs hoisting; only ExpressionStmt, DeclStmt and ReturnStmt can carry one");

        return self._hoist_slice(n);
    }

    fn transform_set_literal_expr(self, n: *SetLiteralExpr) -> *Expr {
        ICE_FAIL("ListLiteralLowering: set literal has no lowering yet; {T} cannot reach codegen");
        return static_cast::<*Expr>(n);
    }

    fn transform_map_literal_expr(self, n: *MapLiteralExpr) -> *Expr {
        ICE_FAIL("ListLiteralLowering: map literal has no lowering yet; {K: V} cannot reach codegen");
        return static_cast::<*Expr>(n);
    }

    /// `[a, b, c]` (Slice<T>) -> temp `[T; 3]` + `Slice(&temp, 3)`.
    priv fn _hoist_slice(self, n: *ListLiteralExpr) -> *Expr {
        var slice_ty = n->type_;
        var elem     = self.tu.container_elem(slice_ty);
        if elem == &null { return static_cast::<*Expr>(n); }   // poisoned; already diagnosed.

        var count   = n->elements.size();
        var arr_ty  = self.sc->types->array(elem, static_cast::<u64>(count));
        if arr_ty == &null { return static_cast::<*Expr>(n); }

        // 1. the temp, initialized by the literal RETYPED as the array. The
        //    literal node is reused: it is the same elements in the same order,
        //    and only its type changes.
        var name_tok = self._ident_token(n->range,
            LowerTargets::reserved_prefix() + "tmp" + f"{self._counter}");
        self._counter += 1;

        n->type_ = arr_ty;

        var vd    = VariableDecl::create(self.ctx, n->range, name_tok, StorageClass::Var);
        vd->type_ = arr_ty;
        vd->init  = static_cast::<*Expr>(n);

        self._pending.push_back(static_cast::<*Stmt>(
            DeclStmt::create(self.ctx, n->range, static_cast::<*Decl>(vd))));

        // 2. `&temp`, typed as the ctor's `*T` parameter. Codegen inserts the
        //    cast from the array's own pointer type; Kairo's `&` on an array
        //    and C's array-to-pointer decay are not the same spelling.
        var use = NamedIdentExpr::create(self.ctx, n->range, name_tok);
        use->resolved_decl  = static_cast::<*Decl>(vd);
        use->type_          = arr_ty;
        use->value_category = Expr::ValueCategory::LValue;

        var amp = Token();
        amp.kind  = TokenKind::OpAmp;
        amp.range = n->range;

        var addr = UnaryOperatorExpr::create(self.ctx, n->range,
            static_cast::<*Expr>(use), amp, UnaryOperatorExpr::Fix::Prefix);
        addr->type_          = self.sc->types->pointer(elem);
        addr->value_category = Expr::ValueCategory::RValue;

        // 3. the length.
        var len = self._int_literal(n->range, static_cast::<u64>(count));

        // 4. `Slice(&temp, N)`.
        var ctor = self._slice_ctor();
        ICE_IF(ctor == &null,
            "ListLiteralLowering: the Slice lang item declares no two-argument constructor; Lib/builtin and this pass disagree");

        var callee = NamedIdentExpr::create(self.ctx, n->range,
            self._ident_token(n->range, to_string(WellKnownType::Slice)));
        callee->resolved_decl = ctor;

        var call = CallExpr::create(self.ctx, n->range, static_cast::<*Expr>(callee));
        var args = self.list_builder::<*Expr>();
        args.push(static_cast::<*Expr>(addr));
        args.push(len);
        args.freeze_into(&(call->args));
        call->type_          = slice_ty;
        call->value_category = Expr::ValueCategory::RValue;

        return static_cast::<*Expr>(call);
    }

    // --- synthesis helpers ----------------------------------------------------

    /// An identifier token for a name this pass invented. The imm is interned
    /// into THIS file's table, which is the only one the node may be read
    /// through (RESOLUTION.md hard invariant #2).
    priv fn _ident_token(self, range: SourceRange, spelling: string) -> Token {
        var t = Token();
        t.kind  = TokenKind::LitIdentifier;
        t.range = range;
        // intern_ident_copy, not the lexer path: the bytes are ours, not a
        // source slice. It hashes the way the lexer does, so a synthesized
        // name and a written one of the same spelling share a slot.
        t.imm   = self.sc->imm_table()->intern_ident_copy(spelling);
        return t;
    }

    /// An integer literal with a synthesized value. A literal reads its value
    /// through an Immediate::IntData entry, and the lexer is normally the only
    /// thing that fills one; `create` mints the slot and the value is written
    /// straight in, with no source text to evaluate.
    priv fn _int_literal(self, range: SourceRange, value: u64) -> *Expr {
        var tbl = self.sc->imm_table();
        var idx = tbl->create::<Immediate::IntData>();
        var d   = tbl->get::<Immediate::IntData>(idx);
        d->value_lo = value;
        d->value_hi = 0;
        d->bits     = 0;      // no suffix: an unsuffixed literal takes its context's type.
        d->base     = 10;
        d->flags    = 0;      // not unsigned, not negative, not big, no suffix/prefix.

        var t = Token();
        t.kind  = TokenKind::LitInt;
        t.range = range;
        t.imm   = idx;

        var lit = IntegerLiteralExpr::create(self.ctx, range, t);
        lit->type_          = self.sc->builtin(BuiltinKind::USize);
        lit->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(lit);
    }

    /// The `Slice(data, len)` constructor, by shape: the one ctor with exactly
    /// two non-self parameters. Found through the lang item, never by name.
    priv fn _slice_ctor(self) -> *Decl {
        var d = self.sc->well_known->get(WellKnownType::Slice);
        if d == &null { return &null; }
        var body = self.tu.pattern_of(NameLookup::representative(d));
        var dc   = NameLookup::context_of(body);
        if dc == &null { return &null; }

        var cell = self.sc->lookup.in_context(dc, DeclName::ctor());
        if !cell.found() { return &null; }
        for var i: usize = 0; i < cell.cell->size(); ++i {
            var cand = cell.cell->get(i);
            if !isa::<FunctionDecl>(cand) { continue; }
            var f = cast::<FunctionDecl>(cand);
            var n: usize = 0;
            for var p: usize = 0; p < f->params.size(); ++p {
                var pd = f->params[p];
                if (pd == &null) || pd->is_self { continue; }
                n += 1;
            }
            if n == 2 { return cand; }
        }
        return &null;
    }
}
