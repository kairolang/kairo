/// --- The Kairo Project ----------------------- Sema/Check/InitCheck.k --- ///
///
///   \brief Check initializer forms against the type being initialized.
///
///   \detail
///     Covers named initializers, AnonInitializerExpr, aggregate init,
///     and default member initializers. Verifies every field is
///     initialized exactly once, that field names exist, and selects the
///     @copy or @move constructor for each element. Missing-field
///     diagnostics name the fields, not the count.
///
///     Checked so far: a default member initializer reads only fields
///     declared before it. A default keeps the type body's scope, so it may
///     name a sibling bare, and it runs as a C++ default member initializer
///     (FieldInitLowering), in declaration order: a field declared at or
///     after the one being initialized is not built yet when it is read.
///     A static field is no part of an object and is never refused.
///
///     One read that is allowed is not compiled yet: an earlier sibling read
///     in a GENERIC record's default. The thunk's body names it qualified,
///     and CXXSpell spells that name without the record's template
///     arguments, so clang rejects it. It is reported here as SC116E, since
///     this is the walk that finds it; FeatureGateCheck lists it.
///
///   Phase: CHECKS
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import AST::Context::TranslationUnit::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Statements::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

/// The sibling fields one default reads, each refused if it is not built
/// yet (InitCheck's header).
class FieldReadScan derives RecursiveASTVisitor::<FieldReadScan> {
    pub var sc: *SemaContext;
    priv var _field: *FieldDecl;

    fn FieldReadScan(self, sc: *SemaContext, field: *FieldDecl) {
        self.sc     = sc;
        self._field = field;
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if (n->resolved_decl == &null) || (!isa::<FieldDecl>(n->resolved_decl)) { return true; }
        var read = cast::<FieldDecl>(n->resolved_decl);
        if read->is_static() || (read->semantic_dc != self._field->semantic_dc) { return true; }
        if read->index < self._field->index {
            var odc   = reinterpret_cast::<*DeclContext>(self._field->semantic_dc);
            var owner = (odc->owner_decl()) if (odc != &null) else (&null);
            if (owner == &null) || (decl_generic_params(owner).size() == 0) { return true; }
            var b = self.sc->diag->report(DiagID::SC116E, n->range.start,
                "reading another field in the default of a generic record's field is not yet supported");
            b.first(n->range);
            b.emit();
            return true;
        }

        var tu    = TypeUtil(self.sc);
        var mine  = tu.decl_name(static_cast::<*Decl>(self._field));
        var other = tu.decl_name(static_cast::<*Decl>(read));
        if read == self._field {
            var b = self.sc->diag->report(DiagID::SC001E, n->range.start,
                f"the default of '{mine}' reads '{mine}' itself, which it is still building");
            b.first(n->range);
            b.emit();
            return true;
        }
        var b = self.sc->diag->report(DiagID::SC001E, n->range.start,
            f"the default of '{mine}' reads '{other}', which is declared after it");
        b.first(n->range);
        b.note(read->range.start,
            f"'{other}' is declared here; defaults run in declaration order, so it is not built yet when '{mine}' is"
        ).first(read->range);
        b.emit();
        return true;
    }
}

class InitCheck derives RecursiveASTVisitor::<InitCheck> {
    pub var sc: *SemaContext;

    fn InitCheck(self, sc: *SemaContext) {
        self.sc = sc;
    }

    fn run(self) {
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl { self.dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dispatch_expr(item.as_expr()); }
                default { 0; }
            }
        }
    }

    /// Once per field: an instance shares its pattern's fields.
    fn visit_field_decl(self, n: *FieldDecl) -> bool {
        if (n->init == &null) || n->is_poisoned() || n->init->is_poisoned() { return true; }
        if n->is_static() { return true; }
        var odc   = reinterpret_cast::<*DeclContext>(n->semantic_dc);
        var owner = (odc->owner_decl()) if (odc != &null) else (&null);
        if (owner != &null) && decl_is_instance(owner) { return true; }
        var scan = FieldReadScan(self.sc, n);
        scan.dispatch_expr(n->init);
        return true;
    }
}
