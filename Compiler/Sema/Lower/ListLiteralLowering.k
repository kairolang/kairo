/// --- The Kairo Project ------------- Sema/Lower/ListLiteralLowering.k --- ///
///
///   \brief Render every list literal as ExprTyper decided to build it.
///
///   \detail
///     ExprTyper typed the literal as its target, bound the constructors
///     and chose where a slice's backing array lives. This pass decides
///     nothing:
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
///     DeclStmt: ExprTyper marks a slice literal Extended only where it
///     directly initializes a `var`. Inner backings splice first. A for-init
///     variable and a namespace-scope variable have no statement list to
///     splice into and ICE by name.
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Kind::ExprKind::to_string
import AST::LangItems::{
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
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Expressions::{
    InitField,            InitListExpr,   ListLiteralExpr, ListStorage, MapLiteralExpr,
    NamedInitializerExpr, SetLiteralExpr, TypeCastExpr,
}
import AST::Node::PrimaryExpressions::NullLiteralExpr
import AST::Node::Statements::{
    CompoundStmt,
    DeclStmt,
    IndexedForStmt,
}
import AST::Node::Types::FixedArrayType
import AST::Visitor::ASTWriter::{
    ASTWriter,
    ListBuilder,
}
import Location::SourceRange::SourceRange
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil

pub class ListLiteralLowering derives ASTWriter<ListLiteralLowering> {
    pub var  sc: unsafe *SemaContext
    priv var tu: TypeUtil

    /// Backing declarations minted under the DeclStmt being rewritten, in the
    /// order they must run. Drained by the DeclStmt that opened the window.
    priv var _pending: cxx::std::vector<unsafe *Stmt>

    /// True while a DeclStmt that sits in a statement LIST is being rewritten.
    priv var _window: bool = false

    /// True while a for-init is being rewritten: a scalar slot, nothing splices.
    priv var _scalar_slot: bool = false

    priv var synth: LowerSynth

    fn ListLiteralLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.tu    = TypeUtil(sc)
        self.synth = LowerSynth(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        if self.sc->tu == &null {
            return
        }

        ASTWriter<ListLiteralLowering>::run(self, self.sc->tu)
    }

    /// # the one statement a backing array can precede

    fn transform_decl_stmt(self, n: unsafe *DeclStmt) -> cxx::std::vector<unsafe *Stmt> {
        var mark         = self._pending.size()
        var saved_window = self._window
        var saved_scalar = self._scalar_slot
        self._window      = !saved_scalar
        self._scalar_slot = false         // statements nested in the initializer are lists again.

        var body = ASTWriter<ListLiteralLowering>::transform_decl_stmt(self, n)

        self._window      = saved_window
        self._scalar_slot = saved_scalar

        var out = cxx::std::vector<unsafe *Stmt>()
        for var i: usize = mark; i < self._pending.size(); ++i {
            out.push_back(self._pending[i])
        }

        for var i: usize = 0; i < body.size(); ++i {
            out.push_back(body[i])
        }

        while self._pending.size() > mark {
            self._pending.pop_back()
        }

        return out
    }

    /// The base body, with the init marked as the scalar slot it is.
    fn transform_indexed_for_stmt(self,
                                  n: unsafe *IndexedForStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->init != &null {
            var saved = self._scalar_slot
            self._scalar_slot = true
            n->init           = self.transform_stmt_scalar(n->init)
            self._scalar_slot = saved
        }

        if n->cond != &null {
            n->cond = self.transform_expr(n->cond)
        }

        if n->update != &null {
            n->update = self.transform_expr(n->update)
        }

        n->body = cast<CompoundStmt>(self.transform_stmt_scalar(n->body))
        return self._one_stmt(n)
    }

    /// # the rewrite

    fn transform_list_literal_expr(self, n: unsafe *ListLiteralExpr) -> unsafe *Expr {
        // Children first: nested literals are already lowered, and an inner
        // Extended backing is already pending ahead of this one.
        var unsafe *out = ASTWriter<ListLiteralLowering>::transform_list_literal_expr(self, n)
        if n->is_poisoned() || n->type_ == &null {
            return out
        }

        var unsafe *c = canon_unqual(n->type_)
        if c == &null {
            return out
        }

        if isa<FixedArrayType>(c) {
            return self._init_list(n, c)
        }

        var unsafe *elem = self.tu.container_elem(c)
        if elem == &null {
            kairo::std::ice_fail(
                "ListLiteralLowering: container target with no element type; LiteralTyping invariant violation",
            )
        }

        if self.tu.is_slice(c) {
            return self._slice(n, c, elem)
        }

        if !self.tu.is_vector_like(c) {
            kairo::std::ice_fail(
                "ListLiteralLowering: list literal is not an array, a slice or a vector; LiteralTyping invariant violation",
            )
        }

        if n->owner_ctor == &null {
            kairo::std::ice_fail(
                "ListLiteralLowering: vector literal with no constructor bound; LiteralTyping must bind it",
            )
        }

        var args = self.list_builder<unsafe *Expr>()
        if n->elements.size() > 0 {
            var unsafe *st = self.tu.slice_of(elem)
            if st == &null {
                kairo::std::ice_fail(
                    "ListLiteralLowering: the Slice lang item is unbound under a vector literal",
                )
            }

            // A vector copies out before the statement ends: always a temporary.
            n->storage = ListStorage::FullExpr
            args.push(self._slice(n, st, elem))
        }

        return self._ctor_call(
            n->range,
            n->owner_ctor,
            to_string(WellKnownType::Vector),
            unsafe &args,
            n->type_,
        )
    }

    /// `{a, b}` -> `HashSet(Slice(<array prvalue>, N))`; `{}` typed as a set
    /// -> `HashSet()`. The set's own constructor inserts in order, so a
    /// repeated element keeps its first place.
    fn transform_set_literal_expr(self, n: unsafe *SetLiteralExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<ListLiteralLowering>::transform_set_literal_expr(self, n)
        if n->is_poisoned() || n->type_ == &null {
            return out
        }

        var none = self.list_builder<unsafe *Expr>()
        if self.tu.is_map_like(canon_unqual(n->type_)) { // `{}` as a map.
            return self._hashed(n->range, n->type_, WellKnownType::HashMap, &null, &none)
        }

        var unsafe *elem = self.tu.container_elem(canon_unqual(n->type_))
        if elem == &null {
            kairo::std::ice_fail(
                "ListLiteralLowering: a set literal whose type is not a HashSet; LiteralTyping::type_set_literal invariant violation",
            )
        }

        var elems = self.list_builder<unsafe *Expr>()
        for var i: usize = 0; i < n->elements.size(); ++i {
            elems.push(n->elements[i])
        }

        return self._hashed(n->range, n->type_, WellKnownType::HashSet, elem, &elems)
    }

    /// `{k: v, ...}` -> `HashMap(Slice(<array of (k, v) tuples>, N))`: one
    /// braced array, so the entries are evaluated in written order, key
    /// before value. `{}` typed as a map -> `HashMap()`.
    fn transform_map_literal_expr(self, n: unsafe *MapLiteralExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<ListLiteralLowering>::transform_map_literal_expr(self, n)
        if n->is_poisoned() || n->type_ == &null {
            return out
        }

        var kt: unsafe *Type = &null
        var vt: unsafe *Type = &null
        if !self.tu.map_key_value(canon_unqual(n->type_), unsafe &kt, unsafe &vt) {
            kairo::std::ice_fail(
                "ListLiteralLowering: a map literal whose type is not a HashMap; LiteralTyping::type_map_literal invariant violation",
            )
        }

        var kv = cxx::std::vector<unsafe *Type>()
        kv.push_back(kt)
        kv.push_back(vt)
        var unsafe *tt = self.tu.tuple_of(unsafe &kv)
        if tt == &null {
            kairo::std::ice_fail(
                "ListLiteralLowering: no Tuple2 record for a map literal's entries; LiteralTyping mints it",
            )
        }

        var elems = self.list_builder<unsafe *Expr>()
        for var i: usize = 0; i < n->entries.size(); ++i {
            var unsafe *en    = n->entries.get(i)
            var unsafe *init  = NamedInitializerExpr::create(self.ctx, en->range, &null)
            var        fields = self.list_builder<InitField>()
            for var j: usize = 0; j < 2; ++j {
                var unsafe *e  = if (j == 0) => (en->key) else => en->value
                var unsafe *fd = self.tu.tuple_field(tt, j)
                if fd == &null {
                    kairo::std::ice_fail(
                        "ListLiteralLowering: Tuple2 record with fewer than two fields",
                    )
                }

                var f = InitField{}
                f.name = self.synth.ident(e->range, self.tu.decl_name(unsafe (fd as unsafe *Decl)))
                f.value      = e
                f.range      = e->range
                f.field_decl = unsafe (fd as unsafe *Decl)
                fields.push(f)
            }

            fields.freeze_into(&init->fields)
            init->type_          = tt
            init->value_category = Expr::ValueCategory::RValue
            elems.push(init)
        }

        return self._hashed(n->range, n->type_, WellKnownType::HashMap, tt, &elems)
    }

    /// The HashSet / HashMap lang record \p ty built from \p elems: its
    /// default constructor when there are none, else its one-slice
    /// constructor over a full-expression backing array, as a vector's.
    priv fn _hashed(self,
                    at:    SourceRange,
                    ty:    unsafe *Type,
                    k:     WellKnownType,
                    elem:  unsafe *Type,
                    elems: *ListBuilder<unsafe *Expr>) -> unsafe *Expr {
        var args               = self.list_builder<unsafe *Expr>()
        var ctor: unsafe *Decl = &null
        if elems->size() == 0 {
            ctor = self.tu.lang_ctor(k, 0, false)
        } else {
            ctor = self.tu.lang_ctor(k, 1, true)
            var unsafe *st = self.tu.slice_of(elem)
            if st == &null {
                kairo::std::ice_fail(
                    "ListLiteralLowering: the Slice lang item is unbound under a set or map literal",
                )
            }

            var unsafe *lit = ListLiteralExpr::create(self.ctx, at)
            elems->freeze_into(&lit->elements)
            lit->type_          = st
            lit->value_category = Expr::ValueCategory::RValue
            lit->storage        = ListStorage::FullExpr
            lit->slice_ctor     = self.tu.lang_ctor(WellKnownType::Slice, 2, false)
            if lit->slice_ctor == &null {
                kairo::std::ice_fail("ListLiteralLowering: Slice has no (data, len) constructor")
            }

            args.push(self._slice(lit, st, elem))
        }

        if ctor == &null {
            kairo::std::ice_fail(
                f"ListLiteralLowering: {to_string(k)} has no constructor for a literal (Lib/builtin declares `()` and one taking a slice)",
            )
        }

        return self._ctor_call(at, ctor, to_string(k), unsafe &args, ty)
    }

    /// # pieces

    /// The literal's elements as a braced-init-list typed \p arr_ty. The list
    /// is shared, not copied: the literal node is dropped from the tree.
    priv fn _init_list(self,
                       n:      unsafe *ListLiteralExpr,
                       arr_ty: unsafe *Type) -> unsafe *InitListExpr {
        var unsafe *il = InitListExpr::create(self.ctx, n->range)
        il->elements = n->elements
        il->adopt_sema(n)
        il->type_          = arr_ty
        il->value_category = Expr::ValueCategory::RValue
        return il
    }

    /// `Slice(data, len)` typed \p slice_ty, over the storage X chose.
    priv fn _slice(self,
                   n:        unsafe *ListLiteralExpr,
                   slice_ty: unsafe *Type,
                   elem:     unsafe *Type) -> unsafe *Expr {
        if n->slice_ctor == &null {
            kairo::std::ice_fail(
                "ListLiteralLowering: slice literal with no constructor bound; LiteralTyping must bind it",
            )
        }

        var        count = n->elements.size()
        var unsafe *ptr  = self.sc->types->pointer(elem)

        var data: unsafe *Expr = &null
        if count == 0 {
            // No zero-length array exists to point at.
            var unsafe *nl = NullLiteralExpr::create(self.ctx, n->range, true)
            nl->type_          = ptr
            nl->value_category = Expr::ValueCategory::RValue
            data               = nl
        } else {
            var unsafe *arr_ty = self.sc->types->array(elem, count as u64)
            if arr_ty == &null {
                kairo::std::ice_fail(
                    "ListLiteralLowering: no array canonical for a slice literal's backing",
                )
            }

            var unsafe *il                   = self._init_list(n, arr_ty)
            var        storage: unsafe *Expr = unsafe (il as unsafe *Expr)
            if n->storage == ListStorage::Extended {
                storage = self._backing_local(n->range, arr_ty, il)
            }

            data = self._cast(n->range, storage, ptr)
        }

        var unsafe *len = self._cast(
            n->range,
            self.synth.int_literal(n->range, count as u64, BuiltinKind::USize),
            self.sc->builtin(BuiltinKind::USize),
        )

        var args = self.list_builder<unsafe *Expr>()
        args.push(data)
        args.push(len)
        return self._ctor_call(
            n->range,
            n->slice_ctor,
            to_string(WellKnownType::Slice),
            unsafe &args,
            slice_ty,
        )
    }

    /// `var __kairo_tmpK: [T; N] = { ... };` ahead of the owning DeclStmt;
    /// returns the name that refers to it.
    priv fn _backing_local(self,
                           at:     SourceRange,
                           arr_ty: unsafe *Type,
                           il:     unsafe *InitListExpr) -> unsafe *Expr {
        if !self._window {
            kairo::std::ice_fail(
                "ListLiteralLowering: an Extended slice literal outside a statement list (a for-init or a namespace-scope variable); its backing array needs a home this pass cannot give it",
            )
        }

        var unsafe *vd = self.synth.local(at, "tmp", arr_ty, unsafe (il as unsafe *Expr))
        self._pending.push_back(
            unsafe (DeclStmt::create(self.ctx, at, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
        )

        return self.synth.use_of(vd, at, Expr::ValueCategory::LValue)
    }

    /// An explicit cast to the canonical \p to. EmitIR renders `static_cast`.
    priv fn _cast(self, at: SourceRange, operand: unsafe *Expr, to: unsafe *Type) -> unsafe *Expr {
        var unsafe *c = TypeCastExpr::create(self.ctx, at, operand, to)
        c->type_          = to
        c->value_category = Expr::ValueCategory::RValue
        return c
    }

    /// A constructor call typed \p ty: LowerSynth's, so its post-
    /// SequenceLowering order check sees it. `Slice(data, len)` has at most
    /// one operand with an effect (data; len is a literal), a Vector's one
    /// argument is the Slice, so the check never fires here.
    priv fn _ctor_call(self,
                       at:         SourceRange,
                       ctor:       unsafe *Decl,
                       const name: string,
                       args:       unsafe *ListBuilder<unsafe *Expr>,
                       ty:         unsafe *Type) -> unsafe *Expr {
        return self.synth.ctor_call(at, ctor, name, &*args, ty)
    }
}
