/// --- The Kairo Project ---------------- Codegen/Emit/InterfaceEmitter.k --- ///
///
///   \brief Emit an EmitPlan as C++ declarations. Two callers, one emitter
///          (IMPORTS.md §6.6): Backend for a TU's preamble (TokenSink),
///          EmitCXXHeader for the module's interop header (TextSink).
///
///   \par Text fragments, one per declaration
///     Every declaration is built as a C++ string and landed through
///     EmitSink::spell() anchored on the decl's name span. The string is a
///     pure function of the decl, so the same class is the same bytes in
///     every TU and in the header. That is the whole ODR argument, and it
///     is why nothing here is per-sink.
///
///   \par ADT enums
///     Written as the record EnumLayoutLowering built (EnumDecl::
///     adt_layout), under the enum's own name and template head (_adt_def).
///     Its role functions are the one place a declaration here carries
///     bodies and constraints: they have no Kairo spelling, so the text is
///     rendered from FunctionDecl::adt_role / adt_form, and it is still a
///     pure function of the decl. The constraints are C++ mechanics over the
///     record's flags, never a Kairo requires_clause.
///
///   \par Derived assignment
///     A record's `op =` is derived from its transfer constructor and has
///     no Kairo decl. ClassLifecycle decides how (ClassDecl / StructDecl::
///     assign_form) and _derived_assign writes it after the methods, a pure
///     function of the record. With a body it is the other member that
///     carries one in the class: destroy, then rebuild through the global
///     placement `::new`, so a TU or header that writes one asks the sink
///     for <new> before any class (_needs_new). Included, not declared:
///     libc++ declares that operator with an abi_tag and, from C++26,
///     constexpr, and clang rejects a redeclaration that differs, whichever
///     of the two comes first.
///
///   \par Field initializers
///     A default is a C++ default member initializer. A constant
///     FieldInitLowering folded is spelled as it is (`signed int n = 5;`);
///     any other initializer is the body of the member function it made
///     (FieldDecl::init_thunk), and the default calls it
///     (`signed int d = __kairo_init_d();`). The class names only a member
///     of the record, so it is still a pure function of the decl, and the
///     body goes out of line like every user-written body (invariant 12: no
///     user-written function body is ever emitted in-class).
///
///   \par Static fields
///     Declared in the class with no initializer (C++ allows one in-class
///     only on a const static), then DEFINED right after the outermost
///     record, in its namespace wrapper, as an inline variable:
///     `inline [constinit] T R::s = <init>;` (_static_defs). Inline, because
///     every TU that holds the class must also hold the definition of a
///     static it can odr-use, and the linker keeps one. `constinit` exactly
///     when FieldInitLowering folded the initializer to a literal: that is a
///     constant expression for every instantiation, so clang can never
///     reject it, and it turns cross-TU initialization order from a runtime
///     surprise into a guarantee. A thunk's call is dynamic initialization,
///     never `constinit` -- deciding constness per instance needs the
///     monomorphizer (CODEGEN.md §10). No initializer at all is `{}`: Kairo
///     has no uninitialized variable. Not inside a nested record's braces:
///     `T Outer::Inner::s = ...;` is a namespace-scope declaration.
///
///   \par What is NOT emitted (each an ICE naming its owner)
///     Named unions (later; an anonymous one is written inline as the field
///     that declares it), interfaces (no entity; witnesses MISSING), the
///     initializer of an eval or array-typed field (FeatureGateCheck
///     rejects it), packs in expansion position, structural containers (the
///     container migration). Parameter defaults are not declared:
///     CallLowering's thunks supply them at every call.
///
///   Import law: CodegenContext only.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Codegen::CodegenContext::*;
import Codegen::CodegenICE::*;
import Codegen::EmitPlan::*;
import Codegen::Emit::CXXSpell::*;
import Codegen::Emit::EmitWitness::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::LangItems::*;
import AST::OperatorFacts::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import AST::Kind::ExprKind::*;
import Location::SourceRange::*;
import Token::TokenKind::*;

class InterfaceEmitter {
    priv var _cg:    obs::<CodegenContext>;
    priv var _plan:  obs::<EmitPlan>;
    priv var _spell: obs::<CXXSpell>;
    /// Header mode: the module's own ffi includes, as directive lines, from
    /// EmitCXXHeader (which may see the HeaderSet; this file may not).
    priv var _ffi_lines: vec::<string>;

    /// The host C++ TU already holds the lowering helpers / the const-field
    /// constructor helpers: an earlier `#include "*.k"` in it wrote them
    /// (Backend/IncludeEmitter.k). They are definitions, and a token stream
    /// has no `#ifndef` to guard them with, so they are left out. run() sets
    /// each once it writes them, for the next include to read.
    pub var have_helpers:    bool = false;
    pub var have_ctor_slots: bool = false;
    pub var have_fn_value:   bool = false;
    pub var have_eval_helpers: bool = false;

    fn InterfaceEmitter(self, cg: *CodegenContext, plan: *EmitPlan) {
        self._cg    = cg;
        self._plan  = plan;
        self._spell = plan->spell();
    }

    fn set_ffi_lines(self, lines: vec::<string>) { self._ffi_lines = lines; }

    /// ICE naming the Kairo source at \p at (CodegenICE).
    priv fn _ice(self, at: SourceRange, msg: string) {
        codegen_ice(self._cg->ctx, at, msg);
    }

    // --- Entry point -------------------------------------------------------------

    fn run(self) {
        var header = (self._plan->mode() == PlanMode::Header);
        if header { self._header_prologue(); }
        // A rebuilding `op =` calls the global placement `::new`, which only
        // <new> declares: asked for ahead of every class, and only by a TU
        // or header that writes one (_needs_new). Outside the guard below:
        // a header that needs it may follow one that defined the guard
        // without it.
        if self._needs_new() { self._cg->sink->system_header(self._tu_at(), "new"); }
        // A header carries the module's inline and template bodies too
        // (EmitPlan::visible_bodies), so it needs these as much as a
        // preamble. Guarded there: one C++ TU may include several Kairo
        // headers, and __kairo_tmp is a DEFINITION. An include's token
        // stream cannot be guarded; have_helpers stands in for the macro.
        if !self.have_helpers {
            self._cg->sink->unanchored(true);
            if header { self._cg->sink->directive(self._tu_at(), "#ifndef " + LowerTargets::lower_helpers_guard()); }
            if header { self._cg->sink->directive(self._tu_at(), "#define " + LowerTargets::lower_helpers_guard()); }
            // The array-prvalue alias, once per TU, ahead of every body that
            // can name it.
            self._cg->sink->spell(self._tu_at(),
                "template <class T, decltype(sizeof(0)) N> using " + LowerTargets::array_alias() + " = T[N];");
            self._cg->sink->brk();
            // The materialized-temporary helper: the one place it is spelled.
            // A forwarding reference binds the prvalue, so the address is the
            // temporary's, which lives to the end of the full-expression.
            self._cg->sink->spell(self._tu_at(),
                "template <class T> auto* " + LowerTargets::tmp_addr() + "(T&& t) { return __builtin_addressof(t); }");
            self._cg->sink->brk();
            // An ADT's variant tags: `E(::__kairo_vt<I>{}, ...)` picks variant I's
            // constructor. The explicit default constructor keeps a bare `{}`
            // from converting into a tag.
            self._cg->sink->spell(self._tu_at(),
                "template <" + builtin_info(BuiltinKind::U32)->cxx + " I> struct " + LowerTargets::adt_variant_tag()
                + " { explicit " + LowerTargets::adt_variant_tag() + "() = default; };");
            self._cg->sink->brk();
            // Construction and destruction in place. `new (p) T(...)` finds T's
            // own placement operator new first (an ADT payload declares one),
            // which needs no <new>, so it is never `::new`.
            self._cg->sink->spell(self._tu_at(),
                "template <class T, class... A> inline void " + LowerTargets::construct_at()
                + "(T* p, A&&... a) { new (p) T(static_cast<A&&>(a)...); }");
            self._cg->sink->brk();
            self._cg->sink->spell(self._tu_at(),
                "template <class T> inline void " + LowerTargets::destroy_at() + "(T* p) noexcept { p->~T(); }");
            self._cg->sink->brk();

            if header { self._cg->sink->directive(self._tu_at(), "#endif"); }
            self._cg->sink->unanchored(false);
            self.have_helpers = true;
        }
        // A constructor that initializes a const field (_ctor_slot_helpers).
        // Only when one is planned, so no other TU's text changes; guarded
        // apart from the helpers above, which an earlier header may have
        // defined without these.
        if (!self.have_ctor_slots) && self._needs_ctor_slots() {
            self._cg->sink->unanchored(true);
            self._ctor_slot_helpers(header);
            self._cg->sink->unanchored(false);
            self.have_ctor_slots = true;
        }
        // A Kairo `fn` value (EmitPlan::needs_fn_value), guarded on its own
        // for the same reason.
        if (!self.have_fn_value) && self._plan->needs_fn_value {
            self._cg->sink->unanchored(true);
            self._fn_value_helper(header);
            self._cg->sink->unanchored(false);
            self.have_fn_value = true;
        }
        // `eval for` and eval generators (EVAL.md §5), only where one is:
        // every other TU's text is unchanged.
        if (!self.have_eval_helpers) && self._needs_eval_helpers() {
            self._cg->sink->unanchored(true);
            if header { self._cg->sink->directive(self._tu_at(), "#ifndef " + LowerTargets::eval_helpers_guard()); }
            if header { self._cg->sink->directive(self._tu_at(), "#define " + LowerTargets::eval_helpers_guard()); }
            // `eval for` and eval generators (EVAL.md §5): the index pack an
            // expansion runs over, the compile-time buffer a generator
            // pushes into (a transient constexpr allocation, freed before
            // the constant escapes), and the literal array its values are
            // copied into. Plain text, needing no header.
            var sz = "decltype(sizeof(0))";
            self._cg->sink->spell(self._tu_at(),
                "template <class T, T... I> struct " + LowerTargets::eval_iseq() + " {};");
            self._cg->sink->brk();
            var eb = LowerTargets::eval_buf();
            self._cg->sink->spell(self._tu_at(),
                "template <class T> struct " + eb + " { T* p = nullptr; " + sz + " n = 0; " + sz + " cap = 0; "
                + "constexpr " + eb + "() = default; "
                + "constexpr " + eb + "(" + eb + "&& o) : p(o.p), n(o.n), cap(o.cap) { o.p = nullptr; o.n = 0; o.cap = 0; } "
                + eb + "(const " + eb + "&) = delete; "
                + "constexpr void push(T v) { if (n == cap) { " + sz + " c = cap ? cap * 2 : 8; T* q = new T[c]; "
                + "for (" + sz + " i = 0; i < n; ++i) q[i] = p[i]; delete[] p; p = q; cap = c; } p[n++] = v; } "
                + "constexpr ~" + eb + "() { delete[] p; } };");
            self._cg->sink->brk();
            self._cg->sink->spell(self._tu_at(),
                "template <class T, " + sz + " N> struct " + LowerTargets::eval_arr() + " { T v[N ? N : 1]; };");
            self._cg->sink->brk();
            if header { self._cg->sink->directive(self._tu_at(), "#endif"); }
            self._cg->sink->unanchored(false);
            self.have_eval_helpers = true;
        }

        var i: usize = 0;
        var n = self._plan->entries.size();

        // tier 0: consecutive same-namespace entries share one wrapper.
        while (i < n) && (self._plan->entries[i].tier == PlanTier::FwdDecls) {
            var e = &(self._plan->entries[i]);
            var ns = self._entry_ns(e);
            // The unnamed nesting is part of the wrapper, so a run shares one
            // only if it agrees on that too: grouping on the segments alone
            // would put a `priv` decl in a `pub` decl's namespace.
            var anon = self._entry_anon(e);
            var opened = self._ns_open(e->decl, ns, anon);
            while (i < n) && (self._plan->entries[i].tier == PlanTier::FwdDecls) {
                var f = &(self._plan->entries[i]);
                var fns = self._entry_ns(f);
                if !self._same_ns(ns, fns) { break; }
                if self._entry_anon(f) != anon { break; }
                if header && (!f->own) && (f->need == PlanNeed::Complete) { i += 1; continue; }   // included.
                if f->scope != &null {
                    self._cg->sink->spell(self._at(f->decl), "struct " + f->scope->name + ";");
                } else if (f->witness != &null) && f->is_concept {
                    // Guarded in a header, as the primary is: a definition.
                    var g = LowerTargets::concept_guard(CXXSpell::_path_ident(f->witness->key));
                    if header { self._cg->sink->directive(self._tu_at(), "#ifndef " + g); }
                    if header { self._cg->sink->directive(self._tu_at(), "#define " + g); }
                    EmitWitness(self._cg, self._spell).concept_def(f->witness);
                    if header { self._cg->sink->directive(self._tu_at(), "#endif"); }
                } else if f->witness != &null {
                    EmitWitness(self._cg, self._spell).fwd(f->witness);
                } else {
                    self._fwd_decl(f->decl);
                }
                i += 1;
            }
            self._ns_close(opened);
        }

        // tier 1
        while (i < n) && (self._plan->entries[i].tier == PlanTier::Definitions) {
            var e = &(self._plan->entries[i]);
            i += 1;
            if header && (!e->own) { continue; }   // its header was included.
            if e->scope != &null {
                var opened = self._ns_open(e->decl, e->scope->ns, false);
                self._scope_def(e->scope);
                self._ns_close(opened);
                continue;
            }
            if e->witness != &null {
                // Written by every header that reaches it, so guarded there
                // as a tuple record is: two headers in one C++ TU.
                var g = LowerTargets::witness_guard(CXXSpell::_path_ident(e->witness->key));
                if header { self._cg->sink->directive(self._tu_at(), "#ifndef " + g); }
                if header { self._cg->sink->directive(self._tu_at(), "#define " + g); }
                self._wrapped(e->decl, fn () { EmitWitness(self._cg, self._spell).def(e->witness); });
                if header { self._cg->sink->directive(self._tu_at(), "#endif"); }
                continue;
            }
            // A tuple record is defined by every TU and header that reaches
            // it (EmitPlan::_entry marks it own), so a HEADER's definition
            // is guarded: two headers in one C++ TU would define it twice.
            // A preamble includes nothing and is a token stream, which
            // carries no directive (the helpers above are guarded the same
            // way).
            var tup = dyn_cast::<StructDecl>(e->decl);
            var guard = header && ((tup != &null) && (tup->tuple_arity > 0));
            if guard {
                self._cg->sink->directive(self._tu_at(), "#ifndef " + LowerTargets::tuple_guard(static_cast::<usize>(tup->tuple_arity)));
                self._cg->sink->directive(self._tu_at(), "#define " + LowerTargets::tuple_guard(static_cast::<usize>(tup->tuple_arity)));
            }
            self._wrapped(e->decl, fn () {
                self._type_def(e->decl);
                self._static_defs(e->decl);
            });
            if guard { self._cg->sink->directive(self._tu_at(), "#endif"); }
        }

        // tier 2
        while (i < n) && (self._plan->entries[i].tier == PlanTier::Functions) {
            var e = &(self._plan->entries[i]);
            i += 1;
            if header && (!e->own) { continue; }
            // EmitIR defines main at global scope as `int main`; a prior
            // declaration buys nothing, and inside the file's namespace it
            // would declare a different function.
            if self._spell->is_main(e->decl) { continue; }
            if e->decl->kind == DeclKind::VariableDecl {
                self._wrapped(e->decl, fn () { self._global_var_decl(cast::<VariableDecl>(e->decl)); });
                continue;
            }
            self._wrapped(e->decl, fn () { self._free_fn_decl(cast::<FunctionDecl>(e->decl), &null); });
        }

        // tier 3
        while (i < n) && (self._plan->entries[i].tier == PlanTier::Instantiations) {
            var e = &(self._plan->entries[i]);
            i += 1;
            if e->is_home { continue; }        // definitions come after the bodies; see emit_home_instantiations
            self._instantiation(e);
        }
    }

    /// Explicit instantiation DEFINITIONS, emitted by the backend after every
    /// body: an explicit instantiation only instantiates members defined
    /// before it.
    fn emit_home_instantiations(self) {
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var e = &(self._plan->entries[i]);
            if (e->tier != PlanTier::Instantiations) || (!e->is_home) { continue; }
            self._instantiation(e);
        }
    }

    // --- Header prologue -----------------------------------------------------------

    /// `#pragma once`, then one `#include` per foreign module reached at
    /// Complete, or whose FUNCTION is declared: only an inline or template
    /// body names a foreign function, and tier 2 leaves a foreign one to its
    /// own header. Kairo forbids import cycles, so the include graph is a DAG.
    priv fn _header_prologue(self) {
        var at = self._tu_at();
        self._cg->sink->directive(at, "#pragma once");
        // The module's ffi headers first: its declarations and its inline
        // bodies name what they declare, exactly as the module's own TU did.
        for var i: usize = 0; i < self._ffi_lines.size(); ++i { self._cg->sink->directive(at, self._ffi_lines[i]); }
        var seen = vec::<string>();
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var e = &(self._plan->entries[i]);
            if e->own { continue; }
            if e->tier == PlanTier::Instantiations { continue; }
            if (e->need != PlanNeed::Complete) && (e->tier != PlanTier::Functions) { continue; }
            var p = self._spell->header_path(CXXSpell::tu_of(e->decl));
            var dup = false;
            for var j: usize = 0; j < seen.size(); ++j { if seen[j] == p { dup = true; break; } }
            if dup { continue; }
            seen.push_back(p);
            var line = "#include \x22";
            line += p;
            line += "\x22";
            self._cg->sink->directive(at, line);
        }
    }

    // --- Namespace wrapping ----------------------------------------------------------

    priv fn _same_ns(self, a: ref!(vec::<string>), b: ref!(vec::<string>)) -> bool {
        if a.size() != b.size() { return false; }
        for var i: usize = 0; i < a.size(); ++i { if a[i] != b[i] { return false; } }
        return true;
    }

    /// Returns how many braces were opened: the named namespace, plus an
    /// unnamed one nested in it for a decl with no linkage outside its file.
    priv fn _ns_open(self, d: *Decl, ns: ref!(vec::<string>), anon: bool) -> u32 {
        var at = self._at(d);
        var n: u32 = 0;
        if ns.size() > 0 {
            var s = "namespace ";
            s += self._spell->ns_join(ns);
            s += " {";
            self._cg->sink->spell(at, s);
            n += 1;
        }
        if anon { self._cg->sink->spell(at, "namespace {"); n += 1; }
        return n;
    }

    priv fn _ns_close(self, n: u32) {
        // Closing braces anchored on nothing better than the TU: the wrapper
        // has no bytes of its own.
        for var i: u32 = 0; i < n; ++i { self._cg->sink->spell(self._tu_at(), "}"); }
        if n > 0 { self._cg->sink->brk(); }
    }

    priv fn _wrapped(self, d: *Decl, body: fn()) {
        var ns = self._spell->ns_segments(d);
        var opened = self._ns_open(d, ns, CXXSpell::is_anon(d));
        body();
        self._ns_close(opened);
    }

    /// A plan entry's namespace: an extension scope's own, else its decl's.
    priv fn _entry_ns(self, e: *PlanEntry) -> vec::<string> {
        if e->scope != &null { return e->scope->ns; }
        return self._spell->ns_segments(e->decl);
    }

    /// An extension scope is never in the unnamed namespace: its members
    /// are reached as `::N::__kairo_ext_X::m` from other TUs' preambles,
    /// and a priv member is AccessCheck's to hide, not linkage's.
    priv fn _entry_anon(self, e: *PlanEntry) -> bool {
        if e->scope != &null { return false; }
        return CXXSpell::is_anon(e->decl);
    }

    priv fn _scope_qual(self, s: *ExtScope) -> string {
        var q = "";
        for var i: usize = 0; i < s->ns.size(); ++i { q += "::"; q += s->ns[i]; }
        return q + "::" + s->name;
    }


    priv fn _at(self, d: *Decl) -> SourceRange {
        return CXXSpell::at(d);
    }

    /// Byte 0 of the TU: the anchor for tokens that have no bytes of their
    /// own (a directive, a namespace's closing brace).
    priv fn _tu_at(self) -> SourceRange {
        // Unreachable for an empty TU (the driver skips it on EmitPlan::
        // is_empty), but a zero-byte file has no byte 0: anchor at the end
        // position instead, which a zero-length range may name.
        var fid = self._cg->tu->fid;
        if self._cg->ctx->sm->get_file_size(fid) == 0 { return self._cg->ctx->sm->get_range(fid, 0, 0); }
        return self._cg->ctx->sm->get_range(fid, 0, 1);
    }

    // --- Tier 0 ----------------------------------------------------------------------

    priv fn _fwd_decl(self, d: *Decl) {
        var s = self._spell->record_head(d);
        switch d->kind {
            case DeclKind::ClassDecl  { s += "class ";  }
            case DeclKind::StructDecl { s += "struct "; }
            case DeclKind::UnionDecl  { self._ice(self._at(d), "InterfaceEmitter: union emission is not implemented yet"); }
            case DeclKind::EnumDecl {
                var en = cast::<EnumDecl>(d);
                // An ADT is written as a record (_adt_def), so it is declared
                // as one.
                if self._plan->adt_record(d) != d {
                    s += "struct ";
                    s += self._spell->leaf(d);
                    s += ";";
                    self._cg->sink->spell(self._fwd_at(d), s);
                    return;
                }
                s += "enum class ";
                s += self._spell->leaf(d);
                s += " : ";
                s += self._enum_underlying(en);
                s += ";";
                self._cg->sink->spell(self._fwd_at(d), s);
                return;
            }
            default { self._ice(self._at(d), "InterfaceEmitter: not a type decl"); }
        }
        s += self._spell->leaf(d);
        s += self._spell->spec_suffix(d);   // `Store<P*>`: which specialization.
        s += ";";
        // On the decl's first byte, not its name: the name's byte goes to
        // the definition's name token (TokenSink::_claim).
        self._cg->sink->spell(self._fwd_at(d), s);
    }

    priv fn _fwd_at(self, d: *Decl) -> SourceRange {
        if !d->range.is_valid() { return self._at(d); }
        return SourceRange::from_bounds(d->range.start, 1);
    }

    priv fn _enum_underlying(self, en: *EnumDecl) -> string {
        if en->underlying != &null { return self._spell->_type(en->underlying); }
        return builtin_info(BuiltinKind::U32)->cxx;   // Kairo's default enum width.
    }

    // --- Tier 1 ----------------------------------------------------------------------

    priv fn _type_def(self, d: *Decl) {
        switch d->kind {
            case DeclKind::ClassDecl  { self._record_def(d, "class");  }
            case DeclKind::StructDecl { self._record_def(d, "struct"); }
            case DeclKind::EnumDecl   { self._enum_def(cast::<EnumDecl>(d)); }
            case DeclKind::UnionDecl  { self._ice(self._at(d), "InterfaceEmitter: union emission is not implemented yet"); }
            default { self._ice(self._at(d), "InterfaceEmitter: not a type decl"); }
        }
    }

    /// The definition, body-less (invariant 12): bases, nested types,
    /// fields, method declarations, the derived `op =` (the exception:
    /// _derived_assign), friends. A field's default is a constant or a
    /// call of its thunk (_field_default); parameter defaults are not
    /// declared. See the file header.
    ///
    /// Every type written inside the braces is spelled with \p d as its
    /// scope (CXXSpell::_type), so the record's own nested types go out by
    /// leaf: qualified, a nested type of a class template would need the
    /// template's arguments, and inside the body the injected class name
    /// already supplies them. A nested record's definition passes itself.
    priv fn _record_def(self, d: *Decl, kw: string) {
        var at = self._at(d);
        var is_class = (d->kind == DeclKind::ClassDecl);
        var s = self._spell->record_head(d);
        s += kw;
        s += " ";
        s += self._spell->leaf(d);
        s += self._spell->spec_suffix(d);

        if is_class {
            var n = cast::<ClassDecl>(d);
            for var i: usize = 0; i < n->derives_list.size(); ++i {
                var e = n->derives_list.get(i);
                if e == &null { continue; }
                s += (" : ") if (i == 0) else (", ");
                if e->is_virtual { s += "virtual "; }
                s += self._base_access(e->visibility);
                s += " ";
                s += self._spell->_type(e->base);
            }
        }
        s += " {";
        self._cg->sink->spell(at, s);
        // An ADT payload is built inside its union by `new (&member) P(...)`,
        // which must not depend on the TU including <new>: this placement
        // form, found in the class before any global one, is what it calls.
        if isa::<StructDecl>(d) && cast::<StructDecl>(d)->is_adt_payload {
            self._cg->sink->spell(at, "static void* operator new(" + builtin_info(BuiltinKind::USize)->cxx + ", void* p) noexcept { return p; }");
        }

        // Default access follows the keyword: a Kairo struct's members are
        // public unless marked; in a class only the VARIABLES are private
        // unless marked, and methods, constructors and nested types are
        // public (classes.md, Default visibility).
        var cur_access = (VIS_PRIV()) if (is_class) else (VIS_PUB());

        // Nested types first: a field may name one.
        var dc = CXXSpell::dc_of(d);
        if dc != &null {
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                var nd = *(dc->dc_decls.get(i));
                if nd == &null { continue; }
                if isa::<VisibilityGroupDecl>(nd) { continue; }   // members are pointers back into the lists below.
                if !self._is_type(nd) { continue; }
                // An anonymous union is not a nested type: it has no name to
                // define it under, and its one declaration is the field
                // below that holds it (_anon_union_field).
                if isa::<UnionDecl>(nd) && cast::<UnionDecl>(nd)->is_anonymous { continue; }
                cur_access = self._access(cur_access, CXXSpell::vis_of(nd), false, at);
                self._type_def(CXXSpell::rep(nd));
            }

            // Member aliases, in declaration order, before any field or
            // method: an alias is usually named in the record's own
            // signatures (`promise_type`, which <coroutine>'s primary reads as
            // `typename R::promise_type`), and a C++ declaration cannot use a
            // member declared below it -- only a body sees the whole class.
            // After the nested types, because an alias may name one. An alias
            // can only refer to what the record itself can name, and Kairo
            // does not let it name a later field, so hoisting is safe.
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                var nd = *(dc->dc_decls.get(i));
                if (nd == &null) || (!isa::<TypeAliasDecl>(nd)) { continue; }
                var ta = cast::<TypeAliasDecl>(nd);
                if ta->aliased == &null { continue; }
                cur_access = self._access(cur_access, CXXSpell::vis_of(nd), false, at);
                var us = self._spell->template_head(nd);
                us += "using " + self._spell->leaf(nd) + " = " + self._spell->_type(ta->aliased, &null, d) + ";";
                self._cg->sink->spell(self._at(nd), us);
            }
        }

        var fields  = (cast::<ClassDecl>(d)->fields)  if (is_class) else (cast::<StructDecl>(d)->fields);
        var methods = (cast::<ClassDecl>(d)->methods) if (is_class) else (cast::<StructDecl>(d)->methods);

        for var i: usize = 0; i < fields.size(); ++i {
            var f = fields[i];
            if f == &null { continue; }
            cur_access = self._access(cur_access, CXXSpell::vis_of(static_cast::<*Decl>(f)), is_class, at);
            // Before anything spells the field: it has no name.
            if f->is_anonymous_union { self._anon_union_field(f, d); continue; }
            var fs = "";
            if f->is_static()  { fs += "static "; }
            if f->is_static() && f->is_thread { fs += "thread_local "; }
            if f->is_mutable   { fs += "mutable "; }
            // An eval field is `static const T k;` here and `constexpr` at its
            // definition (_static_def; EVAL.md 1.2).
            if f->is_const() || f->is_eval() { fs += "const "; }
            fs += self._spell->decl(f->type_, self._spell->leaf(static_cast::<*Decl>(f)), &null, d);
            // A static's value is its definition's (_static_defs), never an
            // in-class initializer, which C++ refuses on a non-const static.
            if !f->is_static() { fs += self._field_default(f); }
            fs += ";";
            self._cg->sink->spell(f->name.range, fs);
        }

        for var i: usize = 0; i < methods.size(); ++i {
            var m = methods[i];
            if m == &null { continue; }
            cur_access = self._access(cur_access, CXXSpell::vis_of(static_cast::<*Decl>(m)), false, at);
            self._cg->sink->spell(self._at(static_cast::<*Decl>(m)), self._method_decl(m, d));
        }

        // Each constructor that initializes a const field: its slot record,
        // its pre-function and the constructor that takes the slots
        // (_split_ctor_decls). Private: only the public constructor calls
        // them.
        for var i: usize = 0; i < methods.size(); ++i {
            var m = methods[i];
            if (m == &null) || (m->ci_split == 0) { continue; }
            cur_access = self._access(cur_access, VIS_PRIV(), false, at);
            self._split_ctor_decls(m, d);
        }

        // The comparisons derived from a member `op <=>` (_derived_cmps).
        cur_access = self._derived_cmps(d, cur_access, at);

        // `op =`, derived from the transfer constructor (_derived_assign).
        // Public, as C++'s implicit one is.
        if self._assign_form_of(d) != AssignForm::Implicit {
            cur_access = self._access(cur_access, VIS_PUB(), false, at);
            self._derived_assign(d);
        }

        self._friends(d);

        self._cg->sink->spell(at, "};");
        // `null_t`'s one value, `::builtin::null` to a C++ host. Inline, so
        // every TU that includes the record has it and none owns it.
        if isa::<StructDecl>(d) && cast::<StructDecl>(d)->is_null_type {
            self._cg->sink->spell(at, "inline constexpr " + self._spell->leaf(d) + " " + LowerTargets::null_constant() + "{};");
        }
        self._cg->sink->brk();
    }

    /// Friends: every same-file extension scope, so an extension member
    /// written beside the type can reach its privates. One line per scope
    /// covers every member, generic or not, and each struct was declared in
    /// tier 0, so its qualified name needs no other prior declaration. A
    /// record's and an ADT's (_adt_def) alike.
    priv fn _friends(self, d: *Decl) {
        var fs = vec::<*ExtScope>();
        self._plan->friend_scopes_of(d, &fs);
        for var i: usize = 0; i < fs.size(); ++i {
            self._cg->sink->spell(self._at(static_cast::<*Decl>(fs[i]->anchor)), "friend struct " + self._scope_qual(fs[i]) + ";");
        }
        if (fs.size() > 0) && self._cg->opts.extension_member_wrappers {
            self._ice(self._at(d), "InterfaceEmitter: extension_member_wrappers is on but wrapper emission is not written; leave it off");
        }
    }

    /// The derived `op =` slots ClassLifecycle wrote on a record; Implicit
    /// and null for anything else.
    priv fn _assign_form_of(self, d: *Decl) -> AssignForm {
        if isa::<ClassDecl>(d)  { return cast::<ClassDecl>(d)->assign_form; }
        if isa::<StructDecl>(d) { return cast::<StructDecl>(d)->assign_form; }
        return AssignForm::Implicit;
    }

    priv fn _assign_from_of(self, d: *Decl) -> *FunctionDecl {
        if isa::<ClassDecl>(d)  { return cast::<ClassDecl>(d)->assign_from; }
        if isa::<StructDecl>(d) { return cast::<StructDecl>(d)->assign_from; }
        return &null;
    }

    /// Some class this run writes carries an `op =` that rebuilds in place
    /// (Body, Constrained): tier 1, and the records _record_def nests in
    /// those. A header skips what it includes, as run() does.
    /// An `eval for` in this TU, or an eval generator the plan declares or
    /// defines here: both spell the eval helpers.
    priv fn _needs_eval_helpers(self) -> bool {
        if (self._cg->tu != &null) && self._cg->tu->has_eval_for { return true; }
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var f = dyn_cast::<FunctionDecl>(self._plan->entries[i].decl);
            if (f != &null) && f->is_eval() && f->is_generator { return true; }
        }
        return false;
    }

    priv fn _needs_new(self) -> bool {
        var header = (self._plan->mode() == PlanMode::Header);
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var e = &(self._plan->entries[i]);
            if (e->tier != PlanTier::Definitions) || (e->scope != &null) || (e->witness != &null) { continue; }
            if header && (!e->own) { continue; }
            if self._rebuilds(e->decl) { return true; }
        }
        return false;
    }

    priv fn _rebuilds(self, d: *Decl) -> bool {
        var form = self._assign_form_of(d);
        if (form == AssignForm::Body) || (form == AssignForm::Constrained) { return true; }
        if (!isa::<ClassDecl>(d)) && (!isa::<StructDecl>(d)) { return false; }
        var dc = CXXSpell::dc_of(d);
        if dc == &null { return false; }
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var nd = *(dc->dc_decls.get(i));
            if (nd == &null) || isa::<VisibilityGroupDecl>(nd) || (!self._is_type(nd)) { continue; }
            if self._rebuilds(CXXSpell::rep(nd)) { return true; }
        }
        return false;
    }

    /// The six comparisons OperatorTyping derives from a member `op <=>`,
    /// written into the class so a C++ host sees what a Kairo caller does.
    /// C++20 cannot find them itself: it rewrites `a < b` as `(a <=> b) < 0`,
    /// which `Ordering` -- a scoped enum, not a comparison category -- cannot
    /// answer, and it never derives `==` from a user `<=>` at all. Each is
    /// `bool operator<(<other>) [const] { return static_cast<signed char>(
    /// this->operator<=>(o)) < 0; }`, the operand and cv the `<=>`'s own, in
    /// the class (invariant 12's exception, as the derived `op =`), with the
    /// `<=>`'s access and anchored on it. A comparison the record declares
    /// is its own and wins in Kairo (OperatorSignatureCheck warns), so it is
    /// not written; nor is `!=` beside a declared `==`, which C++20 rewrites
    /// exactly as Kairo derives it. A generic `<=>` has no one operand to
    /// spell and derives nothing here. Returns the access in force.
    priv fn _derived_cmps(self, d: *Decl, cur: u8, at: SourceRange) -> u8 {
        var methods = (cast::<ClassDecl>(d)->methods) if (isa::<ClassDecl>(d)) else (cast::<StructDecl>(d)->methods);
        var has_eq = false;
        var declared = vec::<TokenKind>();
        for var i: usize = 0; i < methods.size(); ++i {
            var m = methods[i];
            if (m == &null) || (!m->is_operator) { continue; }
            var k = OperatorFacts::op_kind(m);
            // `not_eq` is `!=` to C++.
            if k == TokenKind::KwNotEq { k = TokenKind::OpExclaimEqual; }
            if k == TokenKind::OpEqualEqual { has_eq = true; }
            declared.push_back(k);
        }

        var ops = vec::<TokenKind>();
        ops.push_back(TokenKind::OpLess);
        ops.push_back(TokenKind::OpLessEqual);
        ops.push_back(TokenKind::OpGreater);
        ops.push_back(TokenKind::OpGreaterEqual);
        ops.push_back(TokenKind::OpEqualEqual);
        ops.push_back(TokenKind::OpExclaimEqual);
        var syms = vec::<string>();
        syms.push_back("<");
        syms.push_back("<=");
        syms.push_back(">");
        syms.push_back(">=");
        syms.push_back("==");
        syms.push_back("!=");

        var acc = cur;
        var sc8 = builtin_info(BuiltinKind::I8)->cxx;
        for var i: usize = 0; i < methods.size(); ++i {
            var m = methods[i];
            if (m == &null) || (!m->is_operator) || (!m->is_method()) { continue; }
            if OperatorFacts::op_kind(m) != TokenKind::OpLessEqualGreater { continue; }
            if self._spell->template_head(static_cast::<*Decl>(m)).size() > 0 { continue; }
            var other: *ParamDecl = &null;
            for var j: usize = 0; j < m->params.size(); ++j {
                var p = m->params[j];
                if (p != &null) && (!p->is_self) { other = p; break; }
            }
            if other == &null { continue; }   // OperatorSignatureCheck rejected it already.

            var mat   = self._at(static_cast::<*Decl>(m));
            var param = self._spell->param_decl(other, "o", &null, d);
            var quals = "";
            if m->is_const()  { quals += " const"; }
            if m->no_unwind   { quals += " noexcept"; }
            // Forwarded as the `<=>` takes it: a by-value or `&&` operand
            // is an lvalue `o` here and must be moved on.
            var call  = "static_cast<" + sc8 + ">(this->" + self._spell->leaf(m) + "(static_cast<decltype(o)&&>(o)))";
            for var j: usize = 0; j < ops.size(); ++j {
                var k = ops[j];
                var mine = false;
                for var q: usize = 0; q < declared.size(); ++q {
                    if declared[q] == k { mine = true; break; }
                }
                if mine { continue; }
                if (k == TokenKind::OpExclaimEqual) && has_eq { continue; }
                acc = self._access(acc, CXXSpell::vis_of(static_cast::<*Decl>(m)), false, at);
                self._cg->sink->spell(mat, "bool operator" + syms[j] + "(" + param + ")" + quals
                                         + " { return " + call + " " + syms[j] + " 0; }");
            }
        }
        return acc;
    }

    /// `X& operator=(...)`, as ClassLifecycle chose it (AssignForm). The
    /// operand is the transfer constructor's own `other`, so the
    /// constructor takes it exactly: `const X&` from `@copy fn X(self,
    /// const other: Self)`, `X&` without the `const`, `X&&` from `@move`.
    /// Anchored on the constructor, which it is derived from.
    priv fn _derived_assign(self, d: *Decl) {
        var form = self._assign_form_of(d);
        var x    = self._assign_from_of(d);
        if x == &null { self._ice(self._at(d), "InterfaceEmitter: a derived `op =` with no transfer constructor; ClassLifecycle gate failure"); }
        var other: *ParamDecl = &null;
        for var i: usize = 0; i < x->params.size(); ++i {
            var p = x->params[i];
            if (p != &null) && (!p->is_self) { other = p; break; }
        }
        if other == &null { self._ice(self._at(static_cast::<*Decl>(x)), "InterfaceEmitter: a transfer constructor with no `other`; ClassLifecycle gate failure"); }
        var xat   = self._at(static_cast::<*Decl>(x));
        var head  = self._spell->leaf(d) + "& operator=(";
        var bare  = head + self._spell->param_decl(other, "", &null, d) + ")";
        var named = head + self._spell->param_decl(other, "o", &null, d) + ")";
        switch form {
            case AssignForm::Default { self._cg->sink->spell(xat, bare + " = default;"); }
            case AssignForm::Deleted { self._cg->sink->spell(xat, bare + " = delete;"); }
            case AssignForm::Body    { self._cg->sink->spell(xat, named + self._rebuild(d, x)); }
            case AssignForm::Constrained {
                // Exactly one is viable in an instance, as with a generic
                // ADT's special members; the deleted one leaves an instance
                // that fails the constraint unassignable by name.
                var ok = self._rebuild_constraint(d);
                self._cg->sink->spell(xat, named + " requires (" + ok + ")" + self._rebuild(d, x));
                self._cg->sink->spell(xat, bare + " requires (!(" + ok + ")) = delete;");
            }
            default { 0; }
        }
    }

    /// ` { if (this != &o) { this->X::~X(); ::new (static_cast<void*>(this))
    /// X(o); } return *this; }` (`static_cast<X&&>(o)` from a `@move`
    /// constructor). Nothing on self-assignment: destroying first would
    /// leave nothing to build from. The destructor call is qualified, so it
    /// is never virtual: only X is rebuilt (a polymorphic record never gets
    /// here). The old value goes before the new one is built, not after
    /// building it aside: emitted C++ is compiled without exceptions, so the
    /// constructor cannot leave the record half-assigned. `::new` is the
    /// global placement form (<new>, _needs_new); X is the injected class
    /// name, template or not.
    priv fn _rebuild(self, d: *Decl, x: *FunctionDecl) -> string {
        var nm  = self._spell->leaf(d);
        var src = ("static_cast<" + nm + "&&>(o)") if (x->transfer == TransferKind::Move) else ("o");
        return " { if (this != &o) { this->" + nm + "::~" + nm + "(); ::new (static_cast<void*>(this)) "
             + nm + "(" + src + "); } return *this; }";
    }

    /// What a Constrained `op =` asks of an instance: every by-value field
    /// whose type depends on a generic parameter destructible, and every
    /// such base destructible and not polymorphic -- what ClassLifecycle
    /// could not decide in the pattern (_has_dependent_part walks the same
    /// lists with the same test). Traits over the parts, never over the
    /// record: inside its own body the record is incomplete, and clang
    /// rejects a trait on it there.
    priv fn _rebuild_constraint(self, d: *Decl) -> string {
        var s = "";
        if isa::<ClassDecl>(d) {
            var c = cast::<ClassDecl>(d);
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var e = c->derives_list.get(i);
                if (e == &null) || (!self._dependent(e->base)) { continue; }
                var b = self._spell->_type(e->base);
                if s.size() > 0 { s += " && "; }
                s += "__is_destructible(" + b + ") && !__is_polymorphic(" + b + ")";
            }
        }
        var fields = (cast::<ClassDecl>(d)->fields) if (isa::<ClassDecl>(d)) else (cast::<StructDecl>(d)->fields);
        for var i: usize = 0; i < fields.size(); ++i {
            var f = fields[i];
            if (f == &null) || f->is_static() || (!self._dependent(f->type_)) { continue; }
            if s.size() > 0 { s += " && "; }
            s += "__is_destructible(" + self._spell->_type(f->type_, &null, d) + ")";
        }
        if s.size() == 0 { self._ice(self._at(d), "InterfaceEmitter: a constrained `op =` with no dependent part; ClassLifecycle gate failure"); }
        return s;
    }

    /// The type depends on a generic parameter (ClassLifecycle's test for
    /// an open part).
    priv fn _dependent(self, t: *Type) -> bool {
        if (t == &null) || (t->canonical == &null) { return false; }
        var c = canon_unqual(t->canonical);
        return c->is_dependent() || c->is_instantiation_dependent();
    }

    /// `union { T a; U b; };`: an anonymous union, written where its field
    /// is. Its members are the owner's members to C++ and take the access
    /// in force for the field, so no specifier goes inside. Each member is
    /// spelled as an ordinary field would be, \p owner's body being the
    /// scope its types are named from. The layout is clang's.
    priv fn _anon_union_field(self, f: *FieldDecl, owner: *Decl) {
        var u = self._plan->anon_union_of(f);
        var fat = self._at(static_cast::<*Decl>(f));
        self._cg->sink->spell(fat, "union {");
        for var i: usize = 0; i < u->fields.size(); ++i {
            var m = u->fields[i];
            if m == &null { continue; }
            var ms = self._spell->decl(m->type_, self._spell->leaf(static_cast::<*Decl>(m)), &null, owner);
            ms += ";";
            self._cg->sink->spell(self._at(static_cast::<*Decl>(m)), ms);
        }
        self._cg->sink->spell(fat, "};");
    }

    priv fn _is_type(self, d: *Decl) -> bool {
        return (d->kind == DeclKind::ClassDecl) || (d->kind == DeclKind::StructDecl)
            || (d->kind == DeclKind::EnumDecl)  || (d->kind == DeclKind::UnionDecl);
    }

    /// Emit an access specifier when the member's visibility differs from
    /// the running one. `prot` is `protected`.
    /// \p default_priv: an unmarked member of this kind is private (a class's
    /// variables, and nothing else).
    priv fn _access(self, cur: u8, want_in: u8, default_priv: bool, at: SourceRange) -> u8 {
        var want = want_in;
        if want == VIS_NONE() { want = (VIS_PRIV()) if (default_priv) else (VIS_PUB()); }
        if want == cur { return cur; }
        if want == VIS_PUB()  { self._cg->sink->spell(at, "public:"); }
        if want == VIS_PROT() { self._cg->sink->spell(at, "protected:"); }
        if want == VIS_PRIV() { self._cg->sink->spell(at, "private:"); }
        self._cg->sink->brk();
        return want;
    }

    priv fn _base_access(self, v: u8) -> string {
        if v == VIS_PRIV() { return "private"; }
        if v == VIS_PROT() { return "protected"; }
        return "public";
    }

    priv fn _enum_def(self, en: *EnumDecl) {
        // An ADT is written as the record EnumLayoutLowering built for it; a
        // plain enum, an ADT's tag enum included, as an `enum class`.
        var rec = self._plan->adt_record(static_cast::<*Decl>(en));
        if rec != static_cast::<*Decl>(en) {
            self._adt_def(en, cast::<StructDecl>(rec));
            return;
        }
        if (en->is_adt) { self._ice(self._at(static_cast::<*Decl>(en)), "InterfaceEmitter: ADT enum reached codegen without its layout record; sema stopped before EnumLayoutLowering"); }
        var at = self._at(static_cast::<*Decl>(en));
        var s = "enum class ";
        s += self._spell->leaf(static_cast::<*Decl>(en));
        s += " : ";
        s += self._enum_underlying(en);
        s += " {";
        self._cg->sink->spell(at, s);
        // With no discriminant anywhere every value is its position, which
        // is C++'s own numbering, so the names go out bare. That is also the
        // only form an enum the compiler mints can take: it is built after
        // X, so its value slots were never written.
        var numbered = false;
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if (v != &null) && (v->discriminant != &null) { numbered = true; break; }
        }
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if v == &null { continue; }
            var vs = self._spell->leaf(static_cast::<*Decl>(v));
            if numbered {
                // Every variant, written discriminant or not, gets the value
                // X computed: the source text of a discriminant may name
                // other variants or constants C++ cannot see by those names.
                // Not ok only after an error X reported; --print-cxx still
                // renders such a TU, and a bare name is the harmless form.
                if v->value.ok { vs += " = " + self._enum_value(v->value); }
            }
            vs += ",";
            self._cg->sink->spell(v->name.range, vs);
        }
        self._cg->sink->spell(at, "};");
        self._cg->sink->brk();
    }

    /// An ADT enum: the record EnumLayoutLowering built for it, written
    /// under the enum's own name and template head in place of an `enum
    /// class`, in the record's order -- the tag enum and the payload
    /// structs, the tag, the anonymous union, the flags, the role functions
    /// -- then the friends. Every type inside is spelled with the ENUM as
    /// its scope: the record's members belong to it (their semantic_dc), so
    /// its nested types go out by leaf, as a record's own do in _record_def.
    priv fn _adt_def(self, en: *EnumDecl, lay: *StructDecl) {
        var d       = static_cast::<*Decl>(en);
        var at      = self._at(d);
        var nm      = self._spell->leaf(d);
        var generic = CXXSpell::template_params(d).size() > 0;
        self._cg->sink->spell(at, self._spell->template_head(d) + "struct " + nm + " {");

        // A struct: public unless marked. Only the two helpers the special
        // members call are private. The tag must stay public: `==` on an ADT
        // is a compare of two values' tags, written by OperatorLowering in
        // the user's code, outside the record.
        var cur_access = VIS_PUB();
        var dc = static_cast::<*DeclContext>(lay);
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var nd = *(dc->dc_decls.get(i));
            if (nd == &null) || (!self._is_type(nd)) { continue; }
            // Written where its field is (_anon_union_field).
            if isa::<UnionDecl>(nd) && cast::<UnionDecl>(nd)->is_anonymous { continue; }
            cur_access = self._access(cur_access, CXXSpell::vis_of(nd), false, at);
            self._type_def(CXXSpell::rep(nd));
        }

        for var i: usize = 0; i < lay->fields.size(); ++i {
            var f = lay->fields[i];
            if f == &null { continue; }
            cur_access = self._access(cur_access, CXXSpell::vis_of(static_cast::<*Decl>(f)), false, at);
            if f->is_anonymous_union { self._anon_union_field(f, d); continue; }
            var fnm = self._spell->leaf(static_cast::<*Decl>(f));
            // A flag: a compile-time constant with no Kairo expression behind
            // it (_adt_flag).
            if f->storage == StorageClass::Eval {
                self._cg->sink->spell(f->name.range, "static constexpr bool " + fnm + " = " + self._adt_flag(lay, f, fnm) + ";");
                continue;
            }
            self._cg->sink->spell(f->name.range, self._spell->decl(f->type_, fnm, &null, d) + ";");
        }

        for var i: usize = 0; i < lay->methods.size(); ++i {
            var m = lay->methods[i];
            if m == &null { continue; }
            cur_access = self._access(cur_access, CXXSpell::vis_of(static_cast::<*Decl>(m)), false, at);
            self._cg->sink->spell(self._at(static_cast::<*Decl>(m)), self._adt_member(en, m, nm, generic));
        }

        self._friends(d);

        self._cg->sink->spell(at, "};");
        self._cg->sink->brk();
    }

    /// A flag's initializer: its type trait over every payload struct,
    /// joined with `&&`. Which flag it is is read off the name LowerTargets
    /// gave it; the structs go by leaf, the text being inside the record.
    priv fn _adt_flag(self, lay: *StructDecl, f: *FieldDecl, nm: string) -> string {
        var s  = "";
        var dc = static_cast::<*DeclContext>(lay);
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var ps = dyn_cast::<StructDecl>(*(dc->dc_decls.get(i)));
            if (ps == &null) || (!ps->is_adt_payload) { continue; }
            var p    = self._spell->leaf(static_cast::<*Decl>(ps));
            var term = "";
            if nm == LowerTargets::adt_trivial_dtor()      { term = "__is_trivially_destructible(" + p + ")"; }
            else if nm == LowerTargets::adt_trivial_copy() { term = "__is_trivially_copyable(" + p + ")"; }
            else if nm == LowerTargets::adt_destructible() { term = "__is_destructible(" + p + ")"; }
            else if nm == LowerTargets::adt_copyable()     { term = "__is_constructible(" + p + ", const " + p + "&)"; }
            else if nm == LowerTargets::adt_movable()      { term = "__is_constructible(" + p + ", " + p + "&&)"; }
            else { self._ice(self._at(static_cast::<*Decl>(f)), f"InterfaceEmitter: ADT record field '{nm}' is compile-time but none of the five flags"); }
            if s.size() > 0 { s += " && "; }
            s += term;
        }
        if s.size() == 0 { self._ice(self._at(static_cast::<*Decl>(f)), "InterfaceEmitter: an ADT record with flags and no payload struct; EnumLayoutLowering gate failure"); }
        return s;
    }

    /// The C++ constraint that selects \p m's form among the three a generic
    /// ADT declares; "" for a non-generic one, which declares only the form
    /// its facts chose (a constraint on a non-templated function is
    /// ill-formed). Built from the flag names: C++ mechanics, never a Kairo
    /// requires_clause.
    priv fn _adt_requires(self, m: *FunctionDecl, generic: bool) -> string {
        if !generic { return ""; }
        if m->adt_role == AdtRole::Dtor {
            var td = LowerTargets::adt_trivial_dtor();
            var ds = LowerTargets::adt_destructible();
            switch m->adt_form {
                case AdtForm::Trivial { return " requires " + td; }
                case AdtForm::Body    { return " requires (!" + td + " && " + ds + ")"; }
                case AdtForm::Deleted { return " requires (!" + ds + ")"; }
            }
            return "";
        }
        var tc = LowerTargets::adt_trivial_copy();
        var copying = (m->adt_role == AdtRole::CopyCtor) || (m->adt_role == AdtRole::CopyAssign);
        var ok = (LowerTargets::adt_copyable()) if (copying) else (LowerTargets::adt_movable());
        switch m->adt_form {
            case AdtForm::Trivial { return " requires " + tc; }
            case AdtForm::Body    { return " requires (!" + tc + " && " + ok + ")"; }
            case AdtForm::Deleted { return " requires (!" + tc + " && !" + ok + ")"; }
        }
        return "";
    }

    /// The payload struct holding \p v, by leaf, read off its union member.
    priv fn _payload_leaf(self, v: *EnumVariantDecl) -> string {
        var t = v->adt_member->type_;
        var c: *Type = &null;
        if (t != &null) && (t->canonical != &null) { c = canon_unqual(t->canonical); }
        if (c == &null) || (!isa::<RecordType>(c)) {
            self._ice(self._at(static_cast::<*Decl>(v)), "InterfaceEmitter: an ADT union member whose type is not its payload struct; EnumLayoutLowering gate failure");
        }
        return self._spell->leaf(cast::<RecordType>(c)->decl);
    }

    /// One role function of an ADT's record as C++ text. None has a Kairo
    /// body (EnumLayoutLowering's header says why): the text is a function
    /// of the role, the form and whether the enum is generic, every invented
    /// name from LowerTargets and every other from the record's own decls.
    priv fn _adt_member(self, en: *EnumDecl, m: *FunctionDecl, nm: string, generic: bool) -> string {
        if adt_role_is_nullable(m->adt_role) { return self._nullable_member(en, m, nm); }
        var tag  = LowerTargets::adt_tag_field();
        var tt   = LowerTargets::adt_tag_type();
        var ds   = LowerTargets::adt_destroy();
        var cf   = LowerTargets::adt_construct_from();
        var req  = self._adt_requires(m, generic);
        var tail = (" = default;") if (m->adt_form == AdtForm::Trivial) else (" = delete;");
        var body = m->adt_form == AdtForm::Body;
        switch m->adt_role {
            case AdtRole::VariantCtor {
                if usize(m->adt_variant) >= en->variants.size() {
                    self._ice(self._at(static_cast::<*Decl>(m)), "InterfaceEmitter: an ADT variant constructor past the last variant; EnumLayoutLowering gate failure");
                }
                var v    = en->variants[usize(m->adt_variant)];
                var vt   = "::" + LowerTargets::adt_variant_tag() + f"<{m->adt_variant}>";
                var init = tag + "(" + tt + "::" + self._spell->leaf(static_cast::<*Decl>(v)) + ")";
                if v->adt_member == &null { return nm + "(" + vt + ") : " + init + " {}"; }
                // The payload is the callable's prvalue, so the union member
                // is built straight from it: nothing is copied or moved.
                return "template <class F> " + nm + "(" + vt + ", F&& f) : " + init + ", "
                     + self._spell->leaf(static_cast::<*Decl>(v->adt_member)) + "(static_cast<F&&>(f)()) {}";
            }
            case AdtRole::CopyCtor {
                if body { return nm + "(const " + nm + "& o)" + req + " : " + tag + "(o." + tag + ") { " + cf + "(o); }"; }
                return nm + "(const " + nm + "&)" + req + tail;
            }
            case AdtRole::MoveCtor {
                if body { return nm + "(" + nm + "&& o)" + req + " : " + tag + "(o." + tag + ") { " + cf + "(static_cast<" + nm + "&&>(o)); }"; }
                return nm + "(" + nm + "&&)" + req + tail;
            }
            case AdtRole::CopyAssign {
                // Destroying first would leave a self-assignment nothing to
                // copy from, so it does nothing instead.
                if body {
                    return nm + "& operator=(const " + nm + "& o)" + req + " { if (this != &o) { " + ds + "(); "
                         + tag + " = o." + tag + "; " + cf + "(o); } return *this; }";
                }
                return nm + "& operator=(const " + nm + "&)" + req + tail;
            }
            case AdtRole::MoveAssign {
                if body {
                    return nm + "& operator=(" + nm + "&& o)" + req + " { if (this != &o) { " + ds + "(); "
                         + tag + " = o." + tag + "; " + cf + "(static_cast<" + nm + "&&>(o)); } return *this; }";
                }
                return nm + "& operator=(" + nm + "&&)" + req + tail;
            }
            case AdtRole::Dtor {
                if body { return "~" + nm + "()" + req + " { " + ds + "(); }"; }
                return "~" + nm + "()" + req + tail;
            }
            case AdtRole::Destroy {
                var s = "void " + ds + "() noexcept { switch (" + tag + ") {";
                for var i: usize = 0; i < en->variants.size(); ++i {
                    var v = en->variants[i];
                    if (v == &null) || (v->adt_member == &null) { continue; }
                    var mem = self._spell->leaf(static_cast::<*Decl>(v->adt_member));
                    s += " case " + tt + "::" + self._spell->leaf(static_cast::<*Decl>(v)) + ": " + mem + ".~" + self._payload_leaf(v) + "(); break;";
                }
                return s + " default: break; } }";
            }
            case AdtRole::ConstructFrom {
                // `new` finds the payload struct's own placement form, which
                // needs no <new>.
                var s = "template <class O> void " + cf + "(O&& o) { switch (" + tag + ") {";
                for var i: usize = 0; i < en->variants.size(); ++i {
                    var v = en->variants[i];
                    if (v == &null) || (v->adt_member == &null) { continue; }
                    var mem = self._spell->leaf(static_cast::<*Decl>(v->adt_member));
                    s += " case " + tt + "::" + self._spell->leaf(static_cast::<*Decl>(v)) + ": new (&" + mem + ") "
                       + self._payload_leaf(v) + "(static_cast<O&&>(o)." + mem + "); break;";
                }
                return s + " default: break; } }";
            }
            default { 0; }
        }
        self._ice(self._at(static_cast::<*Decl>(m)), "InterfaceEmitter: an ADT role function with no rendering; EnumLayoutLowering minted a role this emitter does not know");
        return "";
    }

    /// One member of the Nullable lang item's surface (AdtRole, from
    /// NullDefault on). The enum is `Value { v: T }, Null` and nothing else
    /// (Lib/builtin/module.k): the present variant is the one with a
    /// payload, the null one the one without, and both are found, not
    /// assumed.
    priv fn _nullable_member(self, en: *EnumDecl, m: *FunctionDecl, nm: string) -> string {
        var at  = self._at(static_cast::<*Decl>(m));
        var tag = LowerTargets::adt_tag_field();
        var tt  = LowerTargets::adt_tag_type();
        var some: *EnumVariantDecl = &null;
        var none: *EnumVariantDecl = &null;
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if v == &null { continue; }
            if v->adt_member != &null { some = v; } else { none = v; }
        }
        if (some == &null) || (none == &null) || (some->payload.size() != 1) {
            self._ice(at, "InterfaceEmitter: the Nullable lang item is not one one-field variant and one empty one");
            return "";
        }
        var d     = static_cast::<*Decl>(en);
        var mem   = self._spell->leaf(static_cast::<*Decl>(some->adt_member));
        var field = some->payload[0];
        var fld   = self._spell->leaf(static_cast::<*Decl>(field));
        var t     = self._spell->decl(field->type_, "", &null, d);
        var null_tag = tt + "::" + self._spell->leaf(static_cast::<*Decl>(none));
        var is_null = tag + " == " + null_tag;
        var null_init    = " : " + tag + "(" + null_tag + ") {}";
        var present_init = tag + "(" + tt + "::" + self._spell->leaf(static_cast::<*Decl>(some)) + "), " + mem;
        var val = LowerTargets::nullable_value();
        switch m->adt_role {
            case AdtRole::NullDefault { return nm + "()" + null_init; }
            case AdtRole::NullFrom {
                if m->params.size() != 1 { self._ice(at, "InterfaceEmitter: Nullable(null_t) without its parameter"); return ""; }
                return nm + "(" + self._spell->decl(m->params[0]->type_, "", &null, d) + ")" + null_init;
            }
            // Brace-initialized: the payload struct is an aggregate, so its
            // one field is built straight from the argument. Constrained by
            // the ADT's own flags, because an explicit instantiation defines
            // every member whose constraints hold: an unconstrained copy
            // constructor of a `Nullable<MoveOnly>` is a hard error there.
            case AdtRole::ValueCopy {
                return nm + "(const " + t + "& v) requires " + LowerTargets::adt_copyable() + " : " + present_init + "{v} {}";
            }
            case AdtRole::ValueMove {
                return nm + "(" + t + "&& v) requires " + LowerTargets::adt_movable() + " : " + present_init + "{static_cast<" + t + "&&>(v)} {}";
            }
            case AdtRole::IsNull    { return "bool " + LowerTargets::nullable_is_null() + "() const { return " + is_null + "; }"; }
            case AdtRole::ValueRef  { return t + "& " + val + "() { return " + mem + "." + fld + "; }"; }
            case AdtRole::ValueCref { return "const " + t + "& " + val + "() const { return " + mem + "." + fld + "; }"; }
            case AdtRole::Equal {
                return "bool operator==(const " + nm + "& o) const requires requires (const " + t + "& a) { a == a; } { return "
                     + tag + " == o." + tag + " && ((" + is_null + ") || " + mem + "." + fld + " == o." + mem + "." + fld + "); }";
            }
            default { 0; }
        }
        self._ice(at, "InterfaceEmitter: a Nullable role with no rendering");
        return "";
    }

    /// A field's C++ default member initializer, from what
    /// FieldInitLowering made of its Kairo one: a constant as it is, or a
    /// call of the member function holding the expression, named by leaf (a
    /// default member initializer sees the whole class, that member's later
    /// declaration included). Either way the text names nothing outside the
    /// record, so the class stays a pure function of the decl.
    priv fn _field_default(self, f: *FieldDecl) -> string {
        switch f->init_fold {
            case FieldFold::Int {
                var c = IntConst{};
                c.ok  = true;
                c.neg = f->init_neg;
                c.mag = f->init_mag;
                return " = " + self._enum_value(c);
            }
            case FieldFold::True  { return " = true"; }
            case FieldFold::False { return " = false"; }
            case FieldFold::Null  { return " = nullptr"; }
            case FieldFold::Thunk { return " = " + self._spell->leaf(f->init_thunk) + "()"; }
            default { 0; }
        }
        // An initializer still on the field is one FeatureGateCheck rejects
        // (an array-typed field) and FieldInitLowering leaves.
        if f->init != &null {
            self._ice(f->name.range, "InterfaceEmitter: initializer of an array-typed field reached codegen; FeatureGateCheck rejects it");
        }
        return "";
    }

    // --- Const fields in a constructor ----------------------------------------------

    /// True when some record the plan defines has a split constructor.
    priv fn _needs_ctor_slots(self) -> bool {
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var e = &(self._plan->entries[i]);
            if (e->tier != PlanTier::Definitions) || (e->scope != &null) || (e->witness != &null) { continue; }
            if self._has_split_ctor(e->decl) { return true; }
        }
        return false;
    }

    priv fn _has_split_ctor(self, d: *Decl) -> bool {
        if (d == &null) || ((!isa::<ClassDecl>(d)) && (!isa::<StructDecl>(d))) { return false; }
        var methods = (cast::<ClassDecl>(d)->methods) if (isa::<ClassDecl>(d)) else (cast::<StructDecl>(d)->methods);
        for var i: usize = 0; i < methods.size(); ++i {
            if (methods[i] != &null) && (methods[i]->ci_split > 0) { return true; }
        }
        var dc = CXXSpell::dc_of(d);
        if dc == &null { return false; }
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var nd = *(dc->dc_decls.get(i));
            if (nd != &null) && self._has_split_ctor(CXXSpell::rep(nd)) { return true; }
        }
        return false;
    }

    /// `__kairo_lref<T>` is `T&` for every parameter spelling, `T&` and
    /// `T&&` included (reference collapsing), so the pre-function and the
    /// slot constructor take each parameter as the public one's lvalue.
    /// `__kairo_slot<T>` holds a T that does not exist until S_pre first
    /// assigns it: raw storage in a union, built in place through its box's
    /// own placement operator new (no <new>, as an ADT payload's), and
    /// destroyed only if it was built. It is never copied or moved: the
    /// slot record is a temporary the public constructor passes by
    /// reference. `init` is a first assignment (a const field, a local);
    /// `put` may be a later one (a `var` field written twice), so only it
    /// asks T for `operator=`.
    priv fn _ctor_slot_helpers(self, header: bool) {
        var at = self._tu_at();
        if header { self._cg->sink->directive(at, "#ifndef " + LowerTargets::ctor_slot_guard()); }
        if header { self._cg->sink->directive(at, "#define " + LowerTargets::ctor_slot_guard()); }
        self._cg->sink->spell(at, "template <class T> using " + LowerTargets::lref() + " = T&;");
        self._cg->sink->brk();
        var sl = LowerTargets::ctor_slot();
        var sz = builtin_info(BuiltinKind::USize)->cxx;
        var t = "template <class T> struct " + sl + " {";
        t += " struct __b { T v; static void* operator new(" + sz + ", void* p) noexcept { return p; } };";
        t += " union { __b b; };";
        t += " bool set = false;";
        t += " " + sl + "() noexcept {}";
        t += " " + sl + "(const " + sl + "&) = delete;";
        t += " " + sl + "& operator=(const " + sl + "&) = delete;";
        t += " ~" + sl + "() { if (set) { b.~__b(); } }";
        t += " void init(T u) { new (static_cast<void*>(&b)) __b{static_cast<T&&>(u)}; set = true; }";
        t += " void put(T u) { if (set) { b.v = static_cast<T&&>(u); } else { init(static_cast<T&&>(u)); } }";
        t += " T& get() noexcept { return b.v; }";
        t += " T&& take() noexcept { return static_cast<T&&>(b.v); }";
        t += " };";
        self._cg->sink->spell(at, t);
        self._cg->sink->brk();
        if header { self._cg->sink->directive(at, "#endif"); }
    }

    /// `::__kairo_fn<R(A...)>`, the C++ type of a Kairo `fn(A) -> R` value
    /// (CXXSpell, CODEGEN.md §6 Closures). One of:
    ///   - empty (a default-constructed `fn` local);
    ///   - a plain function pointer `__f`: a named function, or a closure
    ///     that captures nothing (`+[](...){...}`);
    ///   - a heap lambda `__o` with its three operations `__t`: a closure
    ///     that captures, adopted by `own(new auto([...](...){...}))`. The
    ///     lambda is built in its heap slot from the prvalue (no temporary,
    ///     so each captured copy is made once and destroyed once).
    /// Copying copies the lambda (each copy keeps its own captured copies,
    /// as copying a C++ lambda does); a lambda with a move-only capture
    /// cannot be copied, and copying one traps. Calling forwards each
    /// argument as its parameter type. Converting to `R(*)(A...)` -- a C
    /// callee's parameter, a C struct's field -- yields the function, and
    /// traps on a capturing closure, which has none. No library header:
    /// `new`/`delete` of a lambda need none, and `__builtin_trap` is
    /// clang's.
    priv fn _fn_value_helper(self, header: bool) {
        var at = self._tu_at();
        var fv = LowerTargets::fn_value();
        if header { self._cg->sink->directive(at, "#ifndef " + LowerTargets::fn_value_guard()); }
        if header { self._cg->sink->directive(at, "#define " + LowerTargets::fn_value_guard()); }
        self._cg->sink->spell(at, "template <class S> class " + fv + ";");
        self._cg->sink->brk();
        // The call path is a Kairo frame: noexcept unless -funwind, as the
        // closures it holds are.
        var nx = (("") if (self._cg->opts.unwind) else (" noexcept"));
        var t = "template <class R, class... A> class " + fv + "<R(A...)> {";
        t += " using __ptr = R (*)(A...);";
        t += " struct __ops { R (*call)(void*, A&&...)" + nx + "; void* (*copy)(const void*); void (*drop)(void*) noexcept; };";
        t += " template <class F> static R __call(void* o, A&&... a)" + nx + " { return (*static_cast<F*>(o))(static_cast<A&&>(a)...); }";
        t += " template <class F> static void* __copy(const void* o) {";
        t +=   " if constexpr (requires (const F& f) { F(f); }) { return new F(*static_cast<const F*>(o)); }";
        t +=   " else { __builtin_trap(); } }";
        t += " template <class F> static void __drop(void* o) noexcept { delete static_cast<F*>(o); }";
        t += " template <class F> static constexpr __ops __ops_of{&__call<F>, &__copy<F>, &__drop<F>};";
        t += " __ptr __f = nullptr;";
        t += " void* __o = nullptr;";
        t += " const __ops* __t = nullptr;";
        t += " public:";
        t += " " + fv + "() noexcept {}";
        t += " " + fv + "(__ptr f) noexcept : __f(f) {}";
        t += " template <class F> static " + fv + " " + LowerTargets::fn_value_own() + "(F* o) noexcept { " + fv + " r; r.__o = o; r.__t = &__ops_of<F>; return r; }";
        t += " " + fv + "(const " + fv + "& o) : __f(o.__f), __o(o.__o ? o.__t->copy(o.__o) : nullptr), __t(o.__t) {}";
        t += " " + fv + "(" + fv + "&& o) noexcept : __f(o.__f), __o(o.__o), __t(o.__t) { o.__o = nullptr; }";
        t += " " + fv + "& operator=(" + fv + " o) noexcept {";
        t +=   " __ptr f = __f; void* p = __o; const __ops* q = __t;";
        t +=   " __f = o.__f; __o = o.__o; __t = o.__t; o.__f = f; o.__o = p; o.__t = q; return *this; }";
        t += " ~" + fv + "() { if (__o) { __t->drop(__o); } }";
        t += " R operator()(A... a) const" + nx + " { if (__o) { return __t->call(__o, static_cast<A&&>(a)...); } return __f(static_cast<A&&>(a)...); }";
        t += " operator __ptr() const noexcept { if (__o) { __builtin_trap(); } return __f; }";
        t += " };";
        self._cg->sink->spell(at, t);
        self._cg->sink->brk();
        if header { self._cg->sink->directive(at, "#endif"); }
    }

    /// In the class, for split constructor \p m (FunctionDecl::ci_split):
    ///   struct __kairo_ciK;
    ///   static auto __kairo_ctor_preK(__kairo_ciK&& __kairo_s, __kairo_lref<P> p...) -> __kairo_ciK&;
    ///   R(__kairo_ciK& __kairo_s, __kairo_lref<P> p...);
    /// The slot record is only declared: its members name the types of
    /// locals the class itself never needs complete, and it is defined
    /// beside the bodies (EmitIR::_split_ctor). The trailing return keeps a
    /// generic owner's out-of-line definition free of `typename`.
    priv fn _split_ctor_decls(self, m: *FunctionDecl, owner: *Decl) {
        var at = self._at(static_cast::<*Decl>(m));
        var ci = LowerTargets::ctor_slots(m->ci_index);
        var sa = LowerTargets::ctor_slot_arg();
        var ps = self._lref_params(m, owner);
        self._cg->sink->spell(at, "struct " + ci + ";");
        self._cg->sink->spell(at, "static auto " + LowerTargets::ctor_pre(m->ci_index) + "(" + ci + "&& " + sa + ps + ") -> " + ci + "&;");
        self._cg->sink->spell(at, self._spell->leaf(owner) + "(" + ci + "& " + sa + ps + ");");
    }

    /// `, __kairo_lref<P> p` per parameter but `self`, in order.
    priv fn _lref_params(self, m: *FunctionDecl, owner: *Decl) -> string {
        var s = "";
        for var i: usize = 0; i < m->params.size(); ++i {
            var p = m->params[i];
            if (p == &null) || p->is_self { continue; }
            s += ", ::" + LowerTargets::lref() + "<" + self._spell->param_type(p, &null, owner) + "> ";
            s += self._spell->imm_name(p->name.imm, CXXSpell::fid_of(static_cast::<*Decl>(m)));
        }
        return s;
    }

    /// The definitions of \p d's static fields and of every nested record's,
    /// after \p d's closing brace (file header, Static fields). \p d is the
    /// outermost record of a tier-1 entry; anything else has no statics.
    priv fn _static_defs(self, d: *Decl) {
        if (!isa::<ClassDecl>(d)) && (!isa::<StructDecl>(d)) { return; }
        var fields = (cast::<ClassDecl>(d)->fields) if (isa::<ClassDecl>(d)) else (cast::<StructDecl>(d)->fields);
        for var i: usize = 0; i < fields.size(); ++i {
            var f = fields[i];
            if (f == &null) || (!f->is_static()) || f->is_anonymous_union { continue; }
            self._static_def(f, d);
        }
        var dc = CXXSpell::dc_of(d);
        if dc == &null { return; }
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var nd = *(dc->dc_decls.get(i));
            if nd == &null { continue; }
            if isa::<ClassDecl>(nd) || isa::<StructDecl>(nd) { self._static_defs(CXXSpell::rep(nd)); }
        }
    }

    /// `[template <...>] inline [constinit] [thread_local] T R::s = init;`.
    /// The initializer of a static member's definition is in its class's
    /// scope, so a thunk is called by leaf, as a default calls it.
    priv fn _static_def(self, f: *FieldDecl, owner: *Decl) {
        // A thunked eval field is defined after its consteval thunk's body,
        // which a constant expression needs DEFINED (EmitIR::_eval_field_def).
        if f->is_eval() && (f->init_fold == FieldFold::Thunk) { return; }
        var s = self._owner_template_head(owner);
        s += "inline ";
        var folded = (f->init_fold == FieldFold::Int) || (f->init_fold == FieldFold::True) || (f->init_fold == FieldFold::False) || (f->init_fold == FieldFold::Null);
        if f->is_eval()  { s += "constexpr "; }
        else if folded   { s += "constinit "; }
        if f->is_thread { s += "thread_local "; }
        // The class body declared it `static const T s;` (`static const`
        // member); C++ rejects a definition whose type drops the const.
        if f->is_const() || f->is_eval() { s += "const "; }
        var nm = self._owner_qual(owner) + "::" + self._spell->leaf(static_cast::<*Decl>(f));
        s += self._spell->decl(f->type_, nm);
        if f->init_fold == FieldFold::None {
            if f->init != &null { self._ice(f->name.range, "InterfaceEmitter: a static field's initializer reached codegen unlowered; FieldInitLowering lowers every one"); }
            s += "{}";
        } else {
            s += self._field_default(f);
        }
        s += ";";
        self._cg->sink->spell(f->name.range, s);
    }

    /// `template <class T>` for each generic owner, outermost first. EmitIR's
    /// rule for an out-of-line member (EmitIR::_owner_template_head).
    priv fn _owner_template_head(self, owner: *Decl) -> string {
        var chain = self._owner_chain(owner);
        var s = "";
        for var i: usize = 0; i < chain.size(); ++i { s += self._spell->template_head(chain[i]); }
        return s;
    }

    /// `Outer<T>::Inner<U>`, each generic owner with its own parameters as
    /// its arguments, relative to the outermost record's namespace wrapper
    /// (EmitIR::_owner_qual).
    priv fn _owner_qual(self, owner: *Decl) -> string {
        var chain = self._owner_chain(owner);
        var s = "";
        for var i: usize = 0; i < chain.size(); ++i {
            if i > 0 { s += "::"; }
            s += self._spell->owner_segment(chain[i]);
        }
        return s;
    }

    /// Type owners from outermost to \p owner inclusive (EmitIR::_owner_chain).
    priv fn _owner_chain(self, owner: *Decl) -> vec::<*Decl> {
        var rev = vec::<*Decl>();
        rev.push_back(CXXSpell::rep(owner));
        var dc = reinterpret_cast::<*DeclContext>(owner->semantic_dc);
        while (dc != &null) && dc->is_type_scope() && (dc->dc_kind != DeclContextKind::Extension) {
            rev.push_back(CXXSpell::rep(dc->dc_owner));
            dc = dc->dc_parent;
        }
        var out = vec::<*Decl>();
        for var i: usize = 0; i < rev.size(); ++i { out.push_back(rev[rev.size() - 1 - i]); }
        return out;
    }

    /// A C++ enumerator value. The 64-bit minimum has no literal (its
    /// magnitude is no long long), so it is spelled as an expression; a
    /// magnitude past the long long range takes `u`, which keeps clang from
    /// warning that the literal is too large for a signed type.
    priv fn _enum_value(self, c: IntConst) -> string {
        var min_mag = u64(1) << u64(63);
        if c.neg {
            if c.mag == min_mag { return "(-9223372036854775807 - 1)"; }
            return f"-{c.mag}";
        }
        if c.mag >= min_mag { return f"{c.mag}u"; }
        return f"{c.mag}";
    }

    // --- Functions ---------------------------------------------------------------------

    /// A method declaration inside its class. `self` is dropped (it is
    /// `this`); a function without `self` is `static`.
    priv fn _method_decl(self, m: *FunctionDecl, owner: *Decl) -> string {
        var s = self._spell->template_head(static_cast::<*Decl>(m));
        var is_ctor = self._is_ctor(m, owner);
        // One spelling, computed once. `op delete` comes back from leaf() as
        // `~Owner` already, so the leading `~` IS the destructor test -- there
        // is no second place that knows how a destructor is named.
        var nm = self._spell->leaf(m);
        var is_dtor = m->is_operator && (nm[0] == '~');
        // `op as` spells `operator T`; C++ gives a conversion no return type.
        var is_conv = m->is_operator && (m->op_token[0].kind == TokenKind::KwAs);
        var is_method = m->is_method();

        if (!is_method) && (!is_ctor) && !is_dtor { s += "static "; }
        if (m->abi == AbiKind::Virtual) || (m->abi == AbiKind::Override) || (m->body_kind == FnBodyKind::Virtual) { s += "virtual "; }
        if m->is_noreturn { s += "[[noreturn]] "; }
        // EVAL.md 1.1: an eval fn runs at compile time only. `consteval` is
        // implicitly inline, so EmitPlan makes its body visible as it does
        // an `inline` one's.
        if m->is_eval() { s += "consteval "; }
        else if m->is_constexpr() { s += "constexpr "; }

        if is_ctor {
            s += self._spell->leaf(owner);
        } else if is_dtor || is_conv {
            s += nm;
        } else {
            s += self._ret(m, owner);
            s += " ";
            s += nm;
        }
        s += "(";
        s += self._params(m, false, &null, owner);
        s += ")";
        if is_method && m->is_const() { s += " const"; }
        if m->no_unwind { s += " noexcept"; }
        if m->abi == AbiKind::Override { s += " override"; }
        s += self._body_suffix(m);
        s += ";";
        return s;
    }

    /// `extern T const x;`. Always `extern`, own globals included: a
    /// namespace-scope `const` has external linkage in C++ only when an
    /// `extern` declaration precedes its definition, and a `pub const` has to
    /// be reachable from every module that imports it.
    priv fn _global_var_decl(self, v: *VariableDecl) {
        self._cg->sink->spell(self._at(static_cast::<*Decl>(v)), "extern " + self._spell->global_var(v) + ";");
    }

    priv fn _free_fn_decl(self, f: *FunctionDecl, ext: *ExtensionDecl) {
        self._cg->sink->spell(self._at(static_cast::<*Decl>(f)), self._free_fn_text(f, ext));
    }

    /// A function declaration. With \p ext, an extension member: a static
    /// member of its scope, its receiver an explicit first parameter
    /// (`Self*` / `const Self*`), its template head the merged one (the
    /// extension's, then its own).
    priv fn _free_fn_text(self, f: *FunctionDecl, ext: *ExtensionDecl) -> string {
        var s = self._spell->template_head(static_cast::<*Decl>(f));
        // An extension member is a static member of its scope struct, and a
        // class member cannot have a language linkage.
        if ext == &null { s += CXXSpell::c_linkage(f); }
        // The attribute leads the decl-specifiers; between `static` and the
        // type it is ill-formed.
        if f->is_noreturn { s += "[[noreturn]] "; }
        if ext != &null { s += "static "; }
        if f->is_eval() { s += "consteval "; }   // EVAL.md 1.1
        s += self._ret(f);
        s += " ";
        s += self._fn_name(f);
        s += "(";
        s += self._params(f, ext != &null, ext);
        s += ")";
        if f->no_unwind { s += " noexcept"; }
        s += ";";
        return s;
    }

    // --- Extension scopes ----------------------------------------------------------

    /// `struct __kairo_ext_X { static ...; };`, every member declared, then
    /// the operator forwarders. Inside the scope's namespace wrapper. All
    /// members are public: Kairo's visibility is AccessCheck's, not C++
    /// access control's, and the struct must be one text everywhere.
    priv fn _scope_def(self, sc: *ExtScope) {
        var at = self._at(static_cast::<*Decl>(sc->anchor));
        self._cg->sink->spell(at, "struct " + sc->name + " {");
        for var i: usize = 0; i < sc->members.size(); ++i {
            var m = sc->members[i];
            self._cg->sink->spell(self._at(static_cast::<*Decl>(m)), self._free_fn_text(m, sc->exts[i]));
        }
        self._cg->sink->spell(at, "};");
        self._cg->sink->brk();
        for var i: usize = 0; i < sc->members.size(); ++i {
            var m = sc->members[i];
            if !m->is_operator { continue; }
            self._forwarder(sc, m, sc->exts[i]);
        }
    }

    /// `inline RET operator+(X& __kairo_a0, Y __kairo_a1) { return
    /// ::N::__kairo_ext_X::__kairo_op_plus(__kairo_a0, ...); }`: the C++
    /// operator an extension operator is, for C++ callers. Kairo calls the
    /// static member directly. Every operand is forwarded as its own
    /// declared type (`static_cast<decltype(a)&&>`), so a by-value or
    /// `@move` operand moves on and an `@inout` one stays an lvalue; the
    /// postfix dummy is passed as is.
    priv fn _forwarder(self, sc: *ExtScope, f: *FunctionDecl, ext: *ExtensionDecl) {
        var _op = self._spell->ext_forwarder_name(f);
        if _op.size() == 0 { return; }   // `in`, `^^`, ...: no C++ operator to forward from.
        var fid = CXXSpell::fid_of(static_cast::<*Decl>(f));
        var s = self._spell->template_head(static_cast::<*Decl>(f));
        // A forwarder of an eval operator is one too: an `inline` one could
        // not pass its parameters on to a consteval call.
        s += (("consteval ") if (f->is_eval()) else ("inline "));
        s += self._ret(f);
        s += " ";
        s += _op;
        s += "(";
        var call = "";
        var k: usize = 0;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            var nm = LowerTargets::forwarder_arg(k);
            if k > 0 { s += ", "; call += ", "; }
            if p->is_self {
                s += self._spell->ext_receiver(f, ext) + " " + nm;
                call += nm;
            } else {
                s += self._spell->param_decl(p, nm);
                call += "static_cast<decltype(" + nm + ")&&>(" + nm + ")";
            }
            k += 1;
        }
        if CXXSpell::op_is_postfix(f) {
            var nm = LowerTargets::forwarder_arg(k);
            if k > 0 { s += ", "; call += ", "; }
            s += "int " + nm;
            call += nm;
        }
        // Explicit template arguments: the forwarder's own parameters are the
        // static member's, so nothing is left for deduction to choose.
        var targs = "";
        var tps = CXXSpell::template_params(static_cast::<*Decl>(f));
        for var i: usize = 0; i < tps.size(); ++i {
            targs += (("<") if (i == 0) else (", "));
            targs += self._spell->imm_name(tps[i]->name.imm, fid);
            if tps[i]->is_pack { targs += "..."; }
        }
        if tps.size() > 0 { targs += ">"; }
        s += ")";
        if f->no_unwind { s += " noexcept"; }
        s += " { return " + self._scope_qual(sc) + "::" + self._spell->leaf(static_cast::<*Decl>(f)) + targs + "(" + call + "); }";
        self._cg->sink->spell(self._at(static_cast::<*Decl>(f)), s);
    }

    /// \p scope: the record whose body the declaration is in, or null
    /// (CXXSpell::_type).
    priv fn _params(self, f: *FunctionDecl, with_self: bool, ext: *ExtensionDecl, scope: *Decl = &null) -> string {
        var s = "";
        var first = true;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            if p->is_self {
                if !with_self { continue; }
                if (ext == &null) { self._ice(p->range, "InterfaceEmitter: `self` outside a type or extension"); }
                if !first { s += ", "; }
                first = false;
                // An extension operator is a real non-member C++ operator, and
                // [over.oper]/7 wants a class-typed parameter: the receiver is
                // `X&`. Unnamed here; EmitIR's definition names it.
                s += self._spell->ext_receiver(f, ext);
                if !f->is_operator { s += " " + LowerTargets::ext_receiver_name(); }   // just the type for an operator; EmitIR names it.
                continue;
            }
            if !first { s += ", "; }
            first = false;
            var nm = "";
            if !p->unname { nm = self._spell->imm_name(p->name.imm, CXXSpell::fid_of(static_cast::<*Decl>(f))); }
            s += self._spell->param_decl(p, nm, &null, scope);
        }
        // C++ distinguishes postfix `++`/`--` from prefix by an unnamed `int`
        // parameter. Kairo says `op r++`, so the dummy is invented here.
        if CXXSpell::op_is_postfix(f) {
            if !first { s += ", "; }
            s += "int";
        }
        return s;
    }

    priv fn _ret(self, f: *FunctionDecl, scope: *Decl = &null) -> string {
        if f->is_noreturn || (f->return_type == &null) { return "void"; }
        return self._spell->return_spelling(f, &null, scope);
    }

    priv fn _fn_name(self, f: *FunctionDecl) -> string {
        return self._spell->leaf(static_cast::<*Decl>(f));
    }

    priv fn _is_ctor(self, m: *FunctionDecl, owner: *Decl) -> bool {
        if m->is_operator { return false; }
        return self._spell->leaf(static_cast::<*Decl>(m)) == self._spell->leaf(owner);
    }

    priv fn _body_suffix(self, f: *FunctionDecl) -> string {
        switch f->body_kind {
            case FnBodyKind::Virtual { return " = 0"; }
            case FnBodyKind::Delete  { return " = delete"; }
            case FnBodyKind::Default { return " = default"; }
            default { return ""; }
        }
        return "";
    }

    // --- Tier 3 -----------------------------------------------------------------------

    /// `template class X<A>;` in the home TU, `extern template ...` elsewhere.
    /// A function instance spells its signature with the args substituted.
    priv fn _instantiation(self, e: *PlanEntry) {
        var d  = e->decl;
        var ie = e->inst;
        var s  = ("") if (e->is_home) else ("extern ");
        s += "template ";
        if isa::<FunctionDecl>(d) {
            var f = cast::<FunctionDecl>(d);
            s += self._ret_subst(f, ie);
            // The declarator-id is parenthesized, always: after a
            // class-template return, `Cell<double> ::test::f<...>` lexes as
            // ONE nested-name-specifier, so clang looks for a member `test`
            // inside Cell<double> ("no member named 'test\x27", "does not refer
            // to a function template"). `long (::test::get<long>)(...)` is
            // equally valid, so there is no case to special.
            s += " (";
            s += self._spell->qual_name(d);
            s += self._spell->args_str(&(ie->args));
            s += ")(";
            // An extension member's receiver is a real first parameter; a
            // method's `self` is `this` and has no slot.
            var ext = decl_extension_of(d);
            var first = true;
            for var i: usize = 0; i < f->params.size(); ++i {
                var p = f->params[i];
                if p == &null { continue; }
                if p->is_self && (ext == &null) { continue; }
                if !first { s += ", "; }
                first = false;
                if p->is_self { s += self._spell->ext_receiver(f, ext, ie); continue; }
                s += self._spell->param_decl(p, "", ie);
            }
            s += ")";
            // A const member template's instantiation names the const member:
            // without the qualifier it matches no declaration ("does not refer
            // to a function template"). An extension member is static.
            if (ext == &null) && f->is_method() && f->is_const() { s += " const"; }
            s += ";";
        } else {
            s += ("class ") if (d->kind == DeclKind::ClassDecl) else ("struct ");
            s += self._spell->qual_name(d);
            s += self._spell->args_str(&(ie->args));
            s += ";";
        }
        self._cg->sink->spell(self._at(d), s);
        self._cg->sink->brk();
    }

    priv fn _ret_subst(self, f: *FunctionDecl, ie: *InstanceEntry) -> string {
        if f->is_noreturn || (f->return_type == &null) { return "void"; }
        return self._spell->return_spelling(f, ie);
    }
}
