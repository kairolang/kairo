/// --- The Kairo Project ---------------------- AST/Visitor/ASTWriter.k --- ///
///
///   \brief A node-rewriting AST transformer for the Kairo AST.
///
///   Where RecursiveASTVisitor (RAV) handles read-only walks and 1:1
///   same-type rewrites, ASTWriter handles structural rewrites:
///   node-count-changing edits (delete, splice, expand), cross-family
///   conversions at a single parent slot, and full list rebuilds.
///
///   Layer contract (per node N of family F):
///     transform_F(*F)    - switch on kind, route to transform_N. (generated)
///                            STMT/DECL return vec<*F> (splice). EXPR/TYPE/
///                            PATTERN return *F (scalar; null = delete).
///     transform_N(...)   - hand-written body. recurse into children via
///                            transform_F / rebuild helpers; return the
///                            (possibly rewritten) node(s).
///
///   Return-type rule:
///     EXPR / TYPE / PATTERN : scalar *F out. These never occupy a list
///                             position that admits splice. A different node
///                             of the same family is a 1:1 rewrite. null is
///                             deletion (only legal where the parent slot is
///                             nullable, or inside a rebuild_*_list filter).
///     STMT / DECL           : vec<*F> out. A statement or declaration can
///                             legitimately become zero, one, or many nodes
///                             in its enclosing list. Empty vec = deletion.
///
///   Cross-family rewrites (expr->type, type->expr, ...) do NOT happen through
///   the dispatch machinery: every parent field is statically typed to one
///   family, so a *Type can never land in a *Expr slot. Such conversions are
///   pass-author helper methods, invoked INSIDE a same-family transform_N
///   that moves data between fields of differing family on the SAME parent
///   node (see the SizeOf/TypeExpr lowering passes for the canonical shape).
///
///   List management is owned by this class, never the pass. Pass authors
///   use:
///     list_builder<T>()        - construct a fresh FrozenList from scratch.
///     rewriter(*FrozenList<T>) - deferred replace/remove/insert on an
///                                 existing list, applied in one rebuild.
///     rebuild_*_list(...)      - map every element through its transform_F.
///   No pass ever touches ArenaList, set_allocator, or from_list directly.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::Expressions::*;
import AST::Node::Patterns::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Types::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import Memory::ArenaList::*;
import AST::Context::TranslationUnit::*;
import AST::Node::Program::*;

// ===========================================================================
//  List infrastructure
// ===========================================================================

///
/// \class ListBuilder<T>
/// \brief Accumulates elements and freezes them into a FrozenList<T>.
///
/// Used when a transform constructs a NEW node whose list children are built
/// from scratch (e.g. lowering a tuple expr's N elements into N type nodes).
/// Owns the arena plumbing so the pass never sees ArenaList directly.
///
class <T> ListBuilder {
    priv var _buf:   ArenaList::<T>;
    priv var _arena: *ArenaAllocator;

    fn ListBuilder(self, ctx: *ASTContext) {
        self._arena = &(ctx->nodes);
        self._buf.set_allocator(self._arena);
    }

    fn push(self, item: T) {
        self._buf.push(item);
    }

    fn size(self) -> usize {
        return self._buf.size();
    }

    fn is_empty(self) -> bool {
        return self._buf.size() == 0;
    }

    /// Freezes the accumulated elements into \p target, overwriting it.
    fn freeze_into(self, target: *FrozenList::<T>) {
        target->from_list(&(self._buf), self._arena);
    }
}

///
/// \class ListRewriter<T>
/// \brief Records replace/remove/insert ops against an existing FrozenList<T>
///        and applies them all in a single rebuild.
///
/// All indices refer to the ORIGINAL list. Ops are order-independent: an
/// insert_before(7) and a remove(3) recorded in either order produce the same
/// result. apply() rebuilds once; the old backing array is abandoned to the
/// arena (reclaimed in bulk).
///
class <T> ListRewriter {
    enum OpKind derives u8 {
        Replace,       ///< original element at index swapped for a new node.
        Remove,        ///< original element at index dropped.
        InsertBefore,  ///< new element emitted just before this index.
    }

    struct Op {
        var kind:  OpKind;
        var index: usize;  ///< original-list index this op targets.
        var item:  T;      ///< replacement / inserted node (unused for Remove).
    }

    priv var _source: *FrozenList::<T>;
    priv var _ops:    vec::<Op>;
    priv var _arena:  *ArenaAllocator;
    priv var _dirty:  bool = false;

    fn ListRewriter(self, source: *FrozenList::<T>, ctx: *ASTContext) {
        self._source = source;
        self._arena  = &(ctx->nodes);
    }

    /// Swap the element at \p index for \p item.
    fn replace(self, index: usize, item: T) {
        var opr = Op{};
        opr.kind  = OpKind::Replace;
        opr.index = index;
        opr.item  = item;
        self._ops.push_back(opr);
        self._dirty = true;
    }

    /// Drop the element at \p index.
    fn remove(self, index: usize) {
        var opr = Op{};
        opr.kind  = OpKind::Remove;
        opr.index = index;
        self._ops.push_back(opr);
        self._dirty = true;
    }

    /// Emit \p item immediately before the element at \p index. An index equal
    /// to the list size appends; multiple inserts at the same index preserve
    /// call order.
    fn insert_before(self, index: usize, item: T) {
        var opr = Op{};
        opr.kind  = OpKind::InsertBefore;
        opr.index = index;
        opr.item  = item;
        self._ops.push_back(opr);
        self._dirty = true;
    }

    /// Emit \p item immediately after the element at \p index.
    fn insert_after(self, index: usize, item: T) {
        self.insert_before(index + 1, item);
    }

    /// Append \p item after the last element.
    fn append(self, item: T) {
        self.insert_before(self._source->size(), item);
    }

    fn has_changes(self) -> bool {
        return self._dirty;
    }

    /// Discard the whole source list and install \p items in its place.
    /// Clears any previously recorded ops.
    fn replace_all(self, items: *vec::<T>) {
        var buf = ArenaList::<T>();
        buf.set_allocator(self._arena);
        for var i: usize = 0; i < items->size(); i++ {
            buf.push((*items)[i]);
        }
        self._source->from_list(&buf, self._arena);
        self._ops.clear();
        self._dirty = false;
    }

    /// Rebuild the source list with every recorded op applied. No-op if
    /// nothing was recorded (the original FrozenList is left untouched, so
    /// passes that inspect-but-don't-edit pay nothing).
    fn apply(self) {
        if !self._dirty { return; }

        var buf = ArenaList::<T>();
        buf.set_allocator(self._arena);

        for var i: usize = 0; i < self._source->size(); i++ {
            // InsertBefore ops targeting this slot fire first, in record order.
            for var j: usize = 0; j < self._ops.size(); j++ {
                if (self._ops[j].kind == OpKind::InsertBefore)
                && (self._ops[j].index == i) {
                    buf.push(self._ops[j].item);
                }
            }

            // Resolve remove/replace for this slot. First matching op wins;
            // Remove dominates Replace if both somehow target the same index.
            var removed  = false;
            var replaced = false;
            var replacement: T;

            for var j: usize = 0; j < self._ops.size(); j++ {
                if self._ops[j].index != i { continue; }
                if self._ops[j].kind == OpKind::Remove {
                    removed = true;
                    break;
                }
                if self._ops[j].kind == OpKind::Replace {
                    replaced    = true;
                    replacement = self._ops[j].item;
                    break;
                }
            }

            if removed { continue; }
            if replaced {
                buf.push(replacement);
            } else {
                buf.push(*(self._source->get(i)));
            }
        }

        // Trailing inserts: any InsertBefore at index >= size is an append.
        for var j: usize = 0; j < self._ops.size(); j++ {
            if (self._ops[j].kind == OpKind::InsertBefore)
            && (self._ops[j].index >= self._source->size()) {
                buf.push(self._ops[j].item);
            }
        }

        self._source->from_list(&buf, self._arena);
        self._ops.clear();
        self._dirty = false;
    }
}

// ===========================================================================
//  ASTWriter
// ===========================================================================

class <D> ASTWriter {
    pub var ctx:  *ASTContext;
    pub var stop: bool = false;

    fn dyn(self) -> *D {
        return static_cast::<*D>(&self);
    }

    // == Pass-facing list helpers ==========================================

    fn <T> list_builder(self) -> ListBuilder::<T> {
        return ListBuilder::<T>(self.ctx);
    }

    fn <T> rewriter(self, list: *FrozenList::<T>) -> ListRewriter::<T> {
        return ListRewriter::<T>(list, self.ctx);
    }

    //- Default list rebuilds: map each element through its transform_F. ---
    // STMT/DECL versions splice (transform returns vec); EXPR/TYPE/PATTERN
    // versions are scalar with null-drop (transform returns *F, null deletes).

    fn rebuild_stmt_list(self, old: *FrozenList::<*Stmt>) {
        var buf = ArenaList::<*Stmt>();
        buf.set_allocator(&(self.ctx->nodes));
        for var i: usize = 0; i < old->size(); i++ {
            if self.stop { buf.push(*(old->get(i))); continue; }
            var results = self.dyn()->transform_stmt(*(old->get(i)));
            for var j: usize = 0; j < results.size(); j++ {
                buf.push(results[j]);
            }
        }
        old->from_list(&buf, &(self.ctx->nodes));
    }

    fn rebuild_decl_list(self, old: *FrozenList::<*Decl>) {
        var buf = ArenaList::<*Decl>();
        buf.set_allocator(&(self.ctx->nodes));
        for var i: usize = 0; i < old->size(); i++ {
            if self.stop { buf.push(*(old->get(i))); continue; }
            var results = self.dyn()->transform_decl(*(old->get(i)));
            for var j: usize = 0; j < results.size(); j++ {
                buf.push(results[j]);
            }
        }
        old->from_list(&buf, &(self.ctx->nodes));
    }

    fn rebuild_expr_list(self, old: *FrozenList::<*Expr>) {
        var buf = ArenaList::<*Expr>();
        buf.set_allocator(&(self.ctx->nodes));
        for var i: usize = 0; i < old->size(); i++ {
            if self.stop { buf.push(*(old->get(i))); continue; }
            var r = self.dyn()->transform_expr(*(old->get(i)));
            if r != &null { buf.push(r); }
        }
        old->from_list(&buf, &(self.ctx->nodes));
    }

    fn rebuild_type_list(self, old: *FrozenList::<*Type>) {
        var buf = ArenaList::<*Type>();
        buf.set_allocator(&(self.ctx->nodes));
        for var i: usize = 0; i < old->size(); i++ {
            if self.stop { buf.push(*(old->get(i))); continue; }
            var r = self.dyn()->transform_type(*(old->get(i)));
            if r != &null { buf.push(r); }
        }
        old->from_list(&buf, &(self.ctx->nodes));
    }

    fn rebuild_pattern_list(self, old: *FrozenList::<*Pattern>) {
        var buf = ArenaList::<*Pattern>();
        buf.set_allocator(&(self.ctx->nodes));
        for var i: usize = 0; i < old->size(); i++ {
            if self.stop { buf.push(*(old->get(i))); continue; }
            var r = self.dyn()->transform_pattern(*(old->get(i)));
            if r != &null { buf.push(r); }
        }
        old->from_list(&buf, &(self.ctx->nodes));
    }

    /// DeclContext::dc_decls is a live ArenaList, not a FrozenList. Rebuild it
    /// in place, splicing transform_decl results.
    fn rebuild_dc_decls(self, dc: *DeclContext) {
        var buf = ArenaList::<*Decl>();
        buf.set_allocator(&(self.ctx->nodes));
        for var i: usize = 0; i < dc->dc_decls.size(); i++ {
            var d = *(dc->dc_decls.get(i));
            if d == &null { continue; }
            if self.stop { buf.push(d); continue; }
            var results = self.dyn()->transform_decl(d);
            for var j: usize = 0; j < results.size(); j++ {
                buf.push(results[j]);
            }
        }
        dc->dc_decls = buf;
    }

    //- Scalar-position wrappers ------------------------------------------
    // A stmt/decl in a SCALAR slot (e.g. IndexedForStmt::init, DeclStmt::decl)
    // still routes through the vec-returning transform; these take the first
    // result and drop the rest. A splice in a non-list slot is a pass bug;
    // assert guards it.

    fn transform_stmt_scalar(self, s: *Stmt) -> *Stmt {
        if s == &null { return &null; }
        var results = self.dyn()->transform_stmt(s);
        if results.size() == 0 { return &null; }
        std::ICE(results.size() == 1,
                 "transform produced multiple stmts in a scalar slot");
        return results[0];
    }

    fn transform_decl_scalar(self, d: *Decl) -> *Decl {
        if d == &null { return &null; }
        var results = self.dyn()->transform_decl(d);
        if results.size() == 0 { return &null; }
        std::ICE(results.size() == 1,
                 "transform produced multiple decls in a scalar slot");
        return results[0];
    }

    //- single-element vec helpers (kept terse; used pervasively below) ----
    fn _one_stmt(self, s: *Stmt) -> vec::<*Stmt> {
        var v = vec::<*Stmt>();
        v.push_back(s);
        return v;
    }

    fn _one_decl(self, d: *Decl) -> vec::<*Decl> {
        var v = vec::<*Decl>();
        v.push_back(d);
        return v;
    }

    // == Shared compound-struct child walkers ==============================
    // These mirror RAV's helpers but rebuild rather than discard.

    fn transform_match_case(self, mc: *MatchCase) {
        self.dyn()->rebuild_pattern_list(&(mc->patterns));
        if mc->guard != &null {
            mc->guard = self.dyn()->transform_expr(mc->guard);
        }
        if mc->body != &null {
            mc->body = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(static_cast::<*Stmt>(mc->body)));
        }
        if mc->expression != &null {
            mc->expression = self.dyn()->transform_expr(mc->expression);
        }
    }

    fn transform_inherit_edge(self, e: *InheritEdge) {
        if e->base != &null {
            e->base = self.dyn()->transform_type(e->base);
        }
    }

    fn transform_generic_arg(self, a: *ChainType::GenericArg) {
        if a->ty != &null {
            a->ty = self.dyn()->transform_type(a->ty);
        }
    }

    // ===========================================================================
    //  TYPE FAMILY  (scalar return: *Type; null = delete)
    // ===========================================================================

    fn transform_type(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        if self.stop  { return t; }

        switch t->kind {
            case TypeKind::MapType               { return self.dyn()->transform_map_type(                 cast::<MapType>(t)               ); }
            case TypeKind::SetType               { return self.dyn()->transform_set_type(                 cast::<SetType>(t)               ); }
            case TypeKind::SelfType              { return self.dyn()->transform_self_type(                cast::<SelfType>(t)              ); }
            case TypeKind::TypeExpr              { return self.dyn()->transform_type_expr(                cast::<TypeExpr>(t)              ); }
            case TypeKind::TupleType             { return self.dyn()->transform_tuple_type(               cast::<TupleType>(t)             ); }
            case TypeKind::ChainType             { return self.dyn()->transform_chain_type(               cast::<ChainType>(t)             ); }
            case TypeKind::VectorType            { return self.dyn()->transform_vector_type(              cast::<VectorType>(t)            ); }
            case TypeKind::PointerType           { return self.dyn()->transform_pointer_type(             cast::<PointerType>(t)           ); }
            case TypeKind::TypeOfType            { return self.dyn()->transform_type_of_type(             cast::<TypeOfType>(t)            ); }
            case TypeKind::InferredType          { return self.dyn()->transform_inferred_type(            cast::<InferredType>(t)          ); }
            case TypeKind::NullableType          { return self.dyn()->transform_nullable_type(            cast::<NullableType>(t)          ); }
            case TypeKind::OpaqueFFIType         { return self.dyn()->transform_opaque_ffi_type(          cast::<OpaqueFFIType>(t)         ); }
            case TypeKind::FixedArrayType        { return self.dyn()->transform_fixed_array_type(         cast::<FixedArrayType>(t)        ); }
            case TypeKind::VariadicPackType      { return self.dyn()->transform_variadic_pack_type(       cast::<VariadicPackType>(t)      ); }
            case TypeKind::GenericParamType      { return self.dyn()->transform_generic_param_type(       cast::<GenericParamType>(t)      ); }
            case TypeKind::PackExpansionType     { return self.dyn()->transform_pack_expansion_type(      cast::<PackExpansionType>(t)     ); }
            case TypeKind::CXXLValueRefType      { return self.dyn()->transform_cxxl_value_ref_type(      cast::<CXXLValueRefType>(t)      ); }
            case TypeKind::CXXRValueRefType      { return self.dyn()->transform_cxxr_value_ref_type(      cast::<CXXRValueRefType>(t)      ); }
            case TypeKind::FunctionPointerType   { return self.dyn()->transform_function_pointer_type(    cast::<FunctionPointerType>(t)   ); }
            case TypeKind::SubstGenericParamType { return self.dyn()->transform_subst_generic_param_type( cast::<SubstGenericParamType>(t) ); }
            case TypeKind::RecoveryType          { return t; }
            case TypeKind::TypeKindCount         {  std::ICE("TypeKindCount reached ASTWriter - bug"); return &null; }
        }
        return t;
    }

    //- transform bodies (default: recurse children, return node) ---------
    fn transform_map_type(self, n: *MapType) -> *Type {
        n->key   = self.dyn()->transform_type(n->key);
        n->value = self.dyn()->transform_type(n->value);
        return n;
    }

    fn transform_set_type(self, n: *SetType) -> *Type {
        n->element = self.dyn()->transform_type(n->element);
        return n;
    }

    fn transform_self_type(self, n: *SelfType) -> *Type {
        return n;
    }

    fn transform_type_expr(self, n: *TypeExpr) -> *Type {
        // n->expr is an *Expr child. A pass that lowers a type-level expression
        // to a concrete type rewrites HERE: it may inspect n->expr and return a
        // different *Type entirely (cross-family: the *Expr is consumed, a
        // *Type is produced). Default keeps the wrapper, transforms the child.
        if n->expr != &null {
            n->expr = self.dyn()->transform_expr(n->expr);
        }
        return n;
    }

    fn transform_tuple_type(self, n: *TupleType) -> *Type {
        self.dyn()->rebuild_type_list(&(n->elements));
        return n;
    }

    fn transform_chain_type(self, n: *ChainType) -> *Type {
        for var i: usize = 0; i < n->segments.size(); i++ {
            if self.stop { break; }
            var seg = n->segments.get(i);
            for var j: usize = 0; j < seg->generic_args.size(); j++ {
                if self.stop { break; }
                self.dyn()->transform_generic_arg(seg->generic_args.get(j));
            }
        }
        return n;
    }

    fn transform_vector_type(self, n: *VectorType) -> *Type {
        n->element = self.dyn()->transform_type(n->element);
        return n;
    }

    fn transform_pointer_type(self, n: *PointerType) -> *Type {
        n->pointee = self.dyn()->transform_type(n->pointee);
        return n;
    }

    fn transform_type_of_type(self, n: *TypeOfType) -> *Type {
        if n->expr != &null {
            n->expr = self.dyn()->transform_expr(n->expr);
        }
        return n;
    }

    fn transform_inferred_type(self, n: *InferredType) -> *Type {
        return n;
    }

    fn transform_nullable_type(self, n: *NullableType) -> *Type {
        n->inner = self.dyn()->transform_type(n->inner);
        return n;
    }

    fn transform_opaque_ffi_type(self, n: *OpaqueFFIType) -> *Type {
        return n;
    }

    fn transform_fixed_array_type(self, n: *FixedArrayType) -> *Type {
        n->element = self.dyn()->transform_type(n->element);
        if n->size_expr != &null {
            n->size_expr = self.dyn()->transform_expr(n->size_expr);
        }
        return n;
    }

    fn transform_variadic_pack_type(self, n: *VariadicPackType) -> *Type {
        return n; // param is a decl back-ref, not a child.
    }

    fn transform_generic_param_type(self, n: *GenericParamType) -> *Type {
        return n; // param_name is a decl back-ref.
    }

    fn transform_pack_expansion_type(self, n: *PackExpansionType) -> *Type {
        n->pattern = self.dyn()->transform_type(n->pattern);
        return n;
    }

    fn transform_cxxl_value_ref_type(self, n: *CXXLValueRefType) -> *Type {
        n->referee = self.dyn()->transform_type(n->referee);
        return n;
    }

    fn transform_cxxr_value_ref_type(self, n: *CXXRValueRefType) -> *Type {
        n->referee = self.dyn()->transform_type(n->referee);
        return n;
    }

    fn transform_function_pointer_type(self, n: *FunctionPointerType) -> *Type {
        self.dyn()->rebuild_type_list(&(n->params));
        if n->return_type != &null {
            n->return_type = self.dyn()->transform_type(n->return_type);
        }
        return n;
    }

    fn transform_subst_generic_param_type(self, n: *SubstGenericParamType) -> *Type {
        n->replacement = self.dyn()->transform_type(n->replacement);
        return n;
    }

    // ===========================================================================
    //  EXPR FAMILY  (scalar return: *Expr; null = delete)
    // ===========================================================================

    fn transform_expr(self, e: *Expr) -> *Expr {
        if e == &null { return &null; }
        if self.stop  { return e; }

        switch e->kind {
            case ExprKind::IntegerLiteralExpr       { return self.dyn()->transform_integer_literal_expr(       cast::<IntegerLiteralExpr>(e)       ); }
            case ExprKind::FloatingLiteralExpr      { return self.dyn()->transform_floating_literal_expr(      cast::<FloatingLiteralExpr>(e)      ); }
            case ExprKind::StringLiteralExpr        { return self.dyn()->transform_string_literal_expr(        cast::<StringLiteralExpr>(e)        ); }
            case ExprKind::CharacterLiteralExpr     { return self.dyn()->transform_character_literal_expr(     cast::<CharacterLiteralExpr>(e)     ); }
            case ExprKind::BooleanLiteralExpr       { return self.dyn()->transform_boolean_literal_expr(       cast::<BooleanLiteralExpr>(e)       ); }
            case ExprKind::NullLiteralExpr          { return self.dyn()->transform_null_literal_expr(          cast::<NullLiteralExpr>(e)          ); }
            case ExprKind::ListLiteralExpr          { return self.dyn()->transform_list_literal_expr(          cast::<ListLiteralExpr>(e)          ); }
            case ExprKind::TupleLiteralExpr         { return self.dyn()->transform_tuple_literal_expr(         cast::<TupleLiteralExpr>(e)         ); }
            case ExprKind::SetLiteralExpr           { return self.dyn()->transform_set_literal_expr(           cast::<SetLiteralExpr>(e)           ); }
            case ExprKind::MapLiteralExpr           { return self.dyn()->transform_map_literal_expr(           cast::<MapLiteralExpr>(e)           ); }
            case ExprKind::NamedInitializerExpr     { return self.dyn()->transform_named_initializer_expr(     cast::<NamedInitializerExpr>(e)     ); }
            case ExprKind::AnonInitializerExpr      { return self.dyn()->transform_anon_initializer_expr(      cast::<AnonInitializerExpr>(e)      ); }
            case ExprKind::ChainExpr                { return self.dyn()->transform_chain_expr(                 cast::<ChainExpr>(e)                ); }
            case ExprKind::CallExpr                 { return self.dyn()->transform_call_expr(                  cast::<CallExpr>(e)                 ); }
            case ExprKind::SubscriptExpr            { return self.dyn()->transform_subscript_expr(             cast::<SubscriptExpr>(e)            ); }
            case ExprKind::NamedIdentExpr           { return self.dyn()->transform_named_ident_expr(           cast::<NamedIdentExpr>(e)           ); }
            case ExprKind::UnaryOperatorExpr        { return self.dyn()->transform_unary_operator_expr(        cast::<UnaryOperatorExpr>(e)        ); }
            case ExprKind::BinaryOperatorExpr       { return self.dyn()->transform_binary_operator_expr(       cast::<BinaryOperatorExpr>(e)       ); }
            case ExprKind::AssignOperatorExpr       { return self.dyn()->transform_assign_operator_expr(       cast::<AssignOperatorExpr>(e)       ); }
            case ExprKind::ImplConformanceExpr      { return self.dyn()->transform_impl_conformance_expr(      cast::<ImplConformanceExpr>(e)      ); }
            case ExprKind::DerivesRelationExpr      { return self.dyn()->transform_derives_relation_expr(      cast::<DerivesRelationExpr>(e)      ); }
            case ExprKind::IfExpr                   { return self.dyn()->transform_if_expr(                    cast::<IfExpr>(e)                   ); }
            case ExprKind::TryCatchExpr             { return self.dyn()->transform_try_catch_expr(             cast::<TryCatchExpr>(e)             ); }
            case ExprKind::MatchExpr                { return self.dyn()->transform_match_expr(                 cast::<MatchExpr>(e)                ); }
            case ExprKind::RangeExpr                { return self.dyn()->transform_range_expr(                 cast::<RangeExpr>(e)                ); }
            case ExprKind::ClosureExpr              { return self.dyn()->transform_closure_expr(               cast::<ClosureExpr>(e)              ); }
            case ExprKind::AwaitExpr                { return self.dyn()->transform_await_expr(                 cast::<AwaitExpr>(e)                ); }
            case ExprKind::SpawnExpr                { return self.dyn()->transform_spawn_expr(                 cast::<SpawnExpr>(e)                ); }
            case ExprKind::ThreadExpr               { return self.dyn()->transform_thread_expr(                cast::<ThreadExpr>(e)               ); }
            case ExprKind::ConstraintExpr           { return self.dyn()->transform_constraint_expr(            cast::<ConstraintExpr>(e)           ); }
            case ExprKind::SizeOfExpr               { return self.dyn()->transform_size_of_expr(               cast::<SizeOfExpr>(e)               ); }
            case ExprKind::AlignOfExpr              { return self.dyn()->transform_align_of_expr(              cast::<AlignOfExpr>(e)              ); }
            case ExprKind::TypeOfExpr               { return self.dyn()->transform_type_of_expr(               cast::<TypeOfExpr>(e)               ); }
            case ExprKind::EvalExpr                 { return self.dyn()->transform_eval_expr(                  cast::<EvalExpr>(e)                 ); }
            case ExprKind::UnsafeExpr               { return self.dyn()->transform_unsafe_expr(                cast::<UnsafeExpr>(e)               ); }
            case ExprKind::DeleteExpr               { return self.dyn()->transform_delete_expr(                cast::<DeleteExpr>(e)               ); }
            case ExprKind::PackExpansionExpr        { return self.dyn()->transform_pack_expansion_expr(        cast::<PackExpansionExpr>(e)        ); }
            case ExprKind::TypeCastExpr             { return self.dyn()->transform_type_cast_expr(             cast::<TypeCastExpr>(e)             ); }
            case ExprKind::ImplicitBoundaryCastExpr { return self.dyn()->transform_implicit_boundary_cast_expr(cast::<ImplicitBoundaryCastExpr>(e) ); }
            case ExprKind::RecoveryExpr             { return e; }
            case ExprKind::ExprKindCount            {  std::ICE("ExprKindCount reached ASTWriter - bug"); return &null; }
        }
        return e;
    }

    //- leaf literals: no children -----------------------------------------
    fn transform_integer_literal_expr(self, n: *IntegerLiteralExpr)     -> *Expr { return n; }
    fn transform_floating_literal_expr(self, n: *FloatingLiteralExpr)   -> *Expr { return n; }
    fn transform_character_literal_expr(self, n: *CharacterLiteralExpr) -> *Expr { return n; }
    fn transform_boolean_literal_expr(self, n: *BooleanLiteralExpr)     -> *Expr { return n; }
    fn transform_null_literal_expr(self, n: *NullLiteralExpr)           -> *Expr { return n; }

    fn transform_string_literal_expr(self, n: *StringLiteralExpr) -> *Expr {
        self.dyn()->rebuild_expr_list(&(n->parts)); // f"" interpolation exprs
        return n;
    }

    fn transform_list_literal_expr(self, n: *ListLiteralExpr) -> *Expr {
        self.dyn()->rebuild_expr_list(&(n->elements));
        return n;
    }

    fn transform_tuple_literal_expr(self, n: *TupleLiteralExpr) -> *Expr {
        self.dyn()->rebuild_expr_list(&(n->elements));
        return n;
    }

    fn transform_set_literal_expr(self, n: *SetLiteralExpr) -> *Expr {
        self.dyn()->rebuild_expr_list(&(n->elements));
        return n;
    }

    fn transform_map_literal_expr(self, n: *MapLiteralExpr) -> *Expr {
        for var i: usize = 0; i < n->entries.size(); i++ {
            if self.stop { break; }
            var en = n->entries.get(i);
            en->key   = self.dyn()->transform_expr(en->key);
            en->value = self.dyn()->transform_expr(en->value);
        }
        return n;
    }

    fn transform_named_initializer_expr(self, n: *NamedInitializerExpr) -> *Expr {
        if n->type_expr != &null {
            n->type_expr = self.dyn()->transform_expr(n->type_expr);
        }
        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop { break; }
            var f = n->fields.get(i);
            if f->value != &null {
                f->value = self.dyn()->transform_expr(f->value);
            }
        }
        return n;
    }

    fn transform_anon_initializer_expr(self, n: *AnonInitializerExpr) -> *Expr {
        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop { break; }
            var f = n->fields.get(i);
            if f->value != &null {
                f->value = self.dyn()->transform_expr(f->value);
            }
        }
        return n;
    }

    fn transform_chain_expr(self, n: *ChainExpr) -> *Expr {
        if n->base != &null {
            n->base = self.dyn()->transform_expr(n->base);
        }
        for var i: usize = 0; i < n->steps.size(); i++ {
            if self.stop { break; }
            var st = n->steps.get(i);
            for var j: usize = 0; j < st->generic_args.size(); j++ {
                if self.stop { break; }
                self.dyn()->transform_generic_arg(st->generic_args.get(j));
            }
        }
        return n;
    }

    fn transform_call_expr(self, n: *CallExpr) -> *Expr {
        if n->callee != &null {
            n->callee = self.dyn()->transform_expr(n->callee);
        }
        self.dyn()->rebuild_expr_list(&(n->args));
        return n;
    }

    fn transform_subscript_expr(self, n: *SubscriptExpr) -> *Expr {
        if n->base  != &null { n->base  = self.dyn()->transform_expr(n->base); }
        if n->index != &null { n->index = self.dyn()->transform_expr(n->index); }
        return n;
    }

    fn transform_named_ident_expr(self, n: *NamedIdentExpr) -> *Expr {
        for var i: usize = 0; i < n->generic_args.size(); i++ {
            if self.stop { break; }
            self.dyn()->transform_generic_arg(n->generic_args.get(i));
        }
        return n;
    }

    fn transform_unary_operator_expr(self, n: *UnaryOperatorExpr) -> *Expr {
        if n->operand != &null { n->operand = self.dyn()->transform_expr(n->operand); }
        return n;
    }

    fn transform_binary_operator_expr(self, n: *BinaryOperatorExpr) -> *Expr {
        if n->lhs != &null { n->lhs = self.dyn()->transform_expr(n->lhs); }
        if n->rhs != &null { n->rhs = self.dyn()->transform_expr(n->rhs); }
        return n;
    }

    fn transform_assign_operator_expr(self, n: *AssignOperatorExpr) -> *Expr {
        if n->lhs != &null { n->lhs = self.dyn()->transform_expr(n->lhs); }
        if n->rhs != &null { n->rhs = self.dyn()->transform_expr(n->rhs); }
        return n;
    }

    fn transform_impl_conformance_expr(self, n: *ImplConformanceExpr) -> *Expr {
        if n->subject != &null { n->subject = self.dyn()->transform_type(n->subject); }
        if n->inter   != &null { n->inter   = self.dyn()->transform_type(n->inter); }
        return n;
    }

    fn transform_derives_relation_expr(self, n: *DerivesRelationExpr) -> *Expr {
        if n->subject != &null { n->subject = self.dyn()->transform_type(n->subject); }
        if n->base    != &null { n->base    = self.dyn()->transform_type(n->base); }
        return n;
    }

    fn transform_if_expr(self, n: *IfExpr) -> *Expr {
        if n->condition != &null { n->condition = self.dyn()->transform_expr(n->condition); }
        if n->then_expr != &null { n->then_expr = self.dyn()->transform_expr(n->then_expr); }
        for var i: usize = 0; i < n->else_ifs.size(); i++ {
            if self.stop { break; }
            var arm = n->else_ifs.get(i);
            if arm->condition != &null { arm->condition = self.dyn()->transform_expr(arm->condition); }
            if arm->body      != &null { arm->body      = self.dyn()->transform_expr(arm->body); }
        }
        if n->else_expr != &null { n->else_expr = self.dyn()->transform_expr(n->else_expr); }
        return n;
    }

    fn transform_try_catch_expr(self, n: *TryCatchExpr) -> *Expr {
        if n->try_expr != &null { n->try_expr = self.dyn()->transform_expr(n->try_expr); }
        for var i: usize = 0; i < n->catch_arms.size(); i++ {
            if self.stop { break; }
            var arm = n->catch_arms.get(i);
            if arm->filter != &null { arm->filter = self.dyn()->transform_type(arm->filter); }
            if arm->body   != &null { arm->body   = self.dyn()->transform_expr(arm->body); }
        }
        return n;
    }

    fn transform_match_expr(self, n: *MatchExpr) -> *Expr {
        if n->scrutinee != &null { n->scrutinee = self.dyn()->transform_expr(n->scrutinee); }
        for var i: usize = 0; i < n->cases.size(); i++ {
            if self.stop { break; }
            self.dyn()->transform_match_case(n->cases.get(i));
        }
        return n;
    }

    fn transform_range_expr(self, n: *RangeExpr) -> *Expr {
        if n->begin != &null { n->begin = self.dyn()->transform_expr(n->begin); }
        if n->end   != &null { n->end   = self.dyn()->transform_expr(n->end); }
        return n;
    }

    fn transform_closure_expr(self, n: *ClosureExpr) -> *Expr {
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->generic_params)));
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->params)));
        for var i: usize = 0; i < n->captures.size(); i++ {
            if self.stop { break; }
            var cap = n->captures.get(i);
            if cap->name != &null { cap->name = cast::<NamedIdentExpr>(self.dyn()->transform_expr(cap->name)); }
        }
        if n->return_type != &null { n->return_type = self.dyn()->transform_type(n->return_type); }
        if n->body_block  != &null { n->body_block  = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body_block)); }
        if n->body_expr   != &null { n->body_expr   = self.dyn()->transform_expr(n->body_expr); }
        return n;
    }

    fn transform_await_expr(self, n: *AwaitExpr) -> *Expr {
        if n->operand != &null { n->operand = self.dyn()->transform_expr(n->operand); }
        return n;
    }

    fn transform_spawn_expr(self, n: *SpawnExpr) -> *Expr {
        if n->operand != &null { n->operand = self.dyn()->transform_expr(n->operand); }
        return n;
    }

    fn transform_thread_expr(self, n: *ThreadExpr) -> *Expr {
        if n->operand != &null { n->operand = self.dyn()->transform_expr(n->operand); }
        return n;
    }

    fn transform_constraint_expr(self, n: *ConstraintExpr) -> *Expr {
        if n->lhs != &null { n->lhs = self.dyn()->transform_expr(n->lhs); }
        if n->rhs != &null { n->rhs = self.dyn()->transform_type(n->rhs); }
        return n;
    }

    fn transform_size_of_expr(self, n: *SizeOfExpr) -> *Expr {
        // CROSS-FAMILY SITE: when the parser saw `sizeof expr` but the operand
        // resolves to a type, a sema pass converts n->operand (*Expr) into a
        // *Type and moves it to n->type_arg, then nulls n->operand. Both slots
        // live on THIS node, so the *Expr return contract is preserved.
        if n->type_arg != &null { n->type_arg = self.dyn()->transform_type(n->type_arg); }
        return n;
    }

    fn transform_align_of_expr(self, n: *AlignOfExpr) -> *Expr {
        if n->type_arg != &null { n->type_arg = self.dyn()->transform_type(n->type_arg); }
        return n;
    }

    fn transform_type_of_expr(self, n: *TypeOfExpr) -> *Expr {
        if n->operand != &null { n->operand = self.dyn()->transform_expr(n->operand); }
        return n;
    }

    fn transform_eval_expr(self, n: *EvalExpr) -> *Expr {
        if n->operand != &null { n->operand = self.dyn()->transform_expr(n->operand); }
        return n;
    }

    fn transform_unsafe_expr(self, n: *UnsafeExpr) -> *Expr {
        if n->operand != &null { n->operand = self.dyn()->transform_expr(n->operand); }
        return n;
    }

    fn transform_delete_expr(self, n: *DeleteExpr) -> *Expr {
        if n->operand != &null { n->operand = self.dyn()->transform_expr(n->operand); }
        return n;
    }

    fn transform_pack_expansion_expr(self, n: *PackExpansionExpr) -> *Expr {
        if n->operand != &null { n->operand = self.dyn()->transform_expr(n->operand); }
        return n;
    }

    fn transform_type_cast_expr(self, n: *TypeCastExpr) -> *Expr {
        if n->operand != &null { n->operand = self.dyn()->transform_expr(n->operand); }
        if n->target  != &null { n->target  = self.dyn()->transform_type(n->target); }
        return n;
    }

    fn transform_implicit_boundary_cast_expr(self, n: *ImplicitBoundaryCastExpr) -> *Expr {
        if n->original    != &null { n->original    = self.dyn()->transform_expr(n->original); }
        if n->source_type != &null { n->source_type = self.dyn()->transform_type(n->source_type); }
        if n->target_type != &null { n->target_type = self.dyn()->transform_type(n->target_type); }
        return n;
    }

    // ===========================================================================
    //  STMT FAMILY  (splice return: vec<*Stmt>; empty = delete)
    // ===========================================================================

    fn transform_stmt(self, s: *Stmt) -> vec::<*Stmt> {
        if s == &null { return vec::<*Stmt>(); }
        if self.stop  { return self._one_stmt(s); }

        switch s->kind {
            case StmtKind::CompoundStmt          { return self.dyn()->transform_compound_stmt(          cast::<CompoundStmt>(s)          ); }
            case StmtKind::ExpressionStmt        { return self.dyn()->transform_expression_stmt(        cast::<ExpressionStmt>(s)        ); }
            case StmtKind::DeclStmt              { return self.dyn()->transform_decl_stmt(              cast::<DeclStmt>(s)              ); }
            case StmtKind::ReturnStmt            { return self.dyn()->transform_return_stmt(            cast::<ReturnStmt>(s)            ); }
            case StmtKind::BreakStmt             { return self.dyn()->transform_break_stmt(             cast::<BreakStmt>(s)             ); }
            case StmtKind::ContinueStmt          { return self.dyn()->transform_continue_stmt(          cast::<ContinueStmt>(s)          ); }
            case StmtKind::PanicStmt             { return self.dyn()->transform_panic_stmt(             cast::<PanicStmt>(s)             ); }
            case StmtKind::YieldStmt             { return self.dyn()->transform_yield_stmt(             cast::<YieldStmt>(s)             ); }
            case StmtKind::RuntimeAssertStmt     { return self.dyn()->transform_runtime_assert_stmt(    cast::<RuntimeAssertStmt>(s)     ); }
            case StmtKind::StaticAssertStmt      { return self.dyn()->transform_static_assert_stmt(     cast::<StaticAssertStmt>(s)      ); }
            case StmtKind::LabelIntrinsicStmt    { return self.dyn()->transform_label_intrinsic_stmt(   cast::<LabelIntrinsicStmt>(s)    ); }
            case StmtKind::JumpIntrinsicStmt     { return self.dyn()->transform_jump_intrinsic_stmt(    cast::<JumpIntrinsicStmt>(s)     ); }
            case StmtKind::ConditionalStmt       { return self.dyn()->transform_conditional_stmt(       cast::<ConditionalStmt>(s)       ); }
            case StmtKind::WhileLoopStmt         { return self.dyn()->transform_while_loop_stmt(        cast::<WhileLoopStmt>(s)         ); }
            case StmtKind::LoopStmt              { return self.dyn()->transform_loop_stmt(              cast::<LoopStmt>(s)              ); }
            case StmtKind::RangedForStmt         { return self.dyn()->transform_ranged_for_stmt(        cast::<RangedForStmt>(s)         ); }
            case StmtKind::IndexedForStmt        { return self.dyn()->transform_indexed_for_stmt(       cast::<IndexedForStmt>(s)        ); }
            case StmtKind::MatchStmt             { return self.dyn()->transform_match_stmt(             cast::<MatchStmt>(s)             ); }
            case StmtKind::LabeledStmt           { return self.dyn()->transform_labeled_stmt(           cast::<LabeledStmt>(s)           ); }
            case StmtKind::TryCatchStmt          { return self.dyn()->transform_try_catch_stmt(         cast::<TryCatchStmt>(s)          ); }
            case StmtKind::FinallyStmt           { return self.dyn()->transform_finally_stmt(           cast::<FinallyStmt>(s)           ); }
            case StmtKind::UnsafeBlockStmt       { return self.dyn()->transform_unsafe_block_stmt(      cast::<UnsafeBlockStmt>(s)       ); }
            case StmtKind::ContextBindingStmt    { return self.dyn()->transform_context_binding_stmt(   cast::<ContextBindingStmt>(s)    ); }
            case StmtKind::DestructuringDeclStmt { return self.dyn()->transform_destructuring_decl_stmt(cast::<DestructuringDeclStmt>(s) ); }
            case StmtKind::InlineBlockStmt       { return self.dyn()->transform_inline_block_stmt(      cast::<InlineBlockStmt>(s)       ); }
            case StmtKind::EvalBlockStmt         { return self.dyn()->transform_eval_block_stmt(        cast::<EvalBlockStmt>(s)         ); }
            case StmtKind::RecoveryStmt          { return self._one_stmt(s); }
            case StmtKind::StmtKindCount         {  std::ICE("StmtKindCount reached ASTWriter - bug"); return vec::<*Stmt>(); }
        }
        return self._one_stmt(s);
    }

    fn transform_compound_stmt(self, n: *CompoundStmt) -> vec::<*Stmt> {
        self.dyn()->rebuild_stmt_list(&(n->body));
        return self._one_stmt(n);
    }

    fn transform_expression_stmt(self, n: *ExpressionStmt) -> vec::<*Stmt> {
        if n->expr != &null { n->expr = self.dyn()->transform_expr(n->expr); }
        return self._one_stmt(n);
    }

    fn transform_decl_stmt(self, n: *DeclStmt) -> vec::<*Stmt> {
        // A single decl can splice into several decls. If that happens, the
        // surrounding stmt list must gain several DeclStmt wrappers so a
        // multi-decl result fans out into multiple DeclStmts here.
        if n->decl == &null { return self._one_stmt(n); }
        var decls = self.dyn()->transform_decl(n->decl);
        if decls.size() == 1 {
            n->decl = decls[0];
            return self._one_stmt(n);
        }
        var out = vec::<*Stmt>();
        for var i: usize = 0; i < decls.size(); i++ {
            var wrapper = DeclStmt::create(self.ctx, n->range, decls[i]);
            out.push_back(wrapper);
        }
        return out;
    }

    fn transform_return_stmt(self, n: *ReturnStmt) -> vec::<*Stmt> {
        if n->value != &null { n->value = self.dyn()->transform_expr(n->value); }
        return self._one_stmt(n);
    }

    fn transform_break_stmt(self, n: *BreakStmt) -> vec::<*Stmt> {
        return self._one_stmt(n);
    }

    fn transform_continue_stmt(self, n: *ContinueStmt) -> vec::<*Stmt> {
        return self._one_stmt(n);
    }

    fn transform_panic_stmt(self, n: *PanicStmt) -> vec::<*Stmt> {
        if n->payload != &null { n->payload = self.dyn()->transform_expr(n->payload); }
        return self._one_stmt(n);
    }

    fn transform_yield_stmt(self, n: *YieldStmt) -> vec::<*Stmt> {
        if n->value != &null { n->value = self.dyn()->transform_expr(n->value); }
        return self._one_stmt(n);
    }

    fn transform_runtime_assert_stmt(self, n: *RuntimeAssertStmt) -> vec::<*Stmt> {
        if n->condition != &null { n->condition = self.dyn()->transform_expr(n->condition); }
        if n->message   != &null { n->message   = self.dyn()->transform_expr(n->message); }
        return self._one_stmt(n);
    }

    fn transform_static_assert_stmt(self, n: *StaticAssertStmt) -> vec::<*Stmt> {
        if n->condition != &null { n->condition = self.dyn()->transform_expr(n->condition); }
        if n->message   != &null { n->message   = self.dyn()->transform_expr(n->message); }
        return self._one_stmt(n);
    }

    fn transform_label_intrinsic_stmt(self, n: *LabelIntrinsicStmt) -> vec::<*Stmt> {
        return self._one_stmt(n);
    }

    fn transform_jump_intrinsic_stmt(self, n: *JumpIntrinsicStmt) -> vec::<*Stmt> {
        return self._one_stmt(n);
    }

    fn transform_conditional_stmt(self, n: *ConditionalStmt) -> vec::<*Stmt> {
        if n->cond != &null { n->cond = self.dyn()->transform_expr(n->cond); }
        n->then_ = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->then_));
        if n->else_ != &null { n->else_ = self.dyn()->transform_stmt_scalar(n->else_); }
        return self._one_stmt(n);
    }

    fn transform_while_loop_stmt(self, n: *WhileLoopStmt) -> vec::<*Stmt> {
        if n->cond != &null { n->cond = self.dyn()->transform_expr(n->cond); }
        n->body = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body));
        return self._one_stmt(n);
    }

    fn transform_loop_stmt(self, n: *LoopStmt) -> vec::<*Stmt> {
        n->body = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body));
        return self._one_stmt(n);
    }

    fn transform_ranged_for_stmt(self, n: *RangedForStmt) -> vec::<*Stmt> {
        if n->iterable != &null { n->iterable = self.dyn()->transform_expr(n->iterable); }
        n->body = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body));
        return self._one_stmt(n);
    }

    fn transform_indexed_for_stmt(self, n: *IndexedForStmt) -> vec::<*Stmt> {
        if n->init   != &null { n->init   = self.dyn()->transform_stmt_scalar(n->init); }
        if n->cond   != &null { n->cond   = self.dyn()->transform_expr(n->cond); }
        if n->update != &null { n->update = self.dyn()->transform_expr(n->update); }
        n->body = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body));
        return self._one_stmt(n);
    }

    fn transform_match_stmt(self, n: *MatchStmt) -> vec::<*Stmt> {
        if n->scrutinee != &null { n->scrutinee = self.dyn()->transform_expr(n->scrutinee); }
        for var i: usize = 0; i < n->cases.size(); i++ {
            if self.stop { break; }
            self.dyn()->transform_match_case(n->cases.get(i));
        }
        return self._one_stmt(n);
    }

    fn transform_labeled_stmt(self, n: *LabeledStmt) -> vec::<*Stmt> {
        if n->inner != &null { n->inner = self.dyn()->transform_stmt_scalar(n->inner); }
        return self._one_stmt(n);
    }

    fn transform_try_catch_stmt(self, n: *TryCatchStmt) -> vec::<*Stmt> {
        n->try_body = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->try_body));
        for var i: usize = 0; i < n->arms.size(); i++ {
            if self.stop { break; }
            var arm = n->arms.get(i);
            if arm->filter != &null { arm->filter = self.dyn()->transform_type(arm->filter); }
            if arm->body   != &null { arm->body   = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(arm->body)); }
        }
        return self._one_stmt(n);
    }

    fn transform_finally_stmt(self, n: *FinallyStmt) -> vec::<*Stmt> {
        n->body = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body));
        return self._one_stmt(n);
    }

    fn transform_unsafe_block_stmt(self, n: *UnsafeBlockStmt) -> vec::<*Stmt> {
        n->body = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body));
        return self._one_stmt(n);
    }

    fn transform_context_binding_stmt(self, n: *ContextBindingStmt) -> vec::<*Stmt> {
        if n->value != &null { n->value = self.dyn()->transform_expr(n->value); }
        n->body = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body));
        return self._one_stmt(n);
    }

    fn transform_destructuring_decl_stmt(self, n: *DestructuringDeclStmt) -> vec::<*Stmt> {
        if n->value != &null { n->value = self.dyn()->transform_expr(n->value); }
        return self._one_stmt(n);
    }

    fn transform_inline_block_stmt(self, n: *InlineBlockStmt) -> vec::<*Stmt> {
        return self._one_stmt(n); // opaque foreign body.
    }

    fn transform_eval_block_stmt(self, n: *EvalBlockStmt) -> vec::<*Stmt> {
        self.dyn()->rebuild_decl_list(&(n->body));
        return self._one_stmt(n);
    }

    fn transform_decl(self, d: *Decl) -> vec::<*Decl> {
        if d == &null { return vec::<*Decl>(); }
        if self.stop  { return self._one_decl(d); }

        switch d->kind {
            case DeclKind::FunctionDecl        { return self.dyn()->transform_function_decl(        cast::<FunctionDecl>(d)        ); }
            case DeclKind::VariableDecl        { return self.dyn()->transform_variable_decl(        cast::<VariableDecl>(d)        ); }
            case DeclKind::FieldDecl           { return self.dyn()->transform_field_decl(           cast::<FieldDecl>(d)           ); }
            case DeclKind::ParamDecl           { return self.dyn()->transform_param_decl(           cast::<ParamDecl>(d)           ); }
            case DeclKind::GenericParamDecl    { return self.dyn()->transform_generic_param_decl(   cast::<GenericParamDecl>(d)    ); }
            case DeclKind::StructDecl          { return self.dyn()->transform_struct_decl(          cast::<StructDecl>(d)          ); }
            case DeclKind::ClassDecl           { return self.dyn()->transform_class_decl(           cast::<ClassDecl>(d)           ); }
            case DeclKind::InterfaceDecl       { return self.dyn()->transform_interface_decl(       cast::<InterfaceDecl>(d)       ); }
            case DeclKind::ExtensionDecl       { return self.dyn()->transform_extension_decl(       cast::<ExtensionDecl>(d)       ); }
            case DeclKind::EnumDecl            { return self.dyn()->transform_enum_decl(            cast::<EnumDecl>(d)            ); }
            case DeclKind::EnumVariantDecl     { return self.dyn()->transform_enum_variant_decl(    cast::<EnumVariantDecl>(d)     ); }
            case DeclKind::UnionDecl           { return self.dyn()->transform_union_decl(           cast::<UnionDecl>(d)           ); }
            case DeclKind::TypeAliasDecl       { return self.dyn()->transform_type_alias_decl(      cast::<TypeAliasDecl>(d)       ); }
            case DeclKind::ModuleDecl          { return self.dyn()->transform_module_decl(          cast::<ModuleDecl>(d)          ); }
            case DeclKind::ImportDecl          { return self.dyn()->transform_import_decl(          cast::<ImportDecl>(d)          ); }
            case DeclKind::VisibilityGroupDecl { return self.dyn()->transform_visibility_group_decl(cast::<VisibilityGroupDecl>(d) ); }
            case DeclKind::EvalBlockDecl       { return self.dyn()->transform_eval_block_decl(      cast::<EvalBlockDecl>(d)       ); }
            case DeclKind::TestDecl            { return self.dyn()->transform_test_decl(            cast::<TestDecl>(d)            ); }
            case DeclKind::MacroDecl           { return self.dyn()->transform_macro_decl(           cast::<MacroDecl>(d)           ); }
            case DeclKind::ProcedureMacroDecl  { return self.dyn()->transform_procedure_macro_decl( cast::<ProcedureMacroDecl>(d)  ); }
            case DeclKind::FFIBlockDecl        { return self.dyn()->transform_ffi_block_decl(       cast::<FFIBlockDecl>(d)        ); }
            case DeclKind::RecoveryDecl        { return self._one_decl(d); }
            case DeclKind::DeclKindCount       {  std::ICE("DeclKindCount reached ASTWriter - bug"); return vec::<*Decl>(); }
        }
        return self._one_decl(d);
    }

    fn transform_function_decl(self, n: *FunctionDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->generic_params)));
        self.dyn()->rebuild_type_list(&(n->spec_args)); // specialization pattern (#68)
        if n->requires_clause != &null { n->requires_clause = self.dyn()->transform_expr(n->requires_clause); }
        if n->where_clause    != &null { n->where_clause    = self.dyn()->transform_expr(n->where_clause); }
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->params)));
        if n->return_type != &null { n->return_type = self.dyn()->transform_type(n->return_type); }
        if n->qualifier   != &null { n->qualifier   = self.dyn()->transform_expr(n->qualifier); }
        if n->body_block  != &null { n->body_block  = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body_block)); }
        if n->body_expr   != &null { n->body_expr   = self.dyn()->transform_expr(n->body_expr); }
        return self._one_decl(n);
    }

    fn transform_variable_decl(self, n: *VariableDecl) -> vec::<*Decl> {
        if n->type_ != &null { n->type_ = self.dyn()->transform_type(n->type_); }
        if n->init  != &null { n->init  = self.dyn()->transform_expr(n->init); }
        return self._one_decl(n);
    }

    fn transform_field_decl(self, n: *FieldDecl) -> vec::<*Decl> {
        if n->type_ != &null { n->type_ = self.dyn()->transform_type(n->type_); }
        if n->init  != &null { n->init  = self.dyn()->transform_expr(n->init); }
        return self._one_decl(n);
    }

    fn transform_param_decl(self, n: *ParamDecl) -> vec::<*Decl> {
        if n->type_       != &null { n->type_       = self.dyn()->transform_type(n->type_); }
        if n->default_val != &null { n->default_val = self.dyn()->transform_expr(n->default_val); }
        return self._one_decl(n);
    }

    fn transform_generic_param_decl(self, n: *GenericParamDecl) -> vec::<*Decl> {
        for var i: usize = 0; i < n->impl_bounds.size(); i++ {
            if self.stop { break; }
            self.dyn()->transform_inherit_edge(n->impl_bounds.get(i));
        }
        for var i: usize = 0; i < n->derives_bounds.size(); i++ {
            if self.stop { break; }
            self.dyn()->transform_inherit_edge(n->derives_bounds.get(i));
        }
        if n->value_type   != &null { n->value_type   = self.dyn()->transform_type(n->value_type); }
        if n->default_type != &null { n->default_type = self.dyn()->transform_type(n->default_type); }
        return self._one_decl(n);
    }

    fn transform_struct_decl(self, n: *StructDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->generic_params)));
        self.dyn()->rebuild_type_list(&(n->spec_args)); // specialization pattern (#68)
        if n->requires_clause != &null { n->requires_clause = self.dyn()->transform_expr(n->requires_clause); }
        for var i: usize = 0; i < n->implements.size(); i++ {
            if self.stop { break; }
            self.dyn()->transform_inherit_edge(n->implements.get(i));
        }
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->fields)));
        self.dyn()->rebuild_dc_decls(static_cast::<*DeclContext>(n));
        return self._one_decl(n);
    }

    fn transform_class_decl(self, n: *ClassDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->generic_params)));
        self.dyn()->rebuild_type_list(&(n->spec_args)); // specialization pattern (#68)
        if n->requires_clause != &null { n->requires_clause = self.dyn()->transform_expr(n->requires_clause); }
        for var i: usize = 0; i < n->derives_list.size(); i++ {
            if self.stop { break; }
            self.dyn()->transform_inherit_edge(n->derives_list.get(i));
        }
        for var i: usize = 0; i < n->implements.size(); i++ {
            if self.stop { break; }
            self.dyn()->transform_inherit_edge(n->implements.get(i));
        }
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->fields)));
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->methods)));
        self.dyn()->rebuild_dc_decls(static_cast::<*DeclContext>(n));
        return self._one_decl(n);
    }

    fn transform_interface_decl(self, n: *InterfaceDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->generic_params)));
        if n->requires_clause != &null { n->requires_clause = self.dyn()->transform_expr(n->requires_clause); }
        for var i: usize = 0; i < n->derives_list.size(); i++ {
            if self.stop { break; }
            self.dyn()->transform_inherit_edge(n->derives_list.get(i));
        }
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->methods)));
        self.dyn()->rebuild_dc_decls(static_cast::<*DeclContext>(n));
        return self._one_decl(n);
    }

    fn transform_extension_decl(self, n: *ExtensionDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->generic_params)));
        if n->requires_clause != &null { n->requires_clause = self.dyn()->transform_expr(n->requires_clause); }
        if n->target != &null { n->target = self.dyn()->transform_type(n->target); }
        for var i: usize = 0; i < n->implements.size(); i++ {
            if self.stop { break; }
            self.dyn()->transform_inherit_edge(n->implements.get(i));
        }
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->methods)));
        self.dyn()->rebuild_dc_decls(static_cast::<*DeclContext>(n));
        return self._one_decl(n);
    }

    fn transform_enum_decl(self, n: *EnumDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->generic_params)));
        if n->requires_clause != &null { n->requires_clause = self.dyn()->transform_expr(n->requires_clause); }
        if n->underlying != &null { n->underlying = self.dyn()->transform_type(n->underlying); }
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->variants)));
        return self._one_decl(n);
    }

    fn transform_enum_variant_decl(self, n: *EnumVariantDecl) -> vec::<*Decl> {
        if n->discriminant != &null { n->discriminant = self.dyn()->transform_expr(n->discriminant); }
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->payload)));
        return self._one_decl(n);
    }

    fn transform_union_decl(self, n: *UnionDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->generic_params)));
        self.dyn()->rebuild_type_list(&(n->spec_args)); // specialization pattern (#68)
        if n->requires_clause != &null { n->requires_clause = self.dyn()->transform_expr(n->requires_clause); }
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->fields)));
        self.dyn()->rebuild_dc_decls(static_cast::<*DeclContext>(n));
        return self._one_decl(n);
    }

    fn transform_type_alias_decl(self, n: *TypeAliasDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->generic_params)));
        if n->requires_clause != &null { n->requires_clause = self.dyn()->transform_expr(n->requires_clause); }
        if n->aliased != &null { n->aliased = self.dyn()->transform_type(n->aliased); }
        return self._one_decl(n);
    }

    fn transform_module_decl(self, n: *ModuleDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_dc_decls(static_cast::<*DeclContext>(n));
        return self._one_decl(n);
    }

    fn transform_import_decl(self, n: *ImportDecl) -> vec::<*Decl> {
        return self._one_decl(n); // token lists, no AST children.
    }

    fn transform_ffi_block_decl(self, n: *FFIBlockDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_decl_list(&(n->body));
        return self._one_decl(n);
    }

    fn transform_visibility_group_decl(self, n: *VisibilityGroupDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_decl_list(&(n->members));
        return self._one_decl(n);
    }

    fn transform_eval_block_decl(self, n: *EvalBlockDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_decl_list(&(n->body));
        return self._one_decl(n);
    }

    fn transform_test_decl(self, n: *TestDecl) -> vec::<*Decl> {
        if n->label != &null { n->label = self.dyn()->transform_expr(n->label); }
        if n->body  != &null { n->body  = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body)); }
        return self._one_decl(n);
    }

    fn transform_macro_decl(self, n: *MacroDecl) -> vec::<*Decl> {
        return self._one_decl(n); // raw token body, no AST children.
    }

    fn transform_procedure_macro_decl(self, n: *ProcedureMacroDecl) -> vec::<*Decl> {
        self.dyn()->rebuild_decl_list(reinterpret_cast::<*FrozenList::<*Decl>>(&(n->params)));
        if n->body != &null { n->body = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body)); }
        return self._one_decl(n);
    }

    fn transform_pattern(self, p: *Pattern) -> *Pattern {
        if p == &null { return &null; }
        if self.stop  { return p; }

        switch p->kind {
            case PatternKind::WildcardPattern              { return self.dyn()->transform_wildcard_pattern(              cast::<WildcardPattern>(p)              ); }
            case PatternKind::LiteralPattern               { return self.dyn()->transform_literal_pattern(               cast::<LiteralPattern>(p)               ); }
            case PatternKind::BindingPattern               { return self.dyn()->transform_binding_pattern(               cast::<BindingPattern>(p)               ); }
            case PatternKind::TupleDestructurePattern      { return self.dyn()->transform_tuple_destructure_pattern(     cast::<TupleDestructurePattern>(p)      ); }
            case PatternKind::ConstructorPattern           { return self.dyn()->transform_constructor_pattern(           cast::<ConstructorPattern>(p)           ); }
            case PatternKind::UnresolvedConstructorPattern { return self.dyn()->transform_unresolved_constructor_pattern(cast::<UnresolvedConstructorPattern>(p) ); }
            case PatternKind::AlternationPattern           { return self.dyn()->transform_alternation_pattern(           cast::<AlternationPattern>(p)           ); }
            case PatternKind::RangePattern                 { return self.dyn()->transform_range_pattern(                 cast::<RangePattern>(p)                 ); }
            case PatternKind::SlicePattern                 { return self.dyn()->transform_slice_pattern(                 cast::<SlicePattern>(p)                 ); }
            case PatternKind::RecoveryPattern              { return p; }
            case PatternKind::PatternKindCount             {  std::ICE("PatternKindCount reached ASTWriter - bug"); return &null; }
        }
        return p;
    }

    fn transform_wildcard_pattern(self, n: *WildcardPattern) -> *Pattern {
        return n;
    }

    fn transform_literal_pattern(self, n: *LiteralPattern) -> *Pattern {
        if n->value != &null { n->value = self.dyn()->transform_expr(n->value); }
        return n;
    }

    fn transform_binding_pattern(self, n: *BindingPattern) -> *Pattern {
        if n->type_ != &null { n->type_ = self.dyn()->transform_type(n->type_); }
        return n;
    }

    fn transform_tuple_destructure_pattern(self, n: *TupleDestructurePattern) -> *Pattern {
        self.dyn()->rebuild_pattern_list(&(n->elements));
        return n;
    }

    fn transform_constructor_pattern(self, n: *ConstructorPattern) -> *Pattern {
        if n->head != &null { n->head = self.dyn()->transform_expr(n->head); }
        self.dyn()->rebuild_pattern_list(&(n->subpatterns));
        return n;
    }

    fn transform_unresolved_constructor_pattern(self, n: *UnresolvedConstructorPattern) -> *Pattern {
        if n->head != &null { n->head = self.dyn()->transform_expr(n->head); }
        self.dyn()->rebuild_pattern_list(&(n->subpatterns));
        return n;
    }

    fn transform_alternation_pattern(self, n: *AlternationPattern) -> *Pattern {
        self.dyn()->rebuild_pattern_list(&(n->alternatives));
        return n;
    }

    fn transform_range_pattern(self, n: *RangePattern) -> *Pattern {
        if n->lo != &null { n->lo = self.dyn()->transform_expr(n->lo); }
        if n->hi != &null { n->hi = self.dyn()->transform_expr(n->hi); }
        return n;
    }

    fn transform_slice_pattern(self, n: *SlicePattern) -> *Pattern {
        self.dyn()->rebuild_pattern_list(&(n->prefix));
        self.dyn()->rebuild_pattern_list(&(n->suffix));
        if n->rest_binding != &null { n->rest_binding = self.dyn()->transform_pattern(n->rest_binding); }
        return n;
    }

    // == ENTRY POINTS ======================================================

    /// Drive the transform over a whole file. The top-level item list lives on
    /// the Program; rebuild it (splice-aware) and the imports/attrs lists.
    fn run(self, tu: *TranslationUnit) {
        if tu->program != &null {
            self.dyn()->rebuild_toplevel_items(&(tu->program->items));
        }
        // imports / tu_attrs are ArenaList<*Decl>; rebuild via dc-style walk
        // only if a pass needs to touch them. Most don't, so left as-is here.
    }

    /// Program::items is a live ArenaList of heterogeneous TopLevelItems
    /// (decl/stmt/expr). Rebuild it in place, dispatching each item to the
    /// matching family transform and re-wrapping the (splice-aware) results.
    fn rebuild_toplevel_items(self, items: *ArenaList::<TopLevelItem>) {
        var buf = ArenaList::<TopLevelItem>();
        buf.set_allocator(&(self.ctx->nodes));
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            if self.stop { buf.push(item); continue; }
            switch item.kind {
                case TopLevelKind::Decl {
                    var results = self.dyn()->transform_decl(item.as_decl());
                    for var j: usize = 0; j < results.size(); j++ {
                        buf.push(TopLevelItem::from_decl(results[j]));
                    }
                }
                case TopLevelKind::Stmt {
                    var results = self.dyn()->transform_stmt(item.as_stmt());
                    for var j: usize = 0; j < results.size(); j++ {
                        buf.push(TopLevelItem::from_stmt(results[j]));
                    }
                }
                case TopLevelKind::Expr {
                    var r = self.dyn()->transform_expr(item.as_expr());
                    if r != &null { buf.push(TopLevelItem::from_expr(r)); }
                }
            }
        }
        (*items) = buf;
    }

    /// Transform a single subtree of any family. Useful for targeted rewrites
    /// (e.g. one function body) without walking the whole TU.
    fn run_on_decl(self, d: *Decl) -> vec::<*Decl> {
        return self.dyn()->transform_decl(d);
    }

    fn run_on_stmt(self, s: *Stmt) -> vec::<*Stmt> {
        return self.dyn()->transform_stmt(s);
    }

    fn run_on_expr(self, e: *Expr) -> *Expr {
        return self.dyn()->transform_expr(e);
    }

    fn run_on_type(self, t: *Type) -> *Type {
        return self.dyn()->transform_type(t);
    }
}

///
/// \class ASTWriterProbe
/// \brief Compile-time tripwire forcing instantiation of ASTWriter<D>.
///
/// Same rationale as RAVProbe (see RecursiveASTVisitor.k): ASTWriter is a
/// CRTP base whose internal calls route through dyn() -> *D, a dependent type.
/// Dependent-name lookups are deferred until a concrete D instantiates the
/// path, so a misspelled transform_/rebuild_ call survives compilation of the
/// base alone. This zero-override derived class instantiates every method body
/// against a real D, turning the dependent-name surface from deferred to
/// verified on every build.
///
/// Do not delete. `_: bool` is filler for the Stage 0 empty-body limitation.
///
class ASTWriterProbe derives ASTWriter::<ASTWriterProbe> {
    pub var _: bool;
}