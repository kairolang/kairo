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
///     No ListLiteralExpr, SetLiteralExpr or MapLiteralExpr reaches codegen,
///     poisoned ones excepted (the gate stops those). A set literal is
///     `HashSet(<its elements as a slice>)` and a map literal `HashMap(<its
///     entries as a slice of (K, V) tuples>)`, through the same backing as a
///     vector's; empty, each is the default constructor.
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
        ASTWriter::<ListLiteralLowering>::run(self.sc->tu);
    }

    // --- the one statement a backing array can precede ------------------------

    fn transform_decl_stmt(self, n: *DeclStmt) -> vec::<*Stmt> {
        var mark         = self._pending.size();
        var saved_window = self._window;
        var saved_scalar = self._scalar_slot;
        self._window      = !saved_scalar;
        self._scalar_slot = false;      // statements nested in the initializer are lists again.

        var body = ASTWriter::<ListLiteralLowering>::transform_decl_stmt(n);

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
        var out = ASTWriter::<ListLiteralLowering>::transform_list_literal_expr(n);
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

    /// `{a, b}` -> `HashSet(Slice(<array prvalue>, N))`; `{}` typed as a set
    /// -> `HashSet()`. The set's own constructor inserts in order, so a
    /// repeated element keeps its first place.
    fn transform_set_literal_expr(self, n: *SetLiteralExpr) -> *Expr {
        var out = ASTWriter::<ListLiteralLowering>::transform_set_literal_expr(n);
        if n->is_poisoned() || (n->type_ == &null) { return out; }
        var none = self.list_builder::<*Expr>();
        if self.tu.is_map_like(canon_unqual(n->type_)) { return self._hashed(n->range, n->type_, WellKnownType::HashMap, &null, &none); }   // `{}` as a map.
        var elem = self.tu.container_elem(canon_unqual(n->type_));
        ICE_IF(elem == &null, "ListLiteralLowering: a set literal whose type is not a HashSet; LiteralTyping::type_set_literal invariant violation");
        var elems = self.list_builder::<*Expr>();
        for var i: usize = 0; i < n->elements.size(); ++i { elems.push(n->elements[i]); }
        return self._hashed(n->range, n->type_, WellKnownType::HashSet, elem, &elems);
    }

    /// `{k: v, ...}` -> `HashMap(Slice(<array of (k, v) tuples>, N))`: one
    /// braced array, so the entries are evaluated in written order, key
    /// before value. `{}` typed as a map -> `HashMap()`.
    fn transform_map_literal_expr(self, n: *MapLiteralExpr) -> *Expr {
        var out = ASTWriter::<ListLiteralLowering>::transform_map_literal_expr(n);
        if n->is_poisoned() || (n->type_ == &null) { return out; }
        var kt: *Type = &null; var vt: *Type = &null;
        ICE_IF(!self.tu.map_key_value(canon_unqual(n->type_), &kt, &vt), "ListLiteralLowering: a map literal whose type is not a HashMap; LiteralTyping::type_map_literal invariant violation");
        var kv = vec::<*Type>(); kv.push_back(kt); kv.push_back(vt);
        var tt = self.tu.tuple_of(&kv);
        ICE_IF(tt == &null, "ListLiteralLowering: no Tuple2 record for a map literal's entries; LiteralTyping mints it");
        var elems = self.list_builder::<*Expr>();
        for var i: usize = 0; i < n->entries.size(); ++i {
            var en = n->entries.get(i);
            var init = NamedInitializerExpr::create(self.ctx, en->range, &null);
            var fields = self.list_builder::<InitField>();
            for var j: usize = 0; j < 2; ++j {
                var e  = (en->key) if (j == 0) else (en->value);
                var fd = self.tu.tuple_field(tt, j);
                ICE_IF(fd == &null, "ListLiteralLowering: Tuple2 record with fewer than two fields");
                var f = InitField{};
                f.name       = self.synth.ident(e->range, self.tu.decl_name(static_cast::<*Decl>(fd)));
                f.value      = e;
                f.range      = e->range;
                f.field_decl = static_cast::<*Decl>(fd);
                fields.push(f);
            }
            fields.freeze_into(&(init->fields));
            init->type_          = tt;
            init->value_category = Expr::ValueCategory::RValue;
            elems.push(static_cast::<*Expr>(init));
        }
        return self._hashed(n->range, n->type_, WellKnownType::HashMap, tt, &elems);
    }

    /// The HashSet / HashMap lang record \p ty built from \p elems: its
    /// default constructor when there are none, else its one-slice
    /// constructor over a full-expression backing array, as a vector's.
    priv fn _hashed(self, at: SourceRange, ty: *Type, k: WellKnownType, elem: *Type, elems: *ListBuilder::<*Expr>) -> *Expr {
        var args = self.list_builder::<*Expr>();
        var ctor: *Decl = &null;
        if elems->size() == 0 {
            ctor = self.tu.lang_ctor(k, 0, false);
        } else {
            ctor = self.tu.lang_ctor(k, 1, true);
            var st = self.tu.slice_of(elem);
            ICE_IF(st == &null, "ListLiteralLowering: the Slice lang item is unbound under a set or map literal");
            var lit = ListLiteralExpr::create(self.ctx, at);
            elems->freeze_into(&(lit->elements));
            lit->type_          = st;
            lit->value_category = Expr::ValueCategory::RValue;
            lit->storage        = ListStorage::FullExpr;
            lit->slice_ctor     = self.tu.lang_ctor(WellKnownType::Slice, 2, false);
            ICE_IF(lit->slice_ctor == &null, "ListLiteralLowering: Slice has no (data, len) constructor");
            args.push(self._slice(lit, st, elem));
        }
        ICE_IF(ctor == &null, f"ListLiteralLowering: {to_string(k)} has no constructor for a literal (Lib/builtin declares `()` and one taking a slice)");
        return self._ctor_call(at, ctor, to_string(k), &args, ty);
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

    /// A constructor call typed \p ty: LowerSynth's, so its post-
    /// SequenceLowering order check sees it. `Slice(data, len)` has at most
    /// one operand with an effect (data; len is a literal), a Vector's one
    /// argument is the Slice, so the check never fires here.
    priv fn _ctor_call(self, at: SourceRange, ctor: *Decl, name: string,
                       args: *ListBuilder::<*Expr>, ty: *Type) -> *Expr {
        return self.synth.ctor_call(at, ctor, name, args, ty);
    }
}
