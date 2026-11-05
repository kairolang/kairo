/// --- The Kairo Project -------------------- Sema/Check/CallConvCheck.k --- ///
///
///   \brief Where `@preserve_most` / `@preserve_all` / `@preserve_none` may
///          stand (functions-declarations.mdx, "Calling conventions").
///
///   \detail
///     A calling convention changes which registers a call clobbers, so
///     every caller and the callee must agree on it, and every route a call
///     can take must know it. Each rule below closes a route that would not:
///
///       kind      a constructor, destructor, operator, `main`, generator,
///                 `async` function, closure or `eval fn` is called by code
///                 Kairo does not write (C++ object lifetime, the C runtime,
///                 the coroutine machinery, a lambda's operator(), the
///                 constant evaluator), which calls it with the C convention.
///       virtual   a call through the base's slot uses the base's
///                 convention, so every method in one override set must
///                 have the same one. Checked from each override against
///                 the method it overrides, which covers both directions.
///       boundary  GCC has no spelling for these conventions, so a function
///                 C or C++ can see (an `ffi` declaration, or one that is not
///                 `priv` and therefore lands in the module's C++ header and
///                 `#include "x.k"` interface) cannot carry one. `priv`, and a
///                 function local to another, stays in its own TU.
///       target    LLVM implements them on x86-64 and AArch64 only; clang
///                 merely warns elsewhere and drops the attribute, which
///                 would silently change what a caller may assume.
///
///     That two conventions are on one function is the parser's (SC133E);
///     that a chain's declarations agree is RedeclMerge's (R039E).
///
///   Phase: CHECK (after ExprTyper: `is_generator` is written by X)
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
import Sema::Check::EffectPropagation::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::LangItems::*;
import AST::Mixin::Annotation::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

/// The FunctionDecl::call_conv value attribute \p name sets, or 0.
fn call_conv_of_attr(name: string) -> u8 {
    if name == LangAttrs::preserve_most() { return 1; }
    if name == LangAttrs::preserve_all()  { return 2; }
    if name == LangAttrs::preserve_none() { return 3; }
    return 0;
}

class CallConvCheck derives RecursiveASTVisitor::<CallConvCheck> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;

    fn CallConvCheck(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    // === functions ========================================================

    fn visit_function_decl(self, n: *FunctionDecl) -> bool {
        if (n == &null) || n->is_poisoned() || (n->call_conv == 0) { return true; }
        var an = self._attr(n->call_conv);
        var at = n->range;

        var kind = self._forbidden_kind(n);
        if kind.size() > 0 {
            var b = self.sc->diag->report(DiagID::SC134E, at.start,
                f"a calling convention cannot be set on {kind}");
            b.first(at);
            b.note(at.start, f"{an} is on this declaration");
            b.emit();
            return true;
        }

        if !self._target_supports() {
            var triple = self._triple();
            var b = self.sc->diag->report(DiagID::SC137E, at.start,
                f"{an} is not available on {triple}");
            b.first(at);
            b.note(at.start, "LLVM implements this calling convention on x86-64 and AArch64 only");
            b.emit();
            return true;
        }

        if self._crosses_boundary(n) {
            var b = self.sc->diag->report(DiagID::SC136E, at.start,
                f"{an} cannot cross the C/C++ boundary: GCC cannot call it");
            b.first(at);
            if n->has_ffi_linkage() {
                b.note(at.start, "this is an ffi declaration");
            } else {
                b.note(at.start, "this function is not \x27priv\x27, so it is in the module\x27s C++ header; make it \x27priv\x27 to keep it in this file");
            }
            b.emit();
            return true;
        }
        return true;
    }

    /// The method set rule: \p cd's overrides against the methods they
    /// override. A plain virtual with no base has nothing to agree with.
    fn visit_class_decl(self, cd: *ClassDecl) -> bool {
        if (cd == &null) || cd->is_poisoned() || decl_is_imported(static_cast::<*Decl>(cd)) { return true; }
        for var i: usize = 0; i < cd->methods.size(); ++i {
            var m = cd->methods[i];
            if (m == &null) || m->is_poisoned() { continue; }
            if (m->abi != AbiKind::Override) && (m->abi != AbiKind::Virtual) { continue; }
            var base = panic_overridden(&(self._tu), cd, m);
            if (base == &null) && (m->abi == AbiKind::Override) { self._overrides_nothing(cd, m); continue; }
            if (base == &null) || (base->call_conv == m->call_conv) { continue; }
            var nm = self._tu.decl_name(static_cast::<*Decl>(m));
            var mine   = self._phrase(m->call_conv);
            var theirs = self._phrase(base->call_conv);
            var b = self.sc->diag->report(DiagID::SC135E, m->range.start,
                f"'{nm}' has {mine}, but the method it overrides has {theirs}");
            b.first(m->range);
            b.note(DiagID::SC135N, base->range.start, f"overridden method declared here with {theirs}");
            b.first(base->range);
            b.emit();
        }
        return true;
    }

    /// `override` on \p m, whose parameter list matches no base virtual of
    /// its name and arity as C++ declares them (SI8): a Kairo `x: D` is a
    /// by-value `D`, not the `const D&` a C++ base takes, so clang says the
    /// method overrides nothing. Reported only when such a base method
    /// exists, the one the override was meant for; the fix is the base's
    /// parameter form (`const x: D` for `const D&`).
    priv fn _overrides_nothing(self, cd: *ClassDecl, m: *FunctionDecl) {
        var bt: *Type = &null;
        var meant = overridden_at(&(self._tu), cd, m, &bt, true);
        if meant == &null { return; }
        var nm = self._tu.decl_name(static_cast::<*Decl>(m));
        var b = self.sc->diag->report(DiagID::SC001E, m->range.start,
            f"'{nm}' is marked 'override' but overrides nothing: its parameter types differ from the base method's as C++ declares them");
        b.first(m->range);
        b.note(meant->range.start, "the base method of that name; a C++ 'const T&' parameter is written 'const x: T\x27");
        b.first(meant->range);
        b.emit();
    }

    /// `@preserve_most fn() { ... }`: the attribute reaches a closure as an
    /// expression attribute. FeatureGateCheck leaves a convention on a
    /// closure to this pass, so the user hears why, not "not yet supported".
    fn visit_attributed_expr(self, n: *AttributedExpr) -> bool {
        if (n == &null) || (n->operand == &null) || (!isa::<ClosureExpr>(n->operand)) { return true; }
        var cc = call_conv_of_attr(self.sc->ctx->get_spelling(n->name));
        if cc == 0 { return true; }
        var at = SourceRange::from_bounds(n->range.start, u32(1)) | n->name.range;
        var an = self._attr(cc);
        var b = self.sc->diag->report(DiagID::SC134E, at.start,
            "a calling convention cannot be set on a closure");
        b.first(at);
        b.remove(at, f"remove {an}");
        b.emit();
        return true;
    }

    // === the rules ========================================================

    /// What \p f is, when it is a kind no convention may be set on; "" when
    /// it may carry one.
    priv fn _forbidden_kind(self, f: *FunctionDecl) -> string {
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        // An operator's name is its token, which has no spelling to ask
        // for; `op delete` is the destructor.
        if f->is_operator {
            if (f->op_token.size() > 0) && (f->op_token[0].kind == TokenKind::KwDelete) { return "a destructor"; }
            return "an operator";
        }
        if (dc != &null) && dc->is_type_scope() && f->is_method() {
            var owner = dc->owner_decl();
            if (owner != &null) && (self._tu.decl_name(static_cast::<*Decl>(f)) == self._tu.decl_name(owner)) {
                return "a constructor";
            }
        }
        if (dc != &null) && dc->is_translation_unit() && (!f->is_method())
            && (self.sc->ctx->get_spelling(f->name) == entry_point_name()) {
            return "\x27main\x27";
        }
        if f->is_generator { return "a generator"; }
        if f->is_async() { return "an 'async' function"; }
        if f->is_eval() { return "an 'eval fn\x27"; }
        return "";
    }

    /// x86-64 and AArch64, any OS: the archs LLVM implements all three
    /// conventions on. `arm64` is Darwin's spelling of AArch64.
    priv fn _target_supports(self) -> bool {
        var ci = self.sc->ctx->ci;
        if ci == &null { return true; }
        var a = ci->target.arch_name;
        if a.size() == 0 { return true; }   // unresolved: the driver reports the target.
        return (a == "x86_64") || (a == "amd64") || (a == "aarch64") || (a == "arm64")
            || (a == "arm64e") || (a == "aarch64_be");
    }

    priv fn _triple(self) -> string {
        var ci = self.sc->ctx->ci;
        if ci == &null { return "this target"; }
        if ci->target.effective_triple.size() > 0 { return ci->target.effective_triple; }
        return ci->target.triple;
    }

    /// \p f is visible to C or C++: an `ffi` declaration, or a function no
    /// enclosing scope makes private. `internal` still reaches the module's
    /// header (another file of the module includes it), so only `priv`, or
    /// a function local to another, keeps it in its TU.
    priv fn _crosses_boundary(self, f: *FunctionDecl) -> bool {
        if f->has_ffi_linkage() { return true; }
        // A requirement is no C++ function: its witness thunk is, inside the
        // witness the conformance emits, and the conformer is checked here
        // in its own right.
        var fdc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (fdc != &null) && (fdc->dc_kind == DeclContextKind::Interface) { return false; }
        var d = static_cast::<*Decl>(f);
        while d != &null {
            var v = d->visibility;
            if v == VisibilityKind::None {
                // A redeclaration chain says it once (AccessCheck::_effective).
                var fd = dyn_cast::<FunctionDecl>(d);
                if (fd != &null) && (fd->canonical_decl() != &null) { v = fd->canonical_decl()->visibility; }
                if (v == VisibilityKind::None) && (fd != &null) && (fd->first_decl() != &null) { v = fd->first_decl()->visibility; }
            }
            if v == VisibilityKind::Private { return false; }
            var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
            if dc == &null { return true; }
            if dc->is_function() { return false; }
            if dc->is_translation_unit() { return true; }
            d = dc->owner_decl();
        }
        return true;
    }

    // === spelling =========================================================

    priv fn _attr(self, cc: u8) -> string { return "\x27@" + LangAttrs::call_conv_name(cc) + "\x27"; }

    priv fn _phrase(self, cc: u8) -> string {
        if cc == 0 { return "the default calling convention"; }
        return self._attr(cc);
    }
}
