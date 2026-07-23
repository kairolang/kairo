/// --- The Kairo Project ------------------ Sema/ConstraintExtraction.k --- ///
///
///   \brief Partition a canonical `requires` clause into conformance
///          constraints vs value predicates.
///
///   \detail
///     Runs AFTER RequiresDesugar, so every decl's constraints live in one
///     place: `requires_clause`, a right-nested `&&` conjunction (plus, for
///     functions, an optional `where_clause` which is a separate runtime
///     concern and is NOT touched here).
///
///     For each generic-param-carrying decl this pass walks the requires
///     conjunction and sorts each leaf conjunct:
///
///       - ConstraintExpr (T impl Foo / T derives Base)
///             -> a CONFORMANCE constraint. Feeds the bound table; checked at
///                the decl's definition (definition-side checking) and at each
///                call site (call-site conformance). `impl` = structural,
///                `derives` = nominal (carries vtable/lineage).
///       - anything else (sizeof T > 10, is_power_of_two(N), ...)
///             -> a VALUE PREDICATE. A compile-time gate checked at
///                instantiation, never a resolution input.
///
///     The result is a ConstraintSet per decl. Definition-side checking,
///     the bound table, and monomorphization read the ConstraintSet; they do
///     NOT re-walk the requires expr. One classification, one home.
///
///     This pass does NOT resolve names or types (that is N/T's job, already
///     done by this phase) it only structurally sorts the already-parsed
///     conjuncts by node kind. Classification is therefore total and
///     decidable: is-a-ConstraintExpr or is-not.
///
///     Diagnostics owned here:
///       - a conformance constraint on a TypeAliasDecl: meaningless, an alias
///         has no body to defer resolution into.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import Sema::SemaContext::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Expressions::*;
import AST::Node::Types::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::ExprKind::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

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
class ConstraintSet {
    pub var owner:               *Decl = &null;
    pub var impl_constraints:    vec::<*ConstraintExpr>;
    pub var derives_constraints: vec::<*ConstraintExpr>;
    pub var value_predicates:    vec::<*Expr>;

    fn ConstraintSet(self, owner: *Decl) {
        self.owner = owner;
    }

    fn is_empty(self) -> bool {
        return self.impl_constraints.size() == 0
            && self.derives_constraints.size() == 0
            && self.value_predicates.size() == 0;
    }

    fn has_conformance(self) -> bool {
        return self.impl_constraints.size() > 0
            || self.derives_constraints.size() > 0;
    }
}

class ConstraintExtraction {
    pub var sc: *SemaContext;

    /// Collected sets, one per decl that had a non-empty requires clause
    pub var sets: vec::<ConstraintSet>;

    fn ConstraintExtraction(self, sc: *SemaContext) {
        self.sc = sc;
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            if item.kind == TopLevelKind::Decl {
                self._visit_decl(item.as_decl());
            }
        }
    }

    priv fn _visit_decl(self, d: *Decl) {
        if d == &null { return; }

        switch d->kind {
            case DeclKind::FunctionDecl {
                var n = cast::<FunctionDecl>(d);
                self._extract(d, n->requires_clause, false);
                self._recurse_members(static_cast::<*DeclContext>(n));
            } case DeclKind::StructDecl {
                var n = cast::<StructDecl>(d);
                self._extract(d, n->requires_clause, false);
                self._recurse_members(static_cast::<*DeclContext>(n));
            } case DeclKind::ClassDecl {
                var n = cast::<ClassDecl>(d);
                self._extract(d, n->requires_clause, false);
                self._recurse_members(static_cast::<*DeclContext>(n));
            } case DeclKind::InterfaceDecl {
                var n = cast::<InterfaceDecl>(d);
                self._extract(d, n->requires_clause, false);
                self._recurse_members(static_cast::<*DeclContext>(n));
            } case DeclKind::EnumDecl {
                var n = cast::<EnumDecl>(d);
                self._extract(d, n->requires_clause, false);
                self._recurse_members(static_cast::<*DeclContext>(n));
            } case DeclKind::UnionDecl {
                var n = cast::<UnionDecl>(d);
                self._extract(d, n->requires_clause, false);
                self._recurse_members(static_cast::<*DeclContext>(n));
            } case DeclKind::ExtensionDecl {
                var n = cast::<ExtensionDecl>(d);
                self._extract(d, n->requires_clause, false);
                self._recurse_members(static_cast::<*DeclContext>(n));
            } case DeclKind::TypeAliasDecl {
                // is_alias=true: a conformance constraint here meaningless
                var n = cast::<TypeAliasDecl>(d);
                self._extract(d, n->requires_clause, true);
            } default {
                break; // nothing to do
            }
        }
    }

    priv fn _recurse_members(self, dc: *DeclContext) {
        if dc == &null { return; }
        for var i: usize = 0; i < dc->dc_decls.size(); i++ {
            self._visit_decl(*(dc->dc_decls.get(i)));
        }
    }

    /// Partition a requires clause into a ConstraintSet, recording it if it
    /// carried anything. \p is_alias gates the meaningless-conformance error.
    priv fn _extract(self, owner: *Decl, req: *Expr, is_alias: bool) {
        if req == &null { return; }

        var set = ConstraintSet(owner);
        self._collect(req, &set, is_alias);

        if !set.is_empty() {
            self.sets.push_back(set);
        }
    }

    /// Flatten the right-nested `&&` conjunction, sorting each leaf. Any binary
    /// `&&` is split; anything else is a leaf conjunct classified by kind.
    priv fn _collect(self, e: *Expr, set: *ConstraintSet, is_alias: bool) {
        if e == &null { return; }

        // split `a && b` (and `and`) into its operands
        if e->kind == ExprKind::BinaryOperatorExpr {
            var b = cast::<BinaryOperatorExpr>(e);
            if (b->op_token.kind == TokenKind::OpAmpAmp)
            || (b->op_token.kind == TokenKind::KwAnd) {
                self._collect(b->lhs, set, is_alias);
                self._collect(b->rhs, set, is_alias);
                return;
            }
        }

        // leaf: conformance constraint or value predicate
        if e->kind == ExprKind::ConstraintExpr {
            var c = cast::<ConstraintExpr>(e);
            if is_alias {
                self.sc->diag->report(DiagID::SC001, e->range.start,
                    "a conformance constraint is meaningless on a type alias; "
                    "an alias has no body to resolve members against. Move the "
                    "constraint to the aliased type or a using function"
                ).first(e->range).emit();
                return; // do not record; it's an error
            }
            if c->is_derives() {
                set->derives_constraints.push_back(c);
            } else {
                set->impl_constraints.push_back(c);
            }
            return;
        }

        // everything else is a compile-time value predicate
        set->value_predicates.push_back(e);
    }
}
