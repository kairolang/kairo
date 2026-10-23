/// --- The Kairo Project --------------------- Sema/Check/FeatureGateCheck.k --- ///
///
///   \brief Reports constructs that type-check but have no lowering yet,
///          as one error each: "<construct> is not yet supported" (SC116E).
///
///   \detail
///     A lowering pass has no diagnostics of its own: by the time it runs,
///     every rejection has been made, and what it cannot render it ICEs on.
///     That is right for an invariant and wrong for a feature that is
///     simply unfinished, because lowering also runs under
///     --type-check-only and a well-typed program then aborts the compiler.
///     This pass is where "unfinished" is said to the user. An error here
///     stops the schedule before the lowerings, so the ICE in the lowering
///     stays an invariant: reaching it means this gate has a hole.
///
///     Gated:
///       - `for x in e` where X classified `e` as Vector, Set, Map or
///         String (RangedForStmt::iter_kind). IterLowering renders the
///         other kinds.
///       - `label!` / `jump!` in user code: EmitIR renders them (they are the
///         lowerings' labels and gotos), but nothing yet proves a user jump
///         crosses no initialization, which C++ rejects and Kairo must
///         report first.
///       - a non-generic ADT enum one of whose lifecycle facts is Unknown (a
///         payload that is an instance of a generic record reads its
///         pattern's facts until they are computed per instance):
///         EnumLayoutLowering picks its special members from those facts.
///         Reported at the enum, with a note at the payload field that left
///         the fact open.
///       - an initializer on an eval or array-typed field.
///         FieldInitLowering turns every other one into a C++ default member
///         initializer (or, for a static, the initializer of its out-of-line
///         definition); an eval field has no constant emission yet, and a C++
///         function cannot return an array, so these keep theirs and codegen
///         would ICE on them.
///       - a generic record's field default that reads another field.
///         InitCheck reports it (SC116E too): it is the pass that walks what
///         a default reads.
///       - `var {a, b} = s`, destructuring a struct by field name.
///         TupleLowering renders the positional form only; a struct's
///         reaching EmitIR is its ICE.
///
///     Reads the same guard IterLowering does: a poisoned or untyped
///     iterable is already diagnosed or dependent, and is not reported.
///
///     A gate is removed in the commit that lands its lowering.
///
///   Phase: CHECKS (last; needs X's iter_kind)
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
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import Sema::Check::ClassLifecycle::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Statements::*;
import AST::Node::Expressions::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Node::CanonicalNodes::*;
import AST::Kind::StmtKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

class FeatureGateCheck derives RecursiveASTVisitor::<FeatureGateCheck> {
    pub var sc: *SemaContext;

    fn FeatureGateCheck(self, sc: *SemaContext) {
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

    fn visit_ranged_for_stmt(self, n: *RangedForStmt) -> bool {
        if n->iterable == &null { return true; }
        if n->iterable->is_poisoned() || (n->iterable->type_ == &null) { return true; }

        var what = "";
        switch n->iter_kind {
            case IterKind::Vector { what = "iterating a vector"; }
            case IterKind::Set    { what = "iterating a set"; }
            case IterKind::Map    { what = "iterating a map"; }
            case IterKind::String { what = "iterating a string"; }
            default               { return true; }
        }

        var b = self.sc->diag->report(DiagID::SC116E, n->iterable->range.start,
            f"{what} is not yet supported");
        b.first(n->iterable->range);
        b.emit();
        return true;
    }

    fn visit_destructuring_decl_stmt(self, n: *DestructuringDeclStmt) -> bool {
        if n->kind_ == DestructureKind::Struct { self._gate(n->range, "destructuring a struct by field name"); }
        return true;
    }

    fn visit_label_intrinsic_stmt(self, n: *LabelIntrinsicStmt) -> bool {
        self._gate(n->range, "'label!\x27");
        return true;
    }

    fn visit_jump_intrinsic_stmt(self, n: *JumpIntrinsicStmt) -> bool {
        self._gate(n->range, "'jump!\x27");
        return true;
    }

    /// A non-generic ADT has no flags for clang to pick its special members
    /// by: EnumLayoutLowering picks one form of each from its lifecycle
    /// facts, and ICEs when one of them is Unknown. A generic ADT leaves the
    /// choice to clang and is never reported. Asked once per entity, as the
    /// lowering builds once: an instance shares its pattern's record, and a
    /// redeclaration is its representative's.
    fn visit_enum_decl(self, n: *EnumDecl) -> bool {
        if (!n->is_adt) || n->is_poisoned() || (n->generic_params.size() > 0) { return true; }
        var d = static_cast::<*Decl>(n);
        if decl_is_instance(d) || (NameLookup::representative(d) != d) { return true; }
        var lc = lifecycle_of(self.sc);
        if !lifecycle_open(lc->facts_of(d)) { return true; }

        var b = self.sc->diag->report(DiagID::SC116E, n->name.range.start,
            "an enum whose payload's lifecycle is not known until instantiation is not yet supported");
        b.first(n->name.range);
        // The first payload field whose own facts are open: the generic
        // instance the enum's copy, move and destruction wait on.
        var tu = TypeUtil(self.sc);
        var noted = false;
        for var i: usize = 0; i < n->variants.size(); ++i {
            if noted { break; }
            var v = n->variants[i];
            if v == &null { continue; }
            for var j: usize = 0; j < v->payload.size(); ++j {
                var fd = v->payload[j];
                if (fd == &null) || (fd->type_ == &null) || (fd->type_->canonical == &null) { continue; }
                var pf = lc->facts_of_type(fd->type_->canonical);
                if !lifecycle_open(&pf) { continue; }
                var fname = self.sc->ctx->get_spelling(fd->name);
                var vname = self.sc->ctx->get_spelling(v->name);
                var tn    = tu.str(fd->type_->canonical);
                b.note(DiagID::SC116N, fd->range.start,
                    f"'{fname}' of variant '{vname}' has type '{tn}', whose copy, move and destruction are not known until instantiation"
                ).first(fd->range);
                noted = true;
                break;
            }
        }
        b.emit();
        return true;
    }

    /// The initializers FieldInitLowering leaves on the field (its file
    /// header, Not lowered). Reported at the initializer, once: an instance
    /// shares its pattern's fields.
    fn visit_field_decl(self, n: *FieldDecl) -> bool {
        if (n->init == &null) || n->is_poisoned() || n->init->is_poisoned() || (n->type_ == &null) { return true; }
        var odc   = reinterpret_cast::<*DeclContext>(n->semantic_dc);
        var owner = (odc->owner_decl()) if (odc != &null) else (&null);
        if (owner != &null) && decl_is_instance(owner) { return true; }
        var what = "";
        // Array first: a static array keeps its initializer too (no thunk
        // can return one), so `static` alone does not clear the gate.
        var c = canon_unqual(n->type_->canonical);
        if n->storage == StorageClass::Eval {
            what = "an eval field";
        } else if (c != &null) && (c->kind == TypeKind::FixedArrayType) {
            what = "an array-typed field";
        } else {
            return true;
        }
        self._gate(n->init->range, f"an initializer on {what}");
        return true;
    }

    priv fn _gate(self, at: SourceRange, what: string) {
        var b = self.sc->diag->report(DiagID::SC116E, at.start, f"{what} is not yet supported");
        b.first(at);
        b.emit();
    }
}
