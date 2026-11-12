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
///                          STMT/DECL return vec<*F> (splice). EXPR/TYPE/
///                          PATTERN return *F (scalar; null = delete).
///     transform_N(...)   - hand-written body. recurse into children via
///                          transform_F / rebuild helpers; return the
///                          (possibly rewritten) node(s).
///
///   Return-type rule:
///     EXPR / TYPE / PATTERN : scalar *F out. These never occupy a list
///                             position that admits splice. A different node
///                             of the same family is a 1:1 rewrite. null is
///                             deletion (only legal where the parent slot is
///                             nullable, or inside a rebuild_*_list filter).
///
///     STMT / DECL : vec<*F> out. A statement or declaration can legitimately
///                   become zero, one, or many nodes in its enclosing list.
///                   Empty vec = deletion.
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
///                                existing list, applied in one rebuild.
///     rebuild_*_list(...)      - map every element through its transform_F.
///   No pass ever touches ArenaList, set_allocator, or from_list directly.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContext
import AST::Context::TranslationUnit::TranslationUnit
import AST::Kind::DeclKind::DeclKind
import AST::Kind::ExprKind::ExprKind
import AST::Kind::PatternKind::PatternKind
import AST::Kind::StmtKind::StmtKind
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Stmt,
    Type,
}
import AST::Node::Casting::cast
import AST::Node::Declarations
import AST::Node::Expressions
import AST::Node::Patterns::{
    AlternationPattern,
    BindingPattern,
    ConstructorPattern,
    LiteralPattern,
    RangePattern,
    SlicePattern,
    TupleDestructurePattern,
    UnresolvedConstructorPattern,
    WildcardPattern,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr, ChainExpr,      CharacterLiteralExpr, FloatingLiteralExpr,
    IntegerLiteralExpr, NamedIdentExpr, NullLiteralExpr,      StringLiteralExpr,
}
import AST::Node::Program::{
    TopLevelItem,
    TopLevelKind,
}
import AST::Node::Statements
import AST::Node::Types
import AST::ParamMode::ParamMode
import Memory::ArenaAllocator::ArenaAllocator
import Memory::ArenaList::ArenaList

///
/// \class ListBuilder<T>
/// \brief Accumulates elements and freezes them into a FrozenList<T>.
///
/// Used when a transform constructs a NEW node whose list children are built
/// from scratch (e.g. lowering a tuple expr's N elements into N type nodes).
/// Owns the arena plumbing so the pass never sees ArenaList directly.
///
pub class <T> ListBuilder {
    priv var _buf:   ArenaList<T>
    priv var _arena: unsafe *ArenaAllocator

    pub fn ListBuilder(self, ctx: unsafe *ASTContext) {
        self._arena = unsafe &ctx->ast_alloc
        // Slabs of 16, not ArenaList's 256: the buffer is copied out by
        // freeze_into and its slabs stay in the context's arena for good (a
        // builder is returned by value, so it cannot own an arena of its
        // own), and a lowering's list is a handful of elements. 256 slots
        // per builder would leave ~2 KB of dead arena per lowered f-string or
        // operator.
        self._buf.set_allocator(self._arena, 16)
    }

    pub fn push(self, item: T) {
        self._buf.push(item)
    }

    pub fn size(self) -> usize {
        return self._buf.size()
    }

    fn is_empty(self) -> bool {
        return self._buf.size() == 0
    }

    /// Freezes the accumulated elements into \p target, overwriting it.
    pub fn freeze_into(self, @inout target: FrozenList<T>) {
        target.from_list(&self._buf, self._arena)
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
pub class <T> ListRewriter {
    enum OpKind derives u8 {
        Replace,      ///< original element at index swapped for a new node.
        Remove,       ///< original element at index dropped.
        InsertBefore, ///< new element emitted just before this index.
    }

    struct Op {
        var kind:  OpKind
        var index: usize  ///< original-list index this op targets.
        var item:  T      ///< replacement / inserted node (unused for Remove).
    }

    priv var _source: *FrozenList<T>
    priv var _ops:    cxx::std::vector<Self::Op>
    priv var _arena:  unsafe *ArenaAllocator
    priv var _dirty:  bool                       = false

    fn ListRewriter(self, source: *FrozenList<T>, ctx: unsafe *ASTContext) {
        self._source = source
        self._arena  = unsafe &ctx->ast_alloc
    }

    /// Swap the element at \p index for \p item.
    fn replace(self, index: usize, item: T) {
        var opr = Self::Op{}
        opr.kind  = Self::OpKind::Replace
        opr.index = index
        opr.item  = item
        self._ops.push_back(opr)
        self._dirty = true
    }

    /// Drop the element at \p index.
    fn remove(self, index: usize) {
        var opr = Self::Op{}
        opr.kind  = Self::OpKind::Remove
        opr.index = index
        self._ops.push_back(opr)
        self._dirty = true
    }

    /// Emit \p item immediately before the element at \p index. An index equal
    /// to the list size appends; multiple inserts at the same index preserve
    /// call order.
    fn insert_before(self, index: usize, item: T) {
        var opr = Self::Op{}
        opr.kind  = Self::OpKind::InsertBefore
        opr.index = index
        opr.item  = item
        self._ops.push_back(opr)
        self._dirty = true
    }

    /// Emit \p item immediately after the element at \p index.
    fn insert_after(self, index: usize, item: T) {
        self.insert_before(index + 1, item)
    }

    /// Append \p item after the last element.
    pub fn append(self, item: T) {
        self.insert_before(self._source->size(), item)
    }

    fn has_changes(self) -> bool {
        return self._dirty
    }

    /// Discard the whole source list and install \p items in its place.
    /// Clears any previously recorded ops.
    fn replace_all(self, const items: cxx::std::vector<T>) {
        // Scratch, copied by from_list (see ASTWriter::rebuild_stmt_list).
        var buf = ArenaList<T>()
        for var i: usize = 0; i < items.size(); i++ {
            buf.push((items)[i])
        }

        self._source->from_list(&buf, self._arena)
        self._ops.clear()
        self._dirty = false
    }

    /// Rebuild the source list with every recorded op applied. No-op if
    /// nothing was recorded (the original FrozenList is left untouched, so
    /// passes that inspect-but-don't-edit pay nothing).
    pub fn apply(self) {
        if !self._dirty {
            return
        }

        // Scratch, copied by from_list (see ASTWriter::rebuild_stmt_list).
        var buf = ArenaList<T>()

        for var i: usize = 0; i < self._source->size(); i++ {
            // InsertBefore ops targeting this slot fire first, in record order.
            for var j: usize = 0; j < self._ops.size(); j++ {
                if self._ops[j].kind == Self::OpKind::InsertBefore && self._ops[j].index == i {
                    buf.push(self._ops[j].item)
                }
            }

            // Resolve remove/replace for this slot. First matching op wins;
            // Remove dominates Replace if both somehow target the same index.
            var removed        = false
            var replaced       = false
            var replacement: T

            for var j: usize = 0; j < self._ops.size(); j++ {
                if self._ops[j].index != i {
                    continue
                }

                if self._ops[j].kind == Self::OpKind::Remove {
                    removed = true
                    break
                }

                if self._ops[j].kind == Self::OpKind::Replace {
                    replaced    = true
                    replacement = self._ops[j].item
                    break
                }
            }

            if removed {
                continue
            }

            if replaced {
                buf.push(replacement)
            } else {
                buf.push(*self._source->get(i))
            }
        }

        // Trailing inserts: any InsertBefore at index >= size is an append.
        for var j: usize = 0; j < self._ops.size(); j++ {
            if self._ops[j].kind == Self::OpKind::InsertBefore
                && self._ops[j].index >= self._source->size() {
                buf.push(self._ops[j].item)
            }
        }

        self._source->from_list(&buf, self._arena)
        self._ops.clear()
        self._dirty = false
    }
}

// TODO(DUCK-GENERIC): D uses rebuild_dc_decls, rebuild_decl_list, rebuild_expr_list, rebuild_pattern_list, rebuild_stmt_list, rebuild_toplevel_items, rebuild_type_list, transform_align_of_expr, transform_alternation_pattern, transform_anon_initializer_expr, transform_assign_operator_expr, transform_attributed_expr, ... (143). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <D: type> ASTWriter {
    pub var ctx:  unsafe *ASTContext
    pub var stop: bool               = false

    fn dyn(self) -> unsafe *D {
        return unsafe ((&self) as *D)
    }

    fn <T> list_builder(self) -> ListBuilder<T> {
        return ListBuilder<T>(self.ctx)
    }

    fn <T> rewriter(self, list: unsafe *FrozenList<T>) -> ListRewriter<T> {
        return ListRewriter<T>(list, self.ctx)
    }

    /// # Default list rebuilds: map each element through its transform_F.
    /// STMT/DECL versions splice (transform returns vec); EXPR/TYPE/PATTERN
    /// versions are scalar with null-drop (transform returns *F, null deletes).
    ///
    /// Copy on change: a list every element of which maps to itself is
    /// left as it was. Rebuilding every list in every lowering pass would copy
    /// each list twice (the buffer, then from_list), changed or not, and the
    /// copies are never reclaimed from the arenas. The first
    /// element that maps to something else starts the buffer, seeded with
    /// the unchanged prefix, so a changed list ends up exactly as before.

    /// The rebuild buffers below are scratch: from_list copies them into the
    /// context's arena, so they stay in the list's own arena, freed on
    /// return. In ast_alloc each would be a 256-slot slab left behind for
    /// good, per list changed per pass. Load-bearing:
    /// `var buf = ArenaList<T>()` must construct in place. A default-built
    /// list points at its own member arena, so a moved one would point into
    /// the dead temporary and its blocks would leak.
    fn rebuild_stmt_list(self, old: *FrozenList<*Stmt>) {
        var buf     = ArenaList<*Stmt>()
        var changed = false
        for var i: usize = 0; i < old->size(); i++ {
            var *orig = *old->get(i)
            if self.stop {
                if changed {
                    buf.push(orig)
                }

                continue
            }

            var results = self.dyn()->transform_stmt(orig)
            if !changed {
                if results.size() == 1 && results[0] == orig {
                    continue
                }

                changed = true
                for var k: usize = 0; k < i; k++ {
                    buf.push(*old->get(k))
                }
            }

            for var j: usize = 0; j < results.size(); j++ {
                buf.push(results[j])
            }
        }

        if changed {
            old->from_list(&buf, unsafe &self.ctx->ast_alloc)
        }
    }

    fn rebuild_decl_list(self, old: *FrozenList<*Decl>) {
        var buf     = ArenaList<*Decl>()
        var changed = false
        for var i: usize = 0; i < old->size(); i++ {
            var *orig = *old->get(i)
            if self.stop {
                if changed {
                    buf.push(orig)
                }

                continue
            }

            var results = self.dyn()->transform_decl(orig)
            if !changed {
                if results.size() == 1 && results[0] == orig {
                    continue
                }

                changed = true
                for var k: usize = 0; k < i; k++ {
                    buf.push(*old->get(k))
                }
            }

            for var j: usize = 0; j < results.size(); j++ {
                buf.push(results[j])
            }
        }

        if changed {
            old->from_list(&buf, unsafe &self.ctx->ast_alloc)
        }
    }

    fn rebuild_expr_list(self, old: *FrozenList<unsafe *Expr>) {
        var buf     = ArenaList<unsafe *Expr>()
        var changed = false
        for var i: usize = 0; i < old->size(); i++ {
            var unsafe *orig = *old->get(i)
            if self.stop {
                if changed {
                    buf.push(orig)
                }

                continue
            }

            var r = self.dyn()->transform_expr(orig)
            if !changed {
                if r != &null && r == orig {
                    continue
                }

                changed = true
                for var k: usize = 0; k < i; k++ {
                    buf.push(*old->get(k))
                }
            }

            if r != &null {
                buf.push(r)
            }
        }

        if changed {
            old->from_list(&buf, unsafe &self.ctx->ast_alloc)
        }
    }

    fn rebuild_type_list(self, old: *FrozenList<*Type>) {
        var buf     = ArenaList<*Type>()
        var changed = false
        for var i: usize = 0; i < old->size(); i++ {
            var *orig = *old->get(i)
            if self.stop {
                if changed {
                    buf.push(orig)
                }

                continue
            }

            var r = self.dyn()->transform_type(orig)
            if !changed {
                if r != &null && r == orig {
                    continue
                }

                changed = true
                for var k: usize = 0; k < i; k++ {
                    buf.push(*old->get(k))
                }
            }

            if r != &null {
                buf.push(r)
            }
        }

        if changed {
            old->from_list(&buf, unsafe &self.ctx->ast_alloc)
        }
    }

    fn rebuild_pattern_list(self, old: *FrozenList<*Pattern>) {
        var buf     = ArenaList<*Pattern>()
        var changed = false
        for var i: usize = 0; i < old->size(); i++ {
            var *orig = *old->get(i)
            if self.stop {
                if changed {
                    buf.push(orig)
                }

                continue
            }

            var r = self.dyn()->transform_pattern(orig)
            if !changed {
                if r != &null && r == orig {
                    continue
                }

                changed = true
                for var k: usize = 0; k < i; k++ {
                    buf.push(*old->get(k))
                }
            }

            if r != &null {
                buf.push(r)
            }
        }

        if changed {
            old->from_list(&buf, unsafe &self.ctx->ast_alloc)
        }
    }

    /// DeclContext::dc_decls is a live ArenaList, not a FrozenList. Rebuild it
    /// in place, splicing transform_decl results; untouched when nothing
    /// changed (a null entry is dropped, which is a change).
    fn rebuild_dc_decls(self, dc: *DeclContext) {
        var buf     = ArenaList<unsafe *Decl>()
        var changed = false
        for var i: usize = 0; i < dc->dc_decls.size(); i++ {
            var unsafe *d = *dc->dc_decls.get(i)
            if !changed {
                if d != &null && self.stop {
                    continue
                }

                if d != &null {
                    var results = self.dyn()->transform_decl(d)
                    if results.size() == 1 && results[0] == d {
                        continue
                    }

                    changed = true
                    buf.set_allocator(unsafe &self.ctx->ast_alloc)
                    for var k: usize = 0; k < i; k++ {
                        buf.push(*dc->dc_decls.get(k))
                    }

                    for var j: usize = 0; j < results.size(); j++ {
                        buf.push(results[j])
                    }

                    continue
                }

                changed = true
                buf.set_allocator(unsafe &self.ctx->ast_alloc)
                for var k: usize = 0; k < i; k++ {
                    buf.push(*dc->dc_decls.get(k))
                }

                continue
            }

            if d == &null {
                continue
            }

            if self.stop {
                buf.push(d)
                continue
            }

            var results = self.dyn()->transform_decl(d)
            for var j: usize = 0; j < results.size(); j++ {
                buf.push(results[j])
            }
        }

        if changed {
            dc->dc_decls = buf
        }
    }

    /// # Scalar-position wrappers
    /// A stmt/decl in a SCALAR slot (e.g. IndexedForStmt::init, DeclStmt::decl)
    /// still routes through the vec-returning transform; these take the first
    /// result and drop the rest. A splice in a non-list slot is a pass bug;
    /// assert guards it.

    pub fn transform_stmt_scalar(self, s: unsafe *Stmt) -> unsafe *Stmt {
        if s == &null {
            return &null
        }

        var results = self.dyn()->transform_stmt(s)
        if results.size() == 0 {
            return &null
        }

        if results.size() != 1 {
            kairo::std::ice_fail("transform produced multiple stmts in a scalar slot")
        }

        return results[0]
    }

    fn transform_decl_scalar(self, d: unsafe *Decl) -> unsafe *Decl {
        if d == &null {
            return &null
        }

        var results = self.dyn()->transform_decl(d)
        if results.size() == 0 {
            return &null
        }

        if results.size() != 1 {
            kairo::std::ice_fail("transform produced multiple decls in a scalar slot")
        }

        return results[0]
    }

    /// # single-element vec helpers (kept terse; used pervasively below)

    fn _one_stmt(self, s: unsafe *Stmt) -> cxx::std::vector<unsafe *Stmt> {
        var v = cxx::std::vector<unsafe *Stmt>()
        v.push_back(s)
        return v
    }

    fn _one_decl(self, d: unsafe *Decl) -> cxx::std::vector<unsafe *Decl> {
        var v = cxx::std::vector<unsafe *Decl>()
        v.push_back(d)
        return v
    }

    fn transform_match_case(self, mc: *Statements::MatchCase) {
        self.dyn()->rebuild_pattern_list(&mc->patterns)
        if mc->guard != &null {
            mc->guard = self.dyn()->transform_expr(mc->guard)
        }

        if mc->body != &null {
            mc->body = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(mc->body))
        }

        if mc->expression != &null {
            mc->expression = self.dyn()->transform_expr(mc->expression)
        }
    }

    fn transform_inherit_edge(self, e: *Declarations::InheritEdge) {
        if e->base != &null {
            e->base = self.dyn()->transform_type(e->base)
        }
    }

    fn transform_generic_arg(self, a: *Types::ChainType::GenericArg) {
        if a->ty != &null {
            a->ty = self.dyn()->transform_type(a->ty)
        }
    }

    fn transform_type(self, t: unsafe *Type) -> unsafe *Type {
        if t == &null {
            return &null
        }

        if self.stop {
            return t
        }

        match t->kind {
            case TypeKind::MapType {
                return self.dyn()->transform_map_type(cast<Types::MapType>(t))
            } case TypeKind::SetType {
                return self.dyn()->transform_set_type(cast<Types::SetType>(t))
            } case TypeKind::SelfType {
                return self.dyn()->transform_self_type(cast<Types::SelfType>(t))
            } case TypeKind::TypeExpr {
                return self.dyn()->transform_type_expr(cast<Types::TypeExpr>(t))
            } case TypeKind::TupleType {
                return self.dyn()->transform_tuple_type(cast<Types::TupleType>(t))
            } case TypeKind::ChainType {
                return self.dyn()->transform_chain_type(cast<Types::ChainType>(t))
            } case TypeKind::VectorType {
                return self.dyn()->transform_vector_type(cast<Types::VectorType>(t))
            } case TypeKind::PointerType {
                return self.dyn()->transform_pointer_type(cast<Types::PointerType>(t))
            } case TypeKind::TypeOfType {
                return self.dyn()->transform_type_of_type(cast<Types::TypeOfType>(t))
            } case TypeKind::InferredType {
                return self.dyn()->transform_inferred_type(cast<Types::InferredType>(t))
            } case TypeKind::NullableType {
                return self.dyn()->transform_nullable_type(cast<Types::NullableType>(t))
            } case TypeKind::OpaqueFFIType {
                return self.dyn()->transform_opaque_ffi_type(cast<Types::OpaqueFFIType>(t))
            } case TypeKind::QualifiedType { // canonical and interned: never rewritten in place.
                return t
            } case TypeKind::FixedArrayType {
                return self.dyn()->transform_fixed_array_type(cast<Types::FixedArrayType>(t))
            } case TypeKind::VariadicPackType {
                return self.dyn()->transform_variadic_pack_type(cast<Types::VariadicPackType>(t))
            } case TypeKind::GenericParamType {
                return self.dyn()->transform_generic_param_type(cast<Types::GenericParamType>(t))
            } case TypeKind::PackExpansionType {
                return self.dyn()->transform_pack_expansion_type(cast<Types::PackExpansionType>(t))
            } case TypeKind::CXXLValueRefType {
                return self.dyn()->transform_cxxl_value_ref_type(cast<Types::CXXLValueRefType>(t))
            } case TypeKind::CXXRValueRefType {
                return self.dyn()->transform_cxxr_value_ref_type(cast<Types::CXXRValueRefType>(t))
            } case TypeKind::FunctionPointerType {
                return self.dyn()->transform_function_pointer_type(
                    cast<Types::FunctionPointerType>(t),
                )
            } case TypeKind::SubstGenericParamType {
                return self.dyn()->transform_subst_generic_param_type(
                    cast<Types::SubstGenericParamType>(t),
                )
            } case TypeKind::AssocType { // canonical and interned.
                return t
            } case TypeKind::RecoveryType {
                return t
            } case TypeKind::TypeKindCount {
                kairo::std::ice_fail("TypeKindCount reached ASTWriter - bug")
            } default { } // a C++ switch without the record / builtin cases falls out to `return t`.
        }

        return t
    }

    /// # transform bodies (default: recurse children, return node)

    fn transform_map_type(self, n: *Types::MapType) -> *Type {
        n->key   = self.dyn()->transform_type(n->key)
        n->value = self.dyn()->transform_type(n->value)
        return n
    }

    fn transform_set_type(self, n: *Types::SetType) -> *Type {
        n->element = self.dyn()->transform_type(n->element)
        return n
    }

    fn transform_self_type(self, n: *Types::SelfType) -> *Type {
        return n
    }

    fn transform_type_expr(self, n: *Types::TypeExpr) -> *Type {
        // n->expr is an *Expr child. A pass that lowers a type-level expression
        // to a concrete type rewrites HERE: it may inspect n->expr and return a
        // different *Type entirely (cross-family: the *Expr is consumed, a
        // *Type is produced). Default keeps the wrapper, transforms the child.
        if n->expr != &null {
            n->expr = self.dyn()->transform_expr(n->expr)
        }

        return n
    }

    fn transform_tuple_type(self, n: *Types::TupleType) -> *Type {
        self.dyn()->rebuild_type_list(&n->elements)
        return n
    }

    fn transform_chain_type(self, n: *Types::ChainType) -> *Type {
        for var i: usize = 0; i < n->segments.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *seg = n->segments.get(i)
            for var j: usize = 0; j < seg->generic_args.size(); j++ {
                if self.stop {
                    break
                }

                self.dyn()->transform_generic_arg(seg->generic_args.get(j))
            }
        }

        return n
    }

    fn transform_vector_type(self, n: *Types::VectorType) -> *Type {
        n->element = self.dyn()->transform_type(n->element)
        return n
    }

    fn transform_pointer_type(self, n: *Types::PointerType) -> *Type {
        n->pointee = self.dyn()->transform_type(n->pointee)
        return n
    }

    fn transform_type_of_type(self, n: *Types::TypeOfType) -> *Type {
        if n->expr != &null {
            n->expr = self.dyn()->transform_expr(n->expr)
        }

        return n
    }

    fn transform_inferred_type(self, n: *Types::InferredType) -> *Type {
        return n
    }

    fn transform_nullable_type(self, n: *Types::NullableType) -> *Type {
        n->inner = self.dyn()->transform_type(n->inner)
        return n
    }

    fn transform_opaque_ffi_type(self, n: *Types::OpaqueFFIType) -> *Type {
        return n
    }

    fn transform_fixed_array_type(self, n: *Types::FixedArrayType) -> *Type {
        n->element = self.dyn()->transform_type(n->element)
        if n->size_expr != &null {
            n->size_expr = self.dyn()->transform_expr(n->size_expr)
        }

        return n
    }

    fn transform_variadic_pack_type(self, n: *Types::VariadicPackType) -> *Type {
        return n // param is a decl back-ref, not a child.
    }

    fn transform_generic_param_type(self, n: *Types::GenericParamType) -> *Type {
        return n // param_name is a decl back-ref.
    }

    fn transform_pack_expansion_type(self, n: *Types::PackExpansionType) -> *Type {
        n->pattern = self.dyn()->transform_type(n->pattern)
        return n
    }

    fn transform_cxxl_value_ref_type(self, n: *Types::CXXLValueRefType) -> *Type {
        n->referee = self.dyn()->transform_type(n->referee)
        return n
    }

    fn transform_cxxr_value_ref_type(self, n: *Types::CXXRValueRefType) -> *Type {
        n->referee = self.dyn()->transform_type(n->referee)
        return n
    }

    /// `params` and `modes` are parallel (FunctionPointerType::modes), and a
    /// transform that returns null DROPS its param -- so the two rebuild in
    /// one loop here, not through rebuild_type_list, or a dropped param would
    /// shift every later mode onto the wrong parameter.
    fn transform_function_pointer_type(self, n: *Types::FunctionPointerType) -> *Type {
        // Scratch, copied by from_list (see rebuild_stmt_list).
        var ps = ArenaList<unsafe *Type>()
        var ms = ArenaList<ParamMode>()
        for var i: usize = 0; i < n->params.size(); i++ {
            var m = if (i < n->modes.size()) => (n->modes[i]) else => ParamMode::Value
            if self.stop {
                ps.push(n->params[i])
                ms.push(m)
                continue
            }

            var r = self.dyn()->transform_type(n->params[i])
            if r != &null {
                ps.push(r)
                ms.push(m)
            }
        }

        n->params.from_list(&ps, unsafe &self.ctx->ast_alloc)
        n->modes.from_list(&ms, unsafe &self.ctx->ast_alloc)
        if n->modes.size() != n->params.size() {
            kairo::std::ice_fail(
                "ASTWriter: FunctionPointerType::modes not parallel to params after rebuild",
            )
        }

        if n->return_type != &null {
            n->return_type = self.dyn()->transform_type(n->return_type)
        }

        self.dyn()->rebuild_type_list(&n->panic_set)
        return n
    }

    fn transform_subst_generic_param_type(self, n: *Types::SubstGenericParamType) -> *Type {
        n->replacement = self.dyn()->transform_type(n->replacement)
        return n
    }

    pub fn transform_expr(self, e: unsafe *Expr) -> unsafe *Expr {
        if e == &null {
            return &null
        }

        if self.stop {
            return e
        }

        match e->kind {
            case ExprKind::IntegerLiteralExpr {
                return self.dyn()->transform_integer_literal_expr(cast<IntegerLiteralExpr>(e))
            } case ExprKind::FloatingLiteralExpr {
                return self.dyn()->transform_floating_literal_expr(cast<FloatingLiteralExpr>(e))
            } case ExprKind::StringLiteralExpr {
                return self.dyn()->transform_string_literal_expr(cast<StringLiteralExpr>(e))
            } case ExprKind::CharacterLiteralExpr {
                return self.dyn()->transform_character_literal_expr(cast<CharacterLiteralExpr>(e))
            } case ExprKind::BooleanLiteralExpr {
                return self.dyn()->transform_boolean_literal_expr(cast<BooleanLiteralExpr>(e))
            } case ExprKind::NullLiteralExpr {
                return self.dyn()->transform_null_literal_expr(cast<NullLiteralExpr>(e))
            } case ExprKind::ListLiteralExpr {
                return self.dyn()->transform_list_literal_expr(
                    cast<Expressions::ListLiteralExpr>(e),
                )
            } case ExprKind::TupleLiteralExpr {
                return self.dyn()->transform_tuple_literal_expr(
                    cast<Expressions::TupleLiteralExpr>(e),
                )
            } case ExprKind::SetLiteralExpr {
                return self.dyn()->transform_set_literal_expr(cast<Expressions::SetLiteralExpr>(e))
            } case ExprKind::MapLiteralExpr {
                return self.dyn()->transform_map_literal_expr(cast<Expressions::MapLiteralExpr>(e))
            } case ExprKind::NamedInitializerExpr {
                return self.dyn()->transform_named_initializer_expr(
                    cast<Expressions::NamedInitializerExpr>(e),
                )
            } case ExprKind::AnonInitializerExpr {
                return self.dyn()->transform_anon_initializer_expr(
                    cast<Expressions::AnonInitializerExpr>(e),
                )
            } case ExprKind::ChainExpr {
                return self.dyn()->transform_chain_expr(cast<ChainExpr>(e))
            } case ExprKind::CallExpr {
                return self.dyn()->transform_call_expr(cast<Expressions::CallExpr>(e))
            } case ExprKind::SubscriptExpr {
                return self.dyn()->transform_subscript_expr(cast<Expressions::SubscriptExpr>(e))
            } case ExprKind::NamedIdentExpr {
                return self.dyn()->transform_named_ident_expr(cast<NamedIdentExpr>(e))
            } case ExprKind::UnaryOperatorExpr {
                return self.dyn()->transform_unary_operator_expr(
                    cast<Expressions::UnaryOperatorExpr>(e),
                )
            } case ExprKind::BinaryOperatorExpr {
                return self.dyn()->transform_binary_operator_expr(
                    cast<Expressions::BinaryOperatorExpr>(e),
                )
            } case ExprKind::AssignOperatorExpr {
                return self.dyn()->transform_assign_operator_expr(
                    cast<Expressions::AssignOperatorExpr>(e),
                )
            } case ExprKind::ImplConformanceExpr {
                return self.dyn()->transform_impl_conformance_expr(
                    cast<Expressions::ImplConformanceExpr>(e),
                )
            } case ExprKind::DerivesRelationExpr {
                return self.dyn()->transform_derives_relation_expr(
                    cast<Expressions::DerivesRelationExpr>(e),
                )
            } case ExprKind::IfExpr {
                return self.dyn()->transform_if_expr(cast<Expressions::IfExpr>(e))
            } case ExprKind::TryCatchExpr {
                return self.dyn()->transform_try_catch_expr(cast<Expressions::TryCatchExpr>(e))
            } case ExprKind::MatchExpr {
                return self.dyn()->transform_match_expr(cast<Expressions::MatchExpr>(e))
            } case ExprKind::RangeExpr {
                return self.dyn()->transform_range_expr(cast<Expressions::RangeExpr>(e))
            } case ExprKind::ClosureExpr {
                return self.dyn()->transform_closure_expr(cast<Expressions::ClosureExpr>(e))
            } case ExprKind::AwaitExpr {
                return self.dyn()->transform_await_expr(cast<Expressions::AwaitExpr>(e))
            } case ExprKind::UnwrapExpr {
                return self.dyn()->transform_unwrap_expr(cast<Expressions::UnwrapExpr>(e))
            } case ExprKind::DefinedExpr {
                return self.dyn()->transform_defined_expr(cast<Expressions::DefinedExpr>(e))
            } case ExprKind::AttributedExpr {
                return self.dyn()->transform_attributed_expr(cast<Expressions::AttributedExpr>(e))
            } case ExprKind::PanicOpExpr {
                return self.dyn()->transform_panic_op_expr(cast<Expressions::PanicOpExpr>(e))
            } case ExprKind::TypeTraitExpr {
                return self.dyn()->transform_type_trait_expr(cast<Expressions::TypeTraitExpr>(e))
            } case ExprKind::CxxNewExpr {
                return self.dyn()->transform_cxx_new_expr(cast<Expressions::CxxNewExpr>(e))
            } case ExprKind::SpawnExpr {
                return self.dyn()->transform_spawn_expr(cast<Expressions::SpawnExpr>(e))
            } case ExprKind::ThreadExpr {
                return self.dyn()->transform_thread_expr(cast<Expressions::ThreadExpr>(e))
            } case ExprKind::ConstraintExpr {
                return self.dyn()->transform_constraint_expr(cast<Expressions::ConstraintExpr>(e))
            } case ExprKind::SizeOfExpr {
                return self.dyn()->transform_size_of_expr(cast<Expressions::SizeOfExpr>(e))
            } case ExprKind::AlignOfExpr {
                return self.dyn()->transform_align_of_expr(cast<Expressions::AlignOfExpr>(e))
            } case ExprKind::TypeOfExpr {
                return self.dyn()->transform_type_of_expr(cast<Expressions::TypeOfExpr>(e))
            } case ExprKind::EvalExpr {
                return self.dyn()->transform_eval_expr(cast<Expressions::EvalExpr>(e))
            } case ExprKind::UnsafeExpr {
                return self.dyn()->transform_unsafe_expr(cast<Expressions::UnsafeExpr>(e))
            } case ExprKind::DeleteExpr {
                return self.dyn()->transform_delete_expr(cast<Expressions::DeleteExpr>(e))
            } case ExprKind::PackExpansionExpr {
                return self.dyn()->transform_pack_expansion_expr(
                    cast<Expressions::PackExpansionExpr>(e),
                )
            } case ExprKind::TypeCastExpr {
                return self.dyn()->transform_type_cast_expr(cast<Expressions::TypeCastExpr>(e))
            } case ExprKind::ImplicitBoundaryCastExpr {
                return self.dyn()->transform_implicit_boundary_cast_expr(
                    cast<Expressions::ImplicitBoundaryCastExpr>(e),
                )
            } case ExprKind::ParenExpr {
                return self.dyn()->transform_paren_expr(cast<Expressions::ParenExpr>(e))
            } case ExprKind::VerbatimExpr {
                return self.dyn()->transform_verbatim_expr(cast<Expressions::VerbatimExpr>(e))
            } case ExprKind::NamedArgExpr {
                return self.dyn()->transform_named_arg_expr(cast<Expressions::NamedArgExpr>(e))
            } case ExprKind::InitListExpr {
                return self.dyn()->transform_init_list_expr(cast<Expressions::InitListExpr>(e))
            } case ExprKind::StmtExpr {
                return self.dyn()->transform_stmt_expr(cast<Expressions::StmtExpr>(e))
            } case ExprKind::VariantInitExpr {
                return self.dyn()->transform_variant_init_expr(
                    cast<Expressions::VariantInitExpr>(e),
                )
            } case ExprKind::RecoveryExpr {
                return e
            } case ExprKind::ExprKindCount {
                kairo::std::ice_fail("ExprKindCount reached ASTWriter - bug")
            }
        }
    }

    /// # leaf literals: no children

    fn transform_integer_literal_expr(self, n: *IntegerLiteralExpr) -> *Expr {
        return n
    }

    fn transform_floating_literal_expr(self, n: *FloatingLiteralExpr) -> *Expr {
        return n
    }

    fn transform_character_literal_expr(self, n: *CharacterLiteralExpr) -> *Expr {
        return n
    }

    fn transform_boolean_literal_expr(self, n: *BooleanLiteralExpr) -> *Expr {
        return n
    }

    fn transform_null_literal_expr(self, n: *NullLiteralExpr) -> *Expr {
        return n
    }

    fn transform_string_literal_expr(self, n: unsafe *StringLiteralExpr) -> unsafe *Expr {
        self.dyn()->rebuild_expr_list(&n->parts) // f"" interpolation exprs
        return n
    }

    fn transform_list_literal_expr(self, n: unsafe *Expressions::ListLiteralExpr) -> unsafe *Expr {
        self.dyn()->rebuild_expr_list(&n->elements)
        return n
    }

    fn transform_init_list_expr(self, n: *Expressions::InitListExpr) -> *Expr {
        self.dyn()->rebuild_expr_list(&n->elements)
        return n
    }

    fn transform_stmt_expr(self, n: *Expressions::StmtExpr) -> *Expr {
        if n->body != &null {
            n->body = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body))
        }

        return n
    }

    // `source_order` is parallel to `fields`: a field may be rewritten, never
    // dropped.
    fn transform_variant_init_expr(self, n: unsafe *Expressions::VariantInitExpr) -> unsafe *Expr {
        self.dyn()->rebuild_expr_list(&n->fields)
        if n->fields.size() != n->source_order.size() {
            kairo::std::ice_fail(
                "ASTWriter: VariantInitExpr::fields not parallel to source_order after rebuild",
            )
        }

        return n
    }

    fn transform_tuple_literal_expr(self,
                                    n: unsafe *Expressions::TupleLiteralExpr) -> unsafe *Expr {
        self.dyn()->rebuild_expr_list(&n->elements)
        return n
    }

    fn transform_set_literal_expr(self, n: unsafe *Expressions::SetLiteralExpr) -> unsafe *Expr {
        self.dyn()->rebuild_expr_list(&n->elements)
        return n
    }

    fn transform_map_literal_expr(self, n: unsafe *Expressions::MapLiteralExpr) -> unsafe *Expr {
        for var i: usize = 0; i < n->entries.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *en = n->entries.get(i)
            en->key   = self.dyn()->transform_expr(en->key)
            en->value = self.dyn()->transform_expr(en->value)
        }

        return n
    }

    fn transform_named_initializer_expr(self,
                                        n: unsafe *Expressions::NamedInitializerExpr) -> unsafe *Expr {
        if n->type_expr != &null {
            n->type_expr = self.dyn()->transform_expr(n->type_expr)
        }

        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *f = n->fields.get(i)
            if f->value != &null {
                f->value = self.dyn()->transform_expr(f->value)
            }
        }

        return n
    }

    fn transform_anon_initializer_expr(self, n: *Expressions::AnonInitializerExpr) -> *Expr {
        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *f = n->fields.get(i)
            if f->value != &null {
                f->value = self.dyn()->transform_expr(f->value)
            }
        }

        return n
    }

    fn transform_chain_expr(self, n: unsafe *ChainExpr) -> unsafe *Expr {
        if n->base != &null {
            n->base = self.dyn()->transform_expr(n->base)
        }

        for var i: usize = 0; i < n->steps.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *st = n->steps.get(i)
            for var j: usize = 0; j < st->generic_args.size(); j++ {
                if self.stop {
                    break
                }

                self.dyn()->transform_generic_arg(st->generic_args.get(j))
            }
        }

        return n
    }

    fn transform_call_expr(self, n: unsafe *Expressions::CallExpr) -> unsafe *Expr {
        if n->callee != &null {
            n->callee = self.dyn()->transform_expr(n->callee)
        }

        self.dyn()->rebuild_expr_list(&n->args)
        return n
    }

    fn transform_subscript_expr(self, n: unsafe *Expressions::SubscriptExpr) -> unsafe *Expr {
        if n->base != &null {
            n->base = self.dyn()->transform_expr(n->base)
        }

        if n->index != &null {
            n->index = self.dyn()->transform_expr(n->index)
        }

        return n
    }

    fn transform_named_ident_expr(self, n: unsafe *NamedIdentExpr) -> unsafe *Expr {
        for var i: usize = 0; i < n->generic_args.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->transform_generic_arg(n->generic_args.get(i))
        }

        return n
    }

    fn transform_unary_operator_expr(self,
                                     n: unsafe *Expressions::UnaryOperatorExpr) -> unsafe *Expr {
        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        return n
    }

    fn transform_binary_operator_expr(self,
                                      n: unsafe *Expressions::BinaryOperatorExpr) -> unsafe *Expr {
        if n->lhs != &null {
            n->lhs = self.dyn()->transform_expr(n->lhs)
        }

        if n->rhs != &null {
            n->rhs = self.dyn()->transform_expr(n->rhs)
        }

        return n
    }

    fn transform_assign_operator_expr(self,
                                      n: unsafe *Expressions::AssignOperatorExpr) -> unsafe *Expr {
        if n->lhs != &null {
            n->lhs = self.dyn()->transform_expr(n->lhs)
        }

        if n->rhs != &null {
            n->rhs = self.dyn()->transform_expr(n->rhs)
        }

        return n
    }

    fn transform_impl_conformance_expr(self, n: *Expressions::ImplConformanceExpr) -> *Expr {
        if n->subject != &null {
            n->subject = self.dyn()->transform_type(n->subject)
        }

        if n->inter != &null {
            n->inter = self.dyn()->transform_type(n->inter)
        }

        return n
    }

    fn transform_derives_relation_expr(self, n: *Expressions::DerivesRelationExpr) -> *Expr {
        if n->subject != &null {
            n->subject = self.dyn()->transform_type(n->subject)
        }

        if n->base != &null {
            n->base = self.dyn()->transform_type(n->base)
        }

        return n
    }

    fn transform_if_expr(self, n: *Expressions::IfExpr) -> *Expr {
        if n->condition != &null {
            n->condition = self.dyn()->transform_expr(n->condition)
        }

        if n->then_expr != &null {
            n->then_expr = self.dyn()->transform_expr(n->then_expr)
        }

        for var i: usize = 0; i < n->else_ifs.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *arm = n->else_ifs.get(i)
            if arm->condition != &null {
                arm->condition = self.dyn()->transform_expr(arm->condition)
            }

            if arm->body != &null {
                arm->body = self.dyn()->transform_expr(arm->body)
            }
        }

        if n->else_expr != &null {
            n->else_expr = self.dyn()->transform_expr(n->else_expr)
        }

        return n
    }

    fn transform_try_catch_expr(self, n: *Expressions::TryCatchExpr) -> *Expr {
        if n->try_expr != &null {
            n->try_expr = self.dyn()->transform_expr(n->try_expr)
        }

        for var i: usize = 0; i < n->catch_arms.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *arm = n->catch_arms.get(i)
            if arm->filter != &null {
                arm->filter = self.dyn()->transform_type(arm->filter)
            }

            if arm->body != &null {
                arm->body = self.dyn()->transform_expr(arm->body)
            }
        }

        return n
    }

    fn transform_match_expr(self, n: unsafe *Expressions::MatchExpr) -> unsafe *Expr {
        if n->scrutinee != &null {
            n->scrutinee = self.dyn()->transform_expr(n->scrutinee)
        }

        for var i: usize = 0; i < n->cases.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->transform_match_case(n->cases.get(i))
        }

        return n
    }

    fn transform_range_expr(self, n: unsafe *Expressions::RangeExpr) -> unsafe *Expr {
        if n->begin != &null {
            n->begin = self.dyn()->transform_expr(n->begin)
        }

        if n->end != &null {
            n->end = self.dyn()->transform_expr(n->end)
        }

        return n
    }

    fn transform_closure_expr(self, n: unsafe *Expressions::ClosureExpr) -> unsafe *Expr {
        self.dyn()->rebuild_decl_list(unsafe ((&n->generic_params) as unsafe *FrozenList<*Decl>))
        self.dyn()->rebuild_decl_list(unsafe ((&n->params) as unsafe *FrozenList<*Decl>))
        for var i: usize = 0; i < n->captures.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *cap = n->captures.get(i)
            if cap->name != &null {
                cap->name = cast<NamedIdentExpr>(self.dyn()->transform_expr(cap->name))
            }
        }

        self.dyn()->rebuild_type_list(&n->panic_set)
        if n->return_type != &null {
            n->return_type = self.dyn()->transform_type(n->return_type)
        }

        if n->body_block != &null {
            n->body_block = cast<Statements::CompoundStmt>(
                self.dyn()->transform_stmt_scalar(n->body_block),
            )
        }

        if n->body_expr != &null {
            n->body_expr = self.dyn()->transform_expr(n->body_expr)
        }

        return n
    }

    fn transform_await_expr(self, n: *Expressions::AwaitExpr) -> *Expr {
        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        return n
    }

    fn transform_defined_expr(self, n: *Expressions::DefinedExpr) -> *Expr {
        return n
    }

    fn transform_type_trait_expr(self, n: *Expressions::TypeTraitExpr) -> *Expr {
        if n->type_arg != &null {
            n->type_arg = self.dyn()->transform_type(n->type_arg)
        }

        return n
    }

    fn transform_cxx_new_expr(self, n: *Expressions::CxxNewExpr) -> *Expr {
        if n->init != &null {
            n->init = self.dyn()->transform_expr(n->init)
        }

        if n->elem_size != &null {
            n->elem_size = self.dyn()->transform_expr(n->elem_size)
        }

        if n->count != &null {
            n->count = self.dyn()->transform_expr(n->count)
        }

        return n
    }

    fn transform_unwrap_expr(self, n: unsafe *Expressions::UnwrapExpr) -> unsafe *Expr {
        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        return n
    }

    fn transform_attributed_expr(self, n: unsafe *Expressions::AttributedExpr) -> unsafe *Expr {
        self.dyn()->rebuild_expr_list(&n->args)
        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        return n
    }

    fn transform_panic_op_expr(self, n: *Expressions::PanicOpExpr) -> *Expr {
        if n->slot != &null {
            n->slot = self.dyn()->transform_expr(n->slot)
        }

        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        return n
    }

    fn transform_spawn_expr(self, n: *Expressions::SpawnExpr) -> *Expr {
        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        return n
    }

    fn transform_thread_expr(self, n: *Expressions::ThreadExpr) -> *Expr {
        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        return n
    }

    fn transform_constraint_expr(self, n: *Expressions::ConstraintExpr) -> *Expr {
        if n->lhs != &null {
            n->lhs = self.dyn()->transform_expr(n->lhs)
        }

        if n->rhs != &null {
            n->rhs = self.dyn()->transform_type(n->rhs)
        }

        return n
    }

    fn transform_size_of_expr(self, n: *Expressions::SizeOfExpr) -> *Expr {
        // CROSS-FAMILY SITE: when the parser saw `sizeof expr` but the operand
        // resolves to a type, a sema pass converts n->operand (*Expr) into a
        // *Type and moves it to n->type_arg, then nulls n->operand. Both slots
        // live on THIS node, so the *Expr return contract is preserved.
        if n->type_arg != &null {
            n->type_arg = self.dyn()->transform_type(n->type_arg)
        }

        return n
    }

    fn transform_align_of_expr(self, n: *Expressions::AlignOfExpr) -> *Expr {
        if n->type_arg != &null {
            n->type_arg = self.dyn()->transform_type(n->type_arg)
        }

        return n
    }

    fn transform_type_of_expr(self, n: *Expressions::TypeOfExpr) -> *Expr {
        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        return n
    }

    fn transform_eval_expr(self, n: *Expressions::EvalExpr) -> *Expr {
        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        return n
    }

    fn transform_paren_expr(self, n: *Expressions::ParenExpr) -> *Expr {
        if n->inner != &null {
            n->inner = self.dyn()->transform_expr(n->inner)
        }

        return n
    }

    /// The value is rewritten; the label is not a node, so there is nothing
    /// to rewrite about the name.
    fn transform_named_arg_expr(self, n: *Expressions::NamedArgExpr) -> *Expr {
        if n->value != &null {
            n->value = self.dyn()->transform_expr(n->value)
        }

        return n
    }

    /// Opaque by construction: a VerbatimExpr is an unparsed source span, so
    /// there is nothing inside for a rewrite pass to reach. Returned unchanged.
    /// A lowering that wants to REPLACE it must do so from the parent.
    fn transform_verbatim_expr(self, n: *Expressions::VerbatimExpr) -> *Expr {
        return n
    }

    fn transform_unsafe_expr(self, n: *Expressions::UnsafeExpr) -> *Expr {
        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        return n
    }

    fn transform_delete_expr(self, n: *Expressions::DeleteExpr) -> *Expr {
        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        return n
    }

    fn transform_pack_expansion_expr(self, n: *Expressions::PackExpansionExpr) -> *Expr {
        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        return n
    }

    fn transform_type_cast_expr(self, n: unsafe *Expressions::TypeCastExpr) -> unsafe *Expr {
        if n->operand != &null {
            n->operand = self.dyn()->transform_expr(n->operand)
        }

        if n->target != &null {
            n->target = self.dyn()->transform_type(n->target)
        }

        return n
    }

    fn transform_implicit_boundary_cast_expr(self,
                                             n: *Expressions::ImplicitBoundaryCastExpr) -> *Expr {
        if n->original != &null {
            n->original = self.dyn()->transform_expr(n->original)
        }

        if n->source_type != &null {
            n->source_type = self.dyn()->transform_type(n->source_type)
        }

        if n->target_type != &null {
            n->target_type = self.dyn()->transform_type(n->target_type)
        }

        return n
    }

    fn transform_stmt(self, s: unsafe *Stmt) -> cxx::std::vector<unsafe *Stmt> {
        if s == &null {
            return cxx::std::vector<unsafe *Stmt>()
        }

        if self.stop {
            return self._one_stmt(s)
        }

        match s->kind {
            case StmtKind::CompoundStmt {
                return self.dyn()->transform_compound_stmt(cast<Statements::CompoundStmt>(s))
            } case StmtKind::ExpressionStmt {
                return self.dyn()->transform_expression_stmt(cast<Statements::ExpressionStmt>(s))
            } case StmtKind::DeclStmt {
                return self.dyn()->transform_decl_stmt(cast<Statements::DeclStmt>(s))
            } case StmtKind::ReturnStmt {
                return self.dyn()->transform_return_stmt(cast<Statements::ReturnStmt>(s))
            } case StmtKind::BreakStmt {
                return self.dyn()->transform_break_stmt(cast<Statements::BreakStmt>(s))
            } case StmtKind::ContinueStmt {
                return self.dyn()->transform_continue_stmt(cast<Statements::ContinueStmt>(s))
            } case StmtKind::PanicStmt {
                return self.dyn()->transform_panic_stmt(cast<Statements::PanicStmt>(s))
            } case StmtKind::YieldStmt {
                return self.dyn()->transform_yield_stmt(cast<Statements::YieldStmt>(s))
            } case StmtKind::RuntimeAssertStmt {
                return self.dyn()->transform_runtime_assert_stmt(
                    cast<Statements::RuntimeAssertStmt>(s),
                )
            } case StmtKind::StaticAssertStmt {
                return self.dyn()->transform_static_assert_stmt(
                    cast<Statements::StaticAssertStmt>(s),
                )
            } case StmtKind::LabelIntrinsicStmt {
                return self.dyn()->transform_label_intrinsic_stmt(
                    cast<Statements::LabelIntrinsicStmt>(s),
                )
            } case StmtKind::JumpIntrinsicStmt {
                return self.dyn()->transform_jump_intrinsic_stmt(
                    cast<Statements::JumpIntrinsicStmt>(s),
                )
            } case StmtKind::ConditionalStmt {
                return self.dyn()->transform_conditional_stmt(cast<Statements::ConditionalStmt>(s))
            } case StmtKind::WhileLoopStmt {
                return self.dyn()->transform_while_loop_stmt(cast<Statements::WhileLoopStmt>(s))
            } case StmtKind::LoopStmt {
                return self.dyn()->transform_loop_stmt(cast<Statements::LoopStmt>(s))
            } case StmtKind::RangedForStmt {
                return self.dyn()->transform_ranged_for_stmt(cast<Statements::RangedForStmt>(s))
            } case StmtKind::IndexedForStmt {
                return self.dyn()->transform_indexed_for_stmt(cast<Statements::IndexedForStmt>(s))
            } case StmtKind::MatchStmt {
                return self.dyn()->transform_match_stmt(cast<Statements::MatchStmt>(s))
            } case StmtKind::LabeledStmt {
                return self.dyn()->transform_labeled_stmt(cast<Statements::LabeledStmt>(s))
            } case StmtKind::TryCatchStmt {
                return self.dyn()->transform_try_catch_stmt(cast<Statements::TryCatchStmt>(s))
            } case StmtKind::FinallyStmt {
                return self.dyn()->transform_finally_stmt(cast<Statements::FinallyStmt>(s))
            } case StmtKind::UnsafeBlockStmt {
                return self.dyn()->transform_unsafe_block_stmt(cast<Statements::UnsafeBlockStmt>(s))
            } case StmtKind::ContextBindingStmt {
                return self.dyn()->transform_context_binding_stmt(
                    cast<Statements::ContextBindingStmt>(s),
                )
            } case StmtKind::DestructuringDeclStmt {
                return self.dyn()->transform_destructuring_decl_stmt(
                    cast<Statements::DestructuringDeclStmt>(s),
                )
            } case StmtKind::InlineBlockStmt {
                return self.dyn()->transform_inline_block_stmt(cast<Statements::InlineBlockStmt>(s))
            } case StmtKind::EvalBlockStmt {
                return self.dyn()->transform_eval_block_stmt(cast<Statements::EvalBlockStmt>(s))
            } case StmtKind::SwitchDispatchStmt {
                return self.dyn()->transform_switch_dispatch_stmt(
                    cast<Statements::SwitchDispatchStmt>(s),
                )
            } case StmtKind::RecoveryStmt {
                return self._one_stmt(s)
            } case StmtKind::StmtKindCount {
                kairo::std::ice_fail("StmtKindCount reached ASTWriter - bug")
            }
        }
    }

    fn transform_compound_stmt(self,
                               n: unsafe *Statements::CompoundStmt) -> cxx::std::vector<unsafe *Stmt> {
        self.dyn()->rebuild_stmt_list(&n->body)
        return self._one_stmt(n)
    }

    fn transform_expression_stmt(self,
                                 n: unsafe *Statements::ExpressionStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->expr != &null {
            n->expr = self.dyn()->transform_expr(n->expr)
        }

        return self._one_stmt(n)
    }

    fn transform_decl_stmt(self,
                           n: unsafe *Statements::DeclStmt) -> cxx::std::vector<unsafe *Stmt> {
        // A single decl can splice into several decls. If that happens, the
        // surrounding stmt list must gain several DeclStmt wrappers so a
        // multi-decl result fans out into multiple DeclStmts here.
        if n->decl == &null {
            return self._one_stmt(n)
        }

        var decls = self.dyn()->transform_decl(n->decl)
        if decls.size() == 1 {
            n->decl = decls[0]
            return self._one_stmt(n)
        }

        var out = cxx::std::vector<unsafe *Stmt>()
        for var i: usize = 0; i < decls.size(); i++ {
            var wrapper = Statements::DeclStmt::create(self.ctx, n->range, decls[i])
            out.push_back(wrapper)
        }

        return out
    }

    fn transform_return_stmt(self,
                             n: unsafe *Statements::ReturnStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->value != &null {
            n->value = self.dyn()->transform_expr(n->value)
        }

        return self._one_stmt(n)
    }

    fn transform_break_stmt(self,
                            n: unsafe *Statements::BreakStmt) -> cxx::std::vector<unsafe *Stmt> {
        return self._one_stmt(n)
    }

    fn transform_continue_stmt(self,
                               n: unsafe *Statements::ContinueStmt) -> cxx::std::vector<unsafe *Stmt> {
        return self._one_stmt(n)
    }

    fn transform_panic_stmt(self,
                            n: unsafe *Statements::PanicStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->payload != &null {
            n->payload = self.dyn()->transform_expr(n->payload)
        }

        return self._one_stmt(n)
    }

    fn transform_yield_stmt(self,
                            n: unsafe *Statements::YieldStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->value != &null {
            n->value = self.dyn()->transform_expr(n->value)
        }

        return self._one_stmt(n)
    }

    fn transform_runtime_assert_stmt(self,
                                     n: unsafe *Statements::RuntimeAssertStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->condition != &null {
            n->condition = self.dyn()->transform_expr(n->condition)
        }

        if n->message != &null {
            n->message = self.dyn()->transform_expr(n->message)
        }

        return self._one_stmt(n)
    }

    fn transform_static_assert_stmt(self,
                                    n: unsafe *Statements::StaticAssertStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->condition != &null {
            n->condition = self.dyn()->transform_expr(n->condition)
        }

        if n->message != &null {
            n->message = self.dyn()->transform_expr(n->message)
        }

        return self._one_stmt(n)
    }

    fn transform_label_intrinsic_stmt(self,
                                      n: unsafe *Statements::LabelIntrinsicStmt) -> cxx::std::vector<unsafe *Stmt> {
        return self._one_stmt(n)
    }

    fn transform_jump_intrinsic_stmt(self,
                                     n: unsafe *Statements::JumpIntrinsicStmt) -> cxx::std::vector<unsafe *Stmt> {
        return self._one_stmt(n)
    }

    fn transform_switch_dispatch_stmt(self,
                                      n: unsafe *Statements::SwitchDispatchStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->value != &null {
            n->value = self.dyn()->transform_expr(n->value)
        }

        for var i: usize = 0; i < n->cases.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *c = n->cases.get(i)
            if c->lo != &null {
                c->lo = self.dyn()->transform_expr(c->lo)
            }

            if c->hi != &null {
                c->hi = self.dyn()->transform_expr(c->hi)
            }
        }

        if n->default_stmt != &null {
            n->default_stmt = self.dyn()->transform_stmt_scalar(n->default_stmt)
        }

        return self._one_stmt(n)
    }

    fn transform_conditional_stmt(self,
                                  n: unsafe *Statements::ConditionalStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->cond != &null {
            n->cond = self.dyn()->transform_expr(n->cond)
        }

        n->then_ = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(n->then_))
        if n->else_ != &null {
            n->else_ = self.dyn()->transform_stmt_scalar(n->else_)
        }

        return self._one_stmt(n)
    }

    fn transform_while_loop_stmt(self,
                                 n: unsafe *Statements::WhileLoopStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->cond != &null {
            n->cond = self.dyn()->transform_expr(n->cond)
        }

        n->body = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body))
        return self._one_stmt(n)
    }

    fn transform_loop_stmt(self,
                           n: unsafe *Statements::LoopStmt) -> cxx::std::vector<unsafe *Stmt> {
        n->body = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body))
        return self._one_stmt(n)
    }

    fn transform_ranged_for_stmt(self,
                                 n: unsafe *Statements::RangedForStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->iterable != &null {
            n->iterable = self.dyn()->transform_expr(n->iterable)
        }

        n->body = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body))
        return self._one_stmt(n)
    }

    fn transform_indexed_for_stmt(self,
                                  n: unsafe *Statements::IndexedForStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->init != &null {
            n->init = self.dyn()->transform_stmt_scalar(n->init)
        }

        if n->cond != &null {
            n->cond = self.dyn()->transform_expr(n->cond)
        }

        if n->update != &null {
            n->update = self.dyn()->transform_expr(n->update)
        }

        n->body = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body))
        return self._one_stmt(n)
    }

    fn transform_match_stmt(self,
                            n: unsafe *Statements::MatchStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->scrutinee != &null {
            n->scrutinee = self.dyn()->transform_expr(n->scrutinee)
        }

        for var i: usize = 0; i < n->cases.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->transform_match_case(n->cases.get(i))
        }

        return self._one_stmt(n)
    }

    fn transform_labeled_stmt(self,
                              n: unsafe *Statements::LabeledStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->inner != &null {
            n->inner = self.dyn()->transform_stmt_scalar(n->inner)
        }

        return self._one_stmt(n)
    }

    fn transform_try_catch_stmt(self,
                                n: unsafe *Statements::TryCatchStmt) -> cxx::std::vector<unsafe *Stmt> {
        n->try_body = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(n->try_body))
        for var i: usize = 0; i < n->arms.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *arm = n->arms.get(i)
            if arm->filter != &null {
                arm->filter = self.dyn()->transform_type(arm->filter)
            }

            if arm->body != &null {
                arm->body = cast<Statements::CompoundStmt>(
                    self.dyn()->transform_stmt_scalar(arm->body),
                )
            }
        }

        return self._one_stmt(n)
    }

    fn transform_finally_stmt(self,
                              n: unsafe *Statements::FinallyStmt) -> cxx::std::vector<unsafe *Stmt> {
        n->body = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body))
        return self._one_stmt(n)
    }

    fn transform_unsafe_block_stmt(self,
                                   n: unsafe *Statements::UnsafeBlockStmt) -> cxx::std::vector<unsafe *Stmt> {
        n->body = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body))
        return self._one_stmt(n)
    }

    fn transform_context_binding_stmt(self,
                                      n: unsafe *Statements::ContextBindingStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->value != &null {
            n->value = self.dyn()->transform_expr(n->value)
        }

        n->body = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body))
        return self._one_stmt(n)
    }

    fn transform_destructuring_decl_stmt(self,
                                         n: unsafe *Statements::DestructuringDeclStmt) -> cxx::std::vector<unsafe *Stmt> {
        if n->value != &null {
            n->value = self.dyn()->transform_expr(n->value)
        }

        return self._one_stmt(n)
    }

    fn transform_inline_block_stmt(self,
                                   n: unsafe *Statements::InlineBlockStmt) -> cxx::std::vector<unsafe *Stmt> {
        return self._one_stmt(n) // opaque foreign body.
    }

    fn transform_eval_block_stmt(self,
                                 n: unsafe *Statements::EvalBlockStmt) -> cxx::std::vector<unsafe *Stmt> {
        self.dyn()->rebuild_decl_list(&n->body)
        return self._one_stmt(n)
    }

    fn transform_decl(self, d: unsafe *Decl) -> cxx::std::vector<unsafe *Decl> {
        if d == &null {
            return cxx::std::vector<unsafe *Decl>()
        }

        if self.stop {
            return self._one_decl(d)
        }

        match d->kind {
            case DeclKind::FunctionDecl {
                return self.dyn()->transform_function_decl(cast<Declarations::FunctionDecl>(d))
            } case DeclKind::VariableDecl {
                return self.dyn()->transform_variable_decl(cast<Declarations::VariableDecl>(d))
            } case DeclKind::FieldDecl {
                return self.dyn()->transform_field_decl(cast<Declarations::FieldDecl>(d))
            } case DeclKind::ParamDecl {
                return self.dyn()->transform_param_decl(cast<Declarations::ParamDecl>(d))
            } case DeclKind::GenericParamDecl {
                return self.dyn()->transform_generic_param_decl(
                    cast<Declarations::GenericParamDecl>(d),
                )
            } case DeclKind::StructDecl {
                return self.dyn()->transform_struct_decl(cast<Declarations::StructDecl>(d))
            } case DeclKind::ClassDecl {
                return self.dyn()->transform_class_decl(cast<Declarations::ClassDecl>(d))
            } case DeclKind::InterfaceDecl {
                return self.dyn()->transform_interface_decl(cast<Declarations::InterfaceDecl>(d))
            } case DeclKind::ExtensionDecl {
                return self.dyn()->transform_extension_decl(cast<Declarations::ExtensionDecl>(d))
            } case DeclKind::EnumDecl {
                return self.dyn()->transform_enum_decl(cast<Declarations::EnumDecl>(d))
            } case DeclKind::EnumVariantDecl {
                return self.dyn()->transform_enum_variant_decl(
                    cast<Declarations::EnumVariantDecl>(d),
                )
            } case DeclKind::UnionDecl {
                return self.dyn()->transform_union_decl(cast<Declarations::UnionDecl>(d))
            } case DeclKind::TypeAliasDecl {
                return self.dyn()->transform_type_alias_decl(cast<Declarations::TypeAliasDecl>(d))
            } case DeclKind::ModuleDecl {
                return self.dyn()->transform_module_decl(cast<Declarations::ModuleDecl>(d))
            } case DeclKind::ImportDecl {
                return self.dyn()->transform_import_decl(cast<Declarations::ImportDecl>(d))
            } case DeclKind::VisibilityGroupDecl {
                return self.dyn()->transform_visibility_group_decl(
                    cast<Declarations::VisibilityGroupDecl>(d),
                )
            } case DeclKind::EvalBlockDecl {
                return self.dyn()->transform_eval_block_decl(cast<Declarations::EvalBlockDecl>(d))
            } case DeclKind::TestDecl {
                return self.dyn()->transform_test_decl(cast<Declarations::TestDecl>(d))
            } case DeclKind::MacroDecl {
                return self.dyn()->transform_macro_decl(cast<Declarations::MacroDecl>(d))
            } case DeclKind::ProcedureMacroDecl {
                return self.dyn()->transform_procedure_macro_decl(
                    cast<Declarations::ProcedureMacroDecl>(d),
                )
            } case DeclKind::FFIBlockDecl {
                return self.dyn()->transform_ffi_block_decl(cast<Declarations::FFIBlockDecl>(d))
            } case DeclKind::RecoveryDecl {
                return self._one_decl(d)
            } case DeclKind::DeclKindCount {
                kairo::std::ice_fail("DeclKindCount reached ASTWriter - bug")
            }
        }
    }

    fn transform_function_decl(self,
                               n: unsafe *Declarations::FunctionDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_decl_list(unsafe ((&n->generic_params) as unsafe *FrozenList<*Decl>))
        self.dyn()->rebuild_type_list(&n->spec_args) // specialization pattern (#68)
        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->transform_expr(n->requires_clause)
        }

        if n->where_clause != &null {
            n->where_clause = self.dyn()->transform_expr(n->where_clause)
        }

        self.dyn()->rebuild_decl_list(unsafe ((&n->params) as unsafe *FrozenList<*Decl>))
        self.dyn()->rebuild_type_list(&n->panic_set)
        if n->return_type != &null {
            n->return_type = self.dyn()->transform_type(n->return_type)
        }

        if n->qualifier != &null {
            n->qualifier = self.dyn()->transform_expr(n->qualifier)
        }

        if n->body_block != &null {
            n->body_block = cast<Statements::CompoundStmt>(
                self.dyn()->transform_stmt_scalar(n->body_block),
            )
        }

        if n->body_expr != &null {
            n->body_expr = self.dyn()->transform_expr(n->body_expr)
        }

        return self._one_decl(n)
    }

    fn transform_variable_decl(self,
                               n: unsafe *Declarations::VariableDecl) -> cxx::std::vector<unsafe *Decl> {
        if n->type_ != &null {
            n->type_ = self.dyn()->transform_type(n->type_)
        }

        if n->init != &null {
            n->init = self.dyn()->transform_expr(n->init)
        }

        return self._one_decl(n)
    }

    fn transform_field_decl(self,
                            n: unsafe *Declarations::FieldDecl) -> cxx::std::vector<unsafe *Decl> {
        if n->type_ != &null {
            n->type_ = self.dyn()->transform_type(n->type_)
        }

        if n->init != &null {
            n->init = self.dyn()->transform_expr(n->init)
        }

        return self._one_decl(n)
    }

    fn transform_param_decl(self,
                            n: unsafe *Declarations::ParamDecl) -> cxx::std::vector<unsafe *Decl> {
        if n->type_ != &null {
            n->type_ = self.dyn()->transform_type(n->type_)
        }

        if n->default_val != &null {
            n->default_val = self.dyn()->transform_expr(n->default_val)
        }

        return self._one_decl(n)
    }

    fn transform_generic_param_decl(self,
                                    n: unsafe *Declarations::GenericParamDecl) -> cxx::std::vector<unsafe *Decl> {
        for var i: usize = 0; i < n->impl_bounds.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->transform_inherit_edge(n->impl_bounds.get(i))
        }

        for var i: usize = 0; i < n->derives_bounds.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->transform_inherit_edge(n->derives_bounds.get(i))
        }

        if n->value_type != &null {
            n->value_type = self.dyn()->transform_type(n->value_type)
        }

        if n->default_type != &null {
            n->default_type = self.dyn()->transform_type(n->default_type)
        }

        return self._one_decl(n)
    }

    fn transform_struct_decl(self,
                             n: unsafe *Declarations::StructDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_decl_list(unsafe ((&n->generic_params) as unsafe *FrozenList<*Decl>))
        self.dyn()->rebuild_type_list(&n->spec_args) // specialization pattern (#68)
        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->transform_expr(n->requires_clause)
        }

        for var i: usize = 0; i < n->implements.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->transform_inherit_edge(n->implements.get(i))
        }

        self.dyn()->rebuild_decl_list(unsafe ((&n->fields) as unsafe *FrozenList<*Decl>))
        self.dyn()->rebuild_decl_list(unsafe ((&n->methods) as unsafe *FrozenList<*Decl>)) // ctors and operators; the RAV walks them, so must every rewrite.
        self.dyn()->rebuild_dc_decls(n)
        return self._one_decl(n)
    }

    fn transform_class_decl(self,
                            n: unsafe *Declarations::ClassDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_decl_list(unsafe ((&n->generic_params) as unsafe *FrozenList<*Decl>))
        self.dyn()->rebuild_type_list(&n->spec_args) // specialization pattern (#68)
        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->transform_expr(n->requires_clause)
        }

        for var i: usize = 0; i < n->derives_list.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->transform_inherit_edge(n->derives_list.get(i))
        }

        for var i: usize = 0; i < n->implements.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->transform_inherit_edge(n->implements.get(i))
        }

        self.dyn()->rebuild_decl_list(unsafe ((&n->fields) as unsafe *FrozenList<*Decl>))
        self.dyn()->rebuild_decl_list(unsafe ((&n->methods) as unsafe *FrozenList<*Decl>))
        self.dyn()->rebuild_dc_decls(n)
        return self._one_decl(n)
    }

    fn transform_interface_decl(self,
                                n: unsafe *Declarations::InterfaceDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_decl_list(unsafe ((&n->generic_params) as unsafe *FrozenList<*Decl>))
        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->transform_expr(n->requires_clause)
        }

        for var i: usize = 0; i < n->derives_list.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->transform_inherit_edge(n->derives_list.get(i))
        }

        self.dyn()->rebuild_decl_list(unsafe ((&n->methods) as unsafe *FrozenList<*Decl>))
        self.dyn()->rebuild_dc_decls(n)
        return self._one_decl(n)
    }

    fn transform_extension_decl(self,
                                n: unsafe *Declarations::ExtensionDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_decl_list(unsafe ((&n->generic_params) as unsafe *FrozenList<*Decl>))
        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->transform_expr(n->requires_clause)
        }

        if n->target != &null {
            n->target = self.dyn()->transform_type(n->target)
        }

        for var i: usize = 0; i < n->implements.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->transform_inherit_edge(n->implements.get(i))
        }

        self.dyn()->rebuild_decl_list(unsafe ((&n->methods) as unsafe *FrozenList<*Decl>))
        self.dyn()->rebuild_dc_decls(n)
        return self._one_decl(n)
    }

    fn transform_enum_decl(self,
                           n: unsafe *Declarations::EnumDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_decl_list(unsafe ((&n->generic_params) as unsafe *FrozenList<*Decl>))
        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->transform_expr(n->requires_clause)
        }

        if n->underlying != &null {
            n->underlying = self.dyn()->transform_type(n->underlying)
        }

        self.dyn()->rebuild_decl_list(unsafe ((&n->variants) as unsafe *FrozenList<*Decl>))
        return self._one_decl(n)
    }

    fn transform_enum_variant_decl(self,
                                   n: unsafe *Declarations::EnumVariantDecl) -> cxx::std::vector<unsafe *Decl> {
        if n->discriminant != &null {
            n->discriminant = self.dyn()->transform_expr(n->discriminant)
        }

        self.dyn()->rebuild_decl_list(unsafe ((&n->payload) as unsafe *FrozenList<*Decl>))
        return self._one_decl(n)
    }

    fn transform_union_decl(self,
                            n: unsafe *Declarations::UnionDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_decl_list(unsafe ((&n->generic_params) as unsafe *FrozenList<*Decl>))
        self.dyn()->rebuild_type_list(&n->spec_args) // specialization pattern (#68)
        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->transform_expr(n->requires_clause)
        }

        self.dyn()->rebuild_decl_list(unsafe ((&n->fields) as unsafe *FrozenList<*Decl>))
        self.dyn()->rebuild_decl_list(unsafe ((&n->methods) as unsafe *FrozenList<*Decl>)) // ctors and operators; the RAV walks them, so must every rewrite.
        self.dyn()->rebuild_dc_decls(n)
        return self._one_decl(n)
    }

    fn transform_type_alias_decl(self,
                                 n: unsafe *Declarations::TypeAliasDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_decl_list(unsafe ((&n->generic_params) as unsafe *FrozenList<*Decl>))
        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->transform_expr(n->requires_clause)
        }

        if n->aliased != &null {
            n->aliased = self.dyn()->transform_type(n->aliased)
        }

        return self._one_decl(n)
    }

    fn transform_module_decl(self,
                             n: unsafe *Declarations::ModuleDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_dc_decls(n)
        return self._one_decl(n)
    }

    fn transform_import_decl(self,
                             n: unsafe *Declarations::ImportDecl) -> cxx::std::vector<unsafe *Decl> {
        return self._one_decl(n) // token lists, no AST children.
    }

    fn transform_ffi_block_decl(self,
                                n: unsafe *Declarations::FFIBlockDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_decl_list(&n->body)
        return self._one_decl(n)
    }

    fn transform_visibility_group_decl(self,
                                       n: unsafe *Declarations::VisibilityGroupDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_decl_list(&n->members)
        return self._one_decl(n)
    }

    fn transform_eval_block_decl(self,
                                 n: unsafe *Declarations::EvalBlockDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_decl_list(&n->body)
        if n->stmt != &null {
            n->stmt = self.dyn()->transform_stmt_scalar(n->stmt)
        }

        return self._one_decl(n)
    }

    fn transform_test_decl(self,
                           n: unsafe *Declarations::TestDecl) -> cxx::std::vector<unsafe *Decl> {
        if n->label != &null {
            n->label = self.dyn()->transform_expr(n->label)
        }

        if n->body != &null {
            n->body = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body))
        }

        return self._one_decl(n)
    }

    fn transform_macro_decl(self,
                            n: unsafe *Declarations::MacroDecl) -> cxx::std::vector<unsafe *Decl> {
        return self._one_decl(n) // raw token body, no AST children.
    }

    fn transform_procedure_macro_decl(self,
                                      n: unsafe *Declarations::ProcedureMacroDecl) -> cxx::std::vector<unsafe *Decl> {
        self.dyn()->rebuild_decl_list(unsafe ((&n->params) as unsafe *FrozenList<*Decl>))
        if n->body != &null {
            n->body = cast<Statements::CompoundStmt>(self.dyn()->transform_stmt_scalar(n->body))
        }

        return self._one_decl(n)
    }

    fn transform_pattern(self, p: unsafe *Pattern) -> unsafe *Pattern {
        if p == &null {
            return &null
        }

        if self.stop {
            return p
        }

        match p->kind {
            case PatternKind::WildcardPattern {
                return self.dyn()->transform_wildcard_pattern(cast<WildcardPattern>(p))
            } case PatternKind::LiteralPattern {
                return self.dyn()->transform_literal_pattern(cast<LiteralPattern>(p))
            } case PatternKind::BindingPattern {
                return self.dyn()->transform_binding_pattern(cast<BindingPattern>(p))
            } case PatternKind::TupleDestructurePattern {
                return self.dyn()->transform_tuple_destructure_pattern(
                    cast<TupleDestructurePattern>(p),
                )
            } case PatternKind::ConstructorPattern {
                return self.dyn()->transform_constructor_pattern(cast<ConstructorPattern>(p))
            } case PatternKind::UnresolvedConstructorPattern {
                return self.dyn()->transform_unresolved_constructor_pattern(
                    cast<UnresolvedConstructorPattern>(p),
                )
            } case PatternKind::AlternationPattern {
                return self.dyn()->transform_alternation_pattern(cast<AlternationPattern>(p))
            } case PatternKind::RangePattern {
                return self.dyn()->transform_range_pattern(cast<RangePattern>(p))
            } case PatternKind::SlicePattern {
                return self.dyn()->transform_slice_pattern(cast<SlicePattern>(p))
            } case PatternKind::RecoveryPattern {
                return p
            } case PatternKind::PatternKindCount {
                kairo::std::ice_fail("PatternKindCount reached ASTWriter - bug")
            }
        }
    }

    fn transform_wildcard_pattern(self, n: *WildcardPattern) -> *Pattern {
        return n
    }

    fn transform_literal_pattern(self, n: *LiteralPattern) -> *Pattern {
        if n->value != &null {
            n->value = self.dyn()->transform_expr(n->value)
        }

        return n
    }

    fn transform_binding_pattern(self, n: *BindingPattern) -> *Pattern {
        if n->type_ != &null {
            n->type_ = self.dyn()->transform_type(n->type_)
        }

        return n
    }

    fn transform_tuple_destructure_pattern(self, n: *TupleDestructurePattern) -> *Pattern {
        self.dyn()->rebuild_pattern_list(&n->elements)
        return n
    }

    fn transform_constructor_pattern(self, n: *ConstructorPattern) -> *Pattern {
        if n->head != &null {
            n->head = self.dyn()->transform_expr(n->head)
        }

        self.dyn()->rebuild_pattern_list(&n->subpatterns)
        return n
    }

    fn transform_unresolved_constructor_pattern(self,
                                                n: *UnresolvedConstructorPattern) -> *Pattern {
        if n->head != &null {
            n->head = self.dyn()->transform_expr(n->head)
        }

        self.dyn()->rebuild_pattern_list(&n->subpatterns)
        return n
    }

    fn transform_alternation_pattern(self, n: *AlternationPattern) -> *Pattern {
        self.dyn()->rebuild_pattern_list(&n->alternatives)
        return n
    }

    fn transform_range_pattern(self, n: *RangePattern) -> *Pattern {
        if n->lo != &null {
            n->lo = self.dyn()->transform_expr(n->lo)
        }

        if n->hi != &null {
            n->hi = self.dyn()->transform_expr(n->hi)
        }

        return n
    }

    fn transform_slice_pattern(self, n: *SlicePattern) -> *Pattern {
        self.dyn()->rebuild_pattern_list(&n->prefix)
        self.dyn()->rebuild_pattern_list(&n->suffix)
        if n->rest_binding != &null {
            n->rest_binding = self.dyn()->transform_pattern(n->rest_binding)
        }

        return n
    }


    /// Drive the transform over a whole file. The top-level item list lives on
    /// the Program; rebuild it (splice-aware) and the imports/attrs lists.
    fn run(self, tu: unsafe *TranslationUnit) {
        if tu->program != &null {
            self.dyn()->rebuild_toplevel_items(&tu->program->items)
            self._resync_tu_decls(tu)
        }

        // imports / tu_attrs are ArenaList<*Decl>; rebuild via dc-style walk
        // only if a pass needs to touch them. Most don't, so left as-is here.
    }

    /// tu->dc_decls from the rebuilt items: the Decl entries, in order.
    /// The parser lands every top-level Decl item in both lists and nothing
    /// else in dc_decls (ASTParse::_parse_top_decl; top-level `var`/`const`
    /// are Stmt items and never in dc_decls), so this is the list the parser
    /// would have built for the rewritten tree. EmitPlan::_collect_own reads
    /// dc_decls, and a TU-scope splice is invisible to it otherwise.
    /// Rebuilt from the items, NOT by running transform_decl over dc_decls:
    /// that would rewrite every top-level decl a second time.
    priv fn _resync_tu_decls(self, tu: unsafe *TranslationUnit) {
        var unsafe *dc = unsafe (tu as unsafe *DeclContext)
        var        buf = ArenaList<unsafe *Decl>()
        buf.set_allocator(unsafe &self.ctx->ast_alloc)
        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            if item.kind != TopLevelKind::Decl {
                continue
            }

            var unsafe *d = item.as_decl()
            if d != &null {
                buf.push(d)
            }
        }

        dc->dc_decls = buf
    }

    /// Program::items is a live ArenaList of heterogeneous TopLevelItems
    /// (decl/stmt/expr). Rebuild it in place, dispatching each item to the
    /// matching family transform and re-wrapping the (splice-aware) results.
    fn rebuild_toplevel_items(self, items: *ArenaList<TopLevelItem>) {
        var buf = ArenaList<TopLevelItem>()
        buf.set_allocator(unsafe &self.ctx->ast_alloc)
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            if self.stop {
                buf.push(item)
                continue
            }

            match item.kind {
                case TopLevelKind::Decl {
                    var results = self.dyn()->transform_decl(item.as_decl())
                    for var j: usize = 0; j < results.size(); j++ {
                        buf.push(TopLevelItem::from_decl(results[j]))
                    }
                } case TopLevelKind::Stmt {
                    var results = self.dyn()->transform_stmt(item.as_stmt())
                    for var j: usize = 0; j < results.size(); j++ {
                        buf.push(TopLevelItem::from_stmt(results[j]))
                    }
                } case TopLevelKind::Expr {
                    var r = self.dyn()->transform_expr(item.as_expr())
                    if r != &null {
                        buf.push(TopLevelItem::from_expr(r))
                    }
                }
            }
        }

        *items = buf
    }

    /// Transform a single subtree of any family. Useful for targeted rewrites
    /// (e.g. one function body) without walking the whole TU.
    fn run_on_decl(self, d: *Decl) -> cxx::std::vector<*Decl> {
        return self.dyn()->transform_decl(d)
    }

    fn run_on_stmt(self, s: *Stmt) -> cxx::std::vector<*Stmt> {
        return self.dyn()->transform_stmt(s)
    }

    pub fn run_on_expr(self, e: unsafe *Expr) -> unsafe *Expr {
        return self.dyn()->transform_expr(e)
    }

    fn run_on_type(self, t: *Type) -> *Type {
        return self.dyn()->transform_type(t)
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
/// verified on every build. Do not delete.
///
pub class ASTWriterProbe derives ASTWriter<ASTWriterProbe> { }
