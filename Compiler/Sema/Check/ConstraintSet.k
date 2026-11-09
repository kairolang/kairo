/// --- The Kairo Project ------------------- Sema/Check/ConstraintSet.k --- ///
///
///   \brief The partitioned constraints of one decl, and nothing else.
///
///   \detail
///     A leaf on purpose. ConstraintExtraction BUILDS these; SemaContext
///     HOLDS them (the bound table, keyed by owner decl); ChainBinding,
///     ConformanceChecking and monomorphization READ them. SemaContext cannot
///     import a pass and a pass cannot import the driver, so the shared datum
///     lives in a file that imports only AST -- the same rule that put
///     ResolutionTrace where it is.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::Node::Base::{
    Decl,
    Expr,
}
import AST::Node::Expressions::ConstraintExpr

///
/// \class ConstraintSet
/// \brief The partitioned constraints of one decl. Built by
///        ConstraintExtraction; read by the bound table, definition-side
///        checking, call-site conformance, and monomorphization.
///
///   impl_constraints    : structural interface bounds  (T impl Foo)
///   derives_constraints : nominal base/lineage bounds   (T derives Base)
///   value_predicates    : compile-time gates            (sizeof T > 10, ...)
///
/// Each ConstraintExpr pointer aliases the node in the requires clause; this
/// set is an index, not a copy. The owning decl is recorded so downstream
/// passes can key back to it.
///
pub class ConstraintSet {
    pub var owner:               unsafe *Decl                             = &null
    pub var impl_constraints:    cxx::std::vector<unsafe *ConstraintExpr>
    pub var derives_constraints: cxx::std::vector<unsafe *ConstraintExpr>
    pub var value_predicates:    cxx::std::vector<unsafe *Expr>

    /// Default ctor: the bound table's map needs one to materialize a slot.
    fn ConstraintSet(self) { }

    fn ConstraintSet(self, owner: unsafe *Decl) {
        self.owner = owner
    }

    fn is_empty(self) -> bool {
        return self.impl_constraints.size() == 0
            && self.derives_constraints.size() == 0
            && self.value_predicates.size() == 0
    }

    fn has_conformance(self) -> bool {
        return self.impl_constraints.size() > 0 || self.derives_constraints.size() > 0
    }
}
