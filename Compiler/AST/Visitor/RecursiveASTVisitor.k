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
import AST::Context::DeclContext::*;
import AST::Context::CanonicalTypes::*;

class <D> RecursiveASTVisitor {
    var ctx: *ASTContext;
    pub var stop: bool = false;

    fn dyn(self) -> *D {
        return static_cast::<*D>(&self);
    }

    // == DISPATCH (generated off TypeKind) ===================================
    // Routes an unknown-kind *Type to its traverse_. Default: identity.
    fn dispatch_type(self, e: *Type) -> *Type {
        if e == &null { return e; }
        if self.stop  { return e; }

        switch e->kind {
            case TypeKind::MapType               { return self.dyn()->traverse_map_type(                 cast::<MapType>(e)                ); }
            case TypeKind::SetType               { return self.dyn()->traverse_set_type(                 cast::<SetType>(e)                ); }
            case TypeKind::SelfType              { return self.dyn()->traverse_self_type(                cast::<SelfType>(e)               ); }
            case TypeKind::TypeExpr              { return self.dyn()->traverse_type_expr(                cast::<TypeExpr>(e)               ); }
            case TypeKind::TupleType             { return self.dyn()->traverse_tuple_type(               cast::<TupleType>(e)              ); }
            case TypeKind::ChainType             { return self.dyn()->traverse_chain_type(               cast::<ChainType>(e)              ); }
            case TypeKind::VectorType            { return self.dyn()->traverse_vector_type(              cast::<VectorType>(e)             ); }
            case TypeKind::PointerType           { return self.dyn()->traverse_pointer_type(             cast::<PointerType>(e)            ); }
            case TypeKind::TypeOfType            { return self.dyn()->traverse_type_of_type(             cast::<TypeOfType>(e)             ); }
            case TypeKind::InferredType          { return self.dyn()->traverse_inferred_type(            cast::<InferredType>(e)           ); }
            case TypeKind::RecordType            { return self.dyn()->traverse_record_type(              cast::<RecordType>(e)             ); }
            case TypeKind::BuiltinType           { return self.dyn()->traverse_builtin_type(             cast::<BuiltinType>(e)            ); }
            case TypeKind::NullableType          { return self.dyn()->traverse_nullable_type(            cast::<NullableType>(e)           ); }
            case TypeKind::OpaqueFFIType         { return self.dyn()->traverse_opaque_ffi_type(          cast::<OpaqueFFIType>(e)          ); }
            case TypeKind::FixedArrayType        { return self.dyn()->traverse_fixed_array_type(         cast::<FixedArrayType>(e)         ); }
            case TypeKind::VariadicPackType      { return self.dyn()->traverse_variadic_pack_type(       cast::<VariadicPackType>(e)       ); }
            case TypeKind::GenericParamType      { return self.dyn()->traverse_generic_param_type(       cast::<GenericParamType>(e)       ); }
            case TypeKind::PackExpansionType     { return self.dyn()->traverse_pack_expansion_type(      cast::<PackExpansionType>(e)      ); }
            case TypeKind::CXXLValueRefType      { return self.dyn()->traverse_cxxl_value_ref_type(      cast::<CXXLValueRefType>(e)       ); }
            case TypeKind::CXXRValueRefType      { return self.dyn()->traverse_cxxr_value_ref_type(      cast::<CXXRValueRefType>(e)       ); }
            case TypeKind::FunctionPointerType   { return self.dyn()->traverse_function_pointer_type(    cast::<FunctionPointerType>(e)    ); }
            case TypeKind::SubstGenericParamType { return self.dyn()->traverse_subst_generic_param_type( cast::<SubstGenericParamType>(e)  ); }
            case TypeKind::RecoveryType          { self.dyn()->visit_type(e); return e; }
            case TypeKind::TypeKindCount         {  ICE_FAIL("TypeKind::TypeKindCount reached RAV - this is a bug"); return &null; }
        }

        return e;
    }

    // == FAMILY HOOK (override for whole-family passes) =====================
    // ValueCategoryPass, TypeChecking, mono-part-1 collect, etc. override this.
    fn visit_type(self, n: *Type) -> bool { return true; }

    // == TRAVERSE bodies (hand-written: each knows its children) ============
    // REFERENCE SHAPE scalar children:
    fn traverse_map_type(self, n: *MapType) -> *MapType {
        if self.dyn()->walkup_map_type(n) == false { return n; }
        n->key   = self.dyn()->dispatch_type(n->key);
        n->value = self.dyn()->dispatch_type(n->value);
        return n;
    }

    fn traverse_set_type(self, n: *SetType) -> *SetType {
        if self.dyn()->walkup_set_type(n) == false { return n; }
        n->element = self.dyn()->dispatch_type(n->element);
        return n;
    }

    fn traverse_self_type(self, n: *SelfType) -> *SelfType {
        self.dyn()->walkup_self_type(n);
        return n;
    }

    fn traverse_type_expr(self, n: *TypeExpr) -> *TypeExpr {
        if self.dyn()->walkup_type_expr(n) == false { return n; }
        n->expr = self.dyn()->dispatch_expr(n->expr);
        return n;
    }

    fn traverse_tuple_type(self, n: *TupleType) -> *TupleType {
        if self.dyn()->walkup_tuple_type(n) == false { return n; }
        for var i: usize = 0; i < n->elements.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_type(*(n->elements.get(i)));  // discard return
        }
        return n;
    }

    fn traverse_chain_type(self, n: *ChainType) -> *ChainType {
        if self.dyn()->walkup_chain_type(n) == false { return n; }
        for var i: usize = 0; i < n->segments.size(); i++ {
            if self.stop { break; }
            var seg = n->segments.get(i);                // *ChainSegment
            // seg->name is a NamedIdentExpr (decl-site identifier) skip,
            //      like other name nodes
            // seg->resolved_type / resolved_decl are sema links skip
            for var j: usize = 0; j < seg->generic_args.size(); j++ {
                if self.stop { break; }
                var arg = seg->generic_args.get(j);      // *GenericArg
                // arg->name is a NamedIdentExpr (named-arg label) skip
                if arg->ty != &null {
                    self.dyn()->dispatch_type(arg->ty);  // the real child
                }
            }
        }
        return n;
    }

    fn traverse_vector_type(self, n: *VectorType) -> *VectorType {
        if self.dyn()->walkup_vector_type(n) == false { return n; }
        n->element = self.dyn()->dispatch_type(n->element);
        return n;
    }

    fn traverse_pointer_type(self, n: *PointerType) -> *PointerType {
        if self.dyn()->walkup_pointer_type(n) == false { return n; }
        n->pointee = self.dyn()->dispatch_type(n->pointee);
        return n;
    }


    fn traverse_type_of_type(self, n: *TypeOfType) -> *TypeOfType {
        if self.dyn()->walkup_type_of_type(n) == false { return n; }
        n->expr = self.dyn()->dispatch_expr(n->expr);
        return n;
    }

    fn traverse_inferred_type(self, n: *InferredType) -> *InferredType {
        self.dyn()->walkup_inferred_type(n);
        return n;
    }

    // Canonical nodes are LEAVES for traversal purposes: their components are
    // themselves canonical and shared across the whole build, so descending
    // would revisit one node once per referring TU.
    fn traverse_record_type(self, n: *RecordType) -> *RecordType {
        self.dyn()->walkup_record_type(n);
        return n;
    }

    fn traverse_builtin_type(self, n: *BuiltinType) -> *BuiltinType {
        self.dyn()->walkup_builtin_type(n);
        return n;
    }

    fn traverse_nullable_type(self, n: *NullableType) -> *NullableType {
        if self.dyn()->walkup_nullable_type(n) == false { return n; }
        n->inner = self.dyn()->dispatch_type(n->inner);
        return n;
    }

    fn traverse_opaque_ffi_type(self, n: *OpaqueFFIType) -> *OpaqueFFIType {
        self.dyn()->walkup_opaque_ffi_type(n);
        return n;
    }

    fn traverse_fixed_array_type(self, n: *FixedArrayType) -> *FixedArrayType {
        if self.dyn()->walkup_fixed_array_type(n) == false { return n; }
        n->element = self.dyn()->dispatch_type(n->element);
        if n->size_expr != &null {       // null when is_incomplete
            n->size_expr = self.dyn()->dispatch_expr(n->size_expr);
        }
        return n;
    }

    fn traverse_variadic_pack_type(self, n: *VariadicPackType) -> *VariadicPackType {
        // param is a back-ref to the declaring pack param: skip.
        self.dyn()->walkup_variadic_pack_type(n);
        return n;
    }

    fn traverse_generic_param_type(self, n: *GenericParamType) -> *GenericParamType {
        // param_name is a decl-site back-ref, not a child: skip.
        self.dyn()->walkup_generic_param_type(n);
        return n;
    }


    fn traverse_pack_expansion_type(self, n: *PackExpansionType) -> *PackExpansionType {
        if self.dyn()->walkup_pack_expansion_type(n) == false { return n; }
        n->pattern = self.dyn()->dispatch_type(n->pattern);
        return n;
    }

    fn traverse_cxxl_value_ref_type(self, n: *CXXLValueRefType) -> *CXXLValueRefType {
        if self.dyn()->walkup_cxxl_value_ref_type(n) == false { return n; }
        n->referee = self.dyn()->dispatch_type(n->referee);
        return n;
    }

    fn traverse_cxxr_value_ref_type(self, n: *CXXRValueRefType) -> *CXXRValueRefType {
        if self.dyn()->walkup_cxxr_value_ref_type(n) == false { return n; }
        n->referee = self.dyn()->dispatch_type(n->referee);
        return n;
    }

    fn traverse_function_pointer_type(self, n: *FunctionPointerType) -> *FunctionPointerType {
        if self.dyn()->walkup_function_pointer_type(n) == false { return n; }
        for var i: usize = 0; i < n->params.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_type(*(n->params.get(i))); // discard return
        }
        if n->return_type != &null {               // null on unprototyped path
            n->return_type = self.dyn()->dispatch_type(n->return_type);
        }
        return n;
    }

    fn traverse_subst_generic_param_type(self, n: *SubstGenericParamType) -> *SubstGenericParamType {
        if self.dyn()->walkup_subst_generic_param_type(n) == false { return n; }
        n->replacement = self.dyn()->dispatch_type(n->replacement);
        return n;
    }

    // == WALKUP (base-first chain: family hook THEN leaf hook) ==============
    fn walkup_map_type(self, n: *MapType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_map_type(n);
    }

    fn walkup_set_type(self, n: *SetType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_set_type(n);
    }

    fn walkup_self_type(self, n: *SelfType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_self_type(n);
    }

    fn walkup_type_expr(self, n: *TypeExpr) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_type_expr(n);
    }

    fn walkup_tuple_type(self, n: *TupleType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_tuple_type(n);
    }

    fn walkup_chain_type(self, n: *ChainType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_chain_type(n);
    }

    fn walkup_vector_type(self, n: *VectorType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_vector_type(n);
    }

    fn walkup_pointer_type(self, n: *PointerType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_pointer_type(n);
    }

    fn walkup_type_of_type(self, n: *TypeOfType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_type_of_type(n);
    }

    fn walkup_inferred_type(self, n: *InferredType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_inferred_type(n);
    }

    fn walkup_record_type(self, n: *RecordType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_record_type(n);
    }

    fn walkup_builtin_type(self, n: *BuiltinType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_builtin_type(n);
    }

    fn walkup_nullable_type(self, n: *NullableType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_nullable_type(n);
    }

    fn walkup_opaque_ffi_type(self, n: *OpaqueFFIType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_opaque_ffi_type(n);
    }

    fn walkup_fixed_array_type(self, n: *FixedArrayType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_fixed_array_type(n);
    }

    fn walkup_variadic_pack_type(self, n: *VariadicPackType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_variadic_pack_type(n);
    }

    fn walkup_generic_param_type(self, n: *GenericParamType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_generic_param_type(n);
    }

    fn walkup_pack_expansion_type(self, n: *PackExpansionType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_pack_expansion_type(n);
    }

    fn walkup_cxxl_value_ref_type(self, n: *CXXLValueRefType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_cxxl_value_ref_type(n);
    }

    fn walkup_cxxr_value_ref_type(self, n: *CXXRValueRefType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_cxxr_value_ref_type(n);
    }

    fn walkup_function_pointer_type(self, n: *FunctionPointerType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_function_pointer_type(n);
    }

    fn walkup_subst_generic_param_type(self, n: *SubstGenericParamType) -> bool {
        if self.dyn()->visit_type(n) == false { return false; }
        return self.dyn()->visit_subst_generic_param_type(n);
    }

    // == LEAF VISIT hooks (override per node kind) ==========================
    fn visit_map_type(                self, n: *MapType              ) -> bool { return true; }
    fn visit_set_type(                self, n: *SetType              ) -> bool { return true; }
    fn visit_self_type(               self, n: *SelfType             ) -> bool { return true; }
    fn visit_type_expr(               self, n: *TypeExpr             ) -> bool { return true; }
    fn visit_tuple_type(              self, n: *TupleType            ) -> bool { return true; }
    fn visit_chain_type(              self, n: *ChainType            ) -> bool { return true; }
    fn visit_vector_type(             self, n: *VectorType           ) -> bool { return true; }
    fn visit_pointer_type(            self, n: *PointerType          ) -> bool { return true; }
    fn visit_type_of_type(            self, n: *TypeOfType           ) -> bool { return true; }
    fn visit_inferred_type(           self, n: *InferredType         ) -> bool { return true; }
    fn visit_record_type(             self, n: *RecordType           ) -> bool { return true; }
    fn visit_builtin_type(            self, n: *BuiltinType          ) -> bool { return true; }
    fn visit_nullable_type(           self, n: *NullableType         ) -> bool { return true; }
    fn visit_opaque_ffi_type(         self, n: *OpaqueFFIType        ) -> bool { return true; }
    fn visit_fixed_array_type(        self, n: *FixedArrayType       ) -> bool { return true; }
    fn visit_variadic_pack_type(      self, n: *VariadicPackType     ) -> bool { return true; }
    fn visit_generic_param_type(      self, n: *GenericParamType     ) -> bool { return true; }
    fn visit_pack_expansion_type(     self, n: *PackExpansionType    ) -> bool { return true; }
    fn visit_cxxl_value_ref_type(     self, n: *CXXLValueRefType     ) -> bool { return true; }
    fn visit_cxxr_value_ref_type(     self, n: *CXXRValueRefType     ) -> bool { return true; }
    fn visit_function_pointer_type(   self, n: *FunctionPointerType  ) -> bool { return true; }
    fn visit_subst_generic_param_type(self, n: *SubstGenericParamType) -> bool { return true; }
    // == SHARED CHILD-WALK HELPERS =========================================
    // CompoundStmt-typed scalar child: rebind through the block. dispatch
    // routes to traverse_compound_stmt; a RAV pass preserves block-ness
    // (node-count rewrites belong in ASTWriter), so the downcast is sound.
    // null-safe for optional bodies (expr-bodied fn, bare default, etc.).
    fn traverse_block(self, b: *CompoundStmt) -> *CompoundStmt {
        if b == &null { return b; }
        return cast::<CompoundStmt>(self.dyn()->dispatch_stmt(b));
    }

    // GenericArg (bare NamedIdentExpr / ChainExpr step): the named label is a
    // name node (skip); only `ty` is a real child. list element -> discard.
    fn traverse_generic_arg(self, a: *ChainType::GenericArg) {
        if self.stop { return; }
        if a->ty != &null {
            self.dyn()->dispatch_type(a->ty);  // discard
        }
    }

    // InheritEdge (derives_list / implements): base type is the only child.
    // visibility / is_virtual / range are leaf data. list element -> discard.
    fn traverse_inherit_edge(self, e: *InheritEdge) {
        if self.stop { return; }
        if e->base != &null {
            self.dyn()->dispatch_type(e->base);  // discard
        }
    }

    // MatchCase (MatchStmt / MatchExpr): patterns + optional guard + one of
    // body (stmt form) / expression (expr form). list element -> discard all.
    fn traverse_match_case(self, mc: *MatchCase) {
        for var i: usize = 0; i < mc->patterns.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_pattern(*(mc->patterns.get(i)));  // discard
        }
        if self.stop { return; }
        if mc->guard      != &null { self.dyn()->dispatch_expr(mc->guard); }
        if mc->body       != &null { self.dyn()->dispatch_stmt(mc->body); }
        if mc->expression != &null { self.dyn()->dispatch_expr(mc->expression); }
    }

    // == EXPR FAMILY =======================================================
    fn dispatch_expr(self, e: *Expr) -> *Expr {
        if e == &null { return e; }
        if self.stop  { return e; }

        switch e->kind {
            case ExprKind::IntegerLiteralExpr       { return self.dyn()->traverse_integer_literal_expr(       cast::<IntegerLiteralExpr>(e)       ); }
            case ExprKind::FloatingLiteralExpr      { return self.dyn()->traverse_floating_literal_expr(      cast::<FloatingLiteralExpr>(e)      ); }
            case ExprKind::StringLiteralExpr        { return self.dyn()->traverse_string_literal_expr(        cast::<StringLiteralExpr>(e)        ); }
            case ExprKind::CharacterLiteralExpr     { return self.dyn()->traverse_character_literal_expr(     cast::<CharacterLiteralExpr>(e)     ); }
            case ExprKind::BooleanLiteralExpr       { return self.dyn()->traverse_boolean_literal_expr(       cast::<BooleanLiteralExpr>(e)       ); }
            case ExprKind::NullLiteralExpr          { return self.dyn()->traverse_null_literal_expr(          cast::<NullLiteralExpr>(e)          ); }
            case ExprKind::ListLiteralExpr          { return self.dyn()->traverse_list_literal_expr(          cast::<ListLiteralExpr>(e)          ); }
            case ExprKind::TupleLiteralExpr         { return self.dyn()->traverse_tuple_literal_expr(         cast::<TupleLiteralExpr>(e)         ); }
            case ExprKind::SetLiteralExpr           { return self.dyn()->traverse_set_literal_expr(           cast::<SetLiteralExpr>(e)           ); }
            case ExprKind::MapLiteralExpr           { return self.dyn()->traverse_map_literal_expr(           cast::<MapLiteralExpr>(e)           ); }
            case ExprKind::NamedInitializerExpr     { return self.dyn()->traverse_named_initializer_expr(     cast::<NamedInitializerExpr>(e)     ); }
            case ExprKind::AnonInitializerExpr      { return self.dyn()->traverse_anon_initializer_expr(      cast::<AnonInitializerExpr>(e)      ); }
            case ExprKind::ChainExpr                { return self.dyn()->traverse_chain_expr(                 cast::<ChainExpr>(e)                ); }
            case ExprKind::CallExpr                 { return self.dyn()->traverse_call_expr(                  cast::<CallExpr>(e)                 ); }
            case ExprKind::SubscriptExpr            { return self.dyn()->traverse_subscript_expr(             cast::<SubscriptExpr>(e)            ); }
            case ExprKind::NamedIdentExpr           { return self.dyn()->traverse_named_ident_expr(           cast::<NamedIdentExpr>(e)           ); }
            case ExprKind::UnaryOperatorExpr        { return self.dyn()->traverse_unary_operator_expr(        cast::<UnaryOperatorExpr>(e)        ); }
            case ExprKind::BinaryOperatorExpr       { return self.dyn()->traverse_binary_operator_expr(       cast::<BinaryOperatorExpr>(e)       ); }
            case ExprKind::AssignOperatorExpr       { return self.dyn()->traverse_assign_operator_expr(       cast::<AssignOperatorExpr>(e)       ); }
            case ExprKind::ImplConformanceExpr      { return self.dyn()->traverse_impl_conformance_expr(      cast::<ImplConformanceExpr>(e)      ); }
            case ExprKind::DerivesRelationExpr      { return self.dyn()->traverse_derives_relation_expr(      cast::<DerivesRelationExpr>(e)      ); }
            case ExprKind::IfExpr                   { return self.dyn()->traverse_if_expr(                    cast::<IfExpr>(e)                   ); }
            case ExprKind::TryCatchExpr             { return self.dyn()->traverse_try_catch_expr(             cast::<TryCatchExpr>(e)             ); }
            case ExprKind::MatchExpr                { return self.dyn()->traverse_match_expr(                 cast::<MatchExpr>(e)                ); }
            case ExprKind::RangeExpr                { return self.dyn()->traverse_range_expr(                 cast::<RangeExpr>(e)                ); }
            case ExprKind::ClosureExpr              { return self.dyn()->traverse_closure_expr(               cast::<ClosureExpr>(e)              ); }
            case ExprKind::AwaitExpr                { return self.dyn()->traverse_await_expr(                 cast::<AwaitExpr>(e)                ); }
            case ExprKind::SpawnExpr                { return self.dyn()->traverse_spawn_expr(                 cast::<SpawnExpr>(e)                ); }
            case ExprKind::ThreadExpr               { return self.dyn()->traverse_thread_expr(                cast::<ThreadExpr>(e)               ); }
            case ExprKind::ConstraintExpr           { return self.dyn()->traverse_constraint_expr(            cast::<ConstraintExpr>(e)           ); }
            case ExprKind::SizeOfExpr               { return self.dyn()->traverse_size_of_expr(               cast::<SizeOfExpr>(e)               ); }
            case ExprKind::AlignOfExpr              { return self.dyn()->traverse_align_of_expr(              cast::<AlignOfExpr>(e)              ); }
            case ExprKind::TypeOfExpr               { return self.dyn()->traverse_type_of_expr(               cast::<TypeOfExpr>(e)               ); }
            case ExprKind::EvalExpr                 { return self.dyn()->traverse_eval_expr(                  cast::<EvalExpr>(e)                 ); }
            case ExprKind::UnsafeExpr               { return self.dyn()->traverse_unsafe_expr(                cast::<UnsafeExpr>(e)               ); }
            case ExprKind::DeleteExpr               { return self.dyn()->traverse_delete_expr(                cast::<DeleteExpr>(e)               ); }
            case ExprKind::PackExpansionExpr        { return self.dyn()->traverse_pack_expansion_expr(        cast::<PackExpansionExpr>(e)        ); }
            case ExprKind::TypeCastExpr             { return self.dyn()->traverse_type_cast_expr(             cast::<TypeCastExpr>(e)             ); }
            case ExprKind::ImplicitBoundaryCastExpr { return self.dyn()->traverse_implicit_boundary_cast_expr(cast::<ImplicitBoundaryCastExpr>(e) ); }
            case ExprKind::ParenExpr                { return self.dyn()->traverse_paren_expr(                 cast::<ParenExpr>(e)                ); }
            case ExprKind::VerbatimExpr             { return self.dyn()->traverse_verbatim_expr(              cast::<VerbatimExpr>(e)             ); }
            case ExprKind::RecoveryExpr             { self.dyn()->visit_expr(e); return e; }
            case ExprKind::ExprKindCount            {  ICE_FAIL("ExprKindCount reached RAV in Stage 1 - driver bail failed"); return &null; }
        }
        return e;
    }

    fn visit_expr(self, n: *Expr) -> bool { return true; }

    // --- traverse bodies ---------------------------------------------------
    fn traverse_integer_literal_expr(self, n: *IntegerLiteralExpr) -> *IntegerLiteralExpr {
        self.dyn()->walkup_integer_literal_expr(n);
        return n;
    }

    fn traverse_floating_literal_expr(self, n: *FloatingLiteralExpr) -> *FloatingLiteralExpr {
        self.dyn()->walkup_floating_literal_expr(n);
        return n;
    }

    fn traverse_string_literal_expr(self, n: *StringLiteralExpr) -> *StringLiteralExpr {
        if self.dyn()->walkup_string_literal_expr(n) == false { return n; }
        for var i: usize = 0; i < n->parts.size(); i++ {   // f"" interpolation exprs
            if self.stop { break; }
            self.dyn()->dispatch_expr(*(n->parts.get(i)));    // discard
        }
        return n;
    }

    fn traverse_character_literal_expr(self, n: *CharacterLiteralExpr) -> *CharacterLiteralExpr {
        self.dyn()->walkup_character_literal_expr(n);
        return n;
    }

    fn traverse_boolean_literal_expr(self, n: *BooleanLiteralExpr) -> *BooleanLiteralExpr {
        self.dyn()->walkup_boolean_literal_expr(n);
        return n;
    }

    fn traverse_null_literal_expr(self, n: *NullLiteralExpr) -> *NullLiteralExpr {
        self.dyn()->walkup_null_literal_expr(n);
        return n;
    }

    fn traverse_list_literal_expr(self, n: *ListLiteralExpr) -> *ListLiteralExpr {
        if self.dyn()->walkup_list_literal_expr(n) == false { return n; }
        for var i: usize = 0; i < n->elements.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_expr(*(n->elements.get(i)));  // discard
        }
        return n;
    }

    fn traverse_tuple_literal_expr(self, n: *TupleLiteralExpr) -> *TupleLiteralExpr {
        if self.dyn()->walkup_tuple_literal_expr(n) == false { return n; }
        for var i: usize = 0; i < n->elements.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_expr(*(n->elements.get(i)));  // discard
        }
        return n;
    }

    fn traverse_set_literal_expr(self, n: *SetLiteralExpr) -> *SetLiteralExpr {
        if self.dyn()->walkup_set_literal_expr(n) == false { return n; }
        for var i: usize = 0; i < n->elements.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_expr(*(n->elements.get(i)));  // discard
        }
        return n;
    }

    fn traverse_map_literal_expr(self, n: *MapLiteralExpr) -> *MapLiteralExpr {
        if self.dyn()->walkup_map_literal_expr(n) == false { return n; }
        for var i: usize = 0; i < n->entries.size(); i++ {
            if self.stop { break; }
            var en = n->entries.get(i);            // *MapLiteralExpr::Entry
            self.dyn()->dispatch_expr(en->key);    // discard
            if self.stop { break; }
            self.dyn()->dispatch_expr(en->value);  // discard
        }
        return n;
    }

    fn traverse_named_initializer_expr(self, n: *NamedInitializerExpr) -> *NamedInitializerExpr {
        if self.dyn()->walkup_named_initializer_expr(n) == false { return n; }
        if n->type_expr != &null {
            n->type_expr = self.dyn()->dispatch_expr(n->type_expr);
        }
        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop { break; }
            var f = n->fields.get(i);              // *InitField (name token skip)
            if f->value != &null {
                self.dyn()->dispatch_expr(f->value);  // discard
            }
        }
        return n;
    }

    fn traverse_anon_initializer_expr(self, n: *AnonInitializerExpr) -> *AnonInitializerExpr {
        if self.dyn()->walkup_anon_initializer_expr(n) == false { return n; }
        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop { break; }
            var f = n->fields.get(i);              // *InitField
            if f->value != &null {
                self.dyn()->dispatch_expr(f->value);  // discard
            }
        }
        return n;
    }

    fn traverse_chain_expr(self, n: *ChainExpr) -> *ChainExpr {
        if self.dyn()->walkup_chain_expr(n) == false { return n; }
        if n->base != &null {                      // null on global-root path
            n->base = self.dyn()->dispatch_expr(n->base);
        }
        for var i: usize = 0; i < n->steps.size(); i++ {
            if self.stop { break; }
            var st = n->steps.get(i);              // *ChainExpr::Step
            // st->name is the accessed identifier (name node) skip
            // st->resolved_type / resolved_decl are sema links skip
            for var j: usize = 0; j < st->generic_args.size(); j++ {
                if self.stop { break; }
                self.dyn()->traverse_generic_arg(st->generic_args.get(j));
            }
        }
        return n;
    }

    fn traverse_call_expr(self, n: *CallExpr) -> *CallExpr {
        if self.dyn()->walkup_call_expr(n) == false { return n; }
        if n->callee != &null {
            n->callee = self.dyn()->dispatch_expr(n->callee);
        }
        for var i: usize = 0; i < n->args.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_expr(*(n->args.get(i)));  // discard
        }
        return n;
    }

    fn traverse_subscript_expr(self, n: *SubscriptExpr) -> *SubscriptExpr {
        if self.dyn()->walkup_subscript_expr(n) == false { return n; }
        if n->base  != &null { n->base  = self.dyn()->dispatch_expr(n->base); }
        if n->index != &null { n->index = self.dyn()->dispatch_expr(n->index); }
        return n;
    }

    fn traverse_named_ident_expr(self, n: *NamedIdentExpr) -> *NamedIdentExpr {
        if self.dyn()->walkup_named_ident_expr(n) == false { return n; }
        // n->name is the identifier token skip. generic_args carry real types.
        for var i: usize = 0; i < n->generic_args.size(); i++ {
            if self.stop { break; }
            self.dyn()->traverse_generic_arg(n->generic_args.get(i));
        }
        return n;
    }

    fn traverse_unary_operator_expr(self, n: *UnaryOperatorExpr) -> *UnaryOperatorExpr {
        if self.dyn()->walkup_unary_operator_expr(n) == false { return n; }
        if n->operand != &null { n->operand = self.dyn()->dispatch_expr(n->operand); }
        return n;
    }

    fn traverse_binary_operator_expr(self, n: *BinaryOperatorExpr) -> *BinaryOperatorExpr {
        if self.dyn()->walkup_binary_operator_expr(n) == false { return n; }
        if n->lhs != &null { n->lhs = self.dyn()->dispatch_expr(n->lhs); }
        if n->rhs != &null { n->rhs = self.dyn()->dispatch_expr(n->rhs); }
        return n;
    }

    fn traverse_assign_operator_expr(self, n: *AssignOperatorExpr) -> *AssignOperatorExpr {
        if self.dyn()->walkup_assign_operator_expr(n) == false { return n; }
        if n->lhs != &null { n->lhs = self.dyn()->dispatch_expr(n->lhs); }
        if n->rhs != &null { n->rhs = self.dyn()->dispatch_expr(n->rhs); }
        return n;
    }

    fn traverse_impl_conformance_expr(self, n: *ImplConformanceExpr) -> *ImplConformanceExpr {
        if self.dyn()->walkup_impl_conformance_expr(n) == false { return n; }
        if n->subject != &null { n->subject = self.dyn()->dispatch_type(n->subject); }
        if n->inter   != &null { n->inter   = self.dyn()->dispatch_type(n->inter); }
        return n;
    }

    fn traverse_derives_relation_expr(self, n: *DerivesRelationExpr) -> *DerivesRelationExpr {
        if self.dyn()->walkup_derives_relation_expr(n) == false { return n; }
        if n->subject != &null { n->subject = self.dyn()->dispatch_type(n->subject); }
        if n->base    != &null { n->base    = self.dyn()->dispatch_type(n->base); }
        return n;
    }

    fn traverse_if_expr(self, n: *IfExpr) -> *IfExpr {
        if self.dyn()->walkup_if_expr(n) == false { return n; }
        if n->condition != &null { n->condition = self.dyn()->dispatch_expr(n->condition); }
        if n->then_expr != &null { n->then_expr = self.dyn()->dispatch_expr(n->then_expr); }
        for var i: usize = 0; i < n->else_ifs.size(); i++ {
            if self.stop { break; }
            var arm = n->else_ifs.get(i);               // *IfExpr::ElseIf
            if arm->condition != &null { self.dyn()->dispatch_expr(arm->condition); }
            if self.stop { break; }
            if arm->body != &null { self.dyn()->dispatch_expr(arm->body); }
        }
        if self.stop { return n; }
        if n->else_expr != &null { n->else_expr = self.dyn()->dispatch_expr(n->else_expr); }
        return n;
    }

    fn traverse_try_catch_expr(self, n: *TryCatchExpr) -> *TryCatchExpr {
        // NOTE: arm->filter / arm->body are frozen-list element fields, walked
        // read-only, returns discarded. Catch-filter type rewrites are NOT
        // possible via RAV (Option B); use ASTWriter if a pass needs that.
        if self.dyn()->walkup_try_catch_expr(n) == false { return n; }
        if n->try_expr != &null { n->try_expr = self.dyn()->dispatch_expr(n->try_expr); }
        for var i: usize = 0; i < n->catch_arms.size(); i++ {
            if self.stop { break; }
            var arm = n->catch_arms.get(i);   // *TryCatchExpr::CatchArm
            // arm->binding is the bound error name (name node) skip
            if arm->filter != &null { self.dyn()->dispatch_type(arm->filter); }  // discard
            if self.stop { break; }
            if arm->body   != &null { self.dyn()->dispatch_expr(arm->body); }    // discard
        }
        return n;
    }

    fn traverse_match_expr(self, n: *MatchExpr) -> *MatchExpr {
        if self.dyn()->walkup_match_expr(n) == false { return n; }
        if n->scrutinee != &null { n->scrutinee = self.dyn()->dispatch_expr(n->scrutinee); }
        for var i: usize = 0; i < n->cases.size(); i++ {
            if self.stop { break; }
            self.dyn()->traverse_match_case(n->cases.get(i));
        }
        return n;
    }

    fn traverse_range_expr(self, n: *RangeExpr) -> *RangeExpr {
        if self.dyn()->walkup_range_expr(n) == false { return n; }
        if n->begin != &null { n->begin = self.dyn()->dispatch_expr(n->begin); }
        if n->end   != &null { n->end   = self.dyn()->dispatch_expr(n->end); }
        return n;
    }

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        if self.dyn()->walkup_closure_expr(n) == false { return n; }

        for var i: usize = 0; i < (n->generic_params.size()); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->generic_params.get(i))); // discard
        }

        if self.stop { return n; }

        for var i: usize = 0; i < (n->params.size()); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->params.get(i))); // discard
        }

        if self.stop { return n; }

        for var i: usize = 0; i < n->captures.size(); i++ {
            if self.stop { break; }
            var cap = n->captures.get(i);
            if cap->name != &null {
                self.dyn()->dispatch_expr(cap->name); // discard
            }
        }

        if self.stop { return n; }

        if n->return_type != &null { n->return_type = self.dyn()->dispatch_type(n->return_type); }
        if n->body_block  != &null { n->body_block = self.dyn()->traverse_block(n->body_block); }
        if n->body_expr   != &null { n->body_expr  = self.dyn()->dispatch_expr(n->body_expr); }
        
        return n;
    }

    fn traverse_await_expr(self, n: *AwaitExpr) -> *AwaitExpr {
        if self.dyn()->walkup_await_expr(n) == false { return n; }
        if n->operand != &null { n->operand = self.dyn()->dispatch_expr(n->operand); }
        return n;
    }

    fn traverse_spawn_expr(self, n: *SpawnExpr) -> *SpawnExpr {
        if self.dyn()->walkup_spawn_expr(n) == false { return n; }
        if n->operand != &null { n->operand = self.dyn()->dispatch_expr(n->operand); }
        return n;
    }

    fn traverse_thread_expr(self, n: *ThreadExpr) -> *ThreadExpr {
        if self.dyn()->walkup_thread_expr(n) == false { return n; }
        if n->operand != &null { n->operand = self.dyn()->dispatch_expr(n->operand); }
        return n;
    }

    fn traverse_constraint_expr(self, n: *ConstraintExpr) -> *ConstraintExpr {
        if self.dyn()->walkup_constraint_expr(n) == false { return n; }
        if n->lhs != &null { n->lhs = self.dyn()->dispatch_expr(n->lhs); }
        if self.stop { return n; }
        if n->rhs != &null { n->rhs = self.dyn()->dispatch_type(n->rhs); }
        return n;
    }

    fn traverse_size_of_expr(self, n: *SizeOfExpr) -> *SizeOfExpr {
        if self.dyn()->walkup_size_of_expr(n) == false { return n; }
        if n->type_arg != &null { n->type_arg = self.dyn()->dispatch_type(n->type_arg); }
        return n;
    }

    fn traverse_align_of_expr(self, n: *AlignOfExpr) -> *AlignOfExpr {
        if self.dyn()->walkup_align_of_expr(n) == false { return n; }
        if n->type_arg != &null { n->type_arg = self.dyn()->dispatch_type(n->type_arg); }
        return n;
    }

    fn traverse_type_of_expr(self, n: *TypeOfExpr) -> *TypeOfExpr {
        if self.dyn()->walkup_type_of_expr(n) == false { return n; }
        if n->operand != &null { n->operand = self.dyn()->dispatch_expr(n->operand); }
        // n->resolved_type is a sema link skip
        return n;
    }

    fn traverse_paren_expr(self, n: *ParenExpr) -> *ParenExpr {
        if self.dyn()->walkup_paren_expr(n) == false { return n; }
        if n->inner != &null { n->inner = self.dyn()->dispatch_expr(n->inner); }
        return n;
    }

    /// No children by construction   a VerbatimExpr is an unparsed span.
    fn traverse_verbatim_expr(self, n: *VerbatimExpr) -> *VerbatimExpr {
        if self.dyn()->walkup_verbatim_expr(n) == false { return n; }
        return n;
    }

    fn traverse_eval_expr(self, n: *EvalExpr) -> *EvalExpr {
        if self.dyn()->walkup_eval_expr(n) == false { return n; }
        if n->operand != &null { n->operand = self.dyn()->dispatch_expr(n->operand); }
        return n;
    }

    fn traverse_unsafe_expr(self, n: *UnsafeExpr) -> *UnsafeExpr {
        if self.dyn()->walkup_unsafe_expr(n) == false { return n; }
        if n->operand != &null { n->operand = self.dyn()->dispatch_expr(n->operand); }
        return n;
    }

    fn traverse_delete_expr(self, n: *DeleteExpr) -> *DeleteExpr {
        if self.dyn()->walkup_delete_expr(n) == false { return n; }
        if n->operand != &null { n->operand = self.dyn()->dispatch_expr(n->operand); }
        return n;
    }

    fn traverse_pack_expansion_expr(self, n: *PackExpansionExpr) -> *PackExpansionExpr {
        if self.dyn()->walkup_pack_expansion_expr(n) == false { return n; }
        if n->operand != &null { n->operand = self.dyn()->dispatch_expr(n->operand); }
        return n;
    }

    fn traverse_type_cast_expr(self, n: *TypeCastExpr) -> *TypeCastExpr {
        if self.dyn()->walkup_type_cast_expr(n) == false { return n; }
        if n->operand != &null { n->operand = self.dyn()->dispatch_expr(n->operand); }
        if n->target  != &null { n->target  = self.dyn()->dispatch_type(n->target); }
        return n;
    }

    fn traverse_implicit_boundary_cast_expr(self, n: *ImplicitBoundaryCastExpr) -> *ImplicitBoundaryCastExpr {
        if self.dyn()->walkup_implicit_boundary_cast_expr(n) == false { return n; }
        if n->original    != &null { n->original    = self.dyn()->dispatch_expr(n->original); }
        if n->source_type != &null { n->source_type = self.dyn()->dispatch_type(n->source_type); }
        if n->target_type != &null { n->target_type = self.dyn()->dispatch_type(n->target_type); }
        return n;
    }

    // --- walkup (family hook THEN leaf hook, base-first) -------------------
    fn walkup_integer_literal_expr(self, n: *IntegerLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_integer_literal_expr(n);
    }

    fn walkup_floating_literal_expr(self, n: *FloatingLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_floating_literal_expr(n);
    }

    fn walkup_string_literal_expr(self, n: *StringLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_string_literal_expr(n);
    }

    fn walkup_character_literal_expr(self, n: *CharacterLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_character_literal_expr(n);
    }

    fn walkup_boolean_literal_expr(self, n: *BooleanLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_boolean_literal_expr(n);
    }

    fn walkup_null_literal_expr(self, n: *NullLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_null_literal_expr(n);
    }

    fn walkup_list_literal_expr(self, n: *ListLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_list_literal_expr(n);
    }

    fn walkup_tuple_literal_expr(self, n: *TupleLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_tuple_literal_expr(n);
    }

    fn walkup_set_literal_expr(self, n: *SetLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_set_literal_expr(n);
    }

    fn walkup_map_literal_expr(self, n: *MapLiteralExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_map_literal_expr(n);
    }

    fn walkup_named_initializer_expr(self, n: *NamedInitializerExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_named_initializer_expr(n);
    }

    fn walkup_anon_initializer_expr(self, n: *AnonInitializerExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_anon_initializer_expr(n);
    }

    fn walkup_chain_expr(self, n: *ChainExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_chain_expr(n);
    }

    fn walkup_call_expr(self, n: *CallExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_call_expr(n);
    }

    fn walkup_subscript_expr(self, n: *SubscriptExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_subscript_expr(n);
    }

    fn walkup_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_named_ident_expr(n);
    }

    fn walkup_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_unary_operator_expr(n);
    }

    fn walkup_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_binary_operator_expr(n);
    }

    fn walkup_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_assign_operator_expr(n);
    }

    fn walkup_impl_conformance_expr(self, n: *ImplConformanceExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_impl_conformance_expr(n);
    }

    fn walkup_derives_relation_expr(self, n: *DerivesRelationExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_derives_relation_expr(n);
    }

    fn walkup_if_expr(self, n: *IfExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_if_expr(n);
    }

    fn walkup_try_catch_expr(self, n: *TryCatchExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_try_catch_expr(n);
    }

    fn walkup_match_expr(self, n: *MatchExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_match_expr(n);
    }

    fn walkup_range_expr(self, n: *RangeExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_range_expr(n);
    }

    fn walkup_closure_expr(self, n: *ClosureExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_closure_expr(n);
    }

    fn walkup_await_expr(self, n: *AwaitExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_await_expr(n);
    }

    fn walkup_spawn_expr(self, n: *SpawnExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_spawn_expr(n);
    }

    fn walkup_thread_expr(self, n: *ThreadExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_thread_expr(n);
    }

    fn walkup_constraint_expr(self, n: *ConstraintExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_constraint_expr(n);
    }

    fn walkup_size_of_expr(self, n: *SizeOfExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_size_of_expr(n);
    }

    fn walkup_align_of_expr(self, n: *AlignOfExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_align_of_expr(n);
    }

    fn walkup_type_of_expr(self, n: *TypeOfExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_type_of_expr(n);
    }

    fn walkup_paren_expr(self, n: *ParenExpr) -> bool {
        if self.dyn()->visit_expr(static_cast::<*Expr>(n)) == false { return false; }
        return self.dyn()->visit_paren_expr(n);
    }

    fn walkup_verbatim_expr(self, n: *VerbatimExpr) -> bool {
        if self.dyn()->visit_expr(static_cast::<*Expr>(n)) == false { return false; }
        return self.dyn()->visit_verbatim_expr(n);
    }

    fn visit_paren_expr(self, n: *ParenExpr) -> bool { return true; }
    fn visit_verbatim_expr(self, n: *VerbatimExpr) -> bool { return true; }

    fn walkup_eval_expr(self, n: *EvalExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_eval_expr(n);
    }

    fn walkup_unsafe_expr(self, n: *UnsafeExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_unsafe_expr(n);
    }

    fn walkup_delete_expr(self, n: *DeleteExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_delete_expr(n);
    }

    fn walkup_pack_expansion_expr(self, n: *PackExpansionExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_pack_expansion_expr(n);
    }

    fn walkup_type_cast_expr(self, n: *TypeCastExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_type_cast_expr(n);
    }

    fn walkup_implicit_boundary_cast_expr(self, n: *ImplicitBoundaryCastExpr) -> bool {
        if self.dyn()->visit_expr(n) == false { return false; }
        return self.dyn()->visit_implicit_boundary_cast_expr(n);
    }

    // --- leaf visit hooks (override per node kind) ------------------------
    fn visit_integer_literal_expr(        self, n: *IntegerLiteralExpr       ) -> bool { return true; }
    fn visit_floating_literal_expr(       self, n: *FloatingLiteralExpr      ) -> bool { return true; }
    fn visit_string_literal_expr(         self, n: *StringLiteralExpr        ) -> bool { return true; }
    fn visit_character_literal_expr(      self, n: *CharacterLiteralExpr     ) -> bool { return true; }
    fn visit_boolean_literal_expr(        self, n: *BooleanLiteralExpr       ) -> bool { return true; }
    fn visit_null_literal_expr(           self, n: *NullLiteralExpr          ) -> bool { return true; }
    fn visit_list_literal_expr(           self, n: *ListLiteralExpr          ) -> bool { return true; }
    fn visit_tuple_literal_expr(          self, n: *TupleLiteralExpr         ) -> bool { return true; }
    fn visit_set_literal_expr(            self, n: *SetLiteralExpr           ) -> bool { return true; }
    fn visit_map_literal_expr(            self, n: *MapLiteralExpr           ) -> bool { return true; }
    fn visit_named_initializer_expr(      self, n: *NamedInitializerExpr     ) -> bool { return true; }
    fn visit_anon_initializer_expr(       self, n: *AnonInitializerExpr      ) -> bool { return true; }
    fn visit_chain_expr(                  self, n: *ChainExpr                ) -> bool { return true; }
    fn visit_call_expr(                   self, n: *CallExpr                 ) -> bool { return true; }
    fn visit_subscript_expr(              self, n: *SubscriptExpr            ) -> bool { return true; }
    fn visit_named_ident_expr(            self, n: *NamedIdentExpr           ) -> bool { return true; }
    fn visit_unary_operator_expr(         self, n: *UnaryOperatorExpr        ) -> bool { return true; }
    fn visit_binary_operator_expr(        self, n: *BinaryOperatorExpr       ) -> bool { return true; }
    fn visit_assign_operator_expr(        self, n: *AssignOperatorExpr       ) -> bool { return true; }
    fn visit_impl_conformance_expr(       self, n: *ImplConformanceExpr      ) -> bool { return true; }
    fn visit_derives_relation_expr(       self, n: *DerivesRelationExpr      ) -> bool { return true; }
    fn visit_if_expr(                     self, n: *IfExpr                   ) -> bool { return true; }
    fn visit_try_catch_expr(              self, n: *TryCatchExpr             ) -> bool { return true; }
    fn visit_match_expr(                  self, n: *MatchExpr                ) -> bool { return true; }
    fn visit_range_expr(                  self, n: *RangeExpr                ) -> bool { return true; }
    fn visit_closure_expr(                self, n: *ClosureExpr              ) -> bool { return true; }
    fn visit_await_expr(                  self, n: *AwaitExpr                ) -> bool { return true; }
    fn visit_spawn_expr(                  self, n: *SpawnExpr                ) -> bool { return true; }
    fn visit_thread_expr(                 self, n: *ThreadExpr               ) -> bool { return true; }
    fn visit_constraint_expr(             self, n: *ConstraintExpr           ) -> bool { return true; }
    fn visit_size_of_expr(                self, n: *SizeOfExpr               ) -> bool { return true; }
    fn visit_align_of_expr(               self, n: *AlignOfExpr              ) -> bool { return true; }
    fn visit_type_of_expr(                self, n: *TypeOfExpr               ) -> bool { return true; }
    fn visit_eval_expr(                   self, n: *EvalExpr                 ) -> bool { return true; }
    fn visit_unsafe_expr(                 self, n: *UnsafeExpr               ) -> bool { return true; }
    fn visit_delete_expr(                 self, n: *DeleteExpr               ) -> bool { return true; }
    fn visit_pack_expansion_expr(         self, n: *PackExpansionExpr        ) -> bool { return true; }
    fn visit_type_cast_expr(              self, n: *TypeCastExpr             ) -> bool { return true; }
    fn visit_implicit_boundary_cast_expr( self, n: *ImplicitBoundaryCastExpr ) -> bool { return true; }
    // == STMT FAMILY =======================================================
    fn dispatch_stmt(self, s: *Stmt) -> *Stmt {
        if s == &null { return s; }
        if self.stop  { return s; }

        switch s->kind {
            case StmtKind::CompoundStmt          { return self.dyn()->traverse_compound_stmt(          cast::<CompoundStmt>(s)          ); }
            case StmtKind::ExpressionStmt        { return self.dyn()->traverse_expression_stmt(        cast::<ExpressionStmt>(s)        ); }
            case StmtKind::DeclStmt              { return self.dyn()->traverse_decl_stmt(              cast::<DeclStmt>(s)              ); }
            case StmtKind::ReturnStmt            { return self.dyn()->traverse_return_stmt(            cast::<ReturnStmt>(s)            ); }
            case StmtKind::BreakStmt             { return self.dyn()->traverse_break_stmt(             cast::<BreakStmt>(s)             ); }
            case StmtKind::ContinueStmt          { return self.dyn()->traverse_continue_stmt(          cast::<ContinueStmt>(s)          ); }
            case StmtKind::PanicStmt             { return self.dyn()->traverse_panic_stmt(             cast::<PanicStmt>(s)             ); }
            case StmtKind::YieldStmt             { return self.dyn()->traverse_yield_stmt(             cast::<YieldStmt>(s)             ); }
            case StmtKind::RuntimeAssertStmt     { return self.dyn()->traverse_runtime_assert_stmt(    cast::<RuntimeAssertStmt>(s)     ); }
            case StmtKind::StaticAssertStmt      { return self.dyn()->traverse_static_assert_stmt(     cast::<StaticAssertStmt>(s)      ); }
            case StmtKind::LabelIntrinsicStmt    { return self.dyn()->traverse_label_intrinsic_stmt(   cast::<LabelIntrinsicStmt>(s)    ); }
            case StmtKind::JumpIntrinsicStmt     { return self.dyn()->traverse_jump_intrinsic_stmt(    cast::<JumpIntrinsicStmt>(s)     ); }
            case StmtKind::ConditionalStmt       { return self.dyn()->traverse_conditional_stmt(       cast::<ConditionalStmt>(s)       ); }
            case StmtKind::WhileLoopStmt         { return self.dyn()->traverse_while_loop_stmt(        cast::<WhileLoopStmt>(s)         ); }
            case StmtKind::LoopStmt              { return self.dyn()->traverse_loop_stmt(              cast::<LoopStmt>(s)              ); }
            case StmtKind::RangedForStmt         { return self.dyn()->traverse_ranged_for_stmt(        cast::<RangedForStmt>(s)         ); }
            case StmtKind::IndexedForStmt        { return self.dyn()->traverse_indexed_for_stmt(       cast::<IndexedForStmt>(s)        ); }
            case StmtKind::MatchStmt             { return self.dyn()->traverse_match_stmt(             cast::<MatchStmt>(s)             ); }
            case StmtKind::LabeledStmt           { return self.dyn()->traverse_labeled_stmt(           cast::<LabeledStmt>(s)           ); }
            case StmtKind::TryCatchStmt          { return self.dyn()->traverse_try_catch_stmt(         cast::<TryCatchStmt>(s)          ); }
            case StmtKind::FinallyStmt           { return self.dyn()->traverse_finally_stmt(           cast::<FinallyStmt>(s)           ); }
            case StmtKind::UnsafeBlockStmt       { return self.dyn()->traverse_unsafe_block_stmt(      cast::<UnsafeBlockStmt>(s)       ); }
            case StmtKind::ContextBindingStmt    { return self.dyn()->traverse_context_binding_stmt(   cast::<ContextBindingStmt>(s)    ); }
            case StmtKind::DestructuringDeclStmt { return self.dyn()->traverse_destructuring_decl_stmt(cast::<DestructuringDeclStmt>(s) ); }
            case StmtKind::InlineBlockStmt       { return self.dyn()->traverse_inline_block_stmt(      cast::<InlineBlockStmt>(s)       ); }
            case StmtKind::EvalBlockStmt         { return self.dyn()->traverse_eval_block_stmt(        cast::<EvalBlockStmt>(s)         ); }
            case StmtKind::RecoveryStmt          { self.dyn()->visit_stmt(s); return s; }
            case StmtKind::StmtKindCount         {  ICE_FAIL("StmtKindCount reached RAV in Stage 1 - this is a bug"); return &null; }
        }
        return s;
    }

    fn visit_stmt(self, n: *Stmt) -> bool { return true; }

    // --- traverse bodies ---------------------------------------------------
    fn traverse_compound_stmt(self, n: *CompoundStmt) -> *CompoundStmt {
        if self.dyn()->walkup_compound_stmt(n) == false { return n; }
        for var i: usize = 0; i < n->body.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_stmt(*(n->body.get(i)));  // discard
        }
        return n;
    }

    fn traverse_expression_stmt(self, n: *ExpressionStmt) -> *ExpressionStmt {
        if self.dyn()->walkup_expression_stmt(n) == false { return n; }
        if n->expr != &null { n->expr = self.dyn()->dispatch_expr(n->expr); }
        return n;
    }

    fn traverse_decl_stmt(self, n: *DeclStmt) -> *DeclStmt {
        if self.dyn()->walkup_decl_stmt(n) == false { return n; }
        if n->decl != &null { n->decl = self.dyn()->dispatch_decl(n->decl); }
        return n;
    }

    fn traverse_return_stmt(self, n: *ReturnStmt) -> *ReturnStmt {
        if self.dyn()->walkup_return_stmt(n) == false { return n; }
        if n->value != &null { n->value = self.dyn()->dispatch_expr(n->value); }
        return n;
    }

    fn traverse_break_stmt(self, n: *BreakStmt) -> *BreakStmt {
        self.dyn()->walkup_break_stmt(n);
        return n;
    }

    fn traverse_continue_stmt(self, n: *ContinueStmt) -> *ContinueStmt {
        self.dyn()->walkup_continue_stmt(n);
        return n;
    }

    fn traverse_panic_stmt(self, n: *PanicStmt) -> *PanicStmt {
        if self.dyn()->walkup_panic_stmt(n) == false { return n; }
        if n->payload != &null { n->payload = self.dyn()->dispatch_expr(n->payload); }
        return n;
    }

    fn traverse_yield_stmt(self, n: *YieldStmt) -> *YieldStmt {
        if self.dyn()->walkup_yield_stmt(n) == false { return n; }
        if n->value != &null { n->value = self.dyn()->dispatch_expr(n->value); }
        return n;
    }

    fn traverse_runtime_assert_stmt(self, n: *RuntimeAssertStmt) -> *RuntimeAssertStmt {
        if self.dyn()->walkup_runtime_assert_stmt(n) == false { return n; }
        if n->condition != &null { n->condition = self.dyn()->dispatch_expr(n->condition); }
        if n->message   != &null { n->message   = self.dyn()->dispatch_expr(n->message); }
        return n;
    }

    fn traverse_static_assert_stmt(self, n: *StaticAssertStmt) -> *StaticAssertStmt {
        if self.dyn()->walkup_static_assert_stmt(n) == false { return n; }
        if n->condition != &null { n->condition = self.dyn()->dispatch_expr(n->condition); }
        if n->message   != &null { n->message   = self.dyn()->dispatch_expr(n->message); }
        return n;
    }

    fn traverse_label_intrinsic_stmt(self, n: *LabelIntrinsicStmt) -> *LabelIntrinsicStmt {
        self.dyn()->walkup_label_intrinsic_stmt(n);
        return n;
    }

    fn traverse_jump_intrinsic_stmt(self, n: *JumpIntrinsicStmt) -> *JumpIntrinsicStmt {
        self.dyn()->walkup_jump_intrinsic_stmt(n);
        return n;
    }

    fn traverse_conditional_stmt(self, n: *ConditionalStmt) -> *ConditionalStmt {
        if self.dyn()->walkup_conditional_stmt(n) == false { return n; }
        if n->cond != &null { n->cond = self.dyn()->dispatch_expr(n->cond); }
        n->then_ = self.dyn()->traverse_block(n->then_);
        if n->else_ != &null { n->else_ = self.dyn()->dispatch_stmt(n->else_); }
        return n;
    }

    fn traverse_while_loop_stmt(self, n: *WhileLoopStmt) -> *WhileLoopStmt {
        if self.dyn()->walkup_while_loop_stmt(n) == false { return n; }
        if n->cond != &null { n->cond = self.dyn()->dispatch_expr(n->cond); }
        n->body = self.dyn()->traverse_block(n->body);
        return n;
    }

    fn traverse_loop_stmt(self, n: *LoopStmt) -> *LoopStmt {
        if self.dyn()->walkup_loop_stmt(n) == false { return n; }
        n->body = self.dyn()->traverse_block(n->body);
        return n;
    }

    fn traverse_ranged_for_stmt(self, n: *RangedForStmt) -> *RangedForStmt {
        if self.dyn()->walkup_ranged_for_stmt(n) == false { return n; }
        // bindings carry only a NamedIdentExpr name (name node) skip.
        if n->iterable != &null { n->iterable = self.dyn()->dispatch_expr(n->iterable); }
        n->body = self.dyn()->traverse_block(n->body);
        return n;
    }

    fn traverse_indexed_for_stmt(self, n: *IndexedForStmt) -> *IndexedForStmt {
        if self.dyn()->walkup_indexed_for_stmt(n) == false { return n; }
        if n->init   != &null { n->init   = self.dyn()->dispatch_stmt(n->init); }
        if n->cond   != &null { n->cond   = self.dyn()->dispatch_expr(n->cond); }
        if n->update != &null { n->update = self.dyn()->dispatch_expr(n->update); }
        n->body = self.dyn()->traverse_block(n->body);
        return n;
    }

    fn traverse_match_stmt(self, n: *MatchStmt) -> *MatchStmt {
        if self.dyn()->walkup_match_stmt(n) == false { return n; }
        if n->scrutinee != &null { n->scrutinee = self.dyn()->dispatch_expr(n->scrutinee); }
        for var i: usize = 0; i < n->cases.size(); i++ {
            if self.stop { break; }
            self.dyn()->traverse_match_case(n->cases.get(i));
        }
        return n;
    }

    fn traverse_labeled_stmt(self, n: *LabeledStmt) -> *LabeledStmt {
        if self.dyn()->walkup_labeled_stmt(n) == false { return n; }
        if n->inner != &null { n->inner = self.dyn()->dispatch_stmt(n->inner); }
        return n;
    }

    fn traverse_try_catch_stmt(self, n: *TryCatchStmt) -> *TryCatchStmt {
        if self.dyn()->walkup_try_catch_stmt(n) == false { return n; }
        n->try_body = self.dyn()->traverse_block(n->try_body);
        for var i: usize = 0; i < n->arms.size(); i++ {
            if self.stop { break; }
            var arm = n->arms.get(i);    // *CatchArm
            // arm->binding is the bound error name (name node) skip
            if arm->filter != &null { self.dyn()->dispatch_type(arm->filter); }      // discard
            if self.stop { break; }
            if arm->body   != &null { self.dyn()->dispatch_stmt(arm->body); } // discard (block, list element)
        }
        return n;
    }

    fn traverse_finally_stmt(self, n: *FinallyStmt) -> *FinallyStmt {
        if self.dyn()->walkup_finally_stmt(n) == false { return n; }
        n->body = self.dyn()->traverse_block(n->body);
        return n;
    }

    fn traverse_unsafe_block_stmt(self, n: *UnsafeBlockStmt) -> *UnsafeBlockStmt {
        if self.dyn()->walkup_unsafe_block_stmt(n) == false { return n; }
        n->body = self.dyn()->traverse_block(n->body);
        return n;
    }

    fn traverse_context_binding_stmt(self, n: *ContextBindingStmt) -> *ContextBindingStmt {
        if self.dyn()->walkup_context_binding_stmt(n) == false { return n; }
        // bindings carry only NamedIdentExpr names skip.
        if n->value != &null { n->value = self.dyn()->dispatch_expr(n->value); }
        n->body = self.dyn()->traverse_block(n->body);
        return n;
    }

    fn traverse_destructuring_decl_stmt(self, n: *DestructuringDeclStmt) -> *DestructuringDeclStmt {
        if self.dyn()->walkup_destructuring_decl_stmt(n) == false { return n; }
        // bindings carry only NamedIdentExpr names skip.
        if n->value != &null { n->value = self.dyn()->dispatch_expr(n->value); }
        return n;
    }

    fn traverse_inline_block_stmt(self, n: *InlineBlockStmt) -> *InlineBlockStmt {
        // body is opaque foreign text (body_span); no Kairo children.
        self.dyn()->walkup_inline_block_stmt(n);
        return n;
    }

    fn traverse_eval_block_stmt(self, n: *EvalBlockStmt) -> *EvalBlockStmt {
        if self.dyn()->walkup_eval_block_stmt(n) == false { return n; }
        for var i: usize = 0; i < n->body.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->body.get(i)));  // discard
        }
        return n;
    }

    // --- walkup ------------------------------------------------------------
    fn walkup_compound_stmt(self, n: *CompoundStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_compound_stmt(n);
    }

    fn walkup_expression_stmt(self, n: *ExpressionStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_expression_stmt(n);
    }

    fn walkup_decl_stmt(self, n: *DeclStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_decl_stmt(n);
    }

    fn walkup_return_stmt(self, n: *ReturnStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_return_stmt(n);
    }

    fn walkup_break_stmt(self, n: *BreakStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_break_stmt(n);
    }

    fn walkup_continue_stmt(self, n: *ContinueStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_continue_stmt(n);
    }

    fn walkup_panic_stmt(self, n: *PanicStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_panic_stmt(n);
    }

    fn walkup_yield_stmt(self, n: *YieldStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_yield_stmt(n);
    }

    fn walkup_runtime_assert_stmt(self, n: *RuntimeAssertStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_runtime_assert_stmt(n);
    }

    fn walkup_static_assert_stmt(self, n: *StaticAssertStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_static_assert_stmt(n);
    }

    fn walkup_label_intrinsic_stmt(self, n: *LabelIntrinsicStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_label_intrinsic_stmt(n);
    }

    fn walkup_jump_intrinsic_stmt(self, n: *JumpIntrinsicStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_jump_intrinsic_stmt(n);
    }

    fn walkup_conditional_stmt(self, n: *ConditionalStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_conditional_stmt(n);
    }

    fn walkup_while_loop_stmt(self, n: *WhileLoopStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_while_loop_stmt(n);
    }

    fn walkup_loop_stmt(self, n: *LoopStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_loop_stmt(n);
    }

    fn walkup_ranged_for_stmt(self, n: *RangedForStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_ranged_for_stmt(n);
    }

    fn walkup_indexed_for_stmt(self, n: *IndexedForStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_indexed_for_stmt(n);
    }

    fn walkup_match_stmt(self, n: *MatchStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_match_stmt(n);
    }

    fn walkup_labeled_stmt(self, n: *LabeledStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_labeled_stmt(n);
    }

    fn walkup_try_catch_stmt(self, n: *TryCatchStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_try_catch_stmt(n);
    }

    fn walkup_finally_stmt(self, n: *FinallyStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_finally_stmt(n);
    }

    fn walkup_unsafe_block_stmt(self, n: *UnsafeBlockStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_unsafe_block_stmt(n);
    }

    fn walkup_context_binding_stmt(self, n: *ContextBindingStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_context_binding_stmt(n);
    }

    fn walkup_destructuring_decl_stmt(self, n: *DestructuringDeclStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_destructuring_decl_stmt(n);
    }

    fn walkup_inline_block_stmt(self, n: *InlineBlockStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_inline_block_stmt(n);
    }

    fn walkup_eval_block_stmt(self, n: *EvalBlockStmt) -> bool {
        if self.dyn()->visit_stmt(n) == false { return false; }
        return self.dyn()->visit_eval_block_stmt(n);
    }

    // --- leaf visit hooks --------------------------------------------------
    fn visit_compound_stmt(           self, n: *CompoundStmt          ) -> bool { return true; }
    fn visit_expression_stmt(         self, n: *ExpressionStmt        ) -> bool { return true; }
    fn visit_decl_stmt(               self, n: *DeclStmt              ) -> bool { return true; }
    fn visit_return_stmt(             self, n: *ReturnStmt            ) -> bool { return true; }
    fn visit_break_stmt(              self, n: *BreakStmt             ) -> bool { return true; }
    fn visit_continue_stmt(           self, n: *ContinueStmt          ) -> bool { return true; }
    fn visit_panic_stmt(              self, n: *PanicStmt             ) -> bool { return true; }
    fn visit_yield_stmt(              self, n: *YieldStmt             ) -> bool { return true; }
    fn visit_runtime_assert_stmt(     self, n: *RuntimeAssertStmt     ) -> bool { return true; }
    fn visit_static_assert_stmt(      self, n: *StaticAssertStmt      ) -> bool { return true; }
    fn visit_label_intrinsic_stmt(    self, n: *LabelIntrinsicStmt    ) -> bool { return true; }
    fn visit_jump_intrinsic_stmt(     self, n: *JumpIntrinsicStmt     ) -> bool { return true; }
    fn visit_conditional_stmt(        self, n: *ConditionalStmt       ) -> bool { return true; }
    fn visit_while_loop_stmt(         self, n: *WhileLoopStmt         ) -> bool { return true; }
    fn visit_loop_stmt(               self, n: *LoopStmt              ) -> bool { return true; }
    fn visit_ranged_for_stmt(         self, n: *RangedForStmt         ) -> bool { return true; }
    fn visit_indexed_for_stmt(        self, n: *IndexedForStmt        ) -> bool { return true; }
    fn visit_match_stmt(              self, n: *MatchStmt             ) -> bool { return true; }
    fn visit_labeled_stmt(            self, n: *LabeledStmt           ) -> bool { return true; }
    fn visit_try_catch_stmt(          self, n: *TryCatchStmt          ) -> bool { return true; }
    fn visit_finally_stmt(            self, n: *FinallyStmt           ) -> bool { return true; }
    fn visit_unsafe_block_stmt(       self, n: *UnsafeBlockStmt       ) -> bool { return true; }
    fn visit_context_binding_stmt(    self, n: *ContextBindingStmt    ) -> bool { return true; }
    fn visit_destructuring_decl_stmt( self, n: *DestructuringDeclStmt ) -> bool { return true; }
    fn visit_inline_block_stmt(       self, n: *InlineBlockStmt       ) -> bool { return true; }
    fn visit_eval_block_stmt(         self, n: *EvalBlockStmt         ) -> bool { return true; }
    // == DECL FAMILY =======================================================
    fn dispatch_decl(self, d: *Decl) -> *Decl {
        if d == &null { return d; }
        if self.stop  { return d; }

        switch d->kind {
            case DeclKind::FunctionDecl        { return self.dyn()->traverse_function_decl(        cast::<FunctionDecl>(d)        ); }
            case DeclKind::VariableDecl        { return self.dyn()->traverse_variable_decl(        cast::<VariableDecl>(d)        ); }
            case DeclKind::FieldDecl           { return self.dyn()->traverse_field_decl(           cast::<FieldDecl>(d)           ); }
            case DeclKind::ParamDecl           { return self.dyn()->traverse_param_decl(           cast::<ParamDecl>(d)           ); }
            case DeclKind::GenericParamDecl    { return self.dyn()->traverse_generic_param_decl(   cast::<GenericParamDecl>(d)    ); }
            case DeclKind::StructDecl          { return self.dyn()->traverse_struct_decl(          cast::<StructDecl>(d)          ); }
            case DeclKind::ClassDecl           { return self.dyn()->traverse_class_decl(           cast::<ClassDecl>(d)           ); }
            case DeclKind::InterfaceDecl       { return self.dyn()->traverse_interface_decl(       cast::<InterfaceDecl>(d)       ); }
            case DeclKind::ExtensionDecl       { return self.dyn()->traverse_extension_decl(       cast::<ExtensionDecl>(d)       ); }
            case DeclKind::EnumDecl            { return self.dyn()->traverse_enum_decl(            cast::<EnumDecl>(d)            ); }
            case DeclKind::EnumVariantDecl     { return self.dyn()->traverse_enum_variant_decl(    cast::<EnumVariantDecl>(d)     ); }
            case DeclKind::UnionDecl           { return self.dyn()->traverse_union_decl(           cast::<UnionDecl>(d)           ); }
            case DeclKind::TypeAliasDecl       { return self.dyn()->traverse_type_alias_decl(      cast::<TypeAliasDecl>(d)       ); }
            case DeclKind::ModuleDecl          { return self.dyn()->traverse_module_decl(          cast::<ModuleDecl>(d)          ); }
            case DeclKind::ImportDecl          { return self.dyn()->traverse_import_decl(          cast::<ImportDecl>(d)          ); }
            case DeclKind::VisibilityGroupDecl { return self.dyn()->traverse_visibility_group_decl(cast::<VisibilityGroupDecl>(d) ); }
            case DeclKind::EvalBlockDecl       { return self.dyn()->traverse_eval_block_decl(      cast::<EvalBlockDecl>(d)       ); }
            case DeclKind::TestDecl            { return self.dyn()->traverse_test_decl(            cast::<TestDecl>(d)            ); }
            case DeclKind::MacroDecl           { return self.dyn()->traverse_macro_decl(           cast::<MacroDecl>(d)           ); }
            case DeclKind::ProcedureMacroDecl  { return self.dyn()->traverse_procedure_macro_decl( cast::<ProcedureMacroDecl>(d)  ); }
            case DeclKind::FFIBlockDecl        { return self.dyn()->traverse_ffi_block_decl(       cast::<FFIBlockDecl>(d)        ); }
            case DeclKind::RecoveryDecl        { self.dyn()->visit_decl(d); return d; }
            case DeclKind::DeclKindCount       {  ICE_FAIL("DeclKindCount reached RAV in Stage 1 - this is a bug"); return &null; }
        }
        return d;
    }

    fn visit_decl(self, n: *Decl) -> bool { return true; }

    // --- traverse bodies ---------------------------------------------------
    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        if self.dyn()->walkup_function_decl(n) == false { return n; }
        // TemplateParams mixin children
        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->generic_params.get(i)));  // discard
        }
        if self.stop { return n; }
        // specialization argument pattern types (#68)
        for var i: usize = 0; i < n->spec_args.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_type(*(n->spec_args.get(i)));  // discard
        }
        if self.stop { return n; }
        if n->requires_clause != &null { n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause); }
        if self.stop { return n; }
        if n->where_clause != &null { n->where_clause = self.dyn()->dispatch_expr(n->where_clause); }
        // params
        for var i: usize = 0; i < n->params.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->params.get(i)));          // discard
        }
        if self.stop { return n; }
        if n->return_type != &null { n->return_type = self.dyn()->dispatch_type(n->return_type); }
        if n->qualifier   != &null { n->qualifier   = self.dyn()->dispatch_expr(n->qualifier); }  // out-of-line Class:: path
        if n->body_block  != &null { n->body_block  = self.dyn()->traverse_block(n->body_block); }
        if n->body_expr   != &null { n->body_expr   = self.dyn()->dispatch_expr(n->body_expr); }
        return n;
    }

    fn traverse_variable_decl(self, n: *VariableDecl) -> *VariableDecl {
        if self.dyn()->walkup_variable_decl(n) == false { return n; }
        if n->type_ != &null { n->type_ = self.dyn()->dispatch_type(n->type_); }
        if n->init  != &null { n->init  = self.dyn()->dispatch_expr(n->init); }
        return n;
    }

    fn traverse_field_decl(self, n: *FieldDecl) -> *FieldDecl {
        if self.dyn()->walkup_field_decl(n) == false { return n; }
        if n->type_ != &null { n->type_ = self.dyn()->dispatch_type(n->type_); }
        if n->init  != &null { n->init  = self.dyn()->dispatch_expr(n->init); }
        return n;
    }

    fn traverse_param_decl(self, n: *ParamDecl) -> *ParamDecl {
        if self.dyn()->walkup_param_decl(n) == false { return n; }
        if n->type_       != &null { n->type_       = self.dyn()->dispatch_type(n->type_); }  // null for self
        if n->default_val != &null { n->default_val = self.dyn()->dispatch_expr(n->default_val); }
        return n;
    }

    fn traverse_generic_param_decl(self, n: *GenericParamDecl) -> *GenericParamDecl {
        if self.dyn()->walkup_generic_param_decl(n) == false { return n; }
        for var i: usize = 0; i < n->impl_bounds.size(); i++ {
            if self.stop { break; }
            self.dyn()->traverse_inherit_edge(n->impl_bounds.get(i));
        }
        for var i: usize = 0; i < n->derives_bounds.size(); i++ {
            if self.stop { break; }
            self.dyn()->traverse_inherit_edge(n->derives_bounds.get(i));
        }
        if self.stop { return n; }
        if n->value_type   != &null { n->value_type   = self.dyn()->dispatch_type(n->value_type); }
        if n->default_type != &null { n->default_type = self.dyn()->dispatch_type(n->default_type); }
        return n;
    }

    // Helper: dispatch the nested-type decls held in dc_decls, skipping the
    // VisibilityGroupDecl wrappers (their members are reached via the node's
    // fields/methods lists, so dispatching the wrapper too would double-visit).
    fn _rav_dc_nested(self, dc: *DeclContext) {
        for var i: usize = 0; i < dc->dc_decls.size(); i++ {
            if self.stop { break; }
            var d = *(dc->dc_decls.get(i));
            if d == &null { continue; }
            if isa::<VisibilityGroupDecl>(d) { continue; }
            self.dyn()->dispatch_decl(d);  // discard
        }
    }

    fn traverse_struct_decl(self, n: *StructDecl) -> *StructDecl {
        if self.dyn()->walkup_struct_decl(n) == false { return n; }
        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->generic_params.get(i)));  // discard
        }
        if self.stop { return n; }
        // specialization argument pattern types (#68)
        for var i: usize = 0; i < n->spec_args.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_type(*(n->spec_args.get(i)));  // discard
        }
        if self.stop { return n; }
        if n->requires_clause != &null { n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause); }
        for var i: usize = 0; i < n->implements.size(); i++ {
            if self.stop { break; }
            self.dyn()->traverse_inherit_edge(n->implements.get(i));
        }
        // MEMBERS: flat fields + nested types (no methods in a struct body).
        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->fields.get(i)));  // discard
        }
        if self.stop { return n; }
        self.dyn()->_rav_dc_nested(static_cast::<*DeclContext>(n));
        return n;
    }

    fn traverse_class_decl(self, n: *ClassDecl) -> *ClassDecl {
        if self.dyn()->walkup_class_decl(n) == false { return n; }
        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->generic_params.get(i)));  // discard
        }
        if self.stop { return n; }
        // specialization argument pattern types (#68)
        for var i: usize = 0; i < n->spec_args.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_type(*(n->spec_args.get(i)));  // discard
        }
        if self.stop { return n; }
        if n->requires_clause != &null { n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause); }
        for var i: usize = 0; i < n->derives_list.size(); i++ {
            if self.stop { break; }
            self.dyn()->traverse_inherit_edge(n->derives_list.get(i));
        }
        for var i: usize = 0; i < n->implements.size(); i++ {
            if self.stop { break; }
            self.dyn()->traverse_inherit_edge(n->implements.get(i));
        }
        // MEMBERS: flat fields + flat methods (grouped members are in these
        // lists too) + nested types from dc_decls. NOT the dc_decls flat walk:
        // dc_decls holds only nested types + vg-wrappers for a type body.
        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->fields.get(i)));  // discard
        }
        for var i: usize = 0; i < n->methods.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->methods.get(i)));  // discard
        }
        if self.stop { return n; }
        self.dyn()->_rav_dc_nested(static_cast::<*DeclContext>(n));
        return n;
    }

    fn traverse_interface_decl(self, n: *InterfaceDecl) -> *InterfaceDecl {
        if self.dyn()->walkup_interface_decl(n) == false { return n; }
        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->generic_params.get(i)));  // discard
        }
        if self.stop { return n; }
        if n->requires_clause != &null { n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause); }
        for var i: usize = 0; i < n->derives_list.size(); i++ {
            if self.stop { break; }
            self.dyn()->traverse_inherit_edge(n->derives_list.get(i));
        }
        for var i: usize = 0; i < n->methods.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->methods.get(i)));  // discard
        }
        if self.stop { return n; }
        self.dyn()->_rav_dc_nested(static_cast::<*DeclContext>(n));
        return n;
    }

    fn traverse_extension_decl(self, n: *ExtensionDecl) -> *ExtensionDecl {
        if self.dyn()->walkup_extension_decl(n) == false { return n; }
        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->generic_params.get(i)));  // discard
        }
        if self.stop { return n; }
        if n->requires_clause != &null { n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause); }
        if n->target != &null { n->target = self.dyn()->dispatch_type(n->target); }
        for var i: usize = 0; i < n->implements.size(); i++ {
            if self.stop { break; }
            self.dyn()->traverse_inherit_edge(n->implements.get(i));
        }
        for var i: usize = 0; i < n->methods.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->methods.get(i)));  // discard
        }
        if self.stop { return n; }
        self.dyn()->_rav_dc_nested(static_cast::<*DeclContext>(n));
        return n;
    }

    fn traverse_enum_decl(self, n: *EnumDecl) -> *EnumDecl {
        if self.dyn()->walkup_enum_decl(n) == false { return n; }
        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->generic_params.get(i)));  // discard
        }
        if self.stop { return n; }
        if n->requires_clause != &null { n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause); }
        if n->underlying != &null { n->underlying = self.dyn()->dispatch_type(n->underlying); }
        // MEMBERS: variants only. The enum body parser pushes to `variants`
        // and never calls add_decl, so dc_decls is empty for an enum.
        for var i: usize = 0; i < n->variants.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->variants.get(i)));  // discard
        }
        return n;
    }

    fn traverse_union_decl(self, n: *UnionDecl) -> *UnionDecl {
        if self.dyn()->walkup_union_decl(n) == false { return n; }
        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->generic_params.get(i)));  // discard
        }
        if self.stop { return n; }
        // specialization argument pattern types (#68)
        for var i: usize = 0; i < n->spec_args.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_type(*(n->spec_args.get(i)));  // discard
        }
        if self.stop { return n; }
        if n->requires_clause != &null { n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause); }
        for var i: usize = 0; i < n->fields.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->fields.get(i)));  // discard
        }
        if self.stop { return n; }
        self.dyn()->_rav_dc_nested(static_cast::<*DeclContext>(n));
        return n;
    }

    fn traverse_enum_variant_decl(self, n: *EnumVariantDecl) -> *EnumVariantDecl {
        if self.dyn()->walkup_enum_variant_decl(n) == false { return n; }
        if n->discriminant != &null { n->discriminant = self.dyn()->dispatch_expr(n->discriminant); }
        for var i: usize = 0; i < n->payload.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->payload.get(i)));         // discard
        }
        return n;
    }

    fn traverse_type_alias_decl(self, n: *TypeAliasDecl) -> *TypeAliasDecl {
        if self.dyn()->walkup_type_alias_decl(n) == false { return n; }
        for var i: usize = 0; i < n->generic_params.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->generic_params.get(i)));  // discard
        }
        if self.stop { return n; }
        if n->requires_clause != &null { n->requires_clause = self.dyn()->dispatch_expr(n->requires_clause); }
        if n->aliased != &null { n->aliased = self.dyn()->dispatch_type(n->aliased); }
        return n;
    }

    fn traverse_module_decl(self, n: *ModuleDecl) -> *ModuleDecl {
        if self.dyn()->walkup_module_decl(n) == false { return n; }
        // Members live in the DeclContext (dc_decls), not a FrozenList field.
        for var i: usize = 0; i < n->dc_decls.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->dc_decls.get(i)));  // discard
        }
        return n;
    }

    fn traverse_import_decl(self, n: *ImportDecl) -> *ImportDecl {
        // path_segments / items are token lists no AST children.
        self.dyn()->walkup_import_decl(n);
        return n;
    }

    fn traverse_ffi_block_decl(self, n: *FFIBlockDecl) -> *FFIBlockDecl {
        if self.dyn()->walkup_ffi_block_decl(n) == false { return n; }
        // lang_token is a leaf token; skip.
        // Traverse each child declaration in the FFI block's body.
        for var i: usize = 0; i < n->body.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->body.get(i)));  // discard return
        }
        return n;
    }

    fn traverse_visibility_group_decl(self, n: *VisibilityGroupDecl) -> *VisibilityGroupDecl {
        if self.dyn()->walkup_visibility_group_decl(n) == false { return n; }
        for var i: usize = 0; i < n->members.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->members.get(i)));  // discard
        }
        return n;
    }

    fn traverse_eval_block_decl(self, n: *EvalBlockDecl) -> *EvalBlockDecl {
        if self.dyn()->walkup_eval_block_decl(n) == false { return n; }
        for var i: usize = 0; i < n->body.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->body.get(i)));  // discard
        }
        return n;
    }

    fn traverse_test_decl(self, n: *TestDecl) -> *TestDecl {
        if self.dyn()->walkup_test_decl(n) == false { return n; }
        if n->label != &null { n->label = self.dyn()->dispatch_expr(n->label); }  // StringLiteralExpr
        if n->body  != &null { n->body  = self.dyn()->traverse_block(n->body); }
        return n;
    }

    fn traverse_macro_decl(self, n: *MacroDecl) -> *MacroDecl {
        // params are bare tokens; body_span is raw tokens no AST children.
        self.dyn()->walkup_macro_decl(n);
        return n;
    }

    fn traverse_procedure_macro_decl(self, n: *ProcedureMacroDecl) -> *ProcedureMacroDecl {
        if self.dyn()->walkup_procedure_macro_decl(n) == false { return n; }
        for var i: usize = 0; i < n->params.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_decl(*(n->params.get(i)));  // discard
        }
        if self.stop { return n; }
        if n->body != &null { n->body = self.dyn()->traverse_block(n->body); }
        return n;
    }

    // --- walkup ------------------------------------------------------------
    fn walkup_function_decl(self, n: *FunctionDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_function_decl(n);
    }

    fn walkup_variable_decl(self, n: *VariableDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_variable_decl(n);
    }

    fn walkup_field_decl(self, n: *FieldDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_field_decl(n);
    }

    fn walkup_param_decl(self, n: *ParamDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_param_decl(n);
    }

    fn walkup_generic_param_decl(self, n: *GenericParamDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_generic_param_decl(n);
    }

    fn walkup_struct_decl(self, n: *StructDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_struct_decl(n);
    }

    fn walkup_class_decl(self, n: *ClassDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_class_decl(n);
    }

    fn walkup_interface_decl(self, n: *InterfaceDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_interface_decl(n);
    }

    fn walkup_extension_decl(self, n: *ExtensionDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_extension_decl(n);
    }

    fn walkup_enum_decl(self, n: *EnumDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_enum_decl(n);
    }

    fn walkup_enum_variant_decl(self, n: *EnumVariantDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_enum_variant_decl(n);
    }

    fn walkup_union_decl(self, n: *UnionDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_union_decl(n);
    }

    fn walkup_type_alias_decl(self, n: *TypeAliasDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_type_alias_decl(n);
    }

    fn walkup_module_decl(self, n: *ModuleDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_module_decl(n);
    }

    fn walkup_import_decl(self, n: *ImportDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_import_decl(n);
    }

    fn walkup_ffi_block_decl(self, n: *FFIBlockDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_ffi_block_decl(n);
    }

    fn walkup_visibility_group_decl(self, n: *VisibilityGroupDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_visibility_group_decl(n);
    }

    fn walkup_eval_block_decl(self, n: *EvalBlockDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_eval_block_decl(n);
    }

    fn walkup_test_decl(self, n: *TestDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_test_decl(n);
    }

    fn walkup_macro_decl(self, n: *MacroDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_macro_decl(n);
    }

    fn walkup_procedure_macro_decl(self, n: *ProcedureMacroDecl) -> bool {
        if self.dyn()->visit_decl(n) == false { return false; }
        return self.dyn()->visit_procedure_macro_decl(n);
    }

    // --- leaf visit hooks --------------------------------------------------
    fn visit_function_decl(        self, n: *FunctionDecl        ) -> bool { return true; }
    fn visit_variable_decl(        self, n: *VariableDecl        ) -> bool { return true; }
    fn visit_field_decl(           self, n: *FieldDecl           ) -> bool { return true; }
    fn visit_param_decl(           self, n: *ParamDecl           ) -> bool { return true; }
    fn visit_generic_param_decl(   self, n: *GenericParamDecl    ) -> bool { return true; }
    fn visit_struct_decl(          self, n: *StructDecl          ) -> bool { return true; }
    fn visit_class_decl(           self, n: *ClassDecl           ) -> bool { return true; }
    fn visit_interface_decl(       self, n: *InterfaceDecl       ) -> bool { return true; }
    fn visit_extension_decl(       self, n: *ExtensionDecl       ) -> bool { return true; }
    fn visit_enum_decl(            self, n: *EnumDecl            ) -> bool { return true; }
    fn visit_enum_variant_decl(    self, n: *EnumVariantDecl     ) -> bool { return true; }
    fn visit_union_decl(           self, n: *UnionDecl           ) -> bool { return true; }
    fn visit_type_alias_decl(      self, n: *TypeAliasDecl       ) -> bool { return true; }
    fn visit_module_decl(          self, n: *ModuleDecl          ) -> bool { return true; }
    fn visit_import_decl(          self, n: *ImportDecl          ) -> bool { return true; }
    fn visit_ffi_block_decl(       self, n: *FFIBlockDecl        ) -> bool { return true; }
    fn visit_visibility_group_decl(self, n: *VisibilityGroupDecl ) -> bool { return true; }
    fn visit_eval_block_decl(      self, n: *EvalBlockDecl       ) -> bool { return true; }
    fn visit_test_decl(            self, n: *TestDecl            ) -> bool { return true; }
    fn visit_macro_decl(           self, n: *MacroDecl           ) -> bool { return true; }
    fn visit_procedure_macro_decl( self, n: *ProcedureMacroDecl  ) -> bool { return true; }
    // == PATTERN FAMILY ====================================================
    fn dispatch_pattern(self, p: *Pattern) -> *Pattern {
        if p == &null { return p; }
        if self.stop  { return p; }

        switch p->kind {
            case PatternKind::WildcardPattern              { return self.dyn()->traverse_wildcard_pattern(              cast::<WildcardPattern>(p)              ); }
            case PatternKind::LiteralPattern               { return self.dyn()->traverse_literal_pattern(               cast::<LiteralPattern>(p)               ); }
            case PatternKind::BindingPattern               { return self.dyn()->traverse_binding_pattern(               cast::<BindingPattern>(p)               ); }
            case PatternKind::TupleDestructurePattern      { return self.dyn()->traverse_tuple_destructure_pattern(     cast::<TupleDestructurePattern>(p)      ); }
            case PatternKind::ConstructorPattern           { return self.dyn()->traverse_constructor_pattern(           cast::<ConstructorPattern>(p)           ); }
            case PatternKind::UnresolvedConstructorPattern { return self.dyn()->traverse_unresolved_constructor_pattern(cast::<UnresolvedConstructorPattern>(p) ); }
            case PatternKind::AlternationPattern           { return self.dyn()->traverse_alternation_pattern(           cast::<AlternationPattern>(p)           ); }
            case PatternKind::RangePattern                 { return self.dyn()->traverse_range_pattern(                 cast::<RangePattern>(p)                 ); }
            case PatternKind::SlicePattern                 { return self.dyn()->traverse_slice_pattern(                 cast::<SlicePattern>(p)                 ); }
            case PatternKind::RecoveryPattern              { self.dyn()->visit_pattern(p); return p; }
            case PatternKind::PatternKindCount             {  ICE_FAIL("PatternKindCount reached RAV in Stage 1 - this is a bug"); return &null; }
        }
        return p;
    }

    fn visit_pattern(self, n: *Pattern) -> bool { return true; }

    // --- traverse bodies ---------------------------------------------------
    fn traverse_wildcard_pattern(self, n: *WildcardPattern) -> *WildcardPattern {
        self.dyn()->walkup_wildcard_pattern(n);
        return n;
    }

    fn traverse_literal_pattern(self, n: *LiteralPattern) -> *LiteralPattern {
        if self.dyn()->walkup_literal_pattern(n) == false { return n; }
        if n->value != &null { n->value = self.dyn()->dispatch_expr(n->value); }
        return n;
    }

    fn traverse_binding_pattern(self, n: *BindingPattern) -> *BindingPattern {
        if self.dyn()->walkup_binding_pattern(n) == false { return n; }
        // n->name is the bound identifier token skip.
        if n->type_ != &null { n->type_ = self.dyn()->dispatch_type(n->type_); }
        return n;
    }

    fn traverse_tuple_destructure_pattern(self, n: *TupleDestructurePattern) -> *TupleDestructurePattern {
        if self.dyn()->walkup_tuple_destructure_pattern(n) == false { return n; }
        for var i: usize = 0; i < n->elements.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_pattern(*(n->elements.get(i)));  // discard
        }
        return n;
    }

    fn traverse_constructor_pattern(self, n: *ConstructorPattern) -> *ConstructorPattern {
        if self.dyn()->walkup_constructor_pattern(n) == false { return n; }
        if n->head != &null { n->head = self.dyn()->dispatch_expr(n->head); }  // null when dotted
        for var i: usize = 0; i < n->subpatterns.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_pattern(*(n->subpatterns.get(i)));  // discard
        }
        return n;
    }

    fn traverse_unresolved_constructor_pattern(self, n: *UnresolvedConstructorPattern) -> *UnresolvedConstructorPattern {
        if self.dyn()->walkup_unresolved_constructor_pattern(n) == false { return n; }
        if n->head != &null { n->head = self.dyn()->dispatch_expr(n->head); }
        for var i: usize = 0; i < n->subpatterns.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_pattern(*(n->subpatterns.get(i)));  // discard
        }
        return n;
    }

    fn traverse_alternation_pattern(self, n: *AlternationPattern) -> *AlternationPattern {
        if self.dyn()->walkup_alternation_pattern(n) == false { return n; }
        for var i: usize = 0; i < n->alternatives.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_pattern(*(n->alternatives.get(i)));  // discard
        }
        return n;
    }

    fn traverse_range_pattern(self, n: *RangePattern) -> *RangePattern {
        if self.dyn()->walkup_range_pattern(n) == false { return n; }
        if n->lo != &null { n->lo = self.dyn()->dispatch_expr(n->lo); }
        if n->hi != &null { n->hi = self.dyn()->dispatch_expr(n->hi); }
        return n;
    }

    fn traverse_slice_pattern(self, n: *SlicePattern) -> *SlicePattern {
        if self.dyn()->walkup_slice_pattern(n) == false { return n; }
        for var i: usize = 0; i < n->prefix.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_pattern(*(n->prefix.get(i)));  // discard
        }
        for var i: usize = 0; i < n->suffix.size(); i++ {
            if self.stop { break; }
            self.dyn()->dispatch_pattern(*(n->suffix.get(i)));  // discard
        }
        if self.stop { return n; }
        if n->rest_binding != &null { n->rest_binding = self.dyn()->dispatch_pattern(n->rest_binding); }
        return n;
    }

    // --- walkup ------------------------------------------------------------
    fn walkup_wildcard_pattern(self, n: *WildcardPattern) -> bool {
        if self.dyn()->visit_pattern(n) == false { return false; }
        return self.dyn()->visit_wildcard_pattern(n);
    }

    fn walkup_literal_pattern(self, n: *LiteralPattern) -> bool {
        if self.dyn()->visit_pattern(n) == false { return false; }
        return self.dyn()->visit_literal_pattern(n);
    }

    fn walkup_binding_pattern(self, n: *BindingPattern) -> bool {
        if self.dyn()->visit_pattern(n) == false { return false; }
        return self.dyn()->visit_binding_pattern(n);
    }

    fn walkup_tuple_destructure_pattern(self, n: *TupleDestructurePattern) -> bool {
        if self.dyn()->visit_pattern(n) == false { return false; }
        return self.dyn()->visit_tuple_destructure_pattern(n);
    }

    fn walkup_constructor_pattern(self, n: *ConstructorPattern) -> bool {
        if self.dyn()->visit_pattern(n) == false { return false; }
        return self.dyn()->visit_constructor_pattern(n);
    }

    fn walkup_unresolved_constructor_pattern(self, n: *UnresolvedConstructorPattern) -> bool {
        if self.dyn()->visit_pattern(n) == false { return false; }
        return self.dyn()->visit_unresolved_constructor_pattern(n);
    }

    fn walkup_alternation_pattern(self, n: *AlternationPattern) -> bool {
        if self.dyn()->visit_pattern(n) == false { return false; }
        return self.dyn()->visit_alternation_pattern(n);
    }

    fn walkup_range_pattern(self, n: *RangePattern) -> bool {
        if self.dyn()->visit_pattern(n) == false { return false; }
        return self.dyn()->visit_range_pattern(n);
    }

    fn walkup_slice_pattern(self, n: *SlicePattern) -> bool {
        if self.dyn()->visit_pattern(n) == false { return false; }
        return self.dyn()->visit_slice_pattern(n);
    }

    // --- leaf visit hooks --------------------------------------------------
    fn visit_wildcard_pattern(              self, n: *WildcardPattern              ) -> bool { return true; }
    fn visit_literal_pattern(               self, n: *LiteralPattern               ) -> bool { return true; }
    fn visit_binding_pattern(               self, n: *BindingPattern               ) -> bool { return true; }
    fn visit_tuple_destructure_pattern(     self, n: *TupleDestructurePattern      ) -> bool { return true; }
    fn visit_constructor_pattern(           self, n: *ConstructorPattern           ) -> bool { return true; }
    fn visit_unresolved_constructor_pattern(self, n: *UnresolvedConstructorPattern ) -> bool { return true; }
    fn visit_alternation_pattern(           self, n: *AlternationPattern           ) -> bool { return true; }
    fn visit_range_pattern(                 self, n: *RangePattern                 ) -> bool { return true; }
    fn visit_slice_pattern(                 self, n: *SlicePattern                 ) -> bool { return true; }
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
///          not replace them. Do not delete losing it reopens the
///          compile-clean-but-wrong gap that the dispatch_decln bug slipped
///          through.
///
/// \note `_: bool` exists only because Stage 0's hand-written parser cannot
///       parse an empty class body `{}`. The field is unused; it is filler to
///       keep the braces non-empty. Remove once Stage 1 is self-hosting.
///
class RAVProbe derives RecursiveASTVisitor::<RAVProbe> {
    pub var _: bool;
}