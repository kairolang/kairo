/// --- The Kairo Project -------------- Sema/Lower/ListLiteralLowering.k --- ///
///
///   \brief Render every list literal as the construction X decided it is.
///
///   \detail
///     X typed the literal as its target, bound the constructors and chose
///     where a slice's backing array lives. This pass decides nothing:
///
///       [T; N]            ->  InitListExpr                       { a, b, c }
///       Slice, FullExpr   ->  Slice(<array prvalue> as *T, N)
///       Slice, Extended   ->  var __kairo_tmpK: [T; N] = { a, b, c };   (spliced before the owner)
///                             Slice(__kairo_tmpK as *T, N)
///       Vector            ->  Vector(Slice(<array prvalue> as *T, N))
///       Vector, empty     ->  Vector()
///       Slice, empty      ->  Slice(&null, 0)
///
///     The array prvalue is an InitListExpr in expression position; C++ gives
///     it the lifetime of the full-expression, which is what FullExpr means.
///     No statement is hoisted for it, so evaluation order and conditional
///     evaluation are the source's.
///
///     Both constructor arguments carry an explicit cast. The callee is the
///     PATTERN's constructor, its parameter types are dependent, and EmitIR's
///     exactness cast skips dependent parameters.
///
///   \par Extended
///     The only case that mints a declaration, and always in front of a
///     DeclStmt: X marks a slice literal Extended only where it directly
///     initializes a `var`. Inner backings splice first. A for-init variable
///     and a namespace-scope variable have no statement list to splice into
///     and ICE by name.
///
///   \par Postcondition
///     No ListLiteralExpr reaches codegen, poisoned ones excepted (the gate
///     stops those). Set and map literals have no lowering yet and ICE.
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
import Sema::Lower::LowerSynth::*;
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

    /// Backing declarations minted under the DeclStmt being rewritten, in the
    /// order they must run. Drained by the DeclStmt that opened the window.
    priv var _pending: vec::<*Stmt>;

    /// True while a DeclStmt that sits in a statement LIST is being rewritten.
    priv var _window: bool = false;

    /// True while a for-init is being rewritten: a scalar slot, nothing splices.
    priv var _scalar_slot: bool = false;

    priv var synth: LowerSynth;

    fn ListLiteralLowering(self, sc: *SemaContext) {
        self.sc  = sc;
        self.ctx = sc->ctx;
        self.tu  = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_ListLiteralLowering::run(self.sc->tu);
    }

    // --- the one statement a backing array can precede ------------------------

    fn transform_decl_stmt(self, n: *DeclStmt) -> vec::<*Stmt> {
        var mark         = self._pending.size();
        var saved_window = self._window;
        var saved_scalar = self._scalar_slot;
        self._window      = !saved_scalar;
        self._scalar_slot = false;      // statements nested in the initializer are lists again.

        var body = ASTWriter_ListLiteralLowering::transform_decl_stmt(n);

        self._window      = saved_window;
        self._scalar_slot = saved_scalar;

        var out = vec::<*Stmt>();
        for var i: usize = mark; i < self._pending.size(); ++i { out.push_back(self._pending[i]); }
        for var i: usize = 0; i < body.size(); ++i { out.push_back(body[i]); }
        while self._pending.size() > mark { self._pending.pop_back(); }
        return out;
    }

    /// The base body, with the init marked as the scalar slot it is.
    fn transform_indexed_for_stmt(self, n: *IndexedForStmt) -> vec::<*Stmt> {
        if n->init != &null {
            var saved = self._scalar_slot;
            self._scalar_slot = true;
            n->init = self.transform_stmt_scalar(n->init);
            self._scalar_slot = saved;
        }
        if n->cond   != &null { n->cond   = self.transform_expr(n->cond); }
        if n->update != &null { n->update = self.transform_expr(n->update); }
        n->body = cast::<CompoundStmt>(self.transform_stmt_scalar(n->body));
        return self._one_stmt(n);
    }

    // --- the rewrite ----------------------------------------------------------

    fn transform_list_literal_expr(self, n: *ListLiteralExpr) -> *Expr {
        // Children first: nested literals are already lowered, and an inner
        // Extended backing is already pending ahead of this one.
        var out = ASTWriter_ListLiteralLowering::transform_list_literal_expr(n);
        if n->is_poisoned() || (n->type_ == &null) { return out; }

        var c = canon_unqual(n->type_);
        if c == &null { return out; }

        if isa::<FixedArrayType>(c) {
            return static_cast::<*Expr>(self._init_list(n, c));
        }

        var elem = self.tu.container_elem(c);
        ICE_IF(elem == &null, "ListLiteralLowering: container target with no element type; LiteralTyping invariant violation");

        if self.tu.is_slice(c) { return self._slice(n, c, elem); }

        ICE_IF(!self.tu.is_vector_like(c),
            "ListLiteralLowering: list literal is not an array, a slice or a vector; LiteralTyping invariant violation");
        ICE_IF(n->owner_ctor == &null, "ListLiteralLowering: vector literal with no constructor bound; LiteralTyping must bind it");

        var args = self.list_builder::<*Expr>();
        if n->elements.size() > 0 {
            var st = self.tu.slice_of(elem);
            ICE_IF(st == &null, "ListLiteralLowering: the Slice lang item is unbound under a vector literal");
            // A vector copies out before the statement ends: always a temporary.
            n->storage = ListStorage::FullExpr;
            args.push(self._slice(n, st, elem));
        }
        return self._ctor_call(n->range, n->owner_ctor, to_string(WellKnownType::Vector), &args, n->type_);
    }

    fn transform_set_literal_expr(self, n: *SetLiteralExpr) -> *Expr {
        ICE_FAIL("ListLiteralLowering: set literal has no lowering yet; {T} cannot reach codegen");
        return static_cast::<*Expr>(n);
    }

    fn transform_map_literal_expr(self, n: *MapLiteralExpr) -> *Expr {
        ICE_FAIL("ListLiteralLowering: map literal has no lowering yet; {K: V} cannot reach codegen");
        return static_cast::<*Expr>(n);
    }

    // --- pieces ---------------------------------------------------------------

    /// The literal's elements as a braced-init-list typed \p arr_ty. The list
    /// is shared, not copied: the literal node is dropped from the tree.
    priv fn _init_list(self, n: *ListLiteralExpr, arr_ty: *Type) -> *InitListExpr {
        var il = InitListExpr::create(self.ctx, n->range);
        il->elements = n->elements;
        il->adopt_sema(static_cast::<*Expr>(n));
        il->type_          = arr_ty;
        il->value_category = Expr::ValueCategory::RValue;
        return il;
    }

    /// `Slice(data, len)` typed \p slice_ty, over the storage X chose.
    priv fn _slice(self, n: *ListLiteralExpr, slice_ty: *Type, elem: *Type) -> *Expr {
        ICE_IF(n->slice_ctor == &null, "ListLiteralLowering: slice literal with no constructor bound; LiteralTyping must bind it");
        var count = n->elements.size();
        var ptr   = self.sc->types->pointer(elem);

        var data: *Expr = &null;
        if count == 0 {
            // No zero-length array exists to point at.
            var nl = NullLiteralExpr::create(self.ctx, n->range, true);
            nl->type_          = ptr;
            nl->value_category = Expr::ValueCategory::RValue;
            data = static_cast::<*Expr>(nl);
        } else {
            var arr_ty = self.sc->types->array(elem, static_cast::<u64>(count));
            ICE_IF(arr_ty == &null, "ListLiteralLowering: no array canonical for a slice literal's backing");
            var il = self._init_list(n, arr_ty);
            var storage: *Expr = static_cast::<*Expr>(il);
            if n->storage == ListStorage::Extended { storage = self._backing_local(n->range, arr_ty, il); }
            data = self._cast(n->range, storage, ptr);
        }

        var len = self._cast(n->range, self.synth.int_literal(n->range, static_cast::<u64>(count), BuiltinKind::USize),
                             self.sc->builtin(BuiltinKind::USize));

        var args = self.list_builder::<*Expr>();
        args.push(data);
        args.push(len);
        return self._ctor_call(n->range, n->slice_ctor, to_string(WellKnownType::Slice), &args, slice_ty);
    }

    /// `var __kairo_tmpK: [T; N] = { ... };` ahead of the owning DeclStmt;
    /// returns the name that refers to it.
    priv fn _backing_local(self, at: SourceRange, arr_ty: *Type, il: *InitListExpr) -> *Expr {
        ICE_IF(!self._window,
            "ListLiteralLowering: an Extended slice literal outside a statement list (a for-init or a namespace-scope variable); its backing array needs a home this pass cannot give it");

        var vd = self.synth.local(at, "tmp", arr_ty, static_cast::<*Expr>(il));
        self._pending.push_back(static_cast::<*Stmt>(
            DeclStmt::create(self.ctx, at, static_cast::<*Decl>(vd))));
        return self.synth.use_of(vd, at, Expr::ValueCategory::LValue);
    }

    /// An explicit cast to the canonical \p to. EmitIR renders `static_cast`.
    priv fn _cast(self, at: SourceRange, operand: *Expr, to: *Type) -> *Expr {
        var c = TypeCastExpr::create(self.ctx, at, operand, to);
        c->type_          = to;
        c->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(c);
    }

    /// A constructor call typed \p ty. The callee names the ctor decl; EmitIR
    /// spells the type from the call's own canonical, never from this token.
    priv fn _ctor_call(self, at: SourceRange, ctor: *Decl, name: string,
                       args: *ListBuilder::<*Expr>, ty: *Type) -> *Expr {
        var callee = NamedIdentExpr::create(self.ctx, at, self.synth.ident(at, name));
        callee->resolved_decl = ctor;

        var call = CallExpr::create(self.ctx, at, static_cast::<*Expr>(callee));
        args->freeze_into(&(call->args));
        call->type_          = ty;
        call->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(call);
    }
}

__inline_cpp("
#undef ASTWriter_ListLiteralLowering
");
