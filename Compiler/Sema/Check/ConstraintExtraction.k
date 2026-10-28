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
///     The result is a ConstraintSet per decl, recorded in SemaContext's bound
///     table under the OWNER decl. Definition-side checking, name binding
///     inside a generic body, and monomorphization read the ConstraintSet;
///     they do NOT re-walk the requires expr. One classification, one home.
///
///   Phase: RESOLVE (T stage, between TypeResolution and ChainBinding --
///          ChainBinding resolves member access through a bound and so reads
///          the table this pass writes).
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
import Sema::Check::ConstraintSet::*;
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

class ConstraintExtraction {
    pub var sc: *SemaContext;

    /// Collected sets, one per decl that had a non-empty requires clause
    pub var sets: vec::<ConstraintSet>;

    fn ConstraintExtraction(self, sc: *SemaContext) {
        self.sc = sc;
    }

    fn run(self) {
        // NamesResolved, not TypesResolved: this pass runs INSIDE the T stage,
        // between TypeResolution and ChainBinding, because ChainBinding reads
        // the bound table it writes. Extraction itself needs no canonicals --
        // it sorts conjuncts by node kind -- and the canonicals its consumers
        // read are already in place by the time TypeResolution returns; only
        // the phase flag has yet to flip.
        self.sc->require_phase(SemaPhase::NamesResolved);
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
                self._recurse_methods(&(n->methods));
            } case DeclKind::ClassDecl {
                var n = cast::<ClassDecl>(d);
                self._extract(d, n->requires_clause, false);
                self._recurse_members(static_cast::<*DeclContext>(n));
                self._recurse_methods(&(n->methods));
            } case DeclKind::InterfaceDecl {
                var n = cast::<InterfaceDecl>(d);
                self._extract(d, n->requires_clause, false);
                self._recurse_members(static_cast::<*DeclContext>(n));
                self._recurse_methods(&(n->methods));
            } case DeclKind::EnumDecl {
                var n = cast::<EnumDecl>(d);
                self._extract(d, n->requires_clause, false);
                self._recurse_members(static_cast::<*DeclContext>(n));
            } case DeclKind::UnionDecl {
                var n = cast::<UnionDecl>(d);
                self._extract(d, n->requires_clause, false);
                self._recurse_members(static_cast::<*DeclContext>(n));
                self._recurse_methods(&(n->methods));
            } case DeclKind::ExtensionDecl {
                var n = cast::<ExtensionDecl>(d);
                self._extract(d, n->requires_clause, false);
                self._recurse_members(static_cast::<*DeclContext>(n));
                self._recurse_methods(&(n->methods));
            } case DeclKind::TypeAliasDecl {
                // is_alias=true: a conformance constraint here meaningless --
                // except on an interface's ASSOCIATED type, whose clause is
                // its bounds (`type N impl X`): the type a conformer supplies
                // must meet them.
                var n = cast::<TypeAliasDecl>(d);
                self._extract(d, n->requires_clause, !n->is_associated);
            } default {
                break; // nothing to do
            }
        }
    }

    /// Recurse into a type body's methods. A type body's dc_decls holds only
    /// nested types and visibility-group wrappers; its methods live in the
    /// flat `methods` list (grouped ones included), so they are walked here.
    priv fn _recurse_methods(self, ms: *FrozenList::<*FunctionDecl>) {
        for var i: usize = 0; i < ms->size(); i++ {
            self._visit_decl(static_cast::<*Decl>(*(ms->get(i))));
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

        var _set = ConstraintSet(owner);
        self._collect(req, &_set, is_alias);

        if !_set.is_empty() {
            self.sets.push_back(_set);
            // THE bound table. Keyed by the owner decl so a body resolving
            // `x.draw()` on an `x: T` can ask what T's declaration promised
            // without re-walking anyone's requires clause.
            self.sc->bounds[reinterpret_cast::<u64>(owner)] = _set;
        }
    }

    /// Flatten the right-nested `&&` conjunction, sorting each leaf. Any binary
    /// `&&` is split; anything else is a leaf conjunct classified by kind.
    priv fn _collect(self, e: *Expr, _set: *ConstraintSet, is_alias: bool) {
        if e == &null { return; }

        // split `a && b` (and `and`) into its operands
        if e->kind == ExprKind::BinaryOperatorExpr {
            var b = cast::<BinaryOperatorExpr>(e);
            if (b->op_token.kind == TokenKind::OpAmpAmp)
            || (b->op_token.kind == TokenKind::KwAnd) {
                self._collect(b->lhs, _set, is_alias);
                self._collect(b->rhs, _set, is_alias);
                return;
            }
        }

        // leaf: conformance constraint or value predicate
        if e->kind == ExprKind::ConstraintExpr {
            var c = cast::<ConstraintExpr>(e);
            if is_alias {
                self.sc->diag->report(DiagID::SC016W, e->range.start,
                    "a conformance constraint is meaningless on a type alias; "
                    "an alias has no body to resolve members against. Move the "
                    "constraint to the aliased type or a using function"
                ).first(e->range).emit();
                return; // do not record; it's an error
            }
            if c->is_derives() {
                _set->derives_constraints.push_back(c);
            } else {
                _set->impl_constraints.push_back(c);
            }
            return;
        }

        // everything else is a compile-time value predicate
        _set->value_predicates.push_back(e);
    }
}
