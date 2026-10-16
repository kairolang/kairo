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
///     A brace initializer (`Foo{...}`, `{...}` against a target) builds an
///     aggregate field by field, which a class that declares a constructor
///     is not: the constructor is the only way to build one, and EmitIR has
///     no lowering from the braces to it. SC088E.
///
///     A `var x: T` with no initializer is default-constructed, so T must
///     have a default: a number or a pointer (0, null), a record with a
///     usable constructor callable on `self` alone, an array of either.
///     `bool` has no zero state to assume, and a record without such a
///     constructor -- none at all, or one deleted -- is never built.
///     Kairo has no uninitialized variable. Imported C++ types and
///     dependent ones are left to clang and to instantiation. A default
///     reached only through defaulted arguments is legal but not compiled
///     yet (SC116E, fix-it `= T()`): the defaults are CallLowering's.
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
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
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
import AST::Kind::DeclKind::*;
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

    priv var _tu: TypeUtil;

    fn InitCheck(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    fn run(self) {
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl {
                    var d = item.as_decl();
                    if (d != &null) && (d->kind == DeclKind::VariableDecl) { self._check_default_init(cast::<VariableDecl>(d)); }
                    self.dispatch_decl(d);
                }
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

    /// Statement-scope `var x: T`. Only a DeclStmt's: a loop binder, a
    /// catch binder or a pattern binding is a VariableDecl with no
    /// initializer too, and each of those is bound, not default-built.
    fn visit_decl_stmt(self, n: *DeclStmt) -> bool {
        if (n->decl != &null) && (n->decl->kind == DeclKind::VariableDecl) { self._check_default_init(cast::<VariableDecl>(n->decl)); }
        return true;
    }

    fn visit_named_initializer_expr(self, n: *NamedInitializerExpr) -> bool {
        self._check_brace_init(static_cast::<*Expr>(n));
        return true;
    }

    fn visit_anon_initializer_expr(self, n: *AnonInitializerExpr) -> bool {
        self._check_brace_init(static_cast::<*Expr>(n));
        return true;
    }

    priv fn _check_brace_init(self, e: *Expr) {
        if e->is_poisoned() || (e->type_ == &null) { return; }
        var rd = self._user_record(e->type_);
        if rd == &null { return; }
        var ctor = self._first_ctor(rd);
        if ctor == &null { return; }
        var nm = self._record_name(rd);
        var b = self.sc->diag->report(DiagID::SC088E, e->range.start,
            f"'{nm}' declares a constructor, so it cannot be built with a brace initializer");
        b.first(e->range);
        b.note(ctor->range.start, f"'{nm}' constructor declared here; call it instead: '{nm}(...)\x27").first(ctor->range);
        b.emit();
        e->poison();
    }

    priv fn _check_default_init(self, v: *VariableDecl) {
        if (v->init != &null) || v->is_poisoned() || (v->type_ == &null) { return; }
        var t = v->type_->canonical;
        if t == &null { return; }
        var nm  = self.sc->ctx->get_spelling(v->name);
        var why = self._why_no_default(t);
        if why.size() == 0 {
            // Legal, but not compiled: the defaults are CallLowering's thunks,
            // not C++ default arguments, so the emitted `T x;` finds no
            // nullary constructor. The call spelling goes through CallLowering.
            var rd = self._user_record(t);
            if rd == &null { return; }
            var dc = self._default_ctor(rd);
            if (dc == &null) || (!self._takes_args(dc)) { return; }
            var rn = self._record_name(rd);
            var g = self.sc->diag->report(DiagID::SC116E, v->range.start,
                f"'{nm}' would be built by a constructor whose arguments all default; declaring it without an initializer is not yet supported");
            g.first(v->name.range);
            g.insert(v->range.end, f" = {rn}()", "call the constructor");
            g.emit();
            v->poison();
            return;
        }
        var b = self.sc->diag->report(DiagID::SC001E, v->range.start,
            f"'{nm}' is declared without an initializer, and {why}; Kairo has no uninitialized variables");
        b.first(v->name.range);
        b.insert(v->range.end, " = ...", "initialize it");
        b.emit();
        v->poison();
    }

    /// Empty when \p t has a default value; otherwise the reason, phrased
    /// to follow "and" in _check_default_init's message.
    priv fn _why_no_default(self, t: *Type) -> string {
        var el = self._tu.element_of(t);
        if el != &null { return self._why_no_default(canon_unqual(el)); }
        if self._tu.is_bool(t) { return "'bool' has no zero state: a default would have to guess true or false"; }
        var rd = self._user_record(t);
        if rd == &null { return ""; }
        var nm = self._record_name(rd);
        var dc = self._default_ctor(rd);
        if dc == &null { return f"'{nm}' has no default constructor (declare 'fn {nm}(self)')"; }
        if dc->body_kind == FnBodyKind::Delete { return f"the default constructor of '{nm}' is deleted"; }
        return "";
    }

    /// A Kairo class or struct, pattern side. Null for an imported C++
    /// record (clang decides), an ADT's layout, a dependent type.
    priv fn _user_record(self, t: *Type) -> *Decl {
        var rd = self._tu.record_decl(t);
        if rd == &null { return &null; }
        if decl_is_instance(rd) { rd = decl_pattern(rd); }
        if (rd == &null) || decl_is_imported(rd) { return &null; }
        if (!isa::<ClassDecl>(rd)) && (!isa::<StructDecl>(rd)) { return &null; }
        return rd;
    }

    priv fn _record_name(self, d: *Decl) -> string {
        if isa::<ClassDecl>(d) { return self.sc->ctx->get_spelling(cast::<ClassDecl>(d)->name); }
        return self.sc->ctx->get_spelling(cast::<StructDecl>(d)->name);
    }

    priv fn _methods(self, d: *Decl) -> *FrozenList::<*FunctionDecl> {
        if isa::<ClassDecl>(d) { return &(cast::<ClassDecl>(d)->methods); }
        return &(cast::<StructDecl>(d)->methods);
    }

    /// A constructor: named after the record, not an operator, not a
    /// transfer (`@copy`/`@move` build from another value, not from none).
    priv fn _is_ctor(self, m: *FunctionDecl, nm: string) -> bool {
        if (m == &null) || m->is_operator { return false; }
        if m->adt_role != AdtRole::None { return false; }
        return self.sc->ctx->get_spelling(m->name) == nm;
    }

    priv fn _first_ctor(self, d: *Decl) -> *FunctionDecl {
        var nm = self._record_name(d);
        var ms = self._methods(d);
        for var i: usize = 0; i < ms->size(); ++i {
            var m = (*ms)[i];
            if self._is_ctor(m, nm) && (m->transfer == TransferKind::NotTransfer) { return m; }
        }
        return &null;
    }

    priv fn _takes_args(self, m: *FunctionDecl) -> bool {
        for var j: usize = 0; j < m->params.size(); ++j {
            if !m->params[j]->is_self { return true; }
        }
        return false;
    }

    /// The constructor callable with no arguments: every parameter but
    /// `self` has a default.
    priv fn _default_ctor(self, d: *Decl) -> *FunctionDecl {
        var nm = self._record_name(d);
        var ms = self._methods(d);
        for var i: usize = 0; i < ms->size(); ++i {
            var m = (*ms)[i];
            if (!self._is_ctor(m, nm)) || (m->transfer != TransferKind::NotTransfer) { continue; }
            var ok = true;
            for var j: usize = 0; j < m->params.size(); ++j {
                var p = m->params[j];
                if p->is_self { continue; }
                if (p->default_val == &null) && (!p->has_default) && (!p->is_pack) { ok = false; break; }
            }
            if ok { return m; }
        }
        return &null;
    }
}
