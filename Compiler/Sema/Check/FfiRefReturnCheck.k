/// --- The Kairo Project --------------- Sema/Check/FfiRefReturnCheck.k --- ///
///
///   \brief Where `ffi::ref<T>` / `ffi::mref<T>` may stand, and that an
///          override of a C++ virtual returns what the virtual returns
///          (P872, functions-parameter-modes.mdx "Reference returns from C++";
///          any return, not only a reference, since P987).
///
///   \detail
///     `ffi::ref<T>` (C++ `T&`), `ffi::ref<const T>` (`const T&`) and
///     `ffi::mref<T>` (`T&&`) are not types: nothing in Kairo holds a
///     reference. They spell the return of a function C++ declares, so the
///     only places one may stand are the WHOLE return type of
///
///       an out-of-line definition of an imported function or member
///         (`fn Widget::at(self, i: usize) -> ffi::ref<i32>`), and
///       an override of an imported virtual method.
///
///     Everything else is SC293E: a parameter, a variable, a field, a
///     generic argument, an alias, inside any other type, a closure, an
///     interface, and every function Kairo itself declares. A generic
///     definition (its own or its owner's type parameters) is SC293E too:
///     what the C++ template returns is a question per instance, not
///     answered yet.
///
///     The written node IS the C++ reference type imports build, so the
///     canonical of a legal one equals the C++ declaration's when the two
///     agree. An out-of-line definition that disagrees is RedeclMerge's
///     (SC294E there, with the fix-it); an override's return is compared
///     here, because this is where an override meets the method it
///     overrides. The legacy `-> *T` for a `T&` virtual (CXX-REF, 2026-11-08)
///     is left alone: CallConvCheck marks it `cxx_ref_return`.
///
///     A misplaced node is rewritten to its referee's canonical once
///     reported, so the passes after this one see `T` and do not cascade.
///     What the body returns is StmtTyping's (SC295E): it needs the typed
///     expression.
///
///   Errors: SC293E (where it stands), SC294E (an override's mismatch).
///
///   Phase: CHECK, after TypeResolve and RedeclMerge (out-of-line
///   definitions are attached), before ExprTyper: a call of a function
///   whose `ffi::ref` was rejected types as returning `T`.
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

import AST::DeclFacts::{
    decl_generic_params,
    decl_is_imported,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,
    FunctionDecl,
    ParamDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    ParenExpr,
    SubscriptExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::ReturnStmt
import AST::ParamMode::ParamMode
import AST::Node::Program::TopLevelKind
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    PointerType,
}
import AST::OperatorFacts::OperatorFacts
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Sema::Check::EffectPropagation::panic_overridden
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::NullnessFlow::null_flow_is_global
import Sema::Type::TypeUtil::TypeUtil

/// \p t is a reference written `ffi::ref<...>` / `ffi::mref<...>`.
pub fn is_ffi_ref_spelled(t: unsafe *Type) -> bool {
    if t == &null {
        return false
    }

    if isa<CXXLValueRefType>(t) {
        return cast<CXXLValueRefType>(t)->ffi_spelled
    }

    if isa<CXXRValueRefType>(t) {
        return cast<CXXRValueRefType>(t)->ffi_spelled
    }

    return false
}

/// \p t's canonical is a C++ reference (`T&` / `T&&`).
pub fn is_cxx_ref_canonical(t: unsafe *Type) -> bool {
    var unsafe *c = canon_unqual(t)
    return c != &null && (isa<CXXLValueRefType>(c) || isa<CXXRValueRefType>(c))
}

/// The written referee of an `ffi::ref` / `ffi::mref` node.
fn ffi_ref_referee(t: unsafe *Type) -> unsafe *Type {
    if isa<CXXLValueRefType>(t) {
        return cast<CXXLValueRefType>(t)->referee
    }

    return cast<CXXRValueRefType>(t)->referee
}

pub class FfiRefReturnCheck derives RecursiveASTVisitor<FfiRefReturnCheck> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    /// The return types judged as such by visit_function_decl; visit_type
    /// reports every other written `ffi::ref`.
    priv var _returns: cxx::std::vector<unsafe *Type>

    fn FfiRefReturnCheck(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            match item.get_kind() {
                case TopLevelKind::Decl {
                    self.dyn()->dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dyn()->dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dyn()->dispatch_expr(item.as_expr())
                }
            }
        }
    }

    /// # positions

    fn visit_type(self, t: unsafe *Type) -> bool {
        if !is_ffi_ref_spelled(t) {
            return true
        }

        for var i: usize = 0; i < self._returns.size(); ++i {
            if self._returns[i] == t {
                return true
            }
        }

        var b = self.sc->diag->report(
            DiagID::SC293E,
            t->range.start,
            "'ffi::ref' and 'ffi::mref' are not types: they may only be the whole return type of a definition of a function C++ declares returning a reference",
        )

        b.first(t->range, "nothing can hold a reference; a pointer ('*T') is the Kairo spelling of an alias")
        b.emit()
        self._degrade(t)
        return true
    }

    fn visit_function_decl(self, n: unsafe *FunctionDecl) -> bool {
        if n == &null || decl_is_imported(unsafe (n as unsafe *Decl)) {
            return true
        }

        var unsafe *rt = n->return_type
        if !is_ffi_ref_spelled(rt) {
            return true
        }

        // Recorded first: a function poisoned by an earlier error still
        // walks its return type, which is not a misplaced one.
        self._returns.push_back(rt)
        if n->is_poisoned() {
            return true
        }

        var why = self._illegal_owner(n)
        if why.empty() {
            return true
        }

        var nm = self._tu.decl_name(unsafe (n as unsafe *Decl))
        var b = self.sc->diag->report(
            DiagID::SC293E,
            rt->range.start,
            f"'{nm}' cannot return 'ffi::ref' / 'ffi::mref': {why}",
        )

        b.first(rt->range, "only a definition of a C++-declared function or an override of a C++ virtual returns a reference")
        b.emit()
        self._degrade(rt)
        return true
    }

    /// Empty when \p n is a place a reference return may be defined; else
    /// why not, worded for the message.
    priv fn _illegal_owner(self, n: unsafe *FunctionDecl) -> string {
        if decl_generic_params(unsafe (n as unsafe *Decl)).size() > 0 {
            return "a generic definition cannot spell a C++ reference return yet"
        }

        // An out-of-line definition: what it defines is the chain's first
        // declaration (RedeclMerge linked it there).
        if n->is_out_of_line() {
            var unsafe *first = n->first_decl()
            if first != &null && first != n && decl_is_imported(unsafe (first as unsafe *Decl)) {
                var unsafe *owner = first->semantic_dc
                if owner != &null && owner->dc_owner != &null
                    && decl_generic_params(owner->dc_owner).size() > 0 {
                    return "a member of a C++ class template cannot spell a C++ reference return yet"
                }

                return ""
            }

            return "it defines a function Kairo declares, not one C++ declares"
        }

        var unsafe *dc = n->semantic_dc
        var cd: unsafe *ClassDecl = &null
        if dc != &null && dc->dc_owner != &null {
            cd = dyn_cast<ClassDecl>(dc->dc_owner)
        }

        if cd == &null || (!n->is_method()) {
            return "it is declared in Kairo, not C++"
        }

        if decl_generic_params(unsafe (cd as unsafe *Decl)).size() > 0 {
            return "a method of a generic class cannot spell a C++ reference return yet"
        }

        var unsafe *base = panic_overridden(unsafe &self._tu, cd, n)
        if base == &null || !decl_is_imported(unsafe (base as unsafe *Decl)) {
            return "it overrides no C++ virtual method"
        }

        return ""
    }

    /// Reported: the node reads as its referee from here on.
    /// Through every reference: `ffi::ref<ffi::ref<T>>` reads as `T`.
    priv fn _degrade(self, t: unsafe *Type) {
        var unsafe *r = ffi_ref_referee(t)
        if r == &null || r->canonical == &null {
            return
        }

        var unsafe *c = r->canonical
        while is_cxx_ref_canonical(c) {
            var unsafe *u = canon_unqual(c)
            c = if (isa<CXXLValueRefType>(u)) => (cast<CXXLValueRefType>(u)->referee)
                else => cast<CXXRValueRefType>(u)->referee
        }

        t->canonical = c
    }

    /// # overrides

    /// Each override of an imported virtual returns what the virtual
    /// returns: clang would reject the pair anyway, with a message that
    /// names C++ types and no fix. A reference on either side must match
    /// exactly; any other return as _plain_return_agrees says.
    fn visit_class_decl(self, cd: unsafe *ClassDecl) -> bool {
        if cd == &null || cd->is_poisoned() || decl_is_imported(unsafe (cd as unsafe *Decl)) {
            return true
        }

        if cd->derives_list.size() == 0 {
            return true
        }

        for var i: usize = 0; i < cd->methods.size(); ++i {
            var unsafe *m = cd->methods[i]
            if m == &null || m->is_poisoned() || (!m->is_method()) {
                continue
            }

            var unsafe *base = panic_overridden(unsafe &self._tu, cd, m)
            if base == &null || !decl_is_imported(unsafe (base as unsafe *Decl)) {
                continue
            }

            self._check_override_return(m, base)
        }

        return true
    }

    /// Neither return is a reference: true when C++ accepts the pair or
    /// Kairo cannot tell. Any other mismatch (`-> i64` over `int val()`)
    /// passed Kairo and failed in clang as "virtual function 'val' has a
    /// different return type" (P987).
    ///
    /// A pointer to a record on both sides may be a covariant return, legal
    /// in C++ when the override's record derives from the virtual's (and is
    /// complete, and the base accessible and unambiguous): clang judges that
    /// pair, not this check. Top-level qualifiers are ignored on both sides.
    priv fn _plain_return_agrees(self, mc: unsafe *Type, bc: unsafe *Type) -> bool {
        if mc == &null {
            return self._tu.is_void(bc) // no `->`: the override returns void.
        }

        var unsafe *mu = canon_unqual(mc)
        var unsafe *bu = canon_unqual(bc)
        if mu == bu || mu == &null || bu == &null || mu->is_dependent() {
            return true
        }

        var unsafe *mp = self._tu.pointee(mu)
        var unsafe *bp = self._tu.pointee(bu)
        if mp != &null && bp != &null
            && self._tu.record_decl(mp) != &null
            && self._tu.record_decl(bp) != &null {
            return true
        }

        return false
    }

    priv fn _check_override_return(self, m: unsafe *FunctionDecl, base: unsafe *FunctionDecl) {
        if base->return_type == &null || base->return_type->canonical == &null {
            return
        }

        var unsafe *bc = base->return_type->canonical
        if bc->is_dependent() {
            return // a C++ template base: clang judges each instance.
        }

        var mc: unsafe *Type = &null
        if m->return_type != &null {
            mc = m->return_type->canonical
            if mc == &null {
                return // diagnosed by T.
            }
        }

        var cxx_ref = is_cxx_ref_canonical(bc)
        var mine    = m->return_type != &null && (is_ffi_ref_spelled(m->return_type) || is_cxx_ref_canonical(mc))
        if (!cxx_ref) && (!mine) && self._plain_return_agrees(mc, bc) {
            return
        }

        if mc == bc {
            return
        }

        // The decided `-> *T` for `T&` (CXX-REF): CallConvCheck's.
        if mc != &null && OperatorFacts::ptr_implements_lref(mc, bc) {
            return
        }

        var nm   = self._tu.decl_name(unsafe (m as unsafe *Decl))
        var want = self._tu.return_fix(m->return_type, bc)
        var have = if (mc != &null) => (self._tu.return_str(mc)) else => "void"
        if m->return_type != &null && m->return_type->range.is_valid() {
            have = self.sc->ctx->get_spelling(m->return_type->range)
        }

        var at   = if (m->return_type != &null) => (m->return_type->range) else => m->name.range
        var b = self.sc->diag->report(
            DiagID::SC294E,
            at.start,
            f"'{nm}' returns '{have}', but the C++ virtual it overrides returns '{want}'",
        )

        b.first(at)
        if m->return_type != &null && m->return_type->range.is_valid() {
            b.fix(m->return_type->range, want, f"return '{want}', as the C++ declaration does")
        }

        b.note(
            DiagCode(DiagID::SC294N),
            base->range.start,
            "the C++ virtual it overrides, whose return it must match",
        )
        b.child_first(base->range)
        b.emit()
        // Judged here; visit_type must not report it a second time when the
        // method's own traversal reaches it (a poisoned method is skipped).
        self._returns.push_back(m->return_type)
        m->poison()
    }
}

/// # the returned place (SC295E)

/// The local variable or by-value parameter whose storage \p e names, or
/// null when the place outlives the call: a field of `self`, an element
/// through a pointer or a reference, an `@inout` / `@move` parameter, a
/// global, a dereference, a call that returns a reference. Walks the place
/// down to its root through the steps that stay inside one object (`.`,
/// `[i]` on a value, parentheses); a step through a pointer or a
/// reference leaves it.
pub fn ref_return_local_root(e: unsafe *Expr) -> unsafe *Decl {
    var unsafe *x = e
    while x != &null {
        if isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
            continue
        }

        if isa<SubscriptExpr>(x) {
            var unsafe *b = cast<SubscriptExpr>(x)->base
            if b == &null || reaches_out(b->type_) {
                return &null
            }

            x = b
            continue
        }

        if isa<ChainExpr>(x) {
            var unsafe *ch = cast<ChainExpr>(x)
            for var i: usize = 0; i < ch->steps.size(); ++i {
                var k = ch->steps.get(i)->access_kind
                if k == ChainExpr::AccessKind::Arrow || k == ChainExpr::AccessKind::QuestionArrow
                    || k == ChainExpr::AccessKind::ColonColon {
                    return &null
                }
            }

            if ch->base == &null || reaches_out(ch->base->type_) {
                return &null
            }

            x = ch->base
            continue
        }

        if isa<NamedIdentExpr>(x) {
            return local_storage(cast<NamedIdentExpr>(x)->resolved_decl)
        }

        return &null
    }

    return &null
}

/// \p t (an expression's type) is a pointer or a reference: what is
/// reached through it is not part of the object that holds it.
fn reaches_out(t: unsafe *Type) -> bool {
    var unsafe *c = canon_unqual(t)
    return c != &null && (isa<PointerType>(c) || isa<CXXLValueRefType>(c) || isa<CXXRValueRefType>(c))
}

/// \p d when it is storage that ends with the call: a local (not
/// `static` or `thread`) variable, or a by-value parameter other than `self`.
fn local_storage(d: unsafe *Decl) -> unsafe *Decl {
    if d == &null {
        return &null
    }

    var unsafe *p = dyn_cast<ParamDecl>(d)
    if p != &null {
        if p->is_self || p->mode != ParamMode::Value || reaches_out(p->type_) {
            return &null
        }

        return d
    }

    // A local has no semantic context (NullnessFlow's rule, shared).
    if (!isa<VariableDecl>(d)) || null_flow_is_global(d) {
        return &null
    }

    return d
}

/// `return a` in a function written to return `ffi::ref<T>` /
/// `ffi::mref<T>`, \p declared its (still reference) canonical: \p a is
/// a place (an lvalue; an xvalue too for `mref`) whose storage outlives
/// the call. A temporary or a local would leave the caller a reference
/// to nothing, which C++ only warns about.
pub fn check_ref_return_value(sc:       unsafe *SemaContext,
                              n:        unsafe *ReturnStmt,
                              fd:       unsafe *FunctionDecl,
                              declared: unsafe *Type) {
    if n == &null || n->value == &null || fd == &null || (!is_ffi_ref_spelled(fd->return_type)) {
        return
    }

    var unsafe *dc = canon_unqual(declared)
    if dc == &null || (!is_cxx_ref_canonical(dc)) {
        return // rejected by FfiRefReturnCheck, read as its referee now.
    }

    var unsafe *v = n->value
    if v->is_poisoned() || v->type_ == &null {
        return
    }

    var cat = v->value_category
    var ok  = cat == Expr::ValueCategory::LValue
        || (isa<CXXRValueRefType>(dc) && cat == Expr::ValueCategory::XValue)
    if !ok {
        var b = sc->diag->report(
            DiagID::SC295E,
            v->range.start,
            "a reference return returns a place, and this is a temporary: the caller would be left a reference to nothing",
        )

        b.first(v->range, "return a variable, a field or an element that outlives the call")
        b.emit()
        return
    }

    var unsafe *loc = ref_return_local_root(v)
    if loc == &null {
        return
    }

    var tu = TypeUtil(sc)
    var nm = tu.decl_name(loc)
    var what = if (isa<ParamDecl>(loc)) => ("a by-value parameter") else => "a local variable"
    var b = sc->diag->report(
        DiagID::SC295E,
        v->range.start,
        f"'{nm}' is {what}, so the reference returned would outlive it",
    )

    b.first(v->range, "returned by reference")
    b.note(DiagCode(DiagID::SC295N), loc->range.start, f"'{nm}' is declared here and ends with the call")
    b.child_first(loc->range)
    b.emit()
}
