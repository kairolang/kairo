/// --- The Kairo Project --------------------- Sema/RequiresDesugar.k --- ///
///
///   \brief Desugar inline generic bounds into the `requires` clause.
///
///   \detail
///     Surface normalization. Every `<T impl Foo>` / `<T derives Base>` inline
///     bound is hoisted into the owning decl's `requires` clause as a
///     ConstraintExpr conjunct, and the inline `impl_bounds` / `derives_bounds`
///     lists are cleared. After this pass the SINGLE source of truth for a
///     decl's constraints is `requires_clause`; the inline lists are empty.
///
///     Pure AST -> AST rewrite: no name resolution, no types, no bound table.
///     It only relocates syntax into canonical position so ConstraintExtraction
///     can partition the clause from one place.
///
///     Equivalence realized here (from the spec):
///         fn <T impl Serializable> save(d: T) { ... }
///       == fn <T> save(d: T) requires T impl Serializable { ... }
///
///     The kind bound (`: class/struct/...`) is NOT hoisted: it is a property
///     of the parameter slot, not a conjoinable constraint, so it stays on the
///     GenericParamDecl.
///
///     This walker mutates in place (no node identities change), so it drives
///     its own traversal over the TU's top-level items and recurses into nested
///     type bodies via DeclContext. It intentionally does not subclass
///     ASTWriter/RAV: the edit is a field mutation, not a structural rewrite.
///
///   Phase: EXPAND (surface normalization; runs before N/T and before
///          ConstraintExtraction, which consumes the canonical requires clause)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Types::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import Token::Token::*;
import Token::TokenKind::*;

class RequiresDesugar {
    pub var ctx: *ASTContext;

    fn RequiresDesugar(self, ctx: *ASTContext) {
        self.ctx = ctx;
    }

    /// Drive over the whole TU: every top-level decl, recursing into nested
    /// type bodies.
    fn run(self, tu: *TranslationUnit) {
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

        // Hoist bounds on whichever generic-param-carrying decl this is, and
        // recurse into the DeclContext members for context-bearing kinds.
        switch d->kind {
            case DeclKind::FunctionDecl {
                var n = cast::<FunctionDecl>(d);
                self._hoist_bounds(&(n->generic_params), &(n->requires_clause));
                self._recurse_members(static_cast::<*DeclContext>(n));
            }
            case DeclKind::StructDecl {
                var n = cast::<StructDecl>(d);
                self._hoist_bounds(&(n->generic_params), &(n->requires_clause));
                self._recurse_members(static_cast::<*DeclContext>(n));
            }
            case DeclKind::ClassDecl {
                var n = cast::<ClassDecl>(d);
                self._hoist_bounds(&(n->generic_params), &(n->requires_clause));
                self._recurse_members(static_cast::<*DeclContext>(n));
            }
            case DeclKind::InterfaceDecl {
                var n = cast::<InterfaceDecl>(d);
                self._hoist_bounds(&(n->generic_params), &(n->requires_clause));
                self._recurse_members(static_cast::<*DeclContext>(n));
            }
            case DeclKind::EnumDecl {
                var n = cast::<EnumDecl>(d);
                self._hoist_bounds(&(n->generic_params), &(n->requires_clause));
                self._recurse_members(static_cast::<*DeclContext>(n));
            }
            case DeclKind::UnionDecl {
                var n = cast::<UnionDecl>(d);
                self._hoist_bounds(&(n->generic_params), &(n->requires_clause));
                self._recurse_members(static_cast::<*DeclContext>(n));
            }
            case DeclKind::ExtensionDecl {
                var n = cast::<ExtensionDecl>(d);
                self._hoist_bounds(&(n->generic_params), &(n->requires_clause));
                self._recurse_members(static_cast::<*DeclContext>(n));
            }
            case DeclKind::TypeAliasDecl {
                // Alias bounds are meaningless (no body); still normalized so
                // the inline lists are uniformly empty. ConstraintExtraction
                // owns the diagnostic. Aliases carry no DeclContext members.
                var n = cast::<TypeAliasDecl>(d);
                self._hoist_bounds(&(n->generic_params), &(n->requires_clause));
            }
            default { }
        }
    }

    /// Recurse into a DeclContext's owned members (nested types, methods).
    priv fn _recurse_members(self, dc: *DeclContext) {
        if dc == &null { return; }
        for var i: usize = 0; i < dc->dc_decls.size(); i++ {
            self._visit_decl(*(dc->dc_decls.get(i)));
        }
    }

    /// Move every param's impl/derives edges into *req_slot as ConstraintExpr
    /// conjuncts, then clear the inline lists. Conjunction order: existing
    /// requires, then per param derives, then impl.
    priv fn _hoist_bounds(
        self,
        params:   *FrozenList::<*GenericParamDecl>,
        req_slot: *(*Expr)
    ) {
        if params->is_empty() { return; }
        var acc: *Expr = *req_slot;   // existing requires (may be null)

        for var pi: usize = 0; pi < params->size(); pi++ {
            var gp = *(params->get(pi));
            if gp == &null { continue; }

            for var i: usize = 0; i < gp->derives_bounds.size(); i++ {
                var e = gp->derives_bounds.get(i);
                if e->base == &null { continue; }
                acc = self._conjoin(acc, self._make_constraint(gp, e->base, TokenKind::KwDerives));
            }
            for var i: usize = 0; i < gp->impl_bounds.size(); i++ {
                var e = gp->impl_bounds.get(i);
                if e->base == &null { continue; }
                acc = self._conjoin(acc, self._make_constraint(gp, e->base, TokenKind::KwImpl));
            }

            gp->impl_bounds    = FrozenList::<InheritEdge>{};
            gp->derives_bounds = FrozenList::<InheritEdge>{};
        }

        (*req_slot) = acc;
    }

    /// Build `<param> impl/derives <base>` as a ConstraintExpr, reusing the
    /// param's own name token for the LHS so ranges point at real source.
    priv fn _make_constraint(
        self,
        gp:   *GenericParamDecl,
        base: *Type,
        opr:   TokenKind
    ) -> *Expr {
        var lhs = NamedIdentExpr::create(self.ctx, gp->name.range, gp->name);
        var op_tok = Token(gp->name.range, opr);
        return static_cast::<*Expr>(ConstraintExpr::create(
            self.ctx,
            gp->name.range | base->range,
            static_cast::<*Expr>(lhs),
            base,
            op_tok
        ));
    }

    /// lhs && rhs, dropping a null lhs (first-conjunct case).
    priv fn _conjoin(self, lhs: *Expr, rhs: *Expr) -> *Expr {
        if lhs == &null { return rhs; }
        var and_tok = Token(lhs->range | rhs->range, TokenKind::OpAmpAmp);
        return static_cast::<*Expr>(BinaryOperatorExpr::create(
            self.ctx,
            lhs->range | rhs->range,
            lhs, rhs, and_tok
        ));
    }
}
