/// --- The Kairo Project ------------ AST/Visitor/RecursiveASTVisitor.k --- ///
///
///   \brief A recursive AST visitor for traversing the Kairo AST.
///
///   Layer contract (per node N of family F):
///     dispatch_F(*F)     -- switch on kind, route to traverse_N. (generated)
///     traverse_N(*N)->*N -- walkup_N; recurse+rebind children; return n.
///                           (hand-written body)
///     walkup_N(*N)->bool -- visit_F (family hook) THEN visit_N (leaf).
///                           base-first.
///     visit_F(*F)->bool  -- kind-agnostic family hook. override for whole-
///                           family passes.
///     visit_N(*N)->bool  -- leaf hook. override for one node kind.
///
///   bool == "keep going". false anywhere short-circuits that subtree.
///   traverse returns the (possibly rewritten) node; parent rebinds the slot.
///   Read-only pass: returns same ptr (free). 1:1 desugar: returns new node.
///
///   Node-count-changing rewrites do NOT belong here -> use ASTWriter.
///   Child-rewrite rules:
///     scalar child   : n->f = dispatch_F(n->f)          -- read or rewrite, OK
///     nullable scalar : if n->f != &null { n->f = ... } -- same
///     list child     : walk read-only, DISCARD return   -- never write a slot
///                       any list rewrite -> ASTWriter, not RAV
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"

import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContext
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
import AST::Node::CanonicalNodes::{
    BuiltinType,
    QualifiedType,
    RecordType,
}
import AST::Node::Casting::{
    cast,
    isa,
}
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
import AST::Node::Statements
import AST::Node::Types

/// The VALUE of a named call argument, or null when \p a is positional.
///
/// `f(x: 1)` has no node of its own: the parser wraps it in an
/// AssignOperatorExpr with a `:` operator token and a bare identifier on the
/// left (ExprParse::_parse_call_args documents the encoding, and
/// CallTyping::arg_info is the other reader). One decoder, so a change to the
/// encoding has one place to land.
pub fn named_call_arg_value(a: unsafe *Expr) -> unsafe *Expr {
    if a == &null {
        return &null
    }

    if !isa<Expressions::NamedArgExpr>(a) {
        return &null
    }

    return cast<Expressions::NamedArgExpr>(a)->value
}

// TODO(DUCK-GENERIC): D uses _rav_dc_nested, dispatch_decl, dispatch_expr, dispatch_pattern, dispatch_stmt, dispatch_type, traverse_align_of_expr, traverse_alternation_pattern, traverse_anon_initializer_expr, traverse_assign_operator_expr, traverse_attributed_expr, traverse_await_expr, ... (405). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <D: type> RecursiveASTVisitor {
    @move
    fn RecursiveASTVisitor(self, other: Self) = default
    fn RecursiveASTVisitor(self) = default
    var     ctx:  unsafe *ASTContext
    pub var stop: bool               = false

    pub fn dyn(self) -> unsafe *D {
        return unsafe ((&self) as *D)
    }

    /// # DISPATCH (generated off TypeKind)
    /// Routes an unknown-kind *Type to its traverse_. Default: identity.

    pub fn dispatch_type(self, e: unsafe *Type) -> unsafe *Type {
        if e == &null {
            return e
        }

        if self.stop {
            return e
        }

        match e->kind {
            case TypeKind::MapType {
                return self.dyn()->traverse_map_type(cast<Types::MapType>(e))
            } case TypeKind::SetType {
                return self.dyn()->traverse_set_type(cast<Types::SetType>(e))
            } case TypeKind::SelfType {
                return self.dyn()->traverse_self_type(cast<Types::SelfType>(e))
            } case TypeKind::TypeExpr {
                return self.dyn()->traverse_type_expr(cast<Types::TypeExpr>(e))
            } case TypeKind::TupleType {
                return self.dyn()->traverse_tuple_type(cast<Types::TupleType>(e))
            } case TypeKind::ChainType {
                return self.dyn()->traverse_chain_type(cast<Types::ChainType>(e))
            } case TypeKind::VectorType {
                return self.dyn()->traverse_vector_type(cast<Types::VectorType>(e))
            } case TypeKind::PointerType {
                return self.dyn()->traverse_pointer_type(cast<Types::PointerType>(e))
            } case TypeKind::TypeOfType {
                return self.dyn()->traverse_type_of_type(cast<Types::TypeOfType>(e))
            } case TypeKind::InferredType {
                return self.dyn()->traverse_inferred_type(cast<Types::InferredType>(e))
            } case TypeKind::RecordType {
                return self.dyn()->traverse_record_type(cast<RecordType>(e))
            } case TypeKind::BuiltinType {
                return self.dyn()->traverse_builtin_type(cast<BuiltinType>(e))
            } case TypeKind::NullableType {
                return self.dyn()->traverse_nullable_type(cast<Types::NullableType>(e))
            } case TypeKind::OpaqueFFIType {
                return self.dyn()->traverse_opaque_ffi_type(cast<Types::OpaqueFFIType>(e))
            } case TypeKind::QualifiedType {
                return self.dyn()->traverse_qualified_type(cast<QualifiedType>(e))
            } case TypeKind::FixedArrayType {
                return self.dyn()->traverse_fixed_array_type(cast<Types::FixedArrayType>(e))
            } case TypeKind::VariadicPackType {
                return self.dyn()->traverse_variadic_pack_type(cast<Types::VariadicPackType>(e))
            } case TypeKind::GenericParamType {
                return self.dyn()->traverse_generic_param_type(cast<Types::GenericParamType>(e))
            } case TypeKind::PackExpansionType {
                return self.dyn()->traverse_pack_expansion_type(cast<Types::PackExpansionType>(e))
            } case TypeKind::CXXLValueRefType {
                return self.dyn()->traverse_cxxl_value_ref_type(cast<Types::CXXLValueRefType>(e))
            } case TypeKind::CXXRValueRefType {
                return self.dyn()->traverse_cxxr_value_ref_type(cast<Types::CXXRValueRefType>(e))
            } case TypeKind::FunctionPointerType {
                return self.dyn()->traverse_function_pointer_type(
                    cast<Types::FunctionPointerType>(e),
                )
            } case TypeKind::SubstGenericParamType {
                return self.dyn()->traverse_subst_generic_param_type(
                    cast<Types::SubstGenericParamType>(e),
                )
            } case TypeKind::AssocType { // canonical only: never in a written tree.
                return e
            } case TypeKind::RecoveryType {
                self.dyn()->visit_type(e)
                return e
            } case TypeKind::TypeKindCount {
                kairo::std::ice_fail("TypeKind::TypeKindCount reached RAV - this is a bug")
            }
        }
    }

    /// # FAMILY HOOK (override for whole-family passes)
    /// ValueCategoryPass, TypeChecking, mono-part-1 collect, etc. override this.

    fn visit_type(self, n: *Type) -> bool {
        return true
    }

    /// # TRAVERSE bodies (hand-written: each knows its children)
    /// REFERENCE SHAPE scalar children:

    fn traverse_map_type(self, n: *Types::MapType) -> *Types::MapType {
        if self.dyn()->walkup_map_type(n) == false {
            return n
        }

        n->key   = self.dyn()->dispatch_type(n->key)
        n->value = self.dyn()->dispatch_type(n->value)
        return n
    }

    fn traverse_set_type(self, n: *Types::SetType) -> *Types::SetType {
        if self.dyn()->walkup_set_type(n) == false {
            return n
        }

        n->element = self.dyn()->dispatch_type(n->element)
        return n
    }

    fn traverse_self_type(self, n: *Types::SelfType) -> *Types::SelfType {
        self.dyn()->walkup_self_type(n)
        return n
    }

    fn traverse_type_expr(self, n: *Types::TypeExpr) -> *Types::TypeExpr {
        if self.dyn()->walkup_type_expr(n) == false {
            return n
        }

        n->expr = self.dyn()->dispatch_expr(n->expr)
        return n
    }

    fn traverse_tuple_type(self, n: *Types::TupleType) -> *Types::TupleType {
        if self.dyn()->walkup_tuple_type(n) == false {
            return n
        }

        for var i: usize = 0; i < n->elements.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_type(*n->elements.get(i)) // discard return
        }

        return n
    }

    fn traverse_chain_type(self, n: *Types::ChainType) -> *Types::ChainType {
        if self.dyn()->walkup_chain_type(n) == false {
            return n
        }

        for var i: usize = 0; i < n->segments.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *seg = n->segments.get(i) // *ChainSegment
            // seg->name is a NamedIdentExpr (decl-site identifier) skip,
            //      like other name nodes
            // seg->resolved_type / resolved_decl are sema links skip
            for var j: usize = 0; j < seg->generic_args.size(); j++ {
                if self.stop {
                    break
                }

                var unsafe *arg = seg->generic_args.get(j) // *GenericArg
                // arg->name is a NamedIdentExpr (named-arg label) skip
                if arg->ty != &null {
                    self.dyn()->dispatch_type(arg->ty) // the real child
                }
            }
        }

        return n
    }

    fn traverse_vector_type(self, n: *Types::VectorType) -> *Types::VectorType {
        if self.dyn()->walkup_vector_type(n) == false {
            return n
        }

        n->element = self.dyn()->dispatch_type(n->element)
        return n
    }

    fn traverse_pointer_type(self, n: *Types::PointerType) -> *Types::PointerType {
        if self.dyn()->walkup_pointer_type(n) == false {
            return n
        }

        n->pointee = self.dyn()->dispatch_type(n->pointee)
        return n
    }


    fn traverse_type_of_type(self, n: *Types::TypeOfType) -> *Types::TypeOfType {
        if self.dyn()->walkup_type_of_type(n) == false {
            return n
        }

        n->expr = self.dyn()->dispatch_expr(n->expr)
        return n
    }

    fn traverse_inferred_type(self, n: *Types::InferredType) -> *Types::InferredType {
        self.dyn()->walkup_inferred_type(n)
        return n
    }

    // Canonical nodes are LEAVES for traversal purposes: their components are
    // themselves canonical and shared across the whole build, so descending
    // would revisit one node once per referring TU.
    fn traverse_record_type(self, n: *RecordType) -> *RecordType {
        self.dyn()->walkup_record_type(n)
        return n
    }

    fn traverse_builtin_type(self, n: *BuiltinType) -> *BuiltinType {
        self.dyn()->walkup_builtin_type(n)
        return n
    }

    fn traverse_qualified_type(self, n: *QualifiedType) -> *QualifiedType {
        self.dyn()->walkup_qualified_type(n)
        return n
    }

    fn traverse_nullable_type(self, n: *Types::NullableType) -> *Types::NullableType {
        if self.dyn()->walkup_nullable_type(n) == false {
            return n
        }

        n->inner = self.dyn()->dispatch_type(n->inner)
        return n
    }

    fn traverse_opaque_ffi_type(self, n: *Types::OpaqueFFIType) -> *Types::OpaqueFFIType {
        self.dyn()->walkup_opaque_ffi_type(n)
        return n
    }

    fn traverse_fixed_array_type(self, n: *Types::FixedArrayType) -> *Types::FixedArrayType {
        if self.dyn()->walkup_fixed_array_type(n) == false {
            return n
        }

        n->element = self.dyn()->dispatch_type(n->element)
        if n->size_expr != &null { // null when is_incomplete
            n->size_expr = self.dyn()->dispatch_expr(n->size_expr)
        }

        return n
    }

    fn traverse_variadic_pack_type(self, n: *Types::VariadicPackType) -> *Types::VariadicPackType {
        // param is a back-ref to the declaring pack param: skip.
        self.dyn()->walkup_variadic_pack_type(n)
        return n
    }

    fn traverse_generic_param_type(self, n: *Types::GenericParamType) -> *Types::GenericParamType {
        // param_name is a decl-site back-ref, not a child: skip.
        self.dyn()->walkup_generic_param_type(n)
        return n
    }


    fn traverse_pack_expansion_type(self,
                                    n: *Types::PackExpansionType) -> *Types::PackExpansionType {
        if self.dyn()->walkup_pack_expansion_type(n) == false {
            return n
        }

        n->pattern = self.dyn()->dispatch_type(n->pattern)
        return n
    }

    fn traverse_cxxl_value_ref_type(self, n: *Types::CXXLValueRefType) -> *Types::CXXLValueRefType {
        if self.dyn()->walkup_cxxl_value_ref_type(n) == false {
            return n
        }

        n->referee = self.dyn()->dispatch_type(n->referee)
        return n
    }

    fn traverse_cxxr_value_ref_type(self, n: *Types::CXXRValueRefType) -> *Types::CXXRValueRefType {
        if self.dyn()->walkup_cxxr_value_ref_type(n) == false {
            return n
        }

        n->referee = self.dyn()->dispatch_type(n->referee)
        return n
    }

    fn traverse_function_pointer_type(self,
                                      n: *Types::FunctionPointerType) -> *Types::FunctionPointerType {
        if self.dyn()->walkup_function_pointer_type(n) == false {
            return n
        }

        for var i: usize = 0; i < n->params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_type(*n->params.get(i)) // discard return
        }

        if n->return_type != &null { // null on unprototyped path
            n->return_type = self.dyn()->dispatch_type(n->return_type)
        }

        for var i: usize = 0; i < n->panic_set.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_type(*n->panic_set.get(i)) // discard return
        }

        return n
    }

    fn traverse_subst_generic_param_type(self,
                                         n: *Types::SubstGenericParamType) -> *Types::SubstGenericParamType {
        if self.dyn()->walkup_subst_generic_param_type(n) == false {
            return n
        }

        n->replacement = self.dyn()->dispatch_type(n->replacement)
        return n
    }

    /// # WALKUP (base-first chain: family hook THEN leaf hook)

    fn walkup_map_type(self, n: *Types::MapType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_map_type(n)
    }

    fn walkup_set_type(self, n: *Types::SetType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_set_type(n)
    }

    fn walkup_self_type(self, n: *Types::SelfType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_self_type(n)
    }

    fn walkup_type_expr(self, n: *Types::TypeExpr) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_type_expr(n)
    }

    fn walkup_tuple_type(self, n: *Types::TupleType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_tuple_type(n)
    }

    fn walkup_chain_type(self, n: *Types::ChainType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_chain_type(n)
    }

    fn walkup_vector_type(self, n: *Types::VectorType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_vector_type(n)
    }

    fn walkup_pointer_type(self, n: *Types::PointerType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_pointer_type(n)
    }

    fn walkup_type_of_type(self, n: *Types::TypeOfType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_type_of_type(n)
    }

    fn walkup_inferred_type(self, n: *Types::InferredType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_inferred_type(n)
    }

    fn walkup_record_type(self, n: *RecordType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_record_type(n)
    }

    fn walkup_builtin_type(self, n: *BuiltinType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_builtin_type(n)
    }

    fn walkup_nullable_type(self, n: *Types::NullableType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_nullable_type(n)
    }

    fn walkup_opaque_ffi_type(self, n: *Types::OpaqueFFIType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_opaque_ffi_type(n)
    }

    fn walkup_qualified_type(self, n: *QualifiedType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_qualified_type(n)
    }

    fn walkup_fixed_array_type(self, n: *Types::FixedArrayType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_fixed_array_type(n)
    }

    fn walkup_variadic_pack_type(self, n: *Types::VariadicPackType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_variadic_pack_type(n)
    }

    fn walkup_generic_param_type(self, n: *Types::GenericParamType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_generic_param_type(n)
    }

    fn walkup_pack_expansion_type(self, n: *Types::PackExpansionType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_pack_expansion_type(n)
    }

    fn walkup_cxxl_value_ref_type(self, n: *Types::CXXLValueRefType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_cxxl_value_ref_type(n)
    }

    fn walkup_cxxr_value_ref_type(self, n: *Types::CXXRValueRefType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_cxxr_value_ref_type(n)
    }

    fn walkup_function_pointer_type(self, n: *Types::FunctionPointerType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_function_pointer_type(n)
    }

    fn walkup_subst_generic_param_type(self, n: *Types::SubstGenericParamType) -> bool {
        if self.dyn()->visit_type(n) == false {
            return false
        }

        return self.dyn()->visit_subst_generic_param_type(n)
    }

    /// # LEAF VISIT hooks (override per node kind)

    fn visit_map_type(self, n: *Types::MapType) -> bool {
        return true
    }

    fn visit_set_type(self, n: *Types::SetType) -> bool {
        return true
    }

    fn visit_self_type(self, n: *Types::SelfType) -> bool {
        return true
    }

    fn visit_type_expr(self, n: *Types::TypeExpr) -> bool {
        return true
    }

    fn visit_tuple_type(self, n: *Types::TupleType) -> bool {
        return true
    }

    fn visit_chain_type(self, n: *Types::ChainType) -> bool {
        return true
    }

    fn visit_vector_type(self, n: *Types::VectorType) -> bool {
        return true
    }

    fn visit_pointer_type(self, n: *Types::PointerType) -> bool {
        return true
    }

    fn visit_type_of_type(self, n: *Types::TypeOfType) -> bool {
        return true
    }

    fn visit_inferred_type(self, n: *Types::InferredType) -> bool {
        return true
    }

    fn visit_record_type(self, n: *RecordType) -> bool {
        return true
    }

    fn visit_builtin_type(self, n: *BuiltinType) -> bool {
        return true
    }

    fn visit_nullable_type(self, n: *Types::NullableType) -> bool {
        return true
    }

    fn visit_opaque_ffi_type(self, n: *Types::OpaqueFFIType) -> bool {
        return true
    }

    fn visit_qualified_type(self, n: *QualifiedType) -> bool {
        return true
    }

    fn visit_fixed_array_type(self, n: *Types::FixedArrayType) -> bool {
        return true
    }

    fn visit_variadic_pack_type(self, n: *Types::VariadicPackType) -> bool {
        return true
    }

    fn visit_generic_param_type(self, n: *Types::GenericParamType) -> bool {
        return true
    }

    fn visit_pack_expansion_type(self, n: *Types::PackExpansionType) -> bool {
        return true
    }

    fn visit_cxxl_value_ref_type(self, n: *Types::CXXLValueRefType) -> bool {
        return true
    }

    fn visit_cxxr_value_ref_type(self, n: *Types::CXXRValueRefType) -> bool {
        return true
    }

    fn visit_function_pointer_type(self, n: *Types::FunctionPointerType) -> bool {
        return true
    }

    fn visit_subst_generic_param_type(self, n: *Types::SubstGenericParamType) -> bool {
        return true
    }

    /// # SHARED CHILD-WALK HELPERS
    /// CompoundStmt-typed scalar child: rebind through the block. dispatch
    /// routes to traverse_compound_stmt; a RAV pass preserves block-ness
    /// (node-count rewrites belong in ASTWriter), so the downcast is sound.
    /// null-safe for optional bodies (expr-bodied fn, bare default, etc.).

    fn traverse_block(self,
                      b: unsafe *Statements::CompoundStmt) -> unsafe *Statements::CompoundStmt {
        if b == &null {
            return b
        }

        return cast<Statements::CompoundStmt>(self.dyn()->dispatch_stmt(b))
    }

    // GenericArg (bare NamedIdentExpr / ChainExpr step): the named label is a
    // name node (skip); only `ty` is a real child. list element -> discard.
    fn traverse_generic_arg(self, a: *Types::ChainType::GenericArg) {
        if self.stop {
            return
        }

        if a->ty != &null {
            self.dyn()->dispatch_type(a->ty) // discard
        }
    }

    // InheritEdge (derives_list / implements): base type is the only child.
    // visibility / is_virtual / range are leaf data. list element -> discard.
    fn traverse_inherit_edge(self, e: *Declarations::InheritEdge) {
        if self.stop {
            return
        }

        if e->base != &null {
            self.dyn()->dispatch_type(e->base) // discard
        }
    }

    // MatchCase (MatchStmt / MatchExpr): patterns + optional guard + one of
    // body (stmt form) / expression (expr form). list element -> discard all.
    fn traverse_match_case(self, mc: unsafe *Statements::MatchCase) {
        for var i: usize = 0; i < mc->patterns.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_pattern(*mc->patterns.get(i)) // discard
        }

        if self.stop {
            return
        }

        if mc->guard != &null {
            self.dyn()->dispatch_expr(mc->guard)
        }

        if mc->body != &null {
            self.dyn()->dispatch_stmt(mc->body)
        }

        if mc->expression != &null {
            self.dyn()->dispatch_expr(mc->expression)
        }
    }

    /// # EXPR FAMILY

    pub fn dispatch_expr(self, e: unsafe *Expr) -> unsafe *Expr {
        if e == &null {
            return e
        }

        if self.stop {
            return e
        }

        match e->kind {
            case ExprKind::IntegerLiteralExpr {
                return self.dyn()->traverse_integer_literal_expr(cast<IntegerLiteralExpr>(e))
            } case ExprKind::FloatingLiteralExpr {
                return self.dyn()->traverse_floating_literal_expr(cast<FloatingLiteralExpr>(e))
            } case ExprKind::StringLiteralExpr {
                return self.dyn()->traverse_string_literal_expr(cast<StringLiteralExpr>(e))
            } case ExprKind::CharacterLiteralExpr {
                return self.dyn()->traverse_character_literal_expr(cast<CharacterLiteralExpr>(e))
            } case ExprKind::BooleanLiteralExpr {
                return self.dyn()->traverse_boolean_literal_expr(cast<BooleanLiteralExpr>(e))
            } case ExprKind::NullLiteralExpr {
                return self.dyn()->traverse_null_literal_expr(cast<NullLiteralExpr>(e))
            } case ExprKind::ListLiteralExpr {
                return self.dyn()->traverse_list_literal_expr(cast<Expressions::ListLiteralExpr>(e))
            } case ExprKind::InitListExpr {
                return self.dyn()->traverse_init_list_expr(cast<Expressions::InitListExpr>(e))
            } case ExprKind::StmtExpr {
                return self.dyn()->traverse_stmt_expr(cast<Expressions::StmtExpr>(e))
            } case ExprKind::VariantInitExpr {
                return self.dyn()->traverse_variant_init_expr(cast<Expressions::VariantInitExpr>(e))
            } case ExprKind::TupleLiteralExpr {
                return self.dyn()->traverse_tuple_literal_expr(
                    cast<Expressions::TupleLiteralExpr>(e),
                )
            } case ExprKind::SetLiteralExpr {
                return self.dyn()->traverse_set_literal_expr(cast<Expressions::SetLiteralExpr>(e))
            } case ExprKind::MapLiteralExpr {
                return self.dyn()->traverse_map_literal_expr(cast<Expressions::MapLiteralExpr>(e))
            } case ExprKind::NamedInitializerExpr {
                return self.dyn()->traverse_named_initializer_expr(
                    cast<Expressions::NamedInitializerExpr>(e),
                )
            } case ExprKind::AnonInitializerExpr {
                return self.dyn()->traverse_anon_initializer_expr(
                    cast<Expressions::AnonInitializerExpr>(e),
                )
            } case ExprKind::ChainExpr {
                return self.dyn()->traverse_chain_expr(cast<ChainExpr>(e))
            } case ExprKind::CallExpr {
                return self.dyn()->traverse_call_expr(cast<Expressions::CallExpr>(e))
            } case ExprKind::SubscriptExpr {
                return self.dyn()->traverse_subscript_expr(cast<Expressions::SubscriptExpr>(e))
            } case ExprKind::NamedIdentExpr {
                return self.dyn()->traverse_named_ident_expr(cast<NamedIdentExpr>(e))
            } case ExprKind::UnaryOperatorExpr {
                return self.dyn()->traverse_unary_operator_expr(
                    cast<Expressions::UnaryOperatorExpr>(e),
                )
            } case ExprKind::BinaryOperatorExpr {
                return self.dyn()->traverse_binary_operator_expr(
                    cast<Expressions::BinaryOperatorExpr>(e),
                )
            } case ExprKind::AssignOperatorExpr {
                return self.dyn()->traverse_assign_operator_expr(
                    cast<Expressions::AssignOperatorExpr>(e),
                )
            } case ExprKind::ImplConformanceExpr {
                return self.dyn()->traverse_impl_conformance_expr(
                    cast<Expressions::ImplConformanceExpr>(e),
                )
            } case ExprKind::DerivesRelationExpr {
                return self.dyn()->traverse_derives_relation_expr(
                    cast<Expressions::DerivesRelationExpr>(e),
                )
            } case ExprKind::IfExpr {
                return self.dyn()->traverse_if_expr(cast<Expressions::IfExpr>(e))
            } case ExprKind::TryCatchExpr {
                return self.dyn()->traverse_try_catch_expr(cast<Expressions::TryCatchExpr>(e))
            } case ExprKind::MatchExpr {
                return self.dyn()->traverse_match_expr(cast<Expressions::MatchExpr>(e))
            } case ExprKind::RangeExpr {
                return self.dyn()->traverse_range_expr(cast<Expressions::RangeExpr>(e))
            } case ExprKind::ClosureExpr {
                return self.dyn()->traverse_closure_expr(cast<Expressions::ClosureExpr>(e))
            } case ExprKind::AwaitExpr {
                return self.dyn()->traverse_await_expr(cast<Expressions::AwaitExpr>(e))
            } case ExprKind::UnwrapExpr {
                return self.dyn()->traverse_unwrap_expr(cast<Expressions::UnwrapExpr>(e))
            } case ExprKind::DefinedExpr {
                return self.dyn()->traverse_defined_expr(cast<Expressions::DefinedExpr>(e))
            } case ExprKind::AttributedExpr {
                return self.dyn()->traverse_attributed_expr(cast<Expressions::AttributedExpr>(e))
            } case ExprKind::PanicOpExpr {
                return self.dyn()->traverse_panic_op_expr(cast<Expressions::PanicOpExpr>(e))
            } case ExprKind::TypeTraitExpr {
                return self.dyn()->traverse_type_trait_expr(cast<Expressions::TypeTraitExpr>(e))
            } case ExprKind::CxxNewExpr {
                return self.dyn()->traverse_cxx_new_expr(cast<Expressions::CxxNewExpr>(e))
            } case ExprKind::SpawnExpr {
                return self.dyn()->traverse_spawn_expr(cast<Expressions::SpawnExpr>(e))
            } case ExprKind::ThreadExpr {
                return self.dyn()->traverse_thread_expr(cast<Expressions::ThreadExpr>(e))
            } case ExprKind::ConstraintExpr {
                return self.dyn()->traverse_constraint_expr(cast<Expressions::ConstraintExpr>(e))
            } case ExprKind::SizeOfExpr {
                return self.dyn()->traverse_size_of_expr(cast<Expressions::SizeOfExpr>(e))
            } case ExprKind::AlignOfExpr {
                return self.dyn()->traverse_align_of_expr(cast<Expressions::AlignOfExpr>(e))
            } case ExprKind::TypeOfExpr {
                return self.dyn()->traverse_type_of_expr(cast<Expressions::TypeOfExpr>(e))
            } case ExprKind::EvalExpr {
                return self.dyn()->traverse_eval_expr(cast<Expressions::EvalExpr>(e))
            } case ExprKind::UnsafeExpr {
                return self.dyn()->traverse_unsafe_expr(cast<Expressions::UnsafeExpr>(e))
            } case ExprKind::DeleteExpr {
                return self.dyn()->traverse_delete_expr(cast<Expressions::DeleteExpr>(e))
            } case ExprKind::PackExpansionExpr {
                return self.dyn()->traverse_pack_expansion_expr(
                    cast<Expressions::PackExpansionExpr>(e),
                )
            } case ExprKind::TypeCastExpr {
                return self.dyn()->traverse_type_cast_expr(cast<Expressions::TypeCastExpr>(e))
            } case ExprKind::ImplicitBoundaryCastExpr {
                return self.dyn()->traverse_implicit_boundary_cast_expr(
                    cast<Expressions::ImplicitBoundaryCastExpr>(e),
                )
            } case ExprKind::ParenExpr {
                return self.dyn()->traverse_paren_expr(cast<Expressions::ParenExpr>(e))
            } case ExprKind::VerbatimExpr {
                return self.dyn()->traverse_verbatim_expr(cast<Expressions::VerbatimExpr>(e))
            } case ExprKind::NamedArgExpr {
                return self.dyn()->traverse_named_arg_expr(cast<Expressions::NamedArgExpr>(e))
            } case ExprKind::RecoveryExpr {
                self.dyn()->visit_expr(e)
                return e
            } case ExprKind::ExprKindCount {
                kairo::std::ice_fail("ExprKindCount reached RAV in Stage 1 - driver bail failed")
            }
        }
    }

    fn visit_expr(self, n: *Expr) -> bool {
        return true
    }

    /// ## traverse bodies

    fn traverse_integer_literal_expr(self, n: *IntegerLiteralExpr) -> *IntegerLiteralExpr {
        self.dyn()->walkup_integer_literal_expr(n)
        return n
    }

    fn traverse_floating_literal_expr(self, n: *FloatingLiteralExpr) -> *FloatingLiteralExpr {
        self.dyn()->walkup_floating_literal_expr(n)
        return n
    }

    fn traverse_string_literal_expr(self, n: *StringLiteralExpr) -> *StringLiteralExpr {
        if self.dyn()->walkup_string_literal_expr(n) == false {
            return n
        }

        for var i: usize = 0; i < n->parts.size(); i++ { // f"" interpolation exprs
            if self.stop {
                break
            }

            self.dyn()->dispatch_expr(*n->parts.get(i)) // discard
        }

        return n
    }

    fn traverse_character_literal_expr(self, n: *CharacterLiteralExpr) -> *CharacterLiteralExpr {
        self.dyn()->walkup_character_literal_expr(n)
        return n
    }

    fn traverse_boolean_literal_expr(self, n: *BooleanLiteralExpr) -> *BooleanLiteralExpr {
        self.dyn()->walkup_boolean_literal_expr(n)
        return n
    }

    fn traverse_null_literal_expr(self, n: *NullLiteralExpr) -> *NullLiteralExpr {
        self.dyn()->walkup_null_literal_expr(n)
        return n
    }

    fn traverse_list_literal_expr(self,
                                  n: *Expressions::ListLiteralExpr) -> *Expressions::ListLiteralExpr {
        if self.dyn()->walkup_list_literal_expr(n) == false {
            return n
        }

        for var i: usize = 0; i < n->elements.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_expr(*n->elements.get(i)) // discard
        }

        return n
    }

    fn traverse_init_list_expr(self, n: *Expressions::InitListExpr) -> *Expressions::InitListExpr {
        if self.dyn()->walkup_init_list_expr(n) == false {
            return n
        }

        for var i: usize = 0; i < n->elements.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_expr(*n->elements.get(i)) // discard
        }

        return n
    }

    // The block is the whole child. It must be walked: the locals
    // SequenceLowering mints live in it, and a pass that skips them (EmitPlan
    // admitting their types) drops work it has no other way to see.
    fn traverse_stmt_expr(self, n: *Expressions::StmtExpr) -> *Expressions::StmtExpr {
        if self.dyn()->walkup_stmt_expr(n) == false {
            return n
        }

        n->body = self.dyn()->traverse_block(n->body)
        return n
    }

    // The fields in the order they were written, which is the order they run
    // in (SequenceLowering keeps it so); `fields` itself is in declaration
    // order. A walk that reads a use after a move reads it in this order.
    fn traverse_variant_init_expr(self,
                                  n: *Expressions::VariantInitExpr) -> *Expressions::VariantInitExpr {
        if self.dyn()->walkup_variant_init_expr(n) == false {
            return n
        }

        for var k: usize = 0; k < n->fields.size(); k++ {
            for var i: usize = 0; i < n->fields.size(); i++ {
                if self.stop {
                    return n
                }

                if ((*n->source_order.get(i)) as usize) == k {
                    self.dyn()->dispatch_expr(*n->fields.get(i)) // discard
                }
            }
        }

        return n
    }

    fn traverse_tuple_literal_expr(self,
                                   n: *Expressions::TupleLiteralExpr) -> *Expressions::TupleLiteralExpr {
        if self.dyn()->walkup_tuple_literal_expr(n) == false {
            return n
        }

        for var i: usize = 0; i < n->elements.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_expr(*n->elements.get(i)) // discard
        }

        return n
    }

    fn traverse_set_literal_expr(self,
                                 n: *Expressions::SetLiteralExpr) -> *Expressions::SetLiteralExpr {
        if self.dyn()->walkup_set_literal_expr(n) == false {
            return n
        }

        for var i: usize = 0; i < n->elements.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_expr(*n->elements.get(i)) // discard
        }

        return n
    }

    fn traverse_map_literal_expr(self,
                                 n: *Expressions::MapLiteralExpr) -> *Expressions::MapLiteralExpr {
        if self.dyn()->walkup_map_literal_expr(n) == false {
            return n
        }

        for var i: usize = 0; i < n->entries.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *en = n->entries.get(i) // *MapLiteralExpr::Entry
            self.dyn()->dispatch_expr(en->key) // discard
            if self.stop {
                break
            }

            self.dyn()->dispatch_expr(en->value) // discard
        }

        return n
    }

    fn traverse_named_initializer_expr(self,
                                       n: unsafe *Expressions::NamedInitializerExpr) -> unsafe *Expressions::NamedInitializerExpr {
        if self.dyn()->walkup_named_initializer_expr(n) == false {
            return n
        }

        if n->type_expr != &null {
            n->type_expr = self.dyn()->dispatch_expr(n->type_expr)
        }

        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *f = n->fields.get(i) // *InitField (name token skip)
            if f->value != &null {
                self.dyn()->dispatch_expr(f->value) // discard
            }
        }

        return n
    }

    fn traverse_anon_initializer_expr(self,
                                      n: unsafe *Expressions::AnonInitializerExpr) -> unsafe *Expressions::AnonInitializerExpr {
        if self.dyn()->walkup_anon_initializer_expr(n) == false {
            return n
        }

        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *f = n->fields.get(i) // *InitField
            if f->value != &null {
                self.dyn()->dispatch_expr(f->value) // discard
            }
        }

        return n
    }

    fn traverse_chain_expr(self, n: unsafe *ChainExpr) -> unsafe *ChainExpr {
        if self.dyn()->walkup_chain_expr(n) == false {
            return n
        }

        if n->base != &null { // null on global-root path
            n->base = self.dyn()->dispatch_expr(n->base)
        }

        for var i: usize = 0; i < n->steps.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *st = n->steps.get(i) // *ChainExpr::Step
            // st->name is the accessed identifier (name node) skip
            // st->resolved_type / resolved_decl are sema links skip
            for var j: usize = 0; j < st->generic_args.size(); j++ {
                if self.stop {
                    break
                }

                self.dyn()->traverse_generic_arg(st->generic_args.get(j))
            }
        }

        return n
    }

    fn traverse_call_expr(self, n: *Expressions::CallExpr) -> *Expressions::CallExpr {
        if self.dyn()->walkup_call_expr(n) == false {
            return n
        }

        if n->callee != &null {
            n->callee = self.dyn()->dispatch_expr(n->callee)
        }

        for var i: usize = 0; i < n->args.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *a = *n->args.get(i)
            // A NAMED argument is a NamedArgExpr (`label: value`). The label
            // is the callee's PARAMETER name, not a name use: only overload
            // resolution can say what it refers to, and walking it would make
            // every visitor treat it as an unbound identifier. Walk the value.
            var unsafe *value = named_call_arg_value(a)
            if value != &null {
                self.dyn()->dispatch_expr(value)
                continue
            }

            self.dyn()->dispatch_expr(a) // discard
        }

        return n
    }

    fn traverse_subscript_expr(self,
                               n: *Expressions::SubscriptExpr) -> *Expressions::SubscriptExpr {
        if self.dyn()->walkup_subscript_expr(n) == false {
            return n
        }

        if n->base != &null {
            n->base = self.dyn()->dispatch_expr(n->base)
        }

        if n->index != &null {
            n->index = self.dyn()->dispatch_expr(n->index)
        }

        return n
    }

    fn traverse_named_ident_expr(self, n: *NamedIdentExpr) -> *NamedIdentExpr {
        if self.dyn()->walkup_named_ident_expr(n) == false {
            return n
        }

        // n->name is the identifier token skip. generic_args carry real types.
        for var i: usize = 0; i < n->generic_args.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->traverse_generic_arg(n->generic_args.get(i))
        }

        return n
    }

    fn traverse_unary_operator_expr(self,
                                    n: *Expressions::UnaryOperatorExpr) -> *Expressions::UnaryOperatorExpr {
        if self.dyn()->walkup_unary_operator_expr(n) == false {
            return n
        }

        if n->operand != &null {
            n->operand = self.dyn()->dispatch_expr(n->operand)
        }

        return n
    }

    fn traverse_binary_operator_expr(self,
                                     n: *Expressions::BinaryOperatorExpr) -> *Expressions::BinaryOperatorExpr {
        if self.dyn()->walkup_binary_operator_expr(n) == false {
            return n
        }

        if n->lhs != &null {
            n->lhs = self.dyn()->dispatch_expr(n->lhs)
        }

        if n->rhs != &null {
            n->rhs = self.dyn()->dispatch_expr(n->rhs)
        }

        return n
    }

    fn traverse_assign_operator_expr(self,
                                     n: *Expressions::AssignOperatorExpr) -> *Expressions::AssignOperatorExpr {
        if self.dyn()->walkup_assign_operator_expr(n) == false {
            return n
        }

        if n->lhs != &null {
            n->lhs = self.dyn()->dispatch_expr(n->lhs)
        }

        if n->rhs != &null {
            n->rhs = self.dyn()->dispatch_expr(n->rhs)
        }

        return n
    }

    fn traverse_impl_conformance_expr(self,
                                      n: *Expressions::ImplConformanceExpr) -> *Expressions::ImplConformanceExpr {
        if self.dyn()->walkup_impl_conformance_expr(n) == false {
            return n
        }

        if n->subject != &null {
            n->subject = self.dyn()->dispatch_type(n->subject)
        }

        if n->inter != &null {
            n->inter = self.dyn()->dispatch_type(n->inter)
        }

        return n
    }

    fn traverse_derives_relation_expr(self,
                                      n: *Expressions::DerivesRelationExpr) -> *Expressions::DerivesRelationExpr {
        if self.dyn()->walkup_derives_relation_expr(n) == false {
            return n
        }

        if n->subject != &null {
            n->subject = self.dyn()->dispatch_type(n->subject)
        }

        if n->base != &null {
            n->base = self.dyn()->dispatch_type(n->base)
        }

        return n
    }

    fn traverse_if_expr(self, n: *Expressions::IfExpr) -> *Expressions::IfExpr {
        if self.dyn()->walkup_if_expr(n) == false {
            return n
        }

        if n->condition != &null {
            n->condition = self.dyn()->dispatch_expr(n->condition)
        }

        if n->then_expr != &null {
            n->then_expr = self.dyn()->dispatch_expr(n->then_expr)
        }

        for var i: usize = 0; i < n->else_ifs.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *arm = n->else_ifs.get(i) // *IfExpr::ElseIf
            if arm->condition != &null {
                self.dyn()->dispatch_expr(arm->condition)
            }

            if self.stop {
                break
            }

            if arm->body != &null {
                self.dyn()->dispatch_expr(arm->body)
            }
        }

        if self.stop {
            return n
        }

        if n->else_expr != &null {
            n->else_expr = self.dyn()->dispatch_expr(n->else_expr)
        }

        return n
    }

    fn traverse_try_catch_expr(self, n: *Expressions::TryCatchExpr) -> *Expressions::TryCatchExpr {
        // NOTE: arm->filter / arm->body are frozen-list element fields, walked
        // read-only, returns discarded. Catch-filter type rewrites are NOT
        // possible via RAV (Option B); use ASTWriter if a pass needs that.
        if self.dyn()->walkup_try_catch_expr(n) == false {
            return n
        }

        if n->try_expr != &null {
            n->try_expr = self.dyn()->dispatch_expr(n->try_expr)
        }

        for var i: usize = 0; i < n->catch_arms.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *arm = n->catch_arms.get(i) // *TryCatchExpr::CatchArm
            // arm->binding is the bound error name (name node) skip
            if arm->filter != &null { // discard
                self.dyn()->dispatch_type(arm->filter)
            }

            if self.stop {
                break
            }

            if arm->body != &null { // discard
                self.dyn()->dispatch_expr(arm->body)
            }
        }

        return n
    }

    fn traverse_match_expr(self, n: *Expressions::MatchExpr) -> *Expressions::MatchExpr {
        if self.dyn()->walkup_match_expr(n) == false {
            return n
        }

        if n->scrutinee != &null {
            n->scrutinee = self.dyn()->dispatch_expr(n->scrutinee)
        }

        for var i: usize = 0; i < n->cases.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->traverse_match_case(n->cases.get(i))
        }

        return n
    }

    fn traverse_range_expr(self, n: *Expressions::RangeExpr) -> *Expressions::RangeExpr {
        if self.dyn()->walkup_range_expr(n) == false {
            return n
        }

        if n->begin != &null {
            n->begin = self.dyn()->dispatch_expr(n->begin)
        }

        if n->end != &null {
            n->end = self.dyn()->dispatch_expr(n->end)
        }

        return n
    }

    fn traverse_closure_expr(self,
                             n: unsafe *Expressions::ClosureExpr) -> unsafe *Expressions::ClosureExpr {
        if self.dyn()->walkup_closure_expr(n) == false {
            return n
        }

        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->generic_params.get(i)) // discard
        }

        if self.stop {
            return n
        }

        for var i: usize = 0; i < n->params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->params.get(i)) // discard
        }

        if self.stop {
            return n
        }

        for var i: usize = 0; i < n->captures.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *cap = n->captures.get(i)
            if cap->name != &null {
                self.dyn()->dispatch_expr(cap->name) // discard
            }
        }

        if self.stop {
            return n
        }

        for var i: usize = 0; i < n->panic_set.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_type(*n->panic_set.get(i)) // discard
        }

        if self.stop {
            return n
        }

        if n->return_type != &null {
            n->return_type = self.dyn()->dispatch_type(n->return_type)
        }

        if n->body_block != &null {
            n->body_block = self.dyn()->traverse_block(n->body_block)
        }

        if n->body_expr != &null {
            n->body_expr = self.dyn()->dispatch_expr(n->body_expr)
        }

        return n
    }

    fn traverse_await_expr(self, n: *Expressions::AwaitExpr) -> *Expressions::AwaitExpr {
        if self.dyn()->walkup_await_expr(n) == false {
            return n
        }

        if n->operand != &null {
            n->operand = self.dyn()->dispatch_expr(n->operand)
        }

        return n
    }

    fn traverse_defined_expr(self, n: *Expressions::DefinedExpr) -> *Expressions::DefinedExpr {
        self.dyn()->walkup_defined_expr(n)
        return n
    }

    fn traverse_type_trait_expr(self,
                                n: *Expressions::TypeTraitExpr) -> *Expressions::TypeTraitExpr {
        if self.dyn()->walkup_type_trait_expr(n) == false {
            return n
        }

        if n->type_arg != &null {
            n->type_arg = self.dyn()->dispatch_type(n->type_arg)
        }

        return n
    }

    fn traverse_cxx_new_expr(self, n: *Expressions::CxxNewExpr) -> *Expressions::CxxNewExpr {
        if self.dyn()->walkup_cxx_new_expr(n) == false {
            return n
        }

        if n->init != &null {
            n->init = self.dyn()->dispatch_expr(n->init)
        }

        if self.stop {
            return n
        }

        if n->elem_size != &null {
            n->elem_size = self.dyn()->dispatch_expr(n->elem_size)
        }

        if self.stop {
            return n
        }

        if n->count != &null {
            n->count = self.dyn()->dispatch_expr(n->count)
        }

        return n
    }

    fn traverse_unwrap_expr(self, n: *Expressions::UnwrapExpr) -> *Expressions::UnwrapExpr {
        if self.dyn()->walkup_unwrap_expr(n) == false {
            return n
        }

        if n->operand != &null {
            n->operand = self.dyn()->dispatch_expr(n->operand)
        }

        return n
    }

    /// The attribute's arguments, then its operand. The name is the
    /// attribute's, not a name use: walking it would make every visitor see
    /// an unbound identifier (as a named call argument's label would).
    fn traverse_attributed_expr(self,
                                n: *Expressions::AttributedExpr) -> *Expressions::AttributedExpr {
        if self.dyn()->walkup_attributed_expr(n) == false {
            return n
        }

        for var i: usize = 0; i < n->args.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *a     = *n->args.get(i)
            var unsafe *value = named_call_arg_value(a)
            if value != &null {
                self.dyn()->dispatch_expr(value)
                continue
            }

            self.dyn()->dispatch_expr(a) // discard
        }

        if self.stop {
            return n
        }

        if n->operand != &null {
            n->operand = self.dyn()->dispatch_expr(n->operand)
        }

        return n
    }

    /// The slot, then the operand (a SlotPut builds the slot from it).
    fn traverse_panic_op_expr(self, n: *Expressions::PanicOpExpr) -> *Expressions::PanicOpExpr {
        if self.dyn()->walkup_panic_op_expr(n) == false {
            return n
        }

        if n->slot != &null {
            self.dyn()->dispatch_expr(n->slot)
        }

        if self.stop {
            return n
        }

        if n->operand != &null {
            self.dyn()->dispatch_expr(n->operand)
        }

        return n
    }

    fn traverse_spawn_expr(self, n: *Expressions::SpawnExpr) -> *Expressions::SpawnExpr {
        if self.dyn()->walkup_spawn_expr(n) == false {
            return n
        }

        if n->operand != &null {
            n->operand = self.dyn()->dispatch_expr(n->operand)
        }

        return n
    }

    fn traverse_thread_expr(self, n: *Expressions::ThreadExpr) -> *Expressions::ThreadExpr {
        if self.dyn()->walkup_thread_expr(n) == false {
            return n
        }

        if n->operand != &null {
            n->operand = self.dyn()->dispatch_expr(n->operand)
        }

        return n
    }

    fn traverse_constraint_expr(self,
                                n: *Expressions::ConstraintExpr) -> *Expressions::ConstraintExpr {
        if self.dyn()->walkup_constraint_expr(n) == false {
            return n
        }

        if n->lhs != &null {
            n->lhs = self.dyn()->dispatch_expr(n->lhs)
        }

        if self.stop {
            return n
        }

        if n->rhs != &null {
            n->rhs = self.dyn()->dispatch_type(n->rhs)
        }

        return n
    }

    fn traverse_size_of_expr(self, n: *Expressions::SizeOfExpr) -> *Expressions::SizeOfExpr {
        if self.dyn()->walkup_size_of_expr(n) == false {
            return n
        }

        if n->type_arg != &null {
            n->type_arg = self.dyn()->dispatch_type(n->type_arg)
        }

        return n
    }

    fn traverse_align_of_expr(self, n: *Expressions::AlignOfExpr) -> *Expressions::AlignOfExpr {
        if self.dyn()->walkup_align_of_expr(n) == false {
            return n
        }

        if n->type_arg != &null {
            n->type_arg = self.dyn()->dispatch_type(n->type_arg)
        }

        return n
    }

    fn traverse_type_of_expr(self, n: *Expressions::TypeOfExpr) -> *Expressions::TypeOfExpr {
        if self.dyn()->walkup_type_of_expr(n) == false {
            return n
        }

        if n->operand != &null {
            n->operand = self.dyn()->dispatch_expr(n->operand)
        }

        // n->resolved_type is a sema link skip
        return n
    }

    fn traverse_paren_expr(self, n: *Expressions::ParenExpr) -> *Expressions::ParenExpr {
        if self.dyn()->walkup_paren_expr(n) == false {
            return n
        }

        if n->inner != &null {
            n->inner = self.dyn()->dispatch_expr(n->inner)
        }

        return n
    }

    /// No children by construction   a VerbatimExpr is an unparsed span.
    fn traverse_verbatim_expr(self, n: *Expressions::VerbatimExpr) -> *Expressions::VerbatimExpr {
        if self.dyn()->walkup_verbatim_expr(n) == false {
            return n
        }

        return n
    }

    /// The VALUE is the only child. `name` is a label, not an expression:
    /// walking it would bind a parameter name as though it were a use.
    fn traverse_named_arg_expr(self, n: *Expressions::NamedArgExpr) -> *Expressions::NamedArgExpr {
        if self.dyn()->walkup_named_arg_expr(n) == false {
            return n
        }

        if n->value != &null {
            n->value = self.dyn()->dispatch_expr(n->value)
        }

        return n
    }

    fn traverse_eval_expr(self, n: *Expressions::EvalExpr) -> *Expressions::EvalExpr {
        if self.dyn()->walkup_eval_expr(n) == false {
            return n
        }

        if n->operand != &null {
            n->operand = self.dyn()->dispatch_expr(n->operand)
        }

        return n
    }

    fn traverse_unsafe_expr(self, n: *Expressions::UnsafeExpr) -> *Expressions::UnsafeExpr {
        if self.dyn()->walkup_unsafe_expr(n) == false {
            return n
        }

        if n->operand != &null {
            n->operand = self.dyn()->dispatch_expr(n->operand)
        }

        return n
    }

    fn traverse_delete_expr(self, n: *Expressions::DeleteExpr) -> *Expressions::DeleteExpr {
        if self.dyn()->walkup_delete_expr(n) == false {
            return n
        }

        if n->operand != &null {
            n->operand = self.dyn()->dispatch_expr(n->operand)
        }

        return n
    }

    fn traverse_pack_expansion_expr(self,
                                    n: *Expressions::PackExpansionExpr) -> *Expressions::PackExpansionExpr {
        if self.dyn()->walkup_pack_expansion_expr(n) == false {
            return n
        }

        if n->operand != &null {
            n->operand = self.dyn()->dispatch_expr(n->operand)
        }

        return n
    }

    fn traverse_type_cast_expr(self, n: *Expressions::TypeCastExpr) -> *Expressions::TypeCastExpr {
        if self.dyn()->walkup_type_cast_expr(n) == false {
            return n
        }

        if n->operand != &null {
            n->operand = self.dyn()->dispatch_expr(n->operand)
        }

        if n->target != &null {
            n->target = self.dyn()->dispatch_type(n->target)
        }

        return n
    }

    fn traverse_implicit_boundary_cast_expr(self,
                                            n: *Expressions::ImplicitBoundaryCastExpr) -> *Expressions::ImplicitBoundaryCastExpr {
        if self.dyn()->walkup_implicit_boundary_cast_expr(n) == false {
            return n
        }

        if n->original != &null {
            n->original = self.dyn()->dispatch_expr(n->original)
        }

        if n->source_type != &null {
            n->source_type = self.dyn()->dispatch_type(n->source_type)
        }

        if n->target_type != &null {
            n->target_type = self.dyn()->dispatch_type(n->target_type)
        }

        return n
    }

    /// ## walkup (family hook THEN leaf hook, base-first)

    fn walkup_integer_literal_expr(self, n: *IntegerLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_integer_literal_expr(n)
    }

    fn walkup_floating_literal_expr(self, n: *FloatingLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_floating_literal_expr(n)
    }

    fn walkup_string_literal_expr(self, n: *StringLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_string_literal_expr(n)
    }

    fn walkup_character_literal_expr(self, n: *CharacterLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_character_literal_expr(n)
    }

    fn walkup_boolean_literal_expr(self, n: *BooleanLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_boolean_literal_expr(n)
    }

    fn walkup_null_literal_expr(self, n: *NullLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_null_literal_expr(n)
    }

    fn walkup_list_literal_expr(self, n: *Expressions::ListLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_list_literal_expr(n)
    }

    fn walkup_init_list_expr(self, n: *Expressions::InitListExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_init_list_expr(n)
    }

    fn walkup_stmt_expr(self, n: *Expressions::StmtExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_stmt_expr(n)
    }

    fn walkup_variant_init_expr(self, n: *Expressions::VariantInitExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_variant_init_expr(n)
    }

    fn walkup_tuple_literal_expr(self, n: *Expressions::TupleLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_tuple_literal_expr(n)
    }

    fn walkup_set_literal_expr(self, n: *Expressions::SetLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_set_literal_expr(n)
    }

    fn walkup_map_literal_expr(self, n: *Expressions::MapLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_map_literal_expr(n)
    }

    fn walkup_named_initializer_expr(self, n: *Expressions::NamedInitializerExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_named_initializer_expr(n)
    }

    fn walkup_anon_initializer_expr(self, n: *Expressions::AnonInitializerExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_anon_initializer_expr(n)
    }

    fn walkup_chain_expr(self, n: *ChainExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_chain_expr(n)
    }

    fn walkup_call_expr(self, n: *Expressions::CallExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_call_expr(n)
    }

    fn walkup_subscript_expr(self, n: *Expressions::SubscriptExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_subscript_expr(n)
    }

    fn walkup_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_named_ident_expr(n)
    }

    fn walkup_unary_operator_expr(self, n: *Expressions::UnaryOperatorExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_unary_operator_expr(n)
    }

    fn walkup_binary_operator_expr(self, n: *Expressions::BinaryOperatorExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_binary_operator_expr(n)
    }

    fn walkup_assign_operator_expr(self, n: *Expressions::AssignOperatorExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_assign_operator_expr(n)
    }

    fn walkup_impl_conformance_expr(self, n: *Expressions::ImplConformanceExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_impl_conformance_expr(n)
    }

    fn walkup_derives_relation_expr(self, n: *Expressions::DerivesRelationExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_derives_relation_expr(n)
    }

    fn walkup_if_expr(self, n: *Expressions::IfExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_if_expr(n)
    }

    fn walkup_try_catch_expr(self, n: unsafe *Expressions::TryCatchExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_try_catch_expr(n)
    }

    fn walkup_match_expr(self, n: *Expressions::MatchExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_match_expr(n)
    }

    fn walkup_range_expr(self, n: *Expressions::RangeExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_range_expr(n)
    }

    fn walkup_closure_expr(self, n: unsafe *Expressions::ClosureExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_closure_expr(n)
    }

    fn walkup_await_expr(self, n: *Expressions::AwaitExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_await_expr(n)
    }

    fn walkup_attributed_expr(self, n: *Expressions::AttributedExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_attributed_expr(n)
    }

    fn walkup_panic_op_expr(self, n: *Expressions::PanicOpExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_panic_op_expr(n)
    }

    fn walkup_defined_expr(self, n: *Expressions::DefinedExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_defined_expr(n)
    }

    fn walkup_type_trait_expr(self, n: *Expressions::TypeTraitExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_type_trait_expr(n)
    }

    fn walkup_cxx_new_expr(self, n: *Expressions::CxxNewExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_cxx_new_expr(n)
    }

    fn walkup_unwrap_expr(self, n: *Expressions::UnwrapExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_unwrap_expr(n)
    }

    fn walkup_spawn_expr(self, n: *Expressions::SpawnExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_spawn_expr(n)
    }

    fn walkup_thread_expr(self, n: *Expressions::ThreadExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_thread_expr(n)
    }

    fn walkup_constraint_expr(self, n: *Expressions::ConstraintExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_constraint_expr(n)
    }

    fn walkup_size_of_expr(self, n: *Expressions::SizeOfExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_size_of_expr(n)
    }

    fn walkup_align_of_expr(self, n: *Expressions::AlignOfExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_align_of_expr(n)
    }

    fn walkup_type_of_expr(self, n: *Expressions::TypeOfExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_type_of_expr(n)
    }

    fn walkup_paren_expr(self, n: *Expressions::ParenExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_paren_expr(n)
    }

    fn walkup_verbatim_expr(self, n: *Expressions::VerbatimExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_verbatim_expr(n)
    }

    fn walkup_named_arg_expr(self, n: *Expressions::NamedArgExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_named_arg_expr(n)
    }

    fn visit_paren_expr(self, n: *Expressions::ParenExpr) -> bool {
        return true
    }

    fn visit_verbatim_expr(self, n: *Expressions::VerbatimExpr) -> bool {
        return true
    }

    fn visit_named_arg_expr(self, n: *Expressions::NamedArgExpr) -> bool {
        return true
    }

    fn walkup_eval_expr(self, n: *Expressions::EvalExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_eval_expr(n)
    }

    fn walkup_unsafe_expr(self, n: *Expressions::UnsafeExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_unsafe_expr(n)
    }

    fn walkup_delete_expr(self, n: *Expressions::DeleteExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_delete_expr(n)
    }

    fn walkup_pack_expansion_expr(self, n: *Expressions::PackExpansionExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_pack_expansion_expr(n)
    }

    fn walkup_type_cast_expr(self, n: *Expressions::TypeCastExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_type_cast_expr(n)
    }

    fn walkup_implicit_boundary_cast_expr(self, n: *Expressions::ImplicitBoundaryCastExpr) -> bool {
        if self.dyn()->visit_expr(n) == false {
            return false
        }

        return self.dyn()->visit_implicit_boundary_cast_expr(n)
    }

    /// ## leaf visit hooks (override per node kind)

    fn visit_integer_literal_expr(self, n: *IntegerLiteralExpr) -> bool {
        return true
    }

    fn visit_floating_literal_expr(self, n: *FloatingLiteralExpr) -> bool {
        return true
    }

    fn visit_string_literal_expr(self, n: *StringLiteralExpr) -> bool {
        return true
    }

    fn visit_character_literal_expr(self, n: *CharacterLiteralExpr) -> bool {
        return true
    }

    fn visit_boolean_literal_expr(self, n: *BooleanLiteralExpr) -> bool {
        return true
    }

    fn visit_null_literal_expr(self, n: *NullLiteralExpr) -> bool {
        return true
    }

    fn visit_list_literal_expr(self, n: *Expressions::ListLiteralExpr) -> bool {
        return true
    }

    fn visit_init_list_expr(self, n: *Expressions::InitListExpr) -> bool {
        return true
    }

    fn visit_stmt_expr(self, n: *Expressions::StmtExpr) -> bool {
        return true
    }

    fn visit_variant_init_expr(self, n: *Expressions::VariantInitExpr) -> bool {
        return true
    }

    fn visit_tuple_literal_expr(self, n: *Expressions::TupleLiteralExpr) -> bool {
        return true
    }

    fn visit_set_literal_expr(self, n: *Expressions::SetLiteralExpr) -> bool {
        return true
    }

    fn visit_map_literal_expr(self, n: *Expressions::MapLiteralExpr) -> bool {
        return true
    }

    fn visit_named_initializer_expr(self, n: *Expressions::NamedInitializerExpr) -> bool {
        return true
    }

    fn visit_anon_initializer_expr(self, n: *Expressions::AnonInitializerExpr) -> bool {
        return true
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        return true
    }

    fn visit_call_expr(self, n: *Expressions::CallExpr) -> bool {
        return true
    }

    fn visit_subscript_expr(self, n: *Expressions::SubscriptExpr) -> bool {
        return true
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        return true
    }

    fn visit_unary_operator_expr(self, n: *Expressions::UnaryOperatorExpr) -> bool {
        return true
    }

    fn visit_binary_operator_expr(self, n: *Expressions::BinaryOperatorExpr) -> bool {
        return true
    }

    fn visit_assign_operator_expr(self, n: *Expressions::AssignOperatorExpr) -> bool {
        return true
    }

    fn visit_impl_conformance_expr(self, n: *Expressions::ImplConformanceExpr) -> bool {
        return true
    }

    fn visit_derives_relation_expr(self, n: *Expressions::DerivesRelationExpr) -> bool {
        return true
    }

    fn visit_if_expr(self, n: *Expressions::IfExpr) -> bool {
        return true
    }

    fn visit_try_catch_expr(self, n: *Expressions::TryCatchExpr) -> bool {
        return true
    }

    fn visit_match_expr(self, n: *Expressions::MatchExpr) -> bool {
        return true
    }

    fn visit_range_expr(self, n: *Expressions::RangeExpr) -> bool {
        return true
    }

    fn visit_closure_expr(self, n: *Expressions::ClosureExpr) -> bool {
        return true
    }

    fn visit_await_expr(self, n: *Expressions::AwaitExpr) -> bool {
        return true
    }

    fn visit_unwrap_expr(self, n: *Expressions::UnwrapExpr) -> bool {
        return true
    }

    fn visit_defined_expr(self, n: *Expressions::DefinedExpr) -> bool {
        return true
    }

    fn visit_type_trait_expr(self, n: *Expressions::TypeTraitExpr) -> bool {
        return true
    }

    fn visit_cxx_new_expr(self, n: *Expressions::CxxNewExpr) -> bool {
        return true
    }

    fn visit_attributed_expr(self, n: *Expressions::AttributedExpr) -> bool {
        return true
    }

    fn visit_panic_op_expr(self, n: *Expressions::PanicOpExpr) -> bool {
        return true
    }

    fn visit_spawn_expr(self, n: *Expressions::SpawnExpr) -> bool {
        return true
    }

    fn visit_thread_expr(self, n: *Expressions::ThreadExpr) -> bool {
        return true
    }

    fn visit_constraint_expr(self, n: *Expressions::ConstraintExpr) -> bool {
        return true
    }

    fn visit_size_of_expr(self, n: *Expressions::SizeOfExpr) -> bool {
        return true
    }

    fn visit_align_of_expr(self, n: *Expressions::AlignOfExpr) -> bool {
        return true
    }

    fn visit_type_of_expr(self, n: *Expressions::TypeOfExpr) -> bool {
        return true
    }

    fn visit_eval_expr(self, n: *Expressions::EvalExpr) -> bool {
        return true
    }

    fn visit_unsafe_expr(self, n: *Expressions::UnsafeExpr) -> bool {
        return true
    }

    fn visit_delete_expr(self, n: *Expressions::DeleteExpr) -> bool {
        return true
    }

    fn visit_pack_expansion_expr(self, n: *Expressions::PackExpansionExpr) -> bool {
        return true
    }

    fn visit_type_cast_expr(self, n: *Expressions::TypeCastExpr) -> bool {
        return true
    }

    fn visit_implicit_boundary_cast_expr(self, n: *Expressions::ImplicitBoundaryCastExpr) -> bool {
        return true
    }

    /// # STMT FAMILY

    pub fn dispatch_stmt(self, s: unsafe *Stmt) -> unsafe *Stmt {
        if s == &null {
            return s
        }

        if self.stop {
            return s
        }

        match s->kind {
            case StmtKind::CompoundStmt {
                return self.dyn()->traverse_compound_stmt(cast<Statements::CompoundStmt>(s))
            } case StmtKind::ExpressionStmt {
                return self.dyn()->traverse_expression_stmt(cast<Statements::ExpressionStmt>(s))
            } case StmtKind::DeclStmt {
                return self.dyn()->traverse_decl_stmt(cast<Statements::DeclStmt>(s))
            } case StmtKind::ReturnStmt {
                return self.dyn()->traverse_return_stmt(cast<Statements::ReturnStmt>(s))
            } case StmtKind::BreakStmt {
                return self.dyn()->traverse_break_stmt(cast<Statements::BreakStmt>(s))
            } case StmtKind::ContinueStmt {
                return self.dyn()->traverse_continue_stmt(cast<Statements::ContinueStmt>(s))
            } case StmtKind::PanicStmt {
                return self.dyn()->traverse_panic_stmt(cast<Statements::PanicStmt>(s))
            } case StmtKind::YieldStmt {
                return self.dyn()->traverse_yield_stmt(cast<Statements::YieldStmt>(s))
            } case StmtKind::RuntimeAssertStmt {
                return self.dyn()->traverse_runtime_assert_stmt(
                    cast<Statements::RuntimeAssertStmt>(s),
                )
            } case StmtKind::StaticAssertStmt {
                return self.dyn()->traverse_static_assert_stmt(
                    cast<Statements::StaticAssertStmt>(s),
                )
            } case StmtKind::LabelIntrinsicStmt {
                return self.dyn()->traverse_label_intrinsic_stmt(
                    cast<Statements::LabelIntrinsicStmt>(s),
                )
            } case StmtKind::JumpIntrinsicStmt {
                return self.dyn()->traverse_jump_intrinsic_stmt(
                    cast<Statements::JumpIntrinsicStmt>(s),
                )
            } case StmtKind::ConditionalStmt {
                return self.dyn()->traverse_conditional_stmt(cast<Statements::ConditionalStmt>(s))
            } case StmtKind::WhileLoopStmt {
                return self.dyn()->traverse_while_loop_stmt(cast<Statements::WhileLoopStmt>(s))
            } case StmtKind::LoopStmt {
                return self.dyn()->traverse_loop_stmt(cast<Statements::LoopStmt>(s))
            } case StmtKind::RangedForStmt {
                return self.dyn()->traverse_ranged_for_stmt(cast<Statements::RangedForStmt>(s))
            } case StmtKind::IndexedForStmt {
                return self.dyn()->traverse_indexed_for_stmt(cast<Statements::IndexedForStmt>(s))
            } case StmtKind::MatchStmt {
                return self.dyn()->traverse_match_stmt(cast<Statements::MatchStmt>(s))
            } case StmtKind::LabeledStmt {
                return self.dyn()->traverse_labeled_stmt(cast<Statements::LabeledStmt>(s))
            } case StmtKind::TryCatchStmt {
                return self.dyn()->traverse_try_catch_stmt(cast<Statements::TryCatchStmt>(s))
            } case StmtKind::FinallyStmt {
                return self.dyn()->traverse_finally_stmt(cast<Statements::FinallyStmt>(s))
            } case StmtKind::UnsafeBlockStmt {
                return self.dyn()->traverse_unsafe_block_stmt(cast<Statements::UnsafeBlockStmt>(s))
            } case StmtKind::ContextBindingStmt {
                return self.dyn()->traverse_context_binding_stmt(
                    cast<Statements::ContextBindingStmt>(s),
                )
            } case StmtKind::DestructuringDeclStmt {
                return self.dyn()->traverse_destructuring_decl_stmt(
                    cast<Statements::DestructuringDeclStmt>(s),
                )
            } case StmtKind::InlineBlockStmt {
                return self.dyn()->traverse_inline_block_stmt(cast<Statements::InlineBlockStmt>(s))
            } case StmtKind::EvalBlockStmt {
                return self.dyn()->traverse_eval_block_stmt(cast<Statements::EvalBlockStmt>(s))
            } case StmtKind::SwitchDispatchStmt {
                return self.dyn()->traverse_switch_dispatch_stmt(
                    cast<Statements::SwitchDispatchStmt>(s),
                )
            } case StmtKind::RecoveryStmt {
                self.dyn()->visit_stmt(s)
                return s
            } case StmtKind::StmtKindCount {
                kairo::std::ice_fail("StmtKindCount reached RAV in Stage 1 - this is a bug")
            }
        }
    }

    fn visit_stmt(self, n: *Stmt) -> bool {
        return true
    }

    /// ## traverse bodies

    fn traverse_compound_stmt(self,
                              n: unsafe *Statements::CompoundStmt) -> unsafe *Statements::CompoundStmt {
        if self.dyn()->walkup_compound_stmt(n) == false {
            return n
        }

        for var i: usize = 0; i < n->body.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_stmt(*n->body.get(i)) // discard
        }

        return n
    }

    fn traverse_expression_stmt(self,
                                n: *Statements::ExpressionStmt) -> *Statements::ExpressionStmt {
        if self.dyn()->walkup_expression_stmt(n) == false {
            return n
        }

        if n->expr != &null {
            n->expr = self.dyn()->dispatch_expr(n->expr)
        }

        return n
    }

    fn traverse_decl_stmt(self, n: unsafe *Statements::DeclStmt) -> unsafe *Statements::DeclStmt {
        if self.dyn()->walkup_decl_stmt(n) == false {
            return n
        }

        if n->decl != &null {
            n->decl = self.dyn()->dispatch_decl(n->decl)
        }

        return n
    }

    fn traverse_return_stmt(self, n: *Statements::ReturnStmt) -> *Statements::ReturnStmt {
        if self.dyn()->walkup_return_stmt(n) == false {
            return n
        }

        if n->value != &null {
            n->value = self.dyn()->dispatch_expr(n->value)
        }

        return n
    }

    fn traverse_break_stmt(self, n: *Statements::BreakStmt) -> *Statements::BreakStmt {
        self.dyn()->walkup_break_stmt(n)
        return n
    }

    fn traverse_continue_stmt(self, n: *Statements::ContinueStmt) -> *Statements::ContinueStmt {
        self.dyn()->walkup_continue_stmt(n)
        return n
    }

    fn traverse_panic_stmt(self, n: *Statements::PanicStmt) -> *Statements::PanicStmt {
        if self.dyn()->walkup_panic_stmt(n) == false {
            return n
        }

        if n->payload != &null {
            n->payload = self.dyn()->dispatch_expr(n->payload)
        }

        return n
    }

    fn traverse_yield_stmt(self, n: *Statements::YieldStmt) -> *Statements::YieldStmt {
        if self.dyn()->walkup_yield_stmt(n) == false {
            return n
        }

        if n->value != &null {
            n->value = self.dyn()->dispatch_expr(n->value)
        }

        return n
    }

    fn traverse_runtime_assert_stmt(self,
                                    n: *Statements::RuntimeAssertStmt) -> *Statements::RuntimeAssertStmt {
        if self.dyn()->walkup_runtime_assert_stmt(n) == false {
            return n
        }

        if n->condition != &null {
            n->condition = self.dyn()->dispatch_expr(n->condition)
        }

        if n->message != &null {
            n->message = self.dyn()->dispatch_expr(n->message)
        }

        return n
    }

    fn traverse_static_assert_stmt(self,
                                   n: *Statements::StaticAssertStmt) -> *Statements::StaticAssertStmt {
        if self.dyn()->walkup_static_assert_stmt(n) == false {
            return n
        }

        if n->condition != &null {
            n->condition = self.dyn()->dispatch_expr(n->condition)
        }

        if n->message != &null {
            n->message = self.dyn()->dispatch_expr(n->message)
        }

        return n
    }

    fn traverse_label_intrinsic_stmt(self,
                                     n: *Statements::LabelIntrinsicStmt) -> *Statements::LabelIntrinsicStmt {
        self.dyn()->walkup_label_intrinsic_stmt(n)
        return n
    }

    fn traverse_jump_intrinsic_stmt(self,
                                    n: *Statements::JumpIntrinsicStmt) -> *Statements::JumpIntrinsicStmt {
        self.dyn()->walkup_jump_intrinsic_stmt(n)
        return n
    }

    fn traverse_conditional_stmt(self,
                                 n: unsafe *Statements::ConditionalStmt) -> unsafe *Statements::ConditionalStmt {
        if self.dyn()->walkup_conditional_stmt(n) == false {
            return n
        }

        if n->cond != &null {
            n->cond = self.dyn()->dispatch_expr(n->cond)
        }

        n->then_ = self.dyn()->traverse_block(n->then_)
        if n->else_ != &null {
            n->else_ = self.dyn()->dispatch_stmt(n->else_)
        }

        return n
    }

    fn traverse_while_loop_stmt(self, n: *Statements::WhileLoopStmt) -> *Statements::WhileLoopStmt {
        if self.dyn()->walkup_while_loop_stmt(n) == false {
            return n
        }

        if n->cond != &null {
            n->cond = self.dyn()->dispatch_expr(n->cond)
        }

        n->body = self.dyn()->traverse_block(n->body)
        return n
    }

    fn traverse_loop_stmt(self, n: *Statements::LoopStmt) -> *Statements::LoopStmt {
        if self.dyn()->walkup_loop_stmt(n) == false {
            return n
        }

        n->body = self.dyn()->traverse_block(n->body)
        return n
    }

    fn traverse_ranged_for_stmt(self,
                                n: unsafe *Statements::RangedForStmt) -> unsafe *Statements::RangedForStmt {
        if self.dyn()->walkup_ranged_for_stmt(n) == false {
            return n
        }

        // bindings carry only a NamedIdentExpr name (name node) skip.
        if n->iterable != &null {
            n->iterable = self.dyn()->dispatch_expr(n->iterable)
        }

        n->body = self.dyn()->traverse_block(n->body)
        return n
    }

    fn traverse_indexed_for_stmt(self,
                                 n: *Statements::IndexedForStmt) -> *Statements::IndexedForStmt {
        if self.dyn()->walkup_indexed_for_stmt(n) == false {
            return n
        }

        if n->init != &null {
            n->init = self.dyn()->dispatch_stmt(n->init)
        }

        if n->cond != &null {
            n->cond = self.dyn()->dispatch_expr(n->cond)
        }

        if n->update != &null {
            n->update = self.dyn()->dispatch_expr(n->update)
        }

        n->body = self.dyn()->traverse_block(n->body)
        return n
    }

    fn traverse_match_stmt(self, n: *Statements::MatchStmt) -> *Statements::MatchStmt {
        if self.dyn()->walkup_match_stmt(n) == false {
            return n
        }

        if n->scrutinee != &null {
            n->scrutinee = self.dyn()->dispatch_expr(n->scrutinee)
        }

        for var i: usize = 0; i < n->cases.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->traverse_match_case(n->cases.get(i))
        }

        return n
    }

    fn traverse_labeled_stmt(self, n: *Statements::LabeledStmt) -> *Statements::LabeledStmt {
        if self.dyn()->walkup_labeled_stmt(n) == false {
            return n
        }

        if n->inner != &null {
            n->inner = self.dyn()->dispatch_stmt(n->inner)
        }

        return n
    }

    fn traverse_try_catch_stmt(self, n: *Statements::TryCatchStmt) -> *Statements::TryCatchStmt {
        if self.dyn()->walkup_try_catch_stmt(n) == false {
            return n
        }

        n->try_body = self.dyn()->traverse_block(n->try_body)
        for var i: usize = 0; i < n->arms.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *arm = n->arms.get(i) // *CatchArm
            // arm->binding is the bound error name (name node) skip
            if arm->filter != &null { // discard
                self.dyn()->dispatch_type(arm->filter)
            }

            if self.stop {
                break
            }

            if arm->body != &null { // discard (block, list element)
                self.dyn()->dispatch_stmt(arm->body)
            }
        }

        return n
    }

    fn traverse_finally_stmt(self, n: *Statements::FinallyStmt) -> *Statements::FinallyStmt {
        if self.dyn()->walkup_finally_stmt(n) == false {
            return n
        }

        n->body = self.dyn()->traverse_block(n->body)
        return n
    }

    fn traverse_unsafe_block_stmt(self,
                                  n: *Statements::UnsafeBlockStmt) -> *Statements::UnsafeBlockStmt {
        if self.dyn()->walkup_unsafe_block_stmt(n) == false {
            return n
        }

        n->body = self.dyn()->traverse_block(n->body)
        return n
    }

    fn traverse_context_binding_stmt(self,
                                     n: *Statements::ContextBindingStmt) -> *Statements::ContextBindingStmt {
        if self.dyn()->walkup_context_binding_stmt(n) == false {
            return n
        }

        // bindings carry only NamedIdentExpr names skip.
        if n->value != &null {
            n->value = self.dyn()->dispatch_expr(n->value)
        }

        n->body = self.dyn()->traverse_block(n->body)
        return n
    }

    fn traverse_destructuring_decl_stmt(self,
                                        n: *Statements::DestructuringDeclStmt) -> *Statements::DestructuringDeclStmt {
        if self.dyn()->walkup_destructuring_decl_stmt(n) == false {
            return n
        }

        // bindings carry only NamedIdentExpr names skip.
        if n->value != &null {
            n->value = self.dyn()->dispatch_expr(n->value)
        }

        return n
    }

    fn traverse_inline_block_stmt(self,
                                  n: *Statements::InlineBlockStmt) -> *Statements::InlineBlockStmt {
        // body is opaque foreign text (body_span); no Kairo children.
        self.dyn()->walkup_inline_block_stmt(n)
        return n
    }

    fn traverse_eval_block_stmt(self, n: *Statements::EvalBlockStmt) -> *Statements::EvalBlockStmt {
        if self.dyn()->walkup_eval_block_stmt(n) == false {
            return n
        }

        for var i: usize = 0; i < n->body.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->body.get(i)) // discard
        }

        return n
    }

    fn traverse_switch_dispatch_stmt(self,
                                     n: *Statements::SwitchDispatchStmt) -> *Statements::SwitchDispatchStmt {
        if self.dyn()->walkup_switch_dispatch_stmt(n) == false {
            return n
        }

        if n->value != &null {
            n->value = self.dyn()->dispatch_expr(n->value)
        }

        for var i: usize = 0; i < n->cases.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *c = n->cases.get(i)
            if c->lo != &null {
                c->lo = self.dyn()->dispatch_expr(c->lo)
            }

            if c->hi != &null {
                c->hi = self.dyn()->dispatch_expr(c->hi)
            }
        }

        if n->default_stmt != &null {
            n->default_stmt = self.dyn()->dispatch_stmt(n->default_stmt)
        }

        return n
    }

    /// ## walkup

    fn walkup_compound_stmt(self, n: unsafe *Statements::CompoundStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_compound_stmt(n)
    }

    fn walkup_expression_stmt(self, n: *Statements::ExpressionStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_expression_stmt(n)
    }

    fn walkup_decl_stmt(self, n: unsafe *Statements::DeclStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_decl_stmt(n)
    }

    fn walkup_return_stmt(self, n: *Statements::ReturnStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_return_stmt(n)
    }

    fn walkup_break_stmt(self, n: *Statements::BreakStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_break_stmt(n)
    }

    fn walkup_continue_stmt(self, n: *Statements::ContinueStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_continue_stmt(n)
    }

    fn walkup_panic_stmt(self, n: *Statements::PanicStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_panic_stmt(n)
    }

    fn walkup_yield_stmt(self, n: *Statements::YieldStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_yield_stmt(n)
    }

    fn walkup_runtime_assert_stmt(self, n: *Statements::RuntimeAssertStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_runtime_assert_stmt(n)
    }

    fn walkup_static_assert_stmt(self, n: *Statements::StaticAssertStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_static_assert_stmt(n)
    }

    fn walkup_label_intrinsic_stmt(self, n: *Statements::LabelIntrinsicStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_label_intrinsic_stmt(n)
    }

    fn walkup_jump_intrinsic_stmt(self, n: *Statements::JumpIntrinsicStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_jump_intrinsic_stmt(n)
    }

    fn walkup_conditional_stmt(self, n: unsafe *Statements::ConditionalStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_conditional_stmt(n)
    }

    fn walkup_while_loop_stmt(self, n: *Statements::WhileLoopStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_while_loop_stmt(n)
    }

    fn walkup_loop_stmt(self, n: *Statements::LoopStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_loop_stmt(n)
    }

    fn walkup_ranged_for_stmt(self, n: unsafe *Statements::RangedForStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_ranged_for_stmt(n)
    }

    fn walkup_indexed_for_stmt(self, n: unsafe *Statements::IndexedForStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_indexed_for_stmt(n)
    }

    fn walkup_match_stmt(self, n: *Statements::MatchStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_match_stmt(n)
    }

    fn walkup_labeled_stmt(self, n: *Statements::LabeledStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_labeled_stmt(n)
    }

    fn walkup_try_catch_stmt(self, n: unsafe *Statements::TryCatchStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_try_catch_stmt(n)
    }

    fn walkup_finally_stmt(self, n: *Statements::FinallyStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_finally_stmt(n)
    }

    fn walkup_unsafe_block_stmt(self, n: *Statements::UnsafeBlockStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_unsafe_block_stmt(n)
    }

    fn walkup_context_binding_stmt(self, n: unsafe *Statements::ContextBindingStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_context_binding_stmt(n)
    }

    fn walkup_destructuring_decl_stmt(self, n: unsafe *Statements::DestructuringDeclStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_destructuring_decl_stmt(n)
    }

    fn walkup_inline_block_stmt(self, n: *Statements::InlineBlockStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_inline_block_stmt(n)
    }

    fn walkup_eval_block_stmt(self, n: *Statements::EvalBlockStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_eval_block_stmt(n)
    }

    fn walkup_switch_dispatch_stmt(self, n: *Statements::SwitchDispatchStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false {
            return false
        }

        return self.dyn()->visit_switch_dispatch_stmt(n)
    }

    /// ## leaf visit hooks

    fn visit_compound_stmt(self, n: *Statements::CompoundStmt) -> bool {
        return true
    }

    fn visit_expression_stmt(self, n: *Statements::ExpressionStmt) -> bool {
        return true
    }

    fn visit_decl_stmt(self, n: *Statements::DeclStmt) -> bool {
        return true
    }

    fn visit_return_stmt(self, n: *Statements::ReturnStmt) -> bool {
        return true
    }

    fn visit_break_stmt(self, n: *Statements::BreakStmt) -> bool {
        return true
    }

    fn visit_continue_stmt(self, n: *Statements::ContinueStmt) -> bool {
        return true
    }

    fn visit_panic_stmt(self, n: *Statements::PanicStmt) -> bool {
        return true
    }

    fn visit_yield_stmt(self, n: *Statements::YieldStmt) -> bool {
        return true
    }

    fn visit_runtime_assert_stmt(self, n: *Statements::RuntimeAssertStmt) -> bool {
        return true
    }

    fn visit_static_assert_stmt(self, n: *Statements::StaticAssertStmt) -> bool {
        return true
    }

    fn visit_label_intrinsic_stmt(self, n: *Statements::LabelIntrinsicStmt) -> bool {
        return true
    }

    fn visit_jump_intrinsic_stmt(self, n: *Statements::JumpIntrinsicStmt) -> bool {
        return true
    }

    fn visit_conditional_stmt(self, n: *Statements::ConditionalStmt) -> bool {
        return true
    }

    fn visit_while_loop_stmt(self, n: *Statements::WhileLoopStmt) -> bool {
        return true
    }

    fn visit_loop_stmt(self, n: *Statements::LoopStmt) -> bool {
        return true
    }

    fn visit_ranged_for_stmt(self, n: *Statements::RangedForStmt) -> bool {
        return true
    }

    fn visit_indexed_for_stmt(self, n: *Statements::IndexedForStmt) -> bool {
        return true
    }

    fn visit_match_stmt(self, n: *Statements::MatchStmt) -> bool {
        return true
    }

    fn visit_labeled_stmt(self, n: *Statements::LabeledStmt) -> bool {
        return true
    }

    fn visit_try_catch_stmt(self, n: *Statements::TryCatchStmt) -> bool {
        return true
    }

    fn visit_finally_stmt(self, n: *Statements::FinallyStmt) -> bool {
        return true
    }

    fn visit_unsafe_block_stmt(self, n: *Statements::UnsafeBlockStmt) -> bool {
        return true
    }

    fn visit_context_binding_stmt(self, n: *Statements::ContextBindingStmt) -> bool {
        return true
    }

    fn visit_destructuring_decl_stmt(self, n: *Statements::DestructuringDeclStmt) -> bool {
        return true
    }

    fn visit_inline_block_stmt(self, n: *Statements::InlineBlockStmt) -> bool {
        return true
    }

    fn visit_eval_block_stmt(self, n: *Statements::EvalBlockStmt) -> bool {
        return true
    }

    fn visit_switch_dispatch_stmt(self, n: *Statements::SwitchDispatchStmt) -> bool {
        return true
    }

    /// # DECL FAMILY

    pub fn dispatch_decl(self, d: unsafe *Decl) -> unsafe *Decl {
        if d == &null {
            return d
        }

        if self.stop {
            return d
        }

        match d->kind {
            case DeclKind::FunctionDecl {
                return self.dyn()->traverse_function_decl(cast<Declarations::FunctionDecl>(d))
            } case DeclKind::VariableDecl {
                return self.dyn()->traverse_variable_decl(cast<Declarations::VariableDecl>(d))
            } case DeclKind::FieldDecl {
                return self.dyn()->traverse_field_decl(cast<Declarations::FieldDecl>(d))
            } case DeclKind::ParamDecl {
                return self.dyn()->traverse_param_decl(cast<Declarations::ParamDecl>(d))
            } case DeclKind::GenericParamDecl {
                return self.dyn()->traverse_generic_param_decl(
                    cast<Declarations::GenericParamDecl>(d),
                )
            } case DeclKind::StructDecl {
                return self.dyn()->traverse_struct_decl(cast<Declarations::StructDecl>(d))
            } case DeclKind::ClassDecl {
                return self.dyn()->traverse_class_decl(cast<Declarations::ClassDecl>(d))
            } case DeclKind::InterfaceDecl {
                return self.dyn()->traverse_interface_decl(cast<Declarations::InterfaceDecl>(d))
            } case DeclKind::ExtensionDecl {
                return self.dyn()->traverse_extension_decl(cast<Declarations::ExtensionDecl>(d))
            } case DeclKind::EnumDecl {
                return self.dyn()->traverse_enum_decl(cast<Declarations::EnumDecl>(d))
            } case DeclKind::EnumVariantDecl {
                return self.dyn()->traverse_enum_variant_decl(
                    cast<Declarations::EnumVariantDecl>(d),
                )
            } case DeclKind::UnionDecl {
                return self.dyn()->traverse_union_decl(cast<Declarations::UnionDecl>(d))
            } case DeclKind::TypeAliasDecl {
                return self.dyn()->traverse_type_alias_decl(cast<Declarations::TypeAliasDecl>(d))
            } case DeclKind::ModuleDecl {
                return self.dyn()->traverse_module_decl(cast<Declarations::ModuleDecl>(d))
            } case DeclKind::ImportDecl {
                return self.dyn()->traverse_import_decl(cast<Declarations::ImportDecl>(d))
            } case DeclKind::VisibilityGroupDecl {
                return self.dyn()->traverse_visibility_group_decl(
                    cast<Declarations::VisibilityGroupDecl>(d),
                )
            } case DeclKind::EvalBlockDecl {
                return self.dyn()->traverse_eval_block_decl(cast<Declarations::EvalBlockDecl>(d))
            } case DeclKind::TestDecl {
                return self.dyn()->traverse_test_decl(cast<Declarations::TestDecl>(d))
            } case DeclKind::MacroDecl {
                return self.dyn()->traverse_macro_decl(cast<Declarations::MacroDecl>(d))
            } case DeclKind::ProcedureMacroDecl {
                return self.dyn()->traverse_procedure_macro_decl(
                    cast<Declarations::ProcedureMacroDecl>(d),
                )
            } case DeclKind::FFIBlockDecl {
                return self.dyn()->traverse_ffi_block_decl(cast<Declarations::FFIBlockDecl>(d))
            } case DeclKind::RecoveryDecl {
                self.dyn()->visit_decl(d)
                return d
            } case DeclKind::DeclKindCount {
                kairo::std::ice_fail("DeclKindCount reached RAV in Stage 1 - this is a bug")
            }
        }
    }

    fn visit_decl(self, n: *Decl) -> bool {
        return true
    }

    /// ## traverse bodies

    fn traverse_function_decl(self,
                              n: unsafe *Declarations::FunctionDecl) -> unsafe *Declarations::FunctionDecl {
        if self.dyn()->walkup_function_decl(n) == false {
            return n
        }

        // TemplateParams mixin children
        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->generic_params.get(i)) // discard
        }

        if self.stop {
            return n
        }

        // specialization argument pattern types (#68)
        for var i: usize = 0; i < n->spec_args.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_type(*n->spec_args.get(i)) // discard
        }

        if self.stop {
            return n
        }

        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause)
        }

        if self.stop {
            return n
        }

        if n->where_clause != &null {
            n->where_clause = self.dyn()->dispatch_expr(n->where_clause)
        }

        // params
        for var i: usize = 0; i < n->params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->params.get(i)) // discard
        }

        if self.stop {
            return n
        }

        for var i: usize = 0; i < n->panic_set.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_type(*n->panic_set.get(i)) // discard
        }

        if self.stop {
            return n
        }

        if n->return_type != &null {
            n->return_type = self.dyn()->dispatch_type(n->return_type)
        }

        if n->qualifier != &null { // out-of-line Class:: path
            n->qualifier = self.dyn()->dispatch_expr(n->qualifier)
        }

        if n->body_block != &null {
            n->body_block = self.dyn()->traverse_block(n->body_block)
        }

        if n->body_expr != &null {
            n->body_expr = self.dyn()->dispatch_expr(n->body_expr)
        }

        return n
    }

    fn traverse_variable_decl(self,
                              n: unsafe *Declarations::VariableDecl) -> unsafe *Declarations::VariableDecl {
        if self.dyn()->walkup_variable_decl(n) == false {
            return n
        }

        if n->type_ != &null {
            n->type_ = self.dyn()->dispatch_type(n->type_)
        }

        if n->init != &null {
            n->init = self.dyn()->dispatch_expr(n->init)
        }

        return n
    }

    fn traverse_field_decl(self,
                           n: unsafe *Declarations::FieldDecl) -> unsafe *Declarations::FieldDecl {
        if self.dyn()->walkup_field_decl(n) == false {
            return n
        }

        if n->type_ != &null {
            n->type_ = self.dyn()->dispatch_type(n->type_)
        }

        if n->init != &null {
            n->init = self.dyn()->dispatch_expr(n->init)
        }

        return n
    }

    fn traverse_param_decl(self, n: *Declarations::ParamDecl) -> *Declarations::ParamDecl {
        if self.dyn()->walkup_param_decl(n) == false {
            return n
        }

        if n->type_ != &null { // null for self
            n->type_ = self.dyn()->dispatch_type(n->type_)
        }

        if n->default_val != &null {
            n->default_val = self.dyn()->dispatch_expr(n->default_val)
        }

        return n
    }

    fn traverse_generic_param_decl(self,
                                   n: *Declarations::GenericParamDecl) -> *Declarations::GenericParamDecl {
        if self.dyn()->walkup_generic_param_decl(n) == false {
            return n
        }

        for var i: usize = 0; i < n->impl_bounds.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->traverse_inherit_edge(n->impl_bounds.get(i))
        }

        for var i: usize = 0; i < n->derives_bounds.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->traverse_inherit_edge(n->derives_bounds.get(i))
        }

        if self.stop {
            return n
        }

        if n->value_type != &null {
            n->value_type = self.dyn()->dispatch_type(n->value_type)
        }

        if n->default_type != &null {
            n->default_type = self.dyn()->dispatch_type(n->default_type)
        }

        return n
    }

    // Helper: dispatch the nested-type decls held in dc_decls, skipping the
    // VisibilityGroupDecl wrappers (their members are reached via the node's
    // fields/methods lists, so dispatching the wrapper too would double-visit).
    fn _rav_dc_nested(self, dc: *DeclContext) {
        for var i: usize = 0; i < dc->dc_decls.size(); i++ {
            if self.stop {
                break
            }

            var unsafe *d = *dc->dc_decls.get(i)
            if d == &null {
                continue
            }

            if isa<Declarations::VisibilityGroupDecl>(d) {
                continue
            }

            self.dyn()->dispatch_decl(d) // discard
        }
    }

    fn traverse_struct_decl(self,
                            n: unsafe *Declarations::StructDecl) -> unsafe *Declarations::StructDecl {
        if self.dyn()->walkup_struct_decl(n) == false {
            return n
        }

        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->generic_params.get(i)) // discard
        }

        if self.stop {
            return n
        }

        // specialization argument pattern types (#68)
        for var i: usize = 0; i < n->spec_args.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_type(*n->spec_args.get(i)) // discard
        }

        if self.stop {
            return n
        }

        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause)
        }

        for var i: usize = 0; i < n->implements.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->traverse_inherit_edge(n->implements.get(i))
        }

        // MEMBERS: flat fields + flat methods + nested types.
        //
        // A struct body holds no NAMED functions (S048E), but it does hold
        // constructors and operator overloads, and the parser puts those in
        // `methods` exactly as it does for a class. Walking only the fields
        // left a struct ctor parsed and name-bound but never type-resolved:
        // its parameters' type nodes kept a null canonical, and the first
        // thing to ask for one -- CXXSpell, emitting the interface -- ICEd
        // with "type with no canonical reached codegen". Nullary ctors hid it,
        // which is why `struct string { string() }` was fine and
        // `struct <T> Slice { Slice(*T, usize) }` was not.
        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->fields.get(i)) // discard
        }

        for var i: usize = 0; i < n->methods.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->methods.get(i)) // discard
        }

        if self.stop {
            return n
        }

        self.dyn()->_rav_dc_nested(n)
        return n
    }

    fn traverse_class_decl(self,
                           n: unsafe *Declarations::ClassDecl) -> unsafe *Declarations::ClassDecl {
        if self.dyn()->walkup_class_decl(n) == false {
            return n
        }

        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->generic_params.get(i)) // discard
        }

        if self.stop {
            return n
        }

        // specialization argument pattern types (#68)
        for var i: usize = 0; i < n->spec_args.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_type(*n->spec_args.get(i)) // discard
        }

        if self.stop {
            return n
        }

        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause)
        }

        for var i: usize = 0; i < n->derives_list.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->traverse_inherit_edge(n->derives_list.get(i))
        }

        for var i: usize = 0; i < n->implements.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->traverse_inherit_edge(n->implements.get(i))
        }

        // MEMBERS: flat fields + flat methods (grouped members are in these
        // lists too) + nested types from dc_decls. NOT the dc_decls flat walk:
        // dc_decls holds only nested types + vg-wrappers for a type body.
        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->fields.get(i)) // discard
        }

        for var i: usize = 0; i < n->methods.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->methods.get(i)) // discard
        }

        if self.stop {
            return n
        }

        self.dyn()->_rav_dc_nested(n)
        return n
    }

    fn traverse_interface_decl(self,
                               n: unsafe *Declarations::InterfaceDecl) -> unsafe *Declarations::InterfaceDecl {
        if self.dyn()->walkup_interface_decl(n) == false {
            return n
        }

        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->generic_params.get(i)) // discard
        }

        if self.stop {
            return n
        }

        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause)
        }

        for var i: usize = 0; i < n->derives_list.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->traverse_inherit_edge(n->derives_list.get(i))
        }

        for var i: usize = 0; i < n->methods.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->methods.get(i)) // discard
        }

        if self.stop {
            return n
        }

        self.dyn()->_rav_dc_nested(n)
        return n
    }

    fn traverse_extension_decl(self,
                               n: unsafe *Declarations::ExtensionDecl) -> unsafe *Declarations::ExtensionDecl {
        if self.dyn()->walkup_extension_decl(n) == false {
            return n
        }

        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->generic_params.get(i)) // discard
        }

        if self.stop {
            return n
        }

        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause)
        }

        if n->target != &null {
            n->target = self.dyn()->dispatch_type(n->target)
        }

        for var i: usize = 0; i < n->implements.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->traverse_inherit_edge(n->implements.get(i))
        }

        for var i: usize = 0; i < n->methods.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->methods.get(i)) // discard
        }

        if self.stop {
            return n
        }

        self.dyn()->_rav_dc_nested(n)
        return n
    }

    fn traverse_enum_decl(self,
                          n: unsafe *Declarations::EnumDecl) -> unsafe *Declarations::EnumDecl {
        if self.dyn()->walkup_enum_decl(n) == false {
            return n
        }

        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->generic_params.get(i)) // discard
        }

        if self.stop {
            return n
        }

        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause)
        }

        if n->underlying != &null {
            n->underlying = self.dyn()->dispatch_type(n->underlying)
        }

        // MEMBERS: variants only. The enum body parser pushes to `variants`
        // and never calls add_decl, so dc_decls is empty for an enum.
        for var i: usize = 0; i < n->variants.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->variants.get(i)) // discard
        }

        return n
    }

    fn traverse_union_decl(self,
                           n: unsafe *Declarations::UnionDecl) -> unsafe *Declarations::UnionDecl {
        if self.dyn()->walkup_union_decl(n) == false {
            return n
        }

        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->generic_params.get(i)) // discard
        }

        if self.stop {
            return n
        }

        // specialization argument pattern types (#68)
        for var i: usize = 0; i < n->spec_args.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_type(*n->spec_args.get(i)) // discard
        }

        if self.stop {
            return n
        }

        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause)
        }

        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->fields.get(i)) // discard
        }

        if self.stop {
            return n
        }

        self.dyn()->_rav_dc_nested(n)
        return n
    }

    fn traverse_enum_variant_decl(self,
                                  n: *Declarations::EnumVariantDecl) -> *Declarations::EnumVariantDecl {
        if self.dyn()->walkup_enum_variant_decl(n) == false {
            return n
        }

        if n->discriminant != &null {
            n->discriminant = self.dyn()->dispatch_expr(n->discriminant)
        }

        for var i: usize = 0; i < n->payload.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->payload.get(i)) // discard
        }

        return n
    }

    fn traverse_type_alias_decl(self,
                                n: unsafe *Declarations::TypeAliasDecl) -> unsafe *Declarations::TypeAliasDecl {
        if self.dyn()->walkup_type_alias_decl(n) == false {
            return n
        }

        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->generic_params.get(i)) // discard
        }

        if self.stop {
            return n
        }

        if n->requires_clause != &null {
            n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause)
        }

        if n->aliased != &null {
            n->aliased = self.dyn()->dispatch_type(n->aliased)
        }

        return n
    }

    fn traverse_module_decl(self,
                            n: unsafe *Declarations::ModuleDecl) -> unsafe *Declarations::ModuleDecl {
        if self.dyn()->walkup_module_decl(n) == false {
            return n
        }

        // Members live in the DeclContext (dc_decls), not a FrozenList field.
        for var i: usize = 0; i < n->dc_decls.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->dc_decls.get(i)) // discard
        }

        return n
    }

    fn traverse_import_decl(self, n: *Declarations::ImportDecl) -> *Declarations::ImportDecl {
        // path_segments / items are token lists no AST children.
        self.dyn()->walkup_import_decl(n)
        return n
    }

    fn traverse_ffi_block_decl(self,
                               n: *Declarations::FFIBlockDecl) -> *Declarations::FFIBlockDecl {
        if self.dyn()->walkup_ffi_block_decl(n) == false {
            return n
        }

        // lang_token is a leaf token; skip.
        // Traverse each child declaration in the FFI block's body.
        for var i: usize = 0; i < n->body.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->body.get(i)) // discard return
        }

        return n
    }

    fn traverse_visibility_group_decl(self,
                                      n: *Declarations::VisibilityGroupDecl) -> *Declarations::VisibilityGroupDecl {
        if self.dyn()->walkup_visibility_group_decl(n) == false {
            return n
        }

        for var i: usize = 0; i < n->members.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->members.get(i)) // discard
        }

        return n
    }

    fn traverse_eval_block_decl(self,
                                n: *Declarations::EvalBlockDecl) -> *Declarations::EvalBlockDecl {
        if self.dyn()->walkup_eval_block_decl(n) == false {
            return n
        }

        for var i: usize = 0; i < n->body.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->body.get(i)) // discard
        }

        // a member-position `eval if` / `eval for` (EvalBlockDecl::stmt)
        if n->stmt != &null && !self.stop {
            n->stmt = self.dyn()->dispatch_stmt(n->stmt)
        }

        return n
    }

    fn traverse_test_decl(self, n: *Declarations::TestDecl) -> *Declarations::TestDecl {
        if self.dyn()->walkup_test_decl(n) == false {
            return n
        }

        if n->label != &null { // StringLiteralExpr
            n->label = self.dyn()->dispatch_expr(n->label)
        }

        if n->body != &null {
            n->body = self.dyn()->traverse_block(n->body)
        }

        return n
    }

    fn traverse_macro_decl(self, n: *Declarations::MacroDecl) -> *Declarations::MacroDecl {
        // params are bare tokens; body_span is raw tokens no AST children.
        self.dyn()->walkup_macro_decl(n)
        return n
    }

    fn traverse_procedure_macro_decl(self,
                                     n: *Declarations::ProcedureMacroDecl) -> *Declarations::ProcedureMacroDecl {
        if self.dyn()->walkup_procedure_macro_decl(n) == false {
            return n
        }

        for var i: usize = 0; i < n->params.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_decl(*n->params.get(i)) // discard
        }

        if self.stop {
            return n
        }

        if n->body != &null {
            n->body = self.dyn()->traverse_block(n->body)
        }

        return n
    }

    /// ## walkup

    fn walkup_function_decl(self, n: unsafe *Declarations::FunctionDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_function_decl(n)
    }

    fn walkup_variable_decl(self, n: *Declarations::VariableDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_variable_decl(n)
    }

    fn walkup_field_decl(self, n: *Declarations::FieldDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_field_decl(n)
    }

    fn walkup_param_decl(self, n: *Declarations::ParamDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_param_decl(n)
    }

    fn walkup_generic_param_decl(self, n: *Declarations::GenericParamDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_generic_param_decl(n)
    }

    fn walkup_struct_decl(self, n: *Declarations::StructDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_struct_decl(n)
    }

    fn walkup_class_decl(self, n: *Declarations::ClassDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_class_decl(n)
    }

    fn walkup_interface_decl(self, n: *Declarations::InterfaceDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_interface_decl(n)
    }

    fn walkup_extension_decl(self, n: *Declarations::ExtensionDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_extension_decl(n)
    }

    fn walkup_enum_decl(self, n: *Declarations::EnumDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_enum_decl(n)
    }

    fn walkup_enum_variant_decl(self, n: *Declarations::EnumVariantDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_enum_variant_decl(n)
    }

    fn walkup_union_decl(self, n: *Declarations::UnionDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_union_decl(n)
    }

    fn walkup_type_alias_decl(self, n: unsafe *Declarations::TypeAliasDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_type_alias_decl(n)
    }

    fn walkup_module_decl(self, n: *Declarations::ModuleDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_module_decl(n)
    }

    fn walkup_import_decl(self, n: *Declarations::ImportDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_import_decl(n)
    }

    fn walkup_ffi_block_decl(self, n: *Declarations::FFIBlockDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_ffi_block_decl(n)
    }

    fn walkup_visibility_group_decl(self, n: *Declarations::VisibilityGroupDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_visibility_group_decl(n)
    }

    fn walkup_eval_block_decl(self, n: *Declarations::EvalBlockDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_eval_block_decl(n)
    }

    fn walkup_test_decl(self, n: *Declarations::TestDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_test_decl(n)
    }

    fn walkup_macro_decl(self, n: *Declarations::MacroDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_macro_decl(n)
    }

    fn walkup_procedure_macro_decl(self, n: *Declarations::ProcedureMacroDecl) -> bool {
        if self.dyn()->visit_decl(n) == false {
            return false
        }

        return self.dyn()->visit_procedure_macro_decl(n)
    }

    /// ## leaf visit hooks

    fn visit_function_decl(self, n: *Declarations::FunctionDecl) -> bool {
        return true
    }

    fn visit_variable_decl(self, n: *Declarations::VariableDecl) -> bool {
        return true
    }

    fn visit_field_decl(self, n: *Declarations::FieldDecl) -> bool {
        return true
    }

    fn visit_param_decl(self, n: *Declarations::ParamDecl) -> bool {
        return true
    }

    fn visit_generic_param_decl(self, n: *Declarations::GenericParamDecl) -> bool {
        return true
    }

    fn visit_struct_decl(self, n: *Declarations::StructDecl) -> bool {
        return true
    }

    fn visit_class_decl(self, n: *Declarations::ClassDecl) -> bool {
        return true
    }

    fn visit_interface_decl(self, n: *Declarations::InterfaceDecl) -> bool {
        return true
    }

    fn visit_extension_decl(self, n: *Declarations::ExtensionDecl) -> bool {
        return true
    }

    fn visit_enum_decl(self, n: *Declarations::EnumDecl) -> bool {
        return true
    }

    fn visit_enum_variant_decl(self, n: *Declarations::EnumVariantDecl) -> bool {
        return true
    }

    fn visit_union_decl(self, n: *Declarations::UnionDecl) -> bool {
        return true
    }

    fn visit_type_alias_decl(self, n: *Declarations::TypeAliasDecl) -> bool {
        return true
    }

    fn visit_module_decl(self, n: *Declarations::ModuleDecl) -> bool {
        return true
    }

    fn visit_import_decl(self, n: *Declarations::ImportDecl) -> bool {
        return true
    }

    fn visit_ffi_block_decl(self, n: *Declarations::FFIBlockDecl) -> bool {
        return true
    }

    fn visit_visibility_group_decl(self, n: *Declarations::VisibilityGroupDecl) -> bool {
        return true
    }

    fn visit_eval_block_decl(self, n: *Declarations::EvalBlockDecl) -> bool {
        return true
    }

    fn visit_test_decl(self, n: *Declarations::TestDecl) -> bool {
        return true
    }

    fn visit_macro_decl(self, n: *Declarations::MacroDecl) -> bool {
        return true
    }

    fn visit_procedure_macro_decl(self, n: *Declarations::ProcedureMacroDecl) -> bool {
        return true
    }

    /// # PATTERN FAMILY

    fn dispatch_pattern(self, p: unsafe *Pattern) -> unsafe *Pattern {
        if p == &null {
            return p
        }

        if self.stop {
            return p
        }

        match p->kind {
            case PatternKind::WildcardPattern {
                return self.dyn()->traverse_wildcard_pattern(cast<WildcardPattern>(p))
            } case PatternKind::LiteralPattern {
                return self.dyn()->traverse_literal_pattern(cast<LiteralPattern>(p))
            } case PatternKind::BindingPattern {
                return self.dyn()->traverse_binding_pattern(cast<BindingPattern>(p))
            } case PatternKind::TupleDestructurePattern {
                return self.dyn()->traverse_tuple_destructure_pattern(
                    cast<TupleDestructurePattern>(p),
                )
            } case PatternKind::ConstructorPattern {
                return self.dyn()->traverse_constructor_pattern(cast<ConstructorPattern>(p))
            } case PatternKind::UnresolvedConstructorPattern {
                return self.dyn()->traverse_unresolved_constructor_pattern(
                    cast<UnresolvedConstructorPattern>(p),
                )
            } case PatternKind::AlternationPattern {
                return self.dyn()->traverse_alternation_pattern(cast<AlternationPattern>(p))
            } case PatternKind::RangePattern {
                return self.dyn()->traverse_range_pattern(cast<RangePattern>(p))
            } case PatternKind::SlicePattern {
                return self.dyn()->traverse_slice_pattern(cast<SlicePattern>(p))
            } case PatternKind::RecoveryPattern {
                self.dyn()->visit_pattern(p)
                return p
            } case PatternKind::PatternKindCount {
                kairo::std::ice_fail("PatternKindCount reached RAV in Stage 1 - this is a bug")
            }
        }
    }

    fn visit_pattern(self, n: *Pattern) -> bool {
        return true
    }

    /// ## traverse bodies

    fn traverse_wildcard_pattern(self, n: *WildcardPattern) -> *WildcardPattern {
        self.dyn()->walkup_wildcard_pattern(n)
        return n
    }

    fn traverse_literal_pattern(self, n: *LiteralPattern) -> *LiteralPattern {
        if self.dyn()->walkup_literal_pattern(n) == false {
            return n
        }

        if n->value != &null {
            n->value = self.dyn()->dispatch_expr(n->value)
        }

        return n
    }

    fn traverse_binding_pattern(self, n: *BindingPattern) -> *BindingPattern {
        if self.dyn()->walkup_binding_pattern(n) == false {
            return n
        }

        // n->name is the bound identifier token skip.
        if n->type_ != &null {
            n->type_ = self.dyn()->dispatch_type(n->type_)
        }

        return n
    }

    fn traverse_tuple_destructure_pattern(self,
                                          n: *TupleDestructurePattern) -> *TupleDestructurePattern {
        if self.dyn()->walkup_tuple_destructure_pattern(n) == false {
            return n
        }

        for var i: usize = 0; i < n->elements.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_pattern(*n->elements.get(i)) // discard
        }

        return n
    }

    fn traverse_constructor_pattern(self, n: *ConstructorPattern) -> *ConstructorPattern {
        if self.dyn()->walkup_constructor_pattern(n) == false {
            return n
        }

        if n->head != &null { // null when dotted
            n->head = self.dyn()->dispatch_expr(n->head)
        }

        for var i: usize = 0; i < n->subpatterns.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_pattern(*n->subpatterns.get(i)) // discard
        }

        return n
    }

    fn traverse_unresolved_constructor_pattern(self,
                                               n: *UnresolvedConstructorPattern) -> *UnresolvedConstructorPattern {
        if self.dyn()->walkup_unresolved_constructor_pattern(n) == false {
            return n
        }

        if n->head != &null {
            n->head = self.dyn()->dispatch_expr(n->head)
        }

        for var i: usize = 0; i < n->subpatterns.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_pattern(*n->subpatterns.get(i)) // discard
        }

        return n
    }

    fn traverse_alternation_pattern(self, n: *AlternationPattern) -> *AlternationPattern {
        if self.dyn()->walkup_alternation_pattern(n) == false {
            return n
        }

        for var i: usize = 0; i < n->alternatives.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_pattern(*n->alternatives.get(i)) // discard
        }

        return n
    }

    fn traverse_range_pattern(self, n: *RangePattern) -> *RangePattern {
        if self.dyn()->walkup_range_pattern(n) == false {
            return n
        }

        if n->lo != &null {
            n->lo = self.dyn()->dispatch_expr(n->lo)
        }

        if n->hi != &null {
            n->hi = self.dyn()->dispatch_expr(n->hi)
        }

        return n
    }

    fn traverse_slice_pattern(self, n: *SlicePattern) -> *SlicePattern {
        if self.dyn()->walkup_slice_pattern(n) == false {
            return n
        }

        for var i: usize = 0; i < n->prefix.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_pattern(*n->prefix.get(i)) // discard
        }

        for var i: usize = 0; i < n->suffix.size(); i++ {
            if self.stop {
                break
            }

            self.dyn()->dispatch_pattern(*n->suffix.get(i)) // discard
        }

        if self.stop {
            return n
        }

        if n->rest_binding != &null {
            n->rest_binding = self.dyn()->dispatch_pattern(n->rest_binding)
        }

        return n
    }

    /// ## walkup

    fn walkup_wildcard_pattern(self, n: *WildcardPattern) -> bool {
        if self.dyn()->visit_pattern(n) == false {
            return false
        }

        return self.dyn()->visit_wildcard_pattern(n)
    }

    fn walkup_literal_pattern(self, n: *LiteralPattern) -> bool {
        if self.dyn()->visit_pattern(n) == false {
            return false
        }

        return self.dyn()->visit_literal_pattern(n)
    }

    fn walkup_binding_pattern(self, n: *BindingPattern) -> bool {
        if self.dyn()->visit_pattern(n) == false {
            return false
        }

        return self.dyn()->visit_binding_pattern(n)
    }

    fn walkup_tuple_destructure_pattern(self, n: *TupleDestructurePattern) -> bool {
        if self.dyn()->visit_pattern(n) == false {
            return false
        }

        return self.dyn()->visit_tuple_destructure_pattern(n)
    }

    fn walkup_constructor_pattern(self, n: unsafe *ConstructorPattern) -> bool {
        if self.dyn()->visit_pattern(n) == false {
            return false
        }

        return self.dyn()->visit_constructor_pattern(n)
    }

    fn walkup_unresolved_constructor_pattern(self,
                                             n: unsafe *UnresolvedConstructorPattern) -> bool {
        if self.dyn()->visit_pattern(n) == false {
            return false
        }

        return self.dyn()->visit_unresolved_constructor_pattern(n)
    }

    fn walkup_alternation_pattern(self, n: *AlternationPattern) -> bool {
        if self.dyn()->visit_pattern(n) == false {
            return false
        }

        return self.dyn()->visit_alternation_pattern(n)
    }

    fn walkup_range_pattern(self, n: *RangePattern) -> bool {
        if self.dyn()->visit_pattern(n) == false {
            return false
        }

        return self.dyn()->visit_range_pattern(n)
    }

    fn walkup_slice_pattern(self, n: *SlicePattern) -> bool {
        if self.dyn()->visit_pattern(n) == false {
            return false
        }

        return self.dyn()->visit_slice_pattern(n)
    }

    /// ## leaf visit hooks

    fn visit_wildcard_pattern(self, n: *WildcardPattern) -> bool {
        return true
    }

    fn visit_literal_pattern(self, n: *LiteralPattern) -> bool {
        return true
    }

    fn visit_binding_pattern(self, n: *BindingPattern) -> bool {
        return true
    }

    fn visit_tuple_destructure_pattern(self, n: *TupleDestructurePattern) -> bool {
        return true
    }

    fn visit_constructor_pattern(self, n: *ConstructorPattern) -> bool {
        return true
    }

    fn visit_unresolved_constructor_pattern(self, n: *UnresolvedConstructorPattern) -> bool {
        return true
    }

    fn visit_alternation_pattern(self, n: *AlternationPattern) -> bool {
        return true
    }

    fn visit_range_pattern(self, n: *RangePattern) -> bool {
        return true
    }

    fn visit_slice_pattern(self, n: *SlicePattern) -> bool {
        return true
    }
}

///
/// \class RAVProbe
/// \brief Compile-time tripwire that forces instantiation of
///        RecursiveASTVisitor<D>.
///
/// \details RecursiveASTVisitor is a CRTP base: every internal call routes
///          through dyn() -> *D, a dependent type. Dependent-name lookups are
///          NOT checked when the base template is compiled alone a misspelled
///          dispatch_/walkup_/visit_ call (e.g. the historical `dispatch_decln`
///          typo) or a bad n->field access compiles clean and only errors when
///          some concrete D instantiates the offending path.
///
///          This zero-override derived class is that instantiation. Declaring
///          it + constructing one in Test() below forces the compiler to
///          type-check every method body in the base against a real D, turning
///          the whole dependent-name surface from deferred to verified on every
///          build. If a future edit introduces a dependent-name typo while
///          stamping new families, THIS is what fails the build instead of it
///          silently surviving to runtime.
///
///          Overrides nothing on purpose: it must exercise the base defaults,
///          not replace them. Do not delete: it checks that the
///          base defaults are exercised.
///
pub class RAVProbe derives RecursiveASTVisitor<RAVProbe> { }
