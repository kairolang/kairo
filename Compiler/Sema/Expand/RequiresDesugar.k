/// --- The Kairo Project ---------------- Sema/Expand/RequiresDesugar.k --- ///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import AST::ASTSupport::FrozenList
import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContext
import AST::Context::TranslationUnit::TranslationUnit
import AST::Kind::DeclKind::DeclKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::Casting::cast
import AST::Node::Declarations::{
    ClassDecl,     EnumDecl,   ExtensionDecl, FunctionDecl, GenericParamDecl, InheritEdge,
    InterfaceDecl, StructDecl, TypeAliasDecl, UnionDecl,
}
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    ConstraintExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Program::TopLevelKind
import Token::Token::Token
import Token::TokenKind::TokenKind

pub class RequiresDesugar {
    pub var ctx: unsafe *ASTContext

    fn RequiresDesugar(self, ctx: unsafe *ASTContext) {
        self.ctx = ctx
    }

    /// Drive over the whole TU: every top-level decl, recursing into nested
    /// type bodies.
    fn run(self, tu: unsafe *TranslationUnit) {
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            if item.kind == TopLevelKind::Decl {
                self._visit_decl(item.as_decl())
            }
        }
    }

    priv fn _visit_decl(self, d: unsafe *Decl) {
        if d == &null {
            return
        }

        // Hoist bounds on whichever generic-param-carrying decl this is, and
        // recurse into the DeclContext members for context-bearing kinds.
        match d->kind {
            case DeclKind::FunctionDecl {
                var unsafe *n = cast<FunctionDecl>(d)
                self._hoist_bounds(&n->generic_params, unsafe &n->requires_clause)
                self._recurse_members(n)
            } case DeclKind::StructDecl {
                var unsafe *n = cast<StructDecl>(d)
                self._hoist_bounds(&n->generic_params, unsafe &n->requires_clause)
                self._recurse_members(n)
                self._recurse_methods(&n->methods)
            } case DeclKind::ClassDecl {
                var unsafe *n = cast<ClassDecl>(d)
                self._hoist_bounds(&n->generic_params, unsafe &n->requires_clause)
                self._recurse_members(n)
                self._recurse_methods(&n->methods)
            } case DeclKind::InterfaceDecl {
                var unsafe *n = cast<InterfaceDecl>(d)
                self._hoist_bounds(&n->generic_params, unsafe &n->requires_clause)
                self._recurse_members(n)
                self._recurse_methods(&n->methods)
            } case DeclKind::EnumDecl {
                var unsafe *n = cast<EnumDecl>(d)
                self._hoist_bounds(&n->generic_params, unsafe &n->requires_clause)
                self._recurse_members(n)
            } case DeclKind::UnionDecl {
                var unsafe *n = cast<UnionDecl>(d)
                self._hoist_bounds(&n->generic_params, unsafe &n->requires_clause)
                self._recurse_members(n)
                self._recurse_methods(&n->methods)
            } case DeclKind::ExtensionDecl {
                var unsafe *n = cast<ExtensionDecl>(d)
                self._hoist_bounds(&n->generic_params, unsafe &n->requires_clause)
                self._recurse_members(n)
                self._recurse_methods(&n->methods)
            } case DeclKind::TypeAliasDecl {
                // Alias bounds are meaningless (no body); still normalized so
                // the inline lists are uniformly empty. ConstraintExtraction
                // owns the diagnostic. Aliases carry no DeclContext members.
                var unsafe *n = cast<TypeAliasDecl>(d)
                self._hoist_bounds(&n->generic_params, unsafe &n->requires_clause)
            } default { }
        }
    }

    /// Recurse into a DeclContext's owned decls (nested types only for a type body).
    /// Recurse into a type body's methods. A type body's dc_decls holds only
    /// nested types and visibility-group wrappers; its methods live in the
    /// flat `methods` list (grouped ones included), so they are walked here.
    priv fn _recurse_methods(self, ms: *FrozenList<unsafe *FunctionDecl>) {
        for var i: usize = 0; i < ms->size(); i++ {
            self._visit_decl(*ms->get(i))
        }
    }

    priv fn _recurse_members(self, dc: unsafe *DeclContext) {
        if dc == &null {
            return
        }

        for var i: usize = 0; i < dc->dc_decls.size(); i++ {
            self._visit_decl(*dc->dc_decls.get(i))
        }
    }

    /// Move every param's impl/derives edges into *req_slot as ConstraintExpr
    /// conjuncts, then clear the inline lists. Conjunction order: existing
    /// requires, then per param derives, then impl.
    priv fn _hoist_bounds(self,
                          params:   *FrozenList<unsafe *GenericParamDecl>,
                          req_slot: unsafe *(unsafe *Expr)) {
        if params->is_empty() {
            return
        }

        var acc: unsafe *Expr = *req_slot // existing requires (may be null)

        for var pi: usize = 0; pi < params->size(); pi++ {
            var unsafe *gp = *params->get(pi)
            if gp == &null {
                continue
            }

            for var i: usize = 0; i < gp->derives_bounds.size(); i++ {
                var unsafe *e = gp->derives_bounds.get(i)
                if e->base == &null {
                    continue
                }

                acc = self._conjoin(acc, self._make_constraint(gp, e->base, TokenKind::KwDerives))
            }

            for var i: usize = 0; i < gp->impl_bounds.size(); i++ {
                var unsafe *e = gp->impl_bounds.get(i)
                if e->base == &null {
                    continue
                }

                acc = self._conjoin(acc, self._make_constraint(gp, e->base, TokenKind::KwImpl))
            }

            gp->impl_bounds    = FrozenList<InheritEdge>{}
            gp->derives_bounds = FrozenList<InheritEdge>{}
        }

        *req_slot = acc
    }

    /// Build `<param> impl/derives <base>` as a ConstraintExpr, reusing the
    /// param's own name token for the LHS so ranges point at real source.
    priv fn _make_constraint(self,
                             gp:   unsafe *GenericParamDecl,
                             base: unsafe *Type,
                             opr:  TokenKind) -> unsafe *Expr {
        var unsafe *lhs   = NamedIdentExpr::create(self.ctx, gp->name.range, gp->name)
        var        op_tok = Token(gp->name.range, opr)
        return (unsafe (ConstraintExpr::create(
            self.ctx,
            gp->name.range | base->range,
            lhs,
            base,
            op_tok
        ) as unsafe *Expr))
    }

    /// lhs && rhs, dropping a null lhs (first-conjunct case).
    priv fn _conjoin(self, lhs: unsafe *Expr, rhs: unsafe *Expr) -> unsafe *Expr {
        if lhs == &null {
            return rhs
        }

        var and_tok = Token(lhs->range | rhs->range, TokenKind::OpAmpAmp)
        return ((BinaryOperatorExpr::create(self.ctx, lhs->range | rhs->range, lhs, rhs, and_tok)))
    }
}
