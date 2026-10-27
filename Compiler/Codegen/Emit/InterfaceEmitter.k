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
import AST::EnumNiche::*;
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
    pub var have_niche_helpers: bool = false;
    pub var have_pack_union: bool = false;
    pub var have_panic_helpers: bool = false;
    pub var have_site_type: bool = false;
    pub var have_panic_api: bool = false;
    pub var have_raw_slot: bool = false;
    /// The host C++ TU compiles with exceptions (a kcc include: its
    /// LangOptions), so it gets the throwing half of the C++ view
    /// (_panic_api). A header decides with `#if __cpp_exceptions`; an
    /// object's own TU never throws and never gets it.
    pub var cxx_exceptions: bool = false;
    /// The `__kairo_tid` specializations already written into this C++ TU
    /// (their keys): a token stream carries no guard, so a kcc include
    /// chain carries this from one include to the next (IncludedDecls).
    pub var tid_seen: vec::<u64>;
    /// The instances a kcc include's plan named but does not instantiate
    /// (IncludeEmitter prunes tier 3): their type-id specializations are
    /// still the host's to see.
    pub var pruned_insts: vec::<*InstanceEntry>;

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
        // A constructor that initializes a field in place (_ctor_slot_helpers).
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
            var bp = LowerTargets::eval_buf_data();    // EmitIR reads these three.
            var bn = LowerTargets::eval_buf_count();
            var bu = LowerTargets::eval_buf_push();
            self._cg->sink->spell(self._tu_at(),
                "template <class T> struct " + eb + " { T* " + bp + " = nullptr; " + sz + " " + bn + " = 0; " + sz + " cap = 0; "
                + "constexpr " + eb + "() = default; "
                + "constexpr " + eb + "(" + eb + "&& o) : " + bp + "(o." + bp + "), " + bn + "(o." + bn + "), cap(o.cap) { o." + bp + " = nullptr; o." + bn + " = 0; o.cap = 0; } "
                + eb + "(const " + eb + "&) = delete; "
                + "constexpr void " + bu + "(T v) { if (" + bn + " == cap) { " + sz + " c = cap ? cap * 2 : 8; T* q = new T[c]; "
                + "for (" + sz + " i = 0; i < " + bn + "; ++i) q[i] = " + bp + "[i]; delete[] " + bp + "; " + bp + " = q; cap = c; } " + bp + "[" + bn + "++] = v; } "
                + "constexpr ~" + eb + "() { delete[] " + bp + "; } };");
            self._cg->sink->brk();
            self._cg->sink->spell(self._tu_at(),
                "template <class T, " + sz + " N> struct " + LowerTargets::eval_arr() + " { T " + LowerTargets::eval_arr_values() + "[N ? N : 1]; };");
            self._cg->sink->brk();
            // A string literal C++ reads at compile time (EVAL.md 2a): its
            // bytes and a NUL, keyed on the bytes, so one literal is one
            // object wherever it is spelled.
            self._cg->sink->spell(self._tu_at(),
                "template <unsigned char... C> inline constexpr unsigned char " + LowerTargets::eval_str() + "[sizeof...(C) + 1] = {C..., 0};");
            self._cg->sink->brk();
            if header { self._cg->sink->directive(self._tu_at(), "#endif"); }
            self._cg->sink->unanchored(false);
            self.have_eval_helpers = true;
        }

        // The niche trait (_niche_helpers), wherever an enum is defined: a
        // plain enum's specialization of it follows the enum, and an ADT's
        // record answers it.
        if (!self.have_niche_helpers) && self._needs_niche_helpers() {
            self._cg->sink->unanchored(true);
            self._niche_helpers(header);
            self._cg->sink->unanchored(false);
            self.have_niche_helpers = true;
        }

        // A pack-expanded variant's payload union (_pack_union), wherever an
        // ADT with one is defined.
        if (!self.have_pack_union) && self._needs_pack_union() {
            self._cg->sink->unanchored(true);
            if header { self._cg->sink->directive(self._tu_at(), "#ifndef " + LowerTargets::adt_pack_guard()); }
            if header { self._cg->sink->directive(self._tu_at(), "#define " + LowerTargets::adt_pack_guard()); }
            self._pack_union();
            if header { self._cg->sink->directive(self._tu_at(), "#endif"); }
            self._cg->sink->unanchored(false);
            self.have_pack_union = true;
        }

        // The Panic lang item's layout helpers (_panic_helpers), wherever an
        // ADT with its knobs is defined.
        if (!self.have_panic_helpers) && (self._panic_enum_defined() != &null) {
            self._cg->sink->unanchored(true);
            if header { self._cg->sink->directive(self._tu_at(), "#ifndef " + LowerTargets::panic_helpers_guard()); }
            if header { self._cg->sink->directive(self._tu_at(), "#define " + LowerTargets::panic_helpers_guard()); }
            self._panic_helpers(self._panic_enum_defined());
            if header { self._cg->sink->directive(self._tu_at(), "#endif"); }
            self._cg->sink->unanchored(false);
            self.have_panic_helpers = true;
        }

        // A `try`'s raw slot with no Panic lang item defined here (a C++
        // exception arm's value, EmitPlan::needs_raw_slot).
        if (!self.have_raw_slot) && self._plan->needs_raw_slot {
            self._cg->sink->unanchored(true);
            self._raw_slot_helpers(header);
            self._cg->sink->unanchored(false);
        }

        // The record type of the TU's panic site table (EmitIR::_panic_sites,
        // PANIC.md §1.4), when it has sites. The C++ view reads the table too
        // (_panic_api writes it then).
        if (!self.have_site_type) && (self._cg->tu->panic_sites.size() > 0) {
            self._cg->sink->unanchored(true);
            self._site_type(header);
            self._cg->sink->unanchored(false);
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
                } else if !self._plan->value_param_record(f->decl, &null) {
                    // A template over a class-typed value parameter (EVAL.md
                    // 7e) cannot be declared before that class is complete:
                    // its definition, ordered after the class, declares it.
                    self._fwd_decl(f->decl);
                }
                i += 1;
            }
            self._ns_close(opened);
        }

        // The C++ view of a panic result (_panic_api), after the forward
        // declarations: its templates name the Panic lang item.
        if (!self.have_panic_api) && (self._panic_enum_defined() != &null) {
            self._cg->sink->unanchored(true);
            self._panic_api(self._panic_enum_defined(), header);
            self._cg->sink->unanchored(false);
            self.have_panic_api = true;
        }

        // Each type-id-tagged instance's element ids (_type_id_specs), at
        // global scope after the forward declarations they name and before
        // any definition or body could use one.
        for var j: usize = 0; j < n; ++j {
            var te = &(self._plan->entries[j]);
            if te->tier == PlanTier::Instantiations { self._type_id_specs(te->decl, te->inst); }
        }
        // A kcc include writes no instantiation, but its host instantiates
        // every Panic it uses: IncludeEmitter hands over the ones it pruned.
        for var j: usize = 0; j < self.pruned_insts.size(); ++j {
            var pe = self.pruned_insts[j];
            self._type_id_specs(pe->primary, pe);
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
                self._scope_panic_msg(e->scope);
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
            // A plain enum's niche: the trait's explicit specialization, at
            // global scope, right after the definition every use of it needs.
            var pe = dyn_cast::<EnumDecl>(e->decl);
            if (pe != &null) && enum_has_niche_trait(pe) { self._enum_niche_trait(pe); }
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

        // Each constructor that initializes a field in place: its slot record,
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
    /// So does a compile-time string (`__kairo_estr`, EVAL.md 2a): this TU
    /// spelled one, or a body or constant it emits from elsewhere may (an
    /// eval fn, an eval binding, a record with eval members). Which foreign
    /// body holds a literal is not known here, so any eval entry counts.
    priv fn _needs_eval_helpers(self) -> bool {
        if (self._cg->tu != &null) && (self._cg->tu->has_eval_for || self._cg->tu->has_eval_string) { return true; }
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var d = self._plan->entries[i].decl;
            var f = dyn_cast::<FunctionDecl>(d);
            if (f != &null) && f->is_eval() { return true; }
            var v = dyn_cast::<VariableDecl>(d);
            if (v != &null) && v->is_eval() { return true; }
            if self._has_eval_member(d) { return true; }
        }
        return false;
    }

    priv fn _has_eval_member(self, d: *Decl) -> bool {
        var ms: *FrozenList::<*FunctionDecl> = &null;
        if isa::<ClassDecl>(d)       { ms = &(cast::<ClassDecl>(d)->methods); }
        else if isa::<StructDecl>(d) { ms = &(cast::<StructDecl>(d)->methods); }
        if ms == &null { return false; }
        for var i: usize = 0; i < ms->size(); ++i {
            var m = (*ms)[i];
            if (m != &null) && m->is_eval() { return true; }
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
        // A lang item's aligned payload (EnumDecl::adt_union_align): every
        // payload starts at that boundary, whatever the tag before it.
        var oe = dyn_cast::<EnumDecl>(owner);
        if (oe != &null) && (oe->adt_payload_offset != &null) {
            // max(floor, alignof(payloads)): never weaker than the members'
            // own, which an `alignas` may not be.
            self._cg->sink->spell(fat, "union alignas(" + self._spell->leaf(static_cast::<*Decl>(oe->adt_payload_offset)) + ") {");
        } else {
            self._cg->sink->spell(fat, "union {");
        }
        for var i: usize = 0; i < u->fields.size(); ++i {
            var m = u->fields[i];
            if m == &null { continue; }
            var mps = self._member_payload(m);
            if (mps != &null) && (mps->adt_pack_param != &null) {
                // One payload per element of the pack (_pack_union).
                self._cg->sink->spell(self._at(static_cast::<*Decl>(m)), "::" + LowerTargets::adt_pack_union() + "<" + self._pack_payload(mps, owner)
                                      + "...> " + self._spell->leaf(static_cast::<*Decl>(m)) + ";");
                continue;
            }
            var ms = self._spell->decl(m->type_, self._spell->leaf(static_cast::<*Decl>(m)), &null, owner);
            ms += ";";
            self._cg->sink->spell(self._at(static_cast::<*Decl>(m)), ms);
        }
        self._cg->sink->spell(fat, "};");
    }

    /// The payload member of a pack-expanded variant (PANIC.md §1.2):
    /// `__kairo_pu<P<E>...>`, a union of one payload per element, head and
    /// rest. Element K is `__kairo_get<K>()`; building one is the
    /// `(__kairo_vt<K>, f)` constructor, which recurses to the K-th member;
    /// destroying or copying element k (a runtime index, the tag's) is the
    /// helper of the same name, which recurses the same way. Its special
    /// members are trivial exactly when every member's are, so an ADT over
    /// trivial elements stays trivial; otherwise they do nothing, and the
    /// ADT's own (which know the tag) run the element's. Once per TU,
    /// beside the variant tags it is built with.
    priv fn _pack_union(self) {
        var pu  = LowerTargets::adt_pack_union();
        var hd  = LowerTargets::adt_pack_head();
        var rs  = LowerTargets::adt_pack_rest();
        var get = LowerTargets::adt_pack_get();
        var ds  = LowerTargets::adt_destroy();
        var cf  = LowerTargets::adt_construct_from();
        var vt  = "::" + LowerTargets::adt_variant_tag();
        var u   = builtin_info(BuiltinKind::U32)->cxx;
        var tc  = "(__is_trivially_copyable(H) && (__is_trivially_copyable(R) && ...))";
        var td  = "(__is_trivially_destructible(H) && (__is_trivially_destructible(R) && ...))";
        var at  = self._tu_at();
        self._cg->sink->spell(at, "template <class... P> union " + pu + " { " + pu + "() noexcept {} void " + ds + "(" + u + ") noexcept {} "
            + "template <class O> void " + cf + "(" + u + ", O&&) noexcept {} };");
        self._cg->sink->brk();
        var s = "template <class H, class... R> union " + pu + "<H, R...> { H " + hd + "; " + pu + "<R...> " + rs + "; "
              + pu + "() noexcept {} "
              + "template <class F> " + pu + "(" + vt + "<0>, F&& f) noexcept : " + hd + "(static_cast<F&&>(f)()) {} "
              + "template <" + u + " K, class F> requires (K > 0) " + pu + "(" + vt + "<K>, F&& f) noexcept : " + rs + "(" + vt + "<K - 1>{}, static_cast<F&&>(f)) {} "
              + pu + "(const " + pu + "&) requires " + tc + " = default; "
              + pu + "(const " + pu + "&) noexcept requires (!" + tc + ") {} "
              + pu + "(" + pu + "&&) requires " + tc + " = default; "
              + pu + "(" + pu + "&&) noexcept requires (!" + tc + ") {} "
              + pu + "& operator=(const " + pu + "&) requires " + tc + " = default; "
              + pu + "& operator=(" + pu + "&&) requires " + tc + " = default; "
              + "~" + pu + "() requires " + td + " = default; "
              + "~" + pu + "() noexcept requires (!" + td + ") {} "
              + "template <" + u + " K> auto& " + get + "() noexcept { if constexpr (K == 0) { return " + hd + "; } else { return " + rs + ".template " + get + "<K - 1>(); } } "
              + "template <" + u + " K> const auto& " + get + "() const noexcept { if constexpr (K == 0) { return " + hd + "; } else { return " + rs + ".template " + get + "<K - 1>(); } } "
              + "void " + ds + "(" + u + " k) noexcept { if (k == 0) { " + hd + ".~H(); } else { " + rs + "." + ds + "(k - 1); } } "
              + "template <class O> void " + cf + "(" + u + " k, O&& o) noexcept { if (k == 0) { new (&" + hd + ") H(static_cast<O&&>(o)." + hd + "); } "
              + "else { " + rs + "." + cf + "(k - 1, static_cast<O&&>(o)." + rs + "); } } };";
        self._cg->sink->spell(at, s);
        self._cg->sink->brk();
    }

    /// The Panic lang item's preamble (PANIC.md §1.1a, §1.3):
    ///   `__kairo_tid<E>`        incomplete: an element type with no
    ///                           specialization (no id from Sema) is a
    ///                           compile error, never a silent tag 0;
    ///   `__kairo_type_id<E>`    the id, read off the specialization;
    ///   `__kairo_unit`, `__kairo_nv<T>`   T, or an empty struct for void;
    ///   `__kairo_max_align<P...>(f)`      max(f, alignof(P)...).
    priv fn _panic_helpers(self, en: *EnumDecl) {
        var u  = builtin_info(BuiltinKind::U32)->cxx;
        var at = self._tu_at();
        var ti = LowerTargets::type_id_trait();
        self._cg->sink->spell(at, "template <class E> struct " + ti + ";");
        self._cg->sink->spell(at, "template <class E> inline constexpr " + u + " " + LowerTargets::type_id() + " = " + ti + "<E>::value;");
        self._cg->sink->spell(at, "struct " + LowerTargets::unit_type() + " {};");
        var vs = LowerTargets::void_unit_trait();
        self._cg->sink->spell(at, "template <class T> struct " + vs + " { using type = T; };");
        self._cg->sink->spell(at, "template <> struct " + vs + "<void> { using type = " + LowerTargets::unit_type() + "; };");
        self._cg->sink->spell(at, "template <class T> using " + LowerTargets::void_unit() + " = typename " + vs + "<T>::type;");
        self._cg->sink->spell(at, "template <class... P> constexpr " + u + " " + LowerTargets::max_align() + "(" + u + " f) noexcept { "
                                  + u + " a = f; ((a = (alignof(P) > a) ? static_cast<" + u + ">(alignof(P)) : a), ...); return a; }");
        self._cg->sink->brk();
        self._raw_slot_helpers(self._plan->mode() == PlanMode::Header);
        self._fwd_helpers(en);
    }

    /// `__kairo_raw<T>` (PANIC.md §4.4): storage for a T that the path
    /// which never fills it never builds -- a union, so its empty
    /// constructor and destructor leave the member alone. Filled once by
    /// placement into `__kairo_b` (EmitIR, PanicOp::SlotPut: the box brings
    /// its own placement `new`, so no <new>), read once by `__kairo_take()`,
    /// which moves the value out and destroys the box: from there the value
    /// is an ordinary local, which every exit destroys.
    priv fn _raw_slot_helpers(self, header: bool) {
        // Written with the Panic helpers or alone (a C++ arm's slot), once
        // per C++ TU: its own guard in a header, either way.
        if self.have_raw_slot { return; }
        self.have_raw_slot = true;
        var at  = self._tu_at();
        if header { self._cg->sink->directive(at, "#ifndef " + LowerTargets::raw_slot_guard()); }
        if header { self._cg->sink->directive(at, "#define " + LowerTargets::raw_slot_guard()); }
        var bx  = LowerTargets::raw_box();
        var bm  = LowerTargets::raw_box_member();
        var bv  = LowerTargets::raw_box_value();
        var rs  = LowerTargets::raw_slot();
        var nx  = self._adt_noexcept();
        self._cg->sink->spell(at, "template <class T> struct " + bx + " { static void* operator new(decltype(sizeof(0)), void* p) noexcept { return p; } T " + bv + "; };");
        self._cg->sink->brk();
        self._cg->sink->spell(at, "template <class T> union " + rs + " { " + bx + "<T> " + bm + "; "
            + rs + "() noexcept {} ~" + rs + "() noexcept {} " + rs + "(const " + rs + "&) = delete; "
            + "T " + LowerTargets::raw_take() + "()" + nx + " { T r(static_cast<T&&>(" + bm + "." + bv + ")); " + bm + ".~" + bx + "<T>(); return r; } };");
        self._cg->sink->brk();
        if header { self._cg->sink->directive(at, "#endif"); }
    }

    /// `__kairo_fwd<R, A>(s)` (PANIC.md §4.3): the panic result `s` as the
    /// result R, whose set holds every type `s` can hold here (an error
    /// only, unless A). The same type: moved. The same size and payload
    /// offset, both trivially copied: the bytes, tag and site word and all
    /// (the payload sits at one offset in both, and an error's tag is its
    /// type id in every set). Otherwise one case per element of `s`'s set
    /// (`__kairo_fwd_k`), testing the tag and moving the payload into R's
    /// element of the same type (`__kairo_pidx`), the site word copied. An
    /// element R does not hold is never the tag here, so it gets no case.
    /// Generic over the record (`P<T, E...>`), so no name of the lang item
    /// is spelled; its members are, read off \p en.
    priv fn _fwd_helpers(self, en: *EnumDecl) {
        var at  = self._tu_at();
        var u   = builtin_info(BuiltinKind::U32)->cxx;
        var nx  = self._adt_noexcept();
        var vt  = "::" + LowerTargets::adt_variant_tag();
        var fw  = LowerTargets::panic_fwd();
        var fk  = LowerTargets::panic_fwd_step();
        var px  = LowerTargets::panic_elem_index();
        var tag = LowerTargets::adt_tag_field();
        var tt  = LowerTargets::adt_tag_type();
        var off = LowerTargets::adt_payload_offset();
        var tid = "::" + LowerTargets::type_id();
        var nv  = "::" + LowerTargets::void_unit();
        var get = LowerTargets::adt_pack_get();
        if en->adt_site_field == &null {
            self._ice(self._at(static_cast::<*Decl>(en)), "InterfaceEmitter: the Panic lang item without its site slot; EnumLayoutLowering::_knobs sets it");
        }
        var site = self._spell->leaf(static_cast::<*Decl>(en->adt_site_field));
        var ok: *EnumVariantDecl  = &null;
        var err: *EnumVariantDecl = &null;
        var errpos: usize = 0;
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if v->is_pack_expansion { err = v; errpos = i; }
            else if ok == &null { ok = v; }
        }
        if (ok == &null) || (err == &null) || (ok->adt_member == &null) || (err->adt_member == &null) {
            self._ice(self._at(static_cast::<*Decl>(en)), "InterfaceEmitter: the Panic lang item without its Ok and pack Err variants; lang_item.k pins the shape");
        }
        var okn  = self._spell->leaf(static_cast::<*Decl>(ok));
        var okm  = self._spell->leaf(static_cast::<*Decl>(ok->adt_member));
        var okf  = self._spell->leaf(static_cast::<*Decl>(ok->payload[0]));
        var okt  = LowerTargets::adt_payload_type(okn);
        var erm  = self._spell->leaf(static_cast::<*Decl>(err->adt_member));
        var erf  = self._spell->leaf(static_cast::<*Decl>(err->payload[0]));
        var ert  = LowerTargets::adt_payload_type(self._spell->leaf(static_cast::<*Decl>(err)));
        var npos = "static_cast<" + u + ">(-1)";
        var tp   = "template <class, class...> class P";

        self._cg->sink->spell(at, "template <class X, " + tp + ", class U, class... F> constexpr " + u + " " + px + "(P<U, F...>*) noexcept { "
            + u + " k = 0, i = " + npos + "; ((__is_same(X, F) ? (void)(i = k) : (void)0, ++k), ...); return i; }");
        self._cg->sink->brk();
        // One element: built into R's element of its type when the tag is
        // its id (the last element is the tag without a test).
        self._cg->sink->spell(at, "template <class R, " + u + " K, " + tp + ", class T, class... E> R " + fk + "(P<T, E...>& s)" + nx + " { "
            + "using X = __type_pack_element<K, E...>; "
            + "constexpr " + u + " J = " + px + "<X>(static_cast<R*>(nullptr)); "
            + "if constexpr (J == " + npos + ") { if constexpr (K + 1 < sizeof...(E)) { return " + fk + "<R, K + 1>(s); } else { __builtin_unreachable(); } } "
            + "else { if constexpr (K + 1 < sizeof...(E)) { if (static_cast<" + u + ">(s." + tag + ") != " + tid + "<X>) { return " + fk + "<R, K + 1>(s); } } "
            + "return R(" + vt + "<" + f"{errpos}" + ">{}, " + vt + "<J>{}, s." + site + ", [&]()" + nx + " -> typename R::template " + ert + "<X> { "
            + "return { static_cast<X&&>(s." + erm + ".template " + get + "<K>()." + erf + ") }; }); } }");
        self._cg->sink->brk();
        var bits = "(sizeof(R) == sizeof(S) && R::" + off + " == S::" + off + " && __is_trivially_copyable(R) && __is_trivially_copyable(S)"
                 + " && (!A || __is_same(" + nv + "<T>, decltype(static_cast<R*>(nullptr)->" + okm + "." + okf + "))))";
        self._cg->sink->spell(at, "template <class R, bool A, " + tp + ", class T, class... E> R " + fw + "(P<T, E...>& s)" + nx + " { "
            + "using S = P<T, E...>; "
            + "if constexpr (__is_same(R, S)) { return static_cast<S&&>(s); } "
            + "else if constexpr " + bits + " { return __builtin_bit_cast(R, s); } "
            + "else { if constexpr (A) { if (s." + tag + " == S::" + tt + "::" + okn + ") { return R(" + vt + "<0>{}, [&]()" + nx + " -> typename R::" + okt + " { "
            + "return { static_cast<" + nv + "<T>&&>(s." + okm + "." + okf + ") }; }); } } "
            + "if constexpr (sizeof...(E) == 0) { __builtin_unreachable(); } else { return " + fk + "<R, 0>(s); } } }");
        self._cg->sink->brk();
        self._cg->sink->spell(at, "template <class R, bool A, " + tp + ", class T, class... E> R " + fw + "(P<T, E...>&& s)" + nx + " { return " + fw + "<R, A>(s); }");
        self._cg->sink->brk();
        // A `fn` value converted to a `fn` type whose set is wider (P4's
        // conversion by subset): the call's result as R -- a panic result
        // forwarded whole, a plain value (or nothing) as Ok.
        var pc = LowerTargets::panic_call_as();
        self._cg->sink->spell(at, "template <class R, class F, class... A> R " + pc + "(F& f, A&&... a)" + nx + " { "
            + "using V = decltype(f(static_cast<A&&>(a)...)); "
            + "if constexpr (requires { V::" + off + "; } && requires (V& v) { v." + site + "; }) { return " + fw + "<R, true>(f(static_cast<A&&>(a)...)); } "
            + "else if constexpr (__is_same(V, void)) { f(static_cast<A&&>(a)...); return R(" + vt + "<0>{}, [&]()" + nx + " -> typename R::" + okt + " { return {}; }); } "
            + "else { return R(" + vt + "<0>{}, [&]()" + nx + " -> typename R::" + okt + " { return { f(static_cast<A&&>(a)...) }; }); } }");
        self._cg->sink->brk();
    }

    /// `struct __kairo_panic_site`, the record of the panic site table, once
    /// per C++ TU (a header guards it).
    priv fn _site_type(self, header: bool) {
        if self.have_site_type { return; }
        var u = builtin_info(BuiltinKind::U32)->cxx;
        if header { self._cg->sink->directive(self._tu_at(), "#ifndef " + LowerTargets::panic_site_guard()); }
        if header { self._cg->sink->directive(self._tu_at(), "#define " + LowerTargets::panic_site_guard()); }
        self._cg->sink->spell(self._tu_at(), "struct " + LowerTargets::panic_site_type() + " { " + u + " id; " + u + " line; " + u + " col; const char* file; };");
        if header { self._cg->sink->directive(self._tu_at(), "#endif"); }
        self.have_site_type = true;
    }

    /// The C++ view of a panic result (PANIC.md §4.6): what a C++ caller of
    /// a panicking Kairo function gets, as free templates in `::builtin`
    /// (class text must be one text everywhere, so nothing is a member).
    ///
    ///   type_id<E>, panic_set<P> (value_type, types, size, payload_offset:
    ///   ONE partial specialization over the lang item, as `__kairo_fwd` is
    ///   one template, never a specialization per instance), ok, value,
    ///   is<E>, error<E>, site -- all `noexcept`, no exception needed;
    ///
    ///   panic_error_base (a std::exception), panic_error<E> (its `error`),
    ///   value_or_throw -- only where the C++ compiles with exceptions: a
    ///   header under `#if __cpp_exceptions`, a kcc include when its host
    ///   has them (cxx_exceptions). clang rejects a `throw` at a template's
    ///   definition, not its use, so the half is left out, not guarded.
    ///
    /// error<E> reads E's element the way `__kairo_fwd_k` does
    /// (`__kairo_pidx`, `__kairo_get<K>`), never at a byte offset. site()
    /// and what() search the linker-collected site table (§1.4): records
    /// equal in all four fields are one site (a kcc include writes a site
    /// into every TU that includes it); one id at two places is printed
    /// whole, ` | `-separated. what() is built ONCE, when the exception is
    /// constructed, into a reference-counted buffer the copies share.
    priv fn _panic_api(self, en: *EnumDecl, header: bool) {
        var at  = self._tu_at();
        var u   = builtin_info(BuiltinKind::U32)->cxx;
        var sz  = "decltype(sizeof(0))";
        var st  = "::" + LowerTargets::panic_site_type();
        var pn  = self._spell->qual_name(static_cast::<*Decl>(en));
        var pt  = pn + "<T, E...>";
        var tag = LowerTargets::adt_tag_field();
        var tt  = LowerTargets::adt_tag_type();
        var get = LowerTargets::adt_pack_get();
        var px  = "::" + LowerTargets::panic_elem_index();
        var tid = "::" + LowerTargets::type_id();
        var npos = "static_cast<" + u + ">(-1)";
        var ok: *EnumVariantDecl  = &null;
        var err: *EnumVariantDecl = &null;
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if v->is_pack_expansion { err = v; }
            else if ok == &null { ok = v; }
        }
        if (ok == &null) || (err == &null) || (ok->adt_member == &null) || (err->adt_member == &null) || (en->adt_site_field == &null) {
            self._ice(self._at(static_cast::<*Decl>(en)), "InterfaceEmitter: the Panic lang item without its Ok, pack Err and site; lang_item.k pins the shape");
        }
        var site = self._spell->leaf(static_cast::<*Decl>(en->adt_site_field));
        var okn  = self._spell->leaf(static_cast::<*Decl>(ok));
        var okv  = self._spell->leaf(static_cast::<*Decl>(ok->adt_member)) + "." + self._spell->leaf(static_cast::<*Decl>(ok->payload[0]));
        var erm  = self._spell->leaf(static_cast::<*Decl>(err->adt_member));
        var erf  = self._spell->leaf(static_cast::<*Decl>(err->payload[0]));
        var api  = LowerTargets::panic_api_ns();
        var im   = LowerTargets::panic_api_impl();
        var ss   = "::" + api + "::" + LowerTargets::panic_api_source_site();
        var b0   = LowerTargets::panic_sites_begin_sym();
        var b1   = LowerTargets::panic_sites_end_sym();
        var fmt  = "";
        var ci   = self._cg->ctx->ci;
        if ci != &null { fmt = ci->target.object_format; }

        if header { self._cg->sink->directive(at, "#ifndef " + LowerTargets::panic_api_guard()); }
        if header { self._cg->sink->directive(at, "#define " + LowerTargets::panic_api_guard()); }
        self._site_type(header);
        // The table's bounds. ELF: the linker's __start_/__stop_, weak so a
        // program with no site links. Mach-O: section$start/end. Any other
        // format has none here yet (ticketed): no site is ever found.
        if (fmt == "ELF") || (fmt.size() == 0) {
            self._cg->sink->spell(at, "extern \x22" + "C\x22 { [[gnu::weak]] extern const " + st + " " + LowerTargets::panic_sites_start() + "[]; "
                + "[[gnu::weak]] extern const " + st + " " + LowerTargets::panic_sites_stop() + "[]; }");
            b0 = LowerTargets::panic_sites_start();
            b1 = LowerTargets::panic_sites_stop();
        } else if fmt == "Mach-O" {
            self._cg->sink->spell(at, "extern const " + st + " " + b0 + "[] __asm(\x22" + LowerTargets::panic_sites_start_macho() + "\x22);");
            self._cg->sink->spell(at, "extern const " + st + " " + b1 + "[] __asm(\x22" + LowerTargets::panic_sites_stop_macho() + "\x22);");
        } else {
            b0 = "nullptr";
            b1 = "nullptr";
        }
        self._cg->sink->brk();
        self._cg->sink->spell(at, "template <class E> struct " + LowerTargets::panic_msg_trait() + ";");
        self._cg->sink->brk();

        var cnt = "unsigned long";
        var s = "namespace " + api + " { ";
        s += "template <class E> inline constexpr " + u + " " + LowerTargets::panic_api_type_id() + " = " + tid + "<E>; ";
        s += "template <class... E> struct " + LowerTargets::panic_api_types() + " {}; ";
        s += "template <class P> struct " + LowerTargets::panic_api_set() + "; ";
        s += "template <class T, class... E> struct " + LowerTargets::panic_api_set() + "<" + pt + "> { using value_type = T; using types = ::" + api + "::" + LowerTargets::panic_api_types() + "<E...>; "
           + "static constexpr " + u + " size = sizeof...(E); static constexpr " + u + " payload_offset = " + pt + "::" + LowerTargets::adt_payload_offset() + "; }; ";
        s += "struct " + LowerTargets::panic_api_source_site() + " { const char* file; " + u + " line; " + u + " col; }; ";
        // The machinery: the table walk and what()'s text, sized by a first
        // pass with no buffer (o null) and written by a second.
        s += "struct " + im + " { ";
        s += "static const " + st + "* first() noexcept { return " + b0 + "; } ";
        s += "static const " + st + "* last() noexcept { return " + b1 + "; } ";
        s += "static " + ss + " site_of(" + u + " id) noexcept { if (id != 0) { for (const " + st + "* r = first(); r != last(); ++r) { if (r->id == id) { return " + ss + "{r->file, r->line, r->col}; } } } return " + ss + "{nullptr, 0, 0}; } ";
        s += "static " + sz + " put(char* o, " + sz + " n, const char* x, " + sz + " k) noexcept { if (o) { for (" + sz + " i = 0; i < k; ++i) { o[n + i] = x[i]; } } return n + k; } ";
        s += "static " + sz + " putu(char* o, " + sz + " n, " + u + " v) noexcept { char b[10]; int k = 0; do { b[k++] = static_cast<char>(48 + v % 10); v /= 10; } while (v); "
           + "while (k) { if (o) { o[n] = b[k - 1]; } ++n; --k; } return n; } ";
        s += "static " + sz + " len(const char* x) noexcept { " + sz + " n = 0; while (x[n]) { ++n; } return n; } ";
        s += "static bool same(const " + st + "* a, const " + st + "* b) noexcept { if ((a->line != b->line) || (a->col != b->col)) { return false; } "
           + "const char* x = a->file; const char* y = b->file; while (*x && (*x == *y)) { ++x; ++y; } return *x == *y; } ";
        s += "static " + sz + " text(char* o, const unsigned char* m, " + sz + " ml, bool hm, const char* name, " + u + " site) noexcept { " + sz + " n = 0; "
           + "if (hm) { n = put(o, n, reinterpret_cast<const char*>(m), ml); n = put(o, n, \x22 [\x22, 2); } "
           + "n = put(o, n, name, len(name)); bool one = true; "
           + "if (site != 0) { for (const " + st + "* r = first(); r != last(); ++r) { if (r->id != site) { continue; } bool dup = false; "
           + "for (const " + st + "* q = first(); q != r; ++q) { if ((q->id == site) && same(q, r)) { dup = true; break; } } if (dup) { continue; } "
           + "n = one ? put(o, n, \x22 at \x22, 4) : put(o, n, \x22 | \x22, 3); one = false; "
           + "n = put(o, n, r->file, len(r->file)); n = put(o, n, \x22:\x22, 1); n = putu(o, n, r->line); n = put(o, n, \x22:\x22, 1); n = putu(o, n, r->col); } } "
           + "if (hm) { n = put(o, n, \x22]\x22, 1); } return n; } ";
        s += "}; ";
        s += "template <class T, class... E> bool " + LowerTargets::panic_api_ok() + "(const " + pt + "& p) noexcept { return p." + tag + " == " + pt + "::" + tt + "::" + okn + "; } ";
        s += "template <class T, class... E> auto& " + LowerTargets::panic_api_value() + "(" + pt + "& p) noexcept { return p." + okv + "; } ";
        s += "template <class T, class... E> const auto& " + LowerTargets::panic_api_value() + "(const " + pt + "& p) noexcept { return p." + okv + "; } ";
        s += "template <class X, class T, class... E> bool " + LowerTargets::panic_api_is() + "(const " + pt + "& p) noexcept { "
           + "if constexpr (" + px + "<X>(static_cast<" + pt + "*>(nullptr)) == " + npos + ") { return false; } "
           + "else { return static_cast<" + u + ">(p." + tag + ") == " + tid + "<X>; } } ";
        var nin = "static_assert(J != " + npos + ", \x22::" + api + "::" + LowerTargets::panic_api_error() + "<E>: E is not in this panic set\x22); ";
        s += "template <class X, class T, class... E> X& " + LowerTargets::panic_api_error() + "(" + pt + "& p) noexcept { "
           + "constexpr " + u + " J = " + px + "<X>(static_cast<" + pt + "*>(nullptr)); " + nin + "return p." + erm + ".template " + get + "<J>()." + erf + "; } ";
        s += "template <class X, class T, class... E> const X& " + LowerTargets::panic_api_error() + "(const " + pt + "& p) noexcept { "
           + "constexpr " + u + " J = " + px + "<X>(static_cast<" + pt + "*>(nullptr)); " + nin + "return p." + erm + ".template " + get + "<J>()." + erf + "; } ";
        s += "template <class T, class... E> " + ss + " " + LowerTargets::panic_api_site() + "(const " + pt + "& p) noexcept { return " + im + "::site_of(p." + site + "); } ";
        s += "}";
        self._cg->sink->spell(at, s);
        self._cg->sink->brk();

        // The throwing half.
        var throwing = header || self.cxx_exceptions;
        if throwing {
            if header { self._cg->sink->directive(at, "#if __cpp_exceptions"); }
            self._cg->sink->system_header(at, "exception");
            var eb  = LowerTargets::panic_api_error_base();
            var et  = LowerTargets::panic_api_error_type();
            var w   = LowerTargets::panic_api_text();
            var bld = LowerTargets::panic_api_build();
            var drp = LowerTargets::panic_api_drop();
            var th  = LowerTargets::panic_api_throw();
            var nm  = "::" + LowerTargets::type_id_trait() + "<E>::" + LowerTargets::type_id_name();
            var sd  = LangMembers::string_data();
            var sl  = LangMembers::string_len();
            // No `: ::name` anywhere: a header's text sink writes no space
            // between tokens, and `:::` lexes as `::` `:`. The base is
            // default-built in the copy (std::exception holds nothing).
            // The memory orders by value (relaxed 0, acq_rel 4): a kcc
            // include's tokens are past the preprocessor, so the
            // __ATOMIC_* macros would not expand.
            var t = "namespace " + api + " { ";
            t += "struct " + eb + " : public ::std::exception { " + u + " type; " + u + " site; ";
            t += eb + "(const " + eb + "& o) noexcept : type(o.type), site(o.site), " + w + "(o." + w + ") { if (" + w + ") { __atomic_fetch_add(" + w + ", 1, 0); } } ";
            t += eb + "& operator=(const " + eb + "& o) noexcept { if (o." + w + ") { __atomic_fetch_add(o." + w + ", 1, 0); } " + drp + "(); type = o.type; site = o.site; " + w + " = o." + w + "; return *this; } ";
            t += "~" + eb + "() override { " + drp + "(); } ";
            t += "const char* what() const noexcept override { return " + w + " ? reinterpret_cast<const char*>(" + w + " + 1) : \x22\x22; } ";
            t += "protected: " + eb + "(" + u + " t, " + u + " s) noexcept : type(t), site(s) {} ";
            t += cnt + "* " + w + " = nullptr; ";
            t += "void " + drp + "() noexcept { if (" + w + " && (__atomic_sub_fetch(" + w + ", 1, 4) == 0)) { __builtin_free(" + w + "); } " + w + " = nullptr; } ";
            t += "void " + bld + "(const unsigned char* m, " + sz + " ml, bool hm, const char* name) noexcept { "
               + sz + " n = ::" + api + "::" + im + "::text(nullptr, m, ml, hm, name, site); "
               + w + " = static_cast<" + cnt + "*>(__builtin_malloc(sizeof(" + cnt + ") + n + 1)); if (!" + w + ") { return; } *" + w + " = 1; "
               + "char* o = reinterpret_cast<char*>(" + w + " + 1); ::" + api + "::" + im + "::text(o, m, ml, hm, name, site); o[n] = 0; } ";
            t += "}; ";
            t += "template <class E> struct " + et + " : public ::" + api + "::" + eb + " { E " + LowerTargets::panic_api_error() + "; ";
            t += "template <class A> " + et + "(A&& e, " + u + " s) noexcept : " + eb + "(" + tid + "<E>, s), " + LowerTargets::panic_api_error() + "(static_cast<A&&>(e)) { "
               + "const E& x = this->" + LowerTargets::panic_api_error() + "; "
               + "if constexpr (requires (const E& y) { y." + LowerTargets::op_panic() + "(); }) { auto m = x." + LowerTargets::op_panic() + "(); this->" + bld + "(m." + sd + ", m." + sl + ", true, " + nm + "); } "
               + "else if constexpr (requires (const E& y) { ::" + LowerTargets::panic_msg_trait() + "<E>::" + LowerTargets::panic_msg_get() + "(y); }) { "
               + "auto m = ::" + LowerTargets::panic_msg_trait() + "<E>::" + LowerTargets::panic_msg_get() + "(x); this->" + bld + "(m." + sd + ", m." + sl + ", true, " + nm + "); } "
               + "else { this->" + bld + "(nullptr, 0, false, " + nm + "); } } }; ";
            // The error the result holds, thrown as panic_error<X>: moved
            // out of an rvalue result, copied out of an lvalue one.
            t += "struct " + th + " { ";
            t += "template <" + u + " K, bool M, class T, class... E> [[noreturn]] static void raise(" + pt + "& p) { using X = __type_pack_element<K, E...>; "
               + "if constexpr (K + 1 < sizeof...(E)) { if (static_cast<" + u + ">(p." + tag + ") != " + tid + "<X>) { raise<K + 1, M>(p); } } "
               + "if constexpr (M) { throw ::" + api + "::" + et + "<X>(static_cast<X&&>(p." + erm + ".template " + get + "<K>()." + erf + "), p." + site + "); } "
               + "else { throw ::" + api + "::" + et + "<X>(static_cast<const X&>(p." + erm + ".template " + get + "<K>()." + erf + "), p." + site + "); } } ";
            t += "template <bool M, class T, class... E> static T value(" + pt + "& p) { "
               + "if (p." + tag + " != " + pt + "::" + tt + "::" + okn + ") { if constexpr (sizeof...(E) > 0) { raise<0, M>(p); } else { __builtin_unreachable(); } } "
               + "if constexpr (!__is_same(T, void)) { if constexpr (M) { return static_cast<T&&>(p." + okv + "); } else { return p." + okv + "; } } } ";
            t += "}; ";
            t += "template <class T, class... E> T " + LowerTargets::panic_api_value_or_throw() + "(" + pt + "&& p) { return " + th + "::template value<true>(p); } ";
            t += "template <class T, class... E> T " + LowerTargets::panic_api_value_or_throw() + "(const " + pt + "& p) { return " + th + "::template value<false>(const_cast<" + pt + "&>(p)); } ";
            t += "}";
            self._cg->sink->spell(at, t);
            self._cg->sink->brk();
            if header { self._cg->sink->directive(at, "#endif"); }
        }
        if header { self._cg->sink->directive(at, "#endif"); }
    }

    /// An extension's `op panic` (PANIC.md §1.5) as the C++ view reads it:
    /// `__kairo_pmsg<T>::get(e)`, which calls the scope's static member. A
    /// type's own `op panic` is a member the C++ view finds by itself; an
    /// extension's lives in a scope only Kairo can name. At global scope,
    /// after the scope's definition. A generic target's member is a
    /// template, which no specialization of one type can name: left out
    /// (what() falls back to the type name).
    priv fn _scope_panic_msg(self, sc: *ExtScope) {
        for var i: usize = 0; i < sc->members.size(); ++i {
            var m = sc->members[i];
            if (!m->is_operator) || (m->op_token.size() != 1) || (m->op_token[0].kind != TokenKind::KwPanic) { continue; }
            if self._spell->template_head(static_cast::<*Decl>(m)).size() != 0 { continue; }
            var ty = "";
            if sc->target_ty != &null { ty = self._spell->_type(sc->target_ty); }
            else if (sc->target != &null) && (self._spell->template_head(sc->target).size() == 0) { ty = self._spell->qual_name(sc->target); }
            if ty.size() == 0 { continue; }
            var at = self._at(static_cast::<*Decl>(m));
            var pm = LowerTargets::panic_msg_trait();
            // A template, so its body (which returns a `string`) is compiled
            // where it is used: the string may still be incomplete here.
            self._cg->sink->spell(at, "template <class E> struct " + pm + "; template <> struct " + pm + "<" + ty + "> { template <class X = " + ty + "> static auto "
                + LowerTargets::panic_msg_get() + "(const X& e) noexcept { return " + self._scope_qual(sc) + "::" + LowerTargets::op_panic() + "(e); } };");
            self._cg->sink->brk();
        }
    }

    /// The Panic lang item, when a plan entry defines it here: an ADT with
    /// a lang item's layout knobs (as _needs_pack_union asks).
    priv fn _panic_enum_defined(self) -> *EnumDecl {
        var header = (self._plan->mode() == PlanMode::Header);
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var e = &(self._plan->entries[i]);
            if (e->tier != PlanTier::Definitions) || (e->scope != &null) || (e->witness != &null) { continue; }
            if header && (!e->own) { continue; }
            var en = dyn_cast::<EnumDecl>(e->decl);
            if (en != &null) && en->is_adt && (en->adt_explicit_tags || en->adt_void_unit || (en->adt_payload_offset != &null)) { return en; }
        }
        return &null;
    }

    /// `max(floor, alignof(P)...)` over \p lay's payload structs, the pack
    /// variant's expanded: the initializer of `__kairo_payload_offset`.
    priv fn _payload_offset_init(self, en: *EnumDecl, lay: *StructDecl) -> string {
        var ps = "";
        var dc = static_cast::<*DeclContext>(lay);
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var sd = dyn_cast::<StructDecl>(*(dc->dc_decls.get(i)));
            if (sd == &null) || (!sd->is_adt_payload) { continue; }
            if ps.size() > 0 { ps += ", "; }
            if sd->adt_pack_param != &null { ps += self._pack_payload(sd, lay->adt_of) + "..."; }
            else { ps += self._spell->leaf(static_cast::<*Decl>(sd)); }
        }
        return "::" + LowerTargets::max_align() + "<" + ps + ">(" + f"{en->adt_union_align}" + ")";
    }

    /// The tag element \p k (a C++ expression: a template parameter) of
    /// \p en's pack-expanded variant \p v is stored as, typed as the tag
    /// enum \p tt: the variant's position plus k, or under type-id tags
    /// the element's id. EnumLayoutQuery::tag_value is the same rule.
    priv fn _pack_tag(self, en: *EnumDecl, v: *EnumVariantDecl, k: string, tt: string) -> string {
        if en->adt_explicit_tags {
            return "static_cast<" + tt + ">(::" + LowerTargets::type_id() + "<__type_pack_element<" + k + ", " + self._pack_name(en) + "...>>)";
        }
        return "static_cast<" + tt + ">(" + f"{v->adt_tag_value}" + " + " + k + ")";
    }

    /// The enum's type pack parameter, as its own body names it.
    priv fn _pack_name(self, en: *EnumDecl) -> string {
        var gp = en->generic_params[adt_pack_param(en)];
        return self._spell->imm_name(gp->name.imm, CXXSpell::fid_of(static_cast::<*Decl>(en)));
    }

    /// The payload struct template of pack-expanded variant \p v, applied
    /// to its pack, unexpanded: `__kairo_Err_t<E>`, the pattern a fold or
    /// a `__kairo_pu<...>` expands.
    priv fn _pack_payload(self, ps: *StructDecl, en: *Decl) -> string {
        var gp = ps->adt_pack_param;
        return self._spell->leaf(static_cast::<*Decl>(ps)) + "<" + self._spell->imm_name(gp->name.imm, CXXSpell::fid_of(en)) + ">";
    }

    /// The payload struct an ADT union member \p m holds, or null.
    priv fn _member_payload(self, m: *FieldDecl) -> *StructDecl {
        if (m == &null) || (m->type_ == &null) || (m->type_->canonical == &null) { return &null; }
        var c = canon_unqual(m->type_->canonical);
        if !isa::<RecordType>(c) { return &null; }
        return dyn_cast::<StructDecl>(cast::<RecordType>(c)->decl);
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
            // A minted tag enum has no discriminant expression; an explicit
            // tag (EnumLayoutLowering's knobs) is a value that is not its
            // position.
            if (v != &null) && v->value.ok && (v->value.neg || (v->value.mag != u64(i))) { numbered = true; break; }
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
        if en->adt_niche {
            self._niche_record(en, lay, "struct " + nm + " {", false);
            return;
        }
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
            // A pack-expanded variant's payload: a template over one element,
            // inside which the enum's pack spells as that element.
            var pps = dyn_cast::<StructDecl>(nd);
            var pk = (pps->adt_pack_param) if (pps != &null) else (&null);
            if pk != &null {
                self._cg->sink->spell(self._at(nd), "template <class " + LowerTargets::adt_pack_elem() + ">");
                self._spell->pack_alias = pk;
            }
            // `Panic<void, ...>`'s Ok: T is spelled `__kairo_nv<T>` there.
            var vu = (pps != &null) && pps->is_adt_payload && en->adt_void_unit;
            if vu { self._spell->void_unit_owner = d; }
            self._type_def(CXXSpell::rep(nd));
            if vu { self._spell->void_unit_owner = &null; }
            if pk != &null { self._spell->pack_alias = &null; }
        }

        for var i: usize = 0; i < lay->fields.size(); ++i {
            var f = lay->fields[i];
            if f == &null { continue; }
            cur_access = self._access(cur_access, CXXSpell::vis_of(static_cast::<*Decl>(f)), false, at);
            if f->is_anonymous_union { self._anon_union_field(f, d); continue; }
            // A tag in the payloads' common prefix is read through the
            // union's tag-only member, not stored beside it.
            if (en->adt_tag_member != &null) && (f == en->adt_tag_field) { continue; }
            var fnm = self._spell->leaf(static_cast::<*Decl>(f));
            // A flag: a compile-time constant with no Kairo expression behind
            // it (_adt_flag).
            if f->storage == StorageClass::Eval {
                if f == en->adt_payload_offset {
                    var u = builtin_info(BuiltinKind::U32)->cxx;
                    self._cg->sink->spell(f->name.range, "static constexpr " + u + " " + fnm + " = " + self._payload_offset_init(en, lay) + ";");
                    continue;
                }
                self._cg->sink->spell(f->name.range, "static constexpr bool " + fnm + " = " + self._adt_flag(lay, f, fnm) + ";");
                continue;
            }
            self._cg->sink->spell(f->name.range, self._spell->decl(f->type_, fnm, &null, d) + ";");
        }

        for var i: usize = 0; i < lay->methods.size(); ++i {
            var m = lay->methods[i];
            if m == &null { continue; }
            // Prefix-tagged: every special member is the defaulted one, so
            // the helpers that switch on the tag are never called.
            if (en->adt_tag_member != &null) && ((m->adt_role == AdtRole::Destroy) || (m->adt_role == AdtRole::ConstructFrom)) { continue; }
            cur_access = self._access(cur_access, CXXSpell::vis_of(static_cast::<*Decl>(m)), false, at);
            self._cg->sink->spell(self._at(static_cast::<*Decl>(m)), self._adt_member(en, m, nm, generic));
        }

        // The niche the tag leaves (EnumNiche: the tag values past the
        // variants), for `__kairo_niche<E>`: a niche-filled ADT holding
        // this one stores its dataless variants as those tags.
        cur_access = self._access(cur_access, VIS_PUB(), false, at);
        var tt = LowerTargets::adt_tag_type();
        var nv = f"{adt_first_spare_tag(en)}";
        var w  = builtin_info(BuiltinKind::U64)->cxx;
        // The tag as written and as read: a member of its own, or the
        // union's tag-only member in the common prefix.
        var tset = LowerTargets::adt_tag_field() + "(static_cast<" + tt + ">(" + nv + " + i))";
        var tget = LowerTargets::adt_tag_field();
        if en->adt_tag_member != &null {
            var tmn = self._spell->leaf(static_cast::<*Decl>(en->adt_tag_member));
            tset = tmn + "{static_cast<" + tt + ">(" + nv + " + i)}";
            tget = tmn + "." + LowerTargets::adt_tag_field();
        }
        self._cg->sink->spell(at, "static constexpr " + w + " " + LowerTargets::niche_count() + " = " + f"{adt_tag_niche_count(en)}" + ";");
        self._cg->sink->spell(at, nm + "(::" + LowerTargets::niche_ctor_tag() + ", " + w + " i) noexcept : " + tset + " {}");
        self._cg->sink->spell(at, "static bool " + LowerTargets::niche_test() + "(const " + nm + "& v, " + w + " i) noexcept { return static_cast<"
                                  + w + ">(v." + tget + ") == " + nv + " + i; }");

        self._friends(d);

        self._cg->sink->spell(at, "};");
        self._cg->sink->brk();

        // The niche-filled form of a generic ADT, as a partial specialization
        // constrained on exactly what EnumLayoutQuery::niche_verdict asks:
        // C++ picks it per instance, in every TU and every C++ host alike,
        // so no instance Sema never saw (a generic body's) can disagree.
        if generic && en->adt_niche_shape {
            var gps  = CXXSpell::template_params(d);
            var args = "";
            for var i: usize = 0; i < gps.size(); ++i {
                if i > 0 { args += ", "; }
                args += self._spell->imm_name(gps[i]->name.imm, CXXSpell::fid_of(d));
                if gps[i]->is_pack { args += "..."; }
            }
            var ft   = self._niche_field_spelling(en);
            var cond = "::" + LowerTargets::niche_trait() + "<" + ft + ">::" + LowerTargets::niche_trait_count() + " >= " + f"{adt_niche_dataless(en)}"
                     + " && __is_trivially_copyable(" + ft + ") && __is_trivially_destructible(" + ft + ")";
            self._niche_record(en, lay, self._spell->template_head(d) + "requires (" + cond + ") struct " + nm + "<" + args + "> {", true);
        }
    }

    /// The C++ type of a niche-shaped ADT's one payload field, spelled in the
    /// enum's own scope (a generic one's in terms of its parameters).
    priv fn _niche_field_spelling(self, en: *EnumDecl) -> string {
        var pv = en->variants[usize(adt_niche_payload_variant(en))];
        return self._spell->decl(pv->payload[0]->type_, "", &null, static_cast::<*Decl>(en));
    }

    /// A niche-filled ADT record (EnumLayoutLowering's header): no tag and
    /// no union, the payload struct as the one member, each dataless
    /// variant a pattern of its field from `__kairo_niche<F>`. Written for a
    /// non-generic ADT whose verdict was niche, and as the partial
    /// specialization beside every niche-shaped generic one (\p spec). The
    /// special members are the defaulted ones (the field is trivially
    /// copied and destroyed, which is the rule's condition), so the
    /// destroy and construct helpers, which switch on a tag, are not
    /// written. The record still declares `__kairo_Tag` for
    /// `__kairo_which()`, and answers the niche trait itself: a niche-filled
    /// ADT holding this one uses the field's patterns past these.
    priv fn _niche_record(self, en: *EnumDecl, lay: *StructDecl, head: string, spec: bool) {
        var d   = static_cast::<*Decl>(en);
        var at  = self._at(d);
        var nm  = self._spell->leaf(d);
        var p   = adt_niche_payload_variant(en);
        var pv  = en->variants[usize(p)];
        var fld = pv->payload[0];
        var ft  = self._niche_field_spelling(en);
        var mem = self._spell->leaf(static_cast::<*Decl>(pv->adt_member));
        var fnm = self._spell->leaf(static_cast::<*Decl>(fld));
        var nt  = "::" + LowerTargets::niche_trait() + "<" + ft + ">::";
        var w   = builtin_info(BuiltinKind::U64)->cxx;
        var dl  = adt_niche_dataless(en);
        var tt  = LowerTargets::adt_tag_type();
        self._cg->sink->spell(at, head);

        var dc = static_cast::<*DeclContext>(lay);
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var nd = *(dc->dc_decls.get(i));
            if (nd == &null) || (!self._is_type(nd)) { continue; }
            if isa::<UnionDecl>(nd) && cast::<UnionDecl>(nd)->is_anonymous { continue; }
            self._type_def(CXXSpell::rep(nd));
        }
        self._cg->sink->spell(at, self._spell->leaf(self._payload_struct_of(pv)) + " " + mem + ";");
        // A generic ADT's flags, which the Nullable surface's constraints
        // read: true by the specialization's own constraint.
        for var i: usize = 0; i < lay->fields.size(); ++i {
            var f = lay->fields[i];
            if (f == &null) || (f->storage != StorageClass::Eval) { continue; }
            self._cg->sink->spell(f->name.range, "static constexpr bool " + self._spell->leaf(static_cast::<*Decl>(f)) + " = true;");
        }

        var nx = self._adt_noexcept();
        for var i: usize = 0; i < lay->methods.size(); ++i {
            var m = lay->methods[i];
            if m == &null { continue; }
            var mat = self._at(static_cast::<*Decl>(m));
            if adt_role_is_nullable(m->adt_role) {
                self._cg->sink->spell(mat, self._niche_nullable_member(en, m, nm, nt, mem, fnm, ft));
                continue;
            }
            switch m->adt_role {
                case AdtRole::VariantCtor {
                    var vt = "::" + LowerTargets::adt_variant_tag() + f"<{m->adt_variant}>";
                    if m->adt_variant == p {
                        // The field constructor every concrete site calls,
                        // and the lambda one a generic body's site calls.
                        self._cg->sink->spell(mat, nm + "(" + vt + ", " + self._spell->decl(fld->type_, fnm, &null, d) + ")" + nx + " : " + mem + "{" + fnm + "} {}");
                        self._cg->sink->spell(mat, "template <class F> " + nm + "(" + vt + ", F&& f)" + nx + " : " + mem + "(static_cast<F&&>(f)()) {}");
                    } else {
                        self._cg->sink->spell(mat, nm + "(" + vt + ")" + nx + " : " + mem + "{" + nt + LowerTargets::niche_trait_pattern() + "("
                                                   + f"{adt_niche_pattern_of(en, m->adt_variant)}" + ")} {}");
                    }
                }
                case AdtRole::CopyCtor   { if m->adt_form == AdtForm::Trivial { self._cg->sink->spell(mat, nm + "(const " + nm + "&) = default;"); } }
                case AdtRole::MoveCtor   { if m->adt_form == AdtForm::Trivial { self._cg->sink->spell(mat, nm + "(" + nm + "&&) = default;"); } }
                case AdtRole::CopyAssign { if m->adt_form == AdtForm::Trivial { self._cg->sink->spell(mat, nm + "& operator=(const " + nm + "&) = default;"); } }
                case AdtRole::MoveAssign { if m->adt_form == AdtForm::Trivial { self._cg->sink->spell(mat, nm + "& operator=(" + nm + "&&) = default;"); } }
                case AdtRole::Dtor       { if m->adt_form == AdtForm::Trivial { self._cg->sink->spell(mat, "~" + nm + "() = default;"); } }
                case AdtRole::Which {
                    var s = tt + " " + LowerTargets::adt_which() + "() const" + nx + " { return ";
                    for var k: usize = 0; k < en->variants.size(); ++k {
                        if u32(k) == p { continue; }
                        s += nt + LowerTargets::niche_trait_test() + "(" + mem + "." + fnm + ", " + f"{adt_niche_pattern_of(en, u32(k))}" + ") ? "
                           + tt + "::" + self._spell->leaf(static_cast::<*Decl>(en->variants[k])) + " : ";
                    }
                    self._cg->sink->spell(mat, s + tt + "::" + self._spell->leaf(static_cast::<*Decl>(pv)) + "; }");
                }
                default { 0; }   // destroy and construct_from: no tag to switch on.
            }
        }

        self._cg->sink->spell(at, "static constexpr " + w + " " + LowerTargets::niche_count() + " = " + nt + LowerTargets::niche_trait_count() + " - " + f"{dl}" + ";");
        self._cg->sink->spell(at, nm + "(::" + LowerTargets::niche_ctor_tag() + ", " + w + " i) noexcept : " + mem + "{" + nt + LowerTargets::niche_trait_pattern() + "(" + f"{dl}" + " + i)} {}");
        self._cg->sink->spell(at, "static bool " + LowerTargets::niche_test() + "(const " + nm + "& v, " + w + " i) noexcept { return "
                                  + nt + LowerTargets::niche_trait_test() + "(v." + mem + "." + fnm + ", " + f"{dl}" + " + i); }");
        self._friends(d);
        self._cg->sink->spell(at, "};");
        self._cg->sink->brk();
        if !spec {
            // Pinned: no tag means the record is its payload struct.
            var ps = self._spell->leaf(self._payload_struct_of(pv));
            self._cg->sink->spell(at, "static_assert(sizeof(" + nm + ") == sizeof(" + nm + "::" + ps + ") && __is_standard_layout(" + nm + "));");
            self._cg->sink->brk();
        }
    }

    /// The payload struct variant \p v's union member is typed as.
    priv fn _payload_struct_of(self, v: *EnumVariantDecl) -> *Decl {
        var t = v->adt_member->type_;
        var c: *Type = &null;
        if (t != &null) && (t->canonical != &null) { c = canon_unqual(t->canonical); }
        if (c == &null) || (!isa::<RecordType>(c)) {
            self._ice(self._at(static_cast::<*Decl>(v)), "InterfaceEmitter: an ADT union member whose type is not its payload struct; EnumLayoutLowering gate failure");
        }
        return cast::<RecordType>(c)->decl;
    }

    /// The Nullable lang item's surface over the niche-filled record: null is
    /// pattern 0 in the field, present is any other value, `==` is the
    /// field's own (two nulls hold the same pattern).
    priv fn _niche_nullable_member(self, en: *EnumDecl, m: *FunctionDecl, nm: string, nt: string, mem: string, fnm: string, ft: string) -> string {
        var at  = self._at(static_cast::<*Decl>(m));
        var d   = static_cast::<*Decl>(en);
        var nx  = self._adt_noexcept();
        var val = LowerTargets::nullable_value();
        var nul = mem + "{" + nt + LowerTargets::niche_trait_pattern() + "(0)} {}";
        switch m->adt_role {
            case AdtRole::NullDefault { return nm + "()" + nx + " : " + nul; }
            case AdtRole::NullFrom {
                if m->params.size() != 1 { self._ice(at, "InterfaceEmitter: Nullable(null_t) without its parameter"); return ""; }
                return nm + "(" + self._spell->decl(m->params[0]->type_, "", &null, d) + ")" + nx + " : " + nul;
            }
            case AdtRole::ValueCopy { return nm + "(const " + ft + "& v)" + nx + " : " + mem + "{v} {}"; }
            case AdtRole::ValueMove { return nm + "(" + ft + "&& v)" + nx + " : " + mem + "{static_cast<" + ft + "&&>(v)} {}"; }
            case AdtRole::IsNull    { return "bool " + LowerTargets::nullable_is_null() + "() const" + nx + " { return " + nt + LowerTargets::niche_trait_test() + "(" + mem + "." + fnm + ", 0); }"; }
            case AdtRole::ValueRef  { return ft + "& " + val + "()" + nx + " { return " + mem + "." + fnm + "; }"; }
            case AdtRole::ValueCref { return "const " + ft + "& " + val + "() const" + nx + " { return " + mem + "." + fnm + "; }"; }
            case AdtRole::Equal {
                return "bool operator==(const " + nm + "& o) const" + nx + " requires requires (const " + ft + "& a) { a == a; } { return "
                     + mem + "." + fnm + " == o." + mem + "." + fnm + "; }";
            }
            default { 0; }
        }
        self._ice(at, "InterfaceEmitter: a Nullable role with no niche rendering");
        return "";
    }

    /// `__kairo_niche<E>` for plain enum \p en (EnumNiche): the values past
    /// its variants. At global scope, where the trait is, so the enum is
    /// spelled qualified.
    priv fn _enum_niche_trait(self, en: *EnumDecl) {
        var at = self._at(static_cast::<*Decl>(en));
        var e  = self._spell->qual_name(static_cast::<*Decl>(en));
        var w  = builtin_info(BuiltinKind::U64)->cxx;
        var nv = f"{en->variants.size()}";
        self._cg->sink->spell(at, "template <> struct " + LowerTargets::niche_trait() + "<" + e + "> { static constexpr " + w + " "
            + LowerTargets::niche_trait_count() + " = " + f"{enum_niche_count(en)}" + "; static " + e + " " + LowerTargets::niche_trait_pattern()
            + "(" + w + " i) noexcept { return static_cast<" + e + ">(" + nv + " + i); } static bool " + LowerTargets::niche_trait_test()
            + "(const " + e + "& v, " + w + " i) noexcept { return v == static_cast<" + e + ">(" + nv + " + i); } };");
        self._cg->sink->brk();
    }

    /// The niche trait, written once per TU (guarded in a header): count 0
    /// for anything without one, a pointer's null, and an ADT record's own
    /// answer (`__kairo_niche_count`, its `(__kairo_np, i)` constructor and
    /// `__kairo_niche_test`). A plain enum's is specialized after it
    /// (_enum_niche_trait). EnumLayoutQuery::niche_of is the same table.
    priv fn _niche_helpers(self, header: bool) {
        var at = self._tu_at();
        var w  = builtin_info(BuiltinKind::U64)->cxx;
        var nt = LowerTargets::niche_trait();
        var c  = LowerTargets::niche_trait_count();
        var pt = LowerTargets::niche_trait_pattern();
        var ts = LowerTargets::niche_trait_test();
        var np = LowerTargets::niche_ctor_tag();
        if header { self._cg->sink->directive(at, "#ifndef " + LowerTargets::niche_guard()); }
        if header { self._cg->sink->directive(at, "#define " + LowerTargets::niche_guard()); }
        self._cg->sink->spell(at, "struct " + np + " { explicit " + np + "() = default; };");
        self._cg->sink->brk();
        self._cg->sink->spell(at, "template <class T> struct " + nt + " { static constexpr " + w + " " + c + " = 0; };");
        self._cg->sink->brk();
        self._cg->sink->spell(at, "template <class T> struct " + nt + "<T*> { static constexpr " + w + " " + c + " = 1; static T* " + pt + "(" + w
            + ") noexcept { return nullptr; } static bool " + ts + "(T* const& v, " + w + ") noexcept { return v == nullptr; } };");
        self._cg->sink->brk();
        self._cg->sink->spell(at, "template <class T> requires requires { T::" + LowerTargets::niche_count() + "; } struct " + nt + "<T> { static constexpr "
            + w + " " + c + " = T::" + LowerTargets::niche_count() + "; static T " + pt + "(" + w + " i) noexcept { return T(::" + np + "{}, i); } "
            + "static bool " + ts + "(const T& v, " + w + " i) noexcept { return T::" + LowerTargets::niche_test() + "(v, i); } };");
        self._cg->sink->brk();
        if header { self._cg->sink->directive(at, "#endif"); }
    }

    /// An enum is defined here: a plain one with a niche trait, or any ADT.
    /// A header skips what it includes, as run() does.
    priv fn _needs_niche_helpers(self) -> bool {
        var header = (self._plan->mode() == PlanMode::Header);
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var e = &(self._plan->entries[i]);
            if (e->tier != PlanTier::Definitions) || (e->scope != &null) || (e->witness != &null) { continue; }
            if header && (!e->own) { continue; }
            var en = dyn_cast::<EnumDecl>(e->decl);
            if en == &null { continue; }
            if en->is_adt || enum_has_niche_trait(en) { return true; }
        }
        return false;
    }

    /// An ADT with a pack-expanded variant is defined here (as
    /// _needs_niche_helpers asks).
    priv fn _needs_pack_union(self) -> bool {
        var header = (self._plan->mode() == PlanMode::Header);
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var e = &(self._plan->entries[i]);
            if (e->tier != PlanTier::Definitions) || (e->scope != &null) || (e->witness != &null) { continue; }
            if header && (!e->own) { continue; }
            var en = dyn_cast::<EnumDecl>(e->decl);
            if (en != &null) && en->is_adt && (adt_pack_variant(en) != &null) { return true; }
        }
        return false;
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
            // A pack-expanded variant's: every element's, as a fold (true
            // for an empty pack).
            var fold = ps->adt_pack_param != &null;
            if fold { p = self._pack_payload(ps, lay->adt_of); }
            var term = "";
            if nm == LowerTargets::adt_trivial_dtor()      { term = "__is_trivially_destructible(" + p + ")"; }
            else if nm == LowerTargets::adt_trivial_copy() { term = "__is_trivially_copyable(" + p + ")"; }
            else if nm == LowerTargets::adt_destructible() { term = "__is_destructible(" + p + ")"; }
            else if nm == LowerTargets::adt_copyable()     { term = "__is_constructible(" + p + ", const " + p + "&)"; }
            else if nm == LowerTargets::adt_movable()      { term = "__is_constructible(" + p + ", " + p + "&&)"; }
            else { self._ice(self._at(static_cast::<*Decl>(f)), f"InterfaceEmitter: ADT record field '{nm}' is compile-time but none of the five flags"); }
            if fold { term = "(" + term + " && ...)"; }
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
        var nx   = self._adt_noexcept();
        var dreq = self._adt_requires(m, generic);   // a defaulted or deleted form: C++ deduces its noexcept.
        // A lang item's site slot (EnumDecl::adt_site_field) travels with the
        // tag: zeroed when a variant is built, copied wherever the tag is.
        var site_init   = "";
        var site_copy   = "";
        var site_assign = "";
        if en->adt_site_field != &null {
            var sn = self._spell->leaf(static_cast::<*Decl>(en->adt_site_field));
            site_init   = ", " + sn + "()";
            site_copy   = ", " + sn + "(o." + sn + ")";
            site_assign = sn + " = o." + sn + "; ";
        }
        var req  = nx + dreq;
        var tail = (" = default;") if (m->adt_form == AdtForm::Trivial) else (" = delete;");
        var body = m->adt_form == AdtForm::Body;
        switch m->adt_role {
            case AdtRole::VariantCtor {
                if usize(m->adt_variant) >= en->variants.size() {
                    self._ice(self._at(static_cast::<*Decl>(m)), "InterfaceEmitter: an ADT variant constructor past the last variant; EnumLayoutLowering gate failure");
                }
                var v    = en->variants[usize(m->adt_variant)];
                var vt   = "::" + LowerTargets::adt_variant_tag() + f"<{m->adt_variant}>";
                if en->adt_tag_member != &null {
                    // The common prefix: the tag goes in with the payload, or
                    // alone into the tag-only member.
                    var tv = tt + "::" + self._spell->leaf(static_cast::<*Decl>(v));
                    if v->adt_member == &null {
                        return nm + "(" + vt + ")" + nx + " : " + self._spell->leaf(static_cast::<*Decl>(en->adt_tag_member)) + "{" + tv + "} {}";
                    }
                    if v->adt_ctor != AdtCtorForm::Fields {
                        self._ice(self._at(static_cast::<*Decl>(m)), "InterfaceEmitter: a prefix-tagged variant without its field constructor; EnumLayoutLowering::_prefix_ok admits only trivial fields");
                    }
                    return self._field_ctor(en, v, nm, vt, "", nx, false, tv + ", ");
                }
                var init = tag + "(" + tt + "::" + self._spell->leaf(static_cast::<*Decl>(v)) + ")" + site_init;
                if v->adt_member == &null { return nm + "(" + vt + ")" + nx + " : " + init + " {}"; }
                if v->is_pack_expansion {
                    // Element K: the variant's tag plus K (EnumLayoutQuery::
                    // tag_value), built into the union's K-th member.
                    var u  = builtin_info(BuiltinKind::U32)->cxx;
                    var kv = "::" + LowerTargets::adt_variant_tag();
                    // A site slot (the Panic lang item) is the site id
                    // this construction stores (PANIC.md §1.4); a `panic`
                    // passes its own, a widening the one it copies.
                    var sp = "";
                    var si = site_init;
                    if en->adt_site_field != &null {
                        sp = u + " s, ";
                        si = ", " + self._spell->leaf(static_cast::<*Decl>(en->adt_site_field)) + "(s)";
                    }
                    return "template <" + u + " K, class F> " + nm + "(" + vt + ", " + kv + "<K>, " + sp + "F&& f)" + nx + " : " + tag + "(" + self._pack_tag(en, v, "K", tt) + ")"
                         + si + ", " + self._spell->leaf(static_cast::<*Decl>(v->adt_member)) + "(" + kv + "<K>{}, static_cast<F&&>(f)) {}";
                }
                // The payload is the callable's prvalue, so the union member
                // is built straight from it: nothing is copied or moved.
                var lam = "template <class F> " + nm + "(" + vt + ", F&& f)" + nx + " : " + init + ", "
                        + self._spell->leaf(static_cast::<*Decl>(v->adt_member)) + "(static_cast<F&&>(f)()) {}";
                switch v->adt_ctor {
                    case AdtCtorForm::Fields { return self._field_ctor(en, v, nm, vt, init, nx, false, ""); }
                    case AdtCtorForm::Both   { return self._field_ctor(en, v, nm, vt, init, nx, true, "") + " " + lam; }
                    default { 0; }
                }
                return lam;
            }
            case AdtRole::CopyCtor {
                if body { return nm + "(const " + nm + "& o)" + req + " : " + tag + "(o." + tag + ")" + site_copy + " { " + cf + "(o); }"; }
                return nm + "(const " + nm + "&)" + dreq + tail;
            }
            case AdtRole::MoveCtor {
                if body { return nm + "(" + nm + "&& o)" + req + " : " + tag + "(o." + tag + ")" + site_copy + " { " + cf + "(static_cast<" + nm + "&&>(o)); }"; }
                return nm + "(" + nm + "&&)" + dreq + tail;
            }
            case AdtRole::CopyAssign {
                // Destroying first would leave a self-assignment nothing to
                // copy from, so it does nothing instead.
                if body {
                    return nm + "& operator=(const " + nm + "& o)" + req + " { if (this != &o) { " + ds + "(); "
                         + tag + " = o." + tag + "; " + site_assign + cf + "(o); } return *this; }";
                }
                return nm + "& operator=(const " + nm + "&)" + dreq + tail;
            }
            case AdtRole::MoveAssign {
                if body {
                    return nm + "& operator=(" + nm + "&& o)" + req + " { if (this != &o) { " + ds + "(); "
                         + tag + " = o." + tag + "; " + site_assign + cf + "(static_cast<" + nm + "&&>(o)); } return *this; }";
                }
                return nm + "& operator=(" + nm + "&&)" + dreq + tail;
            }
            case AdtRole::Dtor {
                if body { return "~" + nm + "()" + req + " { " + ds + "(); }"; }
                return "~" + nm + "()" + dreq + tail;
            }
            case AdtRole::Destroy {
                var s = "void " + ds + "() noexcept { switch (" + tag + ") {";
                for var i: usize = 0; i < en->variants.size(); ++i {
                    var v = en->variants[i];
                    if (v == &null) || (v->adt_member == &null) || v->is_pack_expansion { continue; }
                    var mem = self._spell->leaf(static_cast::<*Decl>(v->adt_member));
                    s += " case " + tt + "::" + self._spell->leaf(static_cast::<*Decl>(v)) + ": " + mem + ".~" + self._payload_leaf(v) + "(); break;";
                }
                return s + " default: " + self._pack_default(en, ds, "") + "break; } }";
            }
            case AdtRole::ConstructFrom {
                // `new` finds the payload struct's own placement form, which
                // needs no <new>.
                var s = "template <class O> void " + cf + "(O&& o)" + nx + " { switch (" + tag + ") {";
                for var i: usize = 0; i < en->variants.size(); ++i {
                    var v = en->variants[i];
                    if (v == &null) || (v->adt_member == &null) || v->is_pack_expansion { continue; }
                    var mem = self._spell->leaf(static_cast::<*Decl>(v->adt_member));
                    s += " case " + tt + "::" + self._spell->leaf(static_cast::<*Decl>(v)) + ": new (&" + mem + ") "
                       + self._payload_leaf(v) + "(static_cast<O&&>(o)." + mem + "); break;";
                }
                return s + " default: " + self._pack_default(en, cf, "static_cast<O&&>(o).") + "break; } }";
            }
            // The tagged form; the niche-filled one is _niche_record's.
            case AdtRole::Which { return tt + " " + LowerTargets::adt_which() + "() const" + nx + " { return " + tag + "; }"; }
            default { 0; }
        }
        self._ice(self._at(static_cast::<*Decl>(m)), "InterfaceEmitter: an ADT role function with no rendering; EnumLayoutLowering minted a role this emitter does not know");
        return "";
    }

    /// The `default:` of Destroy / ConstructFrom for a pack-expanded variant
    /// (always last): a tag past its own is element (tag - its tag), which
    /// the union's helper \p fn reaches by that runtime index; \p from is
    /// the source object's prefix for ConstructFrom. "" without one.
    priv fn _pack_default(self, en: *EnumDecl, fn_: string, from: string) -> string {
        var v = adt_pack_variant(en);
        if (v == &null) || (v->adt_member == &null) { return ""; }
        var u   = builtin_info(BuiltinKind::U32)->cxx;
        var tag = "static_cast<" + u + ">(" + LowerTargets::adt_tag_field() + ")";
        var mem = self._spell->leaf(static_cast::<*Decl>(v->adt_member));
        var arg = (", " + from + mem) if (from.size() > 0) else ("");
        if en->adt_explicit_tags {
            // Type-id tags (_pack_tag): the element is the one whose id the
            // tag is, found by a fold over the pack; no match, no payload.
            var e = self._pack_name(en);
            var tid = "::" + LowerTargets::type_id();
            var none = "static_cast<" + u + ">(-1)";
            return "{ " + u + " k = 0, i = " + none + "; ((" + tid + "<" + e + "> == " + tag + " ? (void)(i = k) : (void)0, ++k), ...); "
                 + "if (i != " + none + ") { " + mem + "." + fn_ + "(i" + arg + "); } } ";
        }
        var tv  = f"{v->adt_tag_value}";
        return "if (" + tag + " >= " + tv + ") { " + mem + "." + fn_ + "(" + tag + " - " + tv + arg + "); } ";
    }

    /// Variant \p v's field constructor (AdtCtorForm::Fields / Both): each
    /// field by value, moved into the payload's braced initializer -- a
    /// prvalue initializing the union member, so nothing past the parameter
    /// is copied, and the runtime is the lambda form's: every field is
    /// trivially copied and destroyed (EnumLayoutLowering::_ctor_form), so
    /// the move out of the parameter and its destruction run no code. A
    /// generic ADT's is
    /// constrained on exactly that, which only C++ knows per instance; a
    /// site whose instance is concrete and qualifies calls it
    /// (VariantInitExpr::field_ctor), every other one the lambda form.
    priv fn _field_ctor(self, en: *EnumDecl, v: *EnumVariantDecl, nm: string, vt: string, init: string, nx: string,
                        constrained: bool, lead: string) -> string {
        var d     = static_cast::<*Decl>(en);
        var ps    = "";
        var vals  = "";
        var moves = "";
        for var i: usize = 0; i < v->payload.size(); ++i {
            var f  = v->payload[i];
            var fn_ = self._spell->leaf(static_cast::<*Decl>(f));
            var t  = self._spell->decl(f->type_, "", &null, d);
            ps += ", " + self._spell->decl(f->type_, fn_, &null, d);
            if i > 0 { vals += ", "; moves += " && "; }
            vals  += (fn_) if (self._scalar(f->type_)) else ("static_cast<" + t + "&&>(" + fn_ + ")");
            moves += "__is_constructible(" + t + ", " + t + "&&) && __is_trivially_copyable(" + t + ") && __is_trivially_destructible(" + t + ")";
        }
        var req = (" requires (" + moves + ")") if (constrained) else ("");
        var pre = (init + ", ") if (init.size() > 0) else ("");
        return nm + "(" + vt + ps + ")" + nx + req + " : " + pre
             + self._spell->leaf(static_cast::<*Decl>(v->adt_member)) + "{" + lead + vals + "} {}";
    }

    /// A field type whose move is its copy: a builtin or a pointer, passed
    /// on bare. Anything else is moved out of its parameter.
    priv fn _scalar(self, t: *Type) -> bool {
        if (t == &null) || (t->canonical == &null) { return false; }
        var c = canon_unqual(t->canonical);
        return (c != &null) && (isa::<BuiltinType>(c) || isa::<PointerType>(c));
    }

    /// ` noexcept` on a role function with a body, unless -funwind: each is
    /// part of a Kairo frame -- a variant constructor runs the payload's
    /// initializers, the transfers run the payloads' -- and a Kairo frame
    /// is noexcept by the same rule a closure is (EmitIR::_closure_expr).
    /// Without it every construction site is an invoke with a terminate
    /// landing pad, and the enclosing function carries a personality.
    priv fn _adt_noexcept(self) -> string {
        if self._cg->opts.unwind { return ""; }
        return " noexcept";
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
        var nx  = self._adt_noexcept();
        switch m->adt_role {
            case AdtRole::NullDefault { return nm + "()" + nx + null_init; }
            case AdtRole::NullFrom {
                if m->params.size() != 1 { self._ice(at, "InterfaceEmitter: Nullable(null_t) without its parameter"); return ""; }
                return nm + "(" + self._spell->decl(m->params[0]->type_, "", &null, d) + ")" + nx + null_init;
            }
            // Brace-initialized: the payload struct is an aggregate, so its
            // one field is built straight from the argument. Constrained by
            // the ADT's own flags, because an explicit instantiation defines
            // every member whose constraints hold: an unconstrained copy
            // constructor of a `Nullable<MoveOnly>` is a hard error there.
            case AdtRole::ValueCopy {
                return nm + "(const " + t + "& v)" + nx + " requires " + LowerTargets::adt_copyable() + " : " + present_init + "{v} {}";
            }
            case AdtRole::ValueMove {
                return nm + "(" + t + "&& v)" + nx + " requires " + LowerTargets::adt_movable() + " : " + present_init + "{static_cast<" + t + "&&>(v)} {}";
            }
            case AdtRole::IsNull    { return "bool " + LowerTargets::nullable_is_null() + "() const" + nx + " { return " + is_null + "; }"; }
            case AdtRole::ValueRef  { return t + "& " + val + "()" + nx + " { return " + mem + "." + fld + "; }"; }
            case AdtRole::ValueCref { return "const " + t + "& " + val + "() const" + nx + " { return " + mem + "." + fld + "; }"; }
            case AdtRole::Equal {
                return "bool operator==(const " + nm + "& o) const" + nx + " requires requires (const " + t + "& a) { a == a; } { return "
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
            // An array, element by element (FieldInitLowering, Arrays).
            case FieldFold::Elems {
                var s = " = {";
                for var i: usize = 0; i < f->init_elems.size(); ++i {
                    if i > 0 { s += ", "; }
                    s += self._spell->leaf(f->init_elems[i]) + "()";
                }
                return s + "}";
            }
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
        // The members EmitIR calls, one spelling each (LowerTargets).
        var st = LowerTargets::ctor_slot_set();
        var si = LowerTargets::ctor_slot_init();
        t += " bool " + st + " = false;";
        t += " " + sl + "() noexcept {}";
        t += " " + sl + "(const " + sl + "&) = delete;";
        t += " " + sl + "& operator=(const " + sl + "&) = delete;";
        t += " ~" + sl + "() { if (" + st + ") { b.~__b(); } }";
        t += " void " + si + "(T u) { new (static_cast<void*>(&b)) __b{static_cast<T&&>(u)}; " + st + " = true; }";
        t += " void " + LowerTargets::ctor_slot_put() + "(T u) { if (" + st + ") { b.v = static_cast<T&&>(u); } else { " + si + "(static_cast<T&&>(u)); } }";
        t += " T& " + LowerTargets::ctor_slot_get() + "() noexcept { return b.v; }";
        t += " T&& " + LowerTargets::ctor_slot_take() + "() noexcept { return static_cast<T&&>(b.v); }";
        t += " };";
        self._cg->sink->spell(at, t);
        self._cg->sink->brk();
        // An array field's slot. `init(T u)` would take a decayed pointer and
        // an array has no `=`, so this one builds its elements from the
        // array's, moved from a prvalue (a list literal) or copied from an
        // lvalue, or one at a time (`init_at`), and has no `put`:
        // CtorInitCheck allows one write. The field's mem-initializer reads
        // `take()[i]` per element (EmitIR).
        var a = "template <class T, " + sz + " N> struct " + sl + "<T[N]> {";
        a += " using __a = T[N];";
        a += " template <class I, I... K> struct __q {};";
        a += " struct __b { T v[N]; static void* operator new(" + sz + ", void* p) noexcept { return p; } };";
        a += " union { __b b; };";
        a += " bool " + st + " = false;";
        a += " " + sl + "() noexcept {}";
        a += " " + sl + "(const " + sl + "&) = delete;";
        a += " " + sl + "& operator=(const " + sl + "&) = delete;";
        a += " ~" + sl + "() { if (" + st + ") { b.~__b(); } }";
        a += " template <" + sz + "... K> void __mv(__a& u, __q<" + sz + ", K...>) { new (static_cast<void*>(&b)) __b{{static_cast<T&&>(u[K])...}}; " + st + " = true; }";
        a += " template <" + sz + "... K> void __cp(const __a& u, __q<" + sz + ", K...>) { new (static_cast<void*>(&b)) __b{{u[K]...}}; " + st + " = true; }";
        a += " void " + si + "(__a&& u) { __mv(u, " + LowerTargets::make_index_seq() + "<__q, " + sz + ", N>{}); }";
        a += " void " + si + "(const __a& u) { __cp(u, " + LowerTargets::make_index_seq() + "<__q, " + sz + ", N>{}); }";
        // Element by element (CtorInitCheck): each element is built once,
        // in place, in its own box (no <new>), and the array counts as built
        // when the last one is. A constructor never leaves S_pre with part of
        // it built (it cannot panic or return there, and every path builds
        // every element), so a partly built array is never destroyed.
        a += " struct __e { T v; static void* operator new(" + sz + ", void* p) noexcept { return p; } };";
        a += " " + sz + " __n = 0;";
        a += " void " + LowerTargets::ctor_slot_init_at() + "(" + sz + " k, T u) { new (static_cast<void*>(&b.v[k])) __e{static_cast<T&&>(u)}; if (++__n == N) { " + st + " = true; } }";
        a += " __a& " + LowerTargets::ctor_slot_get() + "() noexcept { return b.v; }";
        a += " __a&& " + LowerTargets::ctor_slot_take() + "() noexcept { return static_cast<__a&&>(b.v); }";
        a += " };";
        self._cg->sink->spell(at, a);
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

        if m->panic_result != &null { s += "[[nodiscard]] "; }   // PANIC.md §4.6, as _free_fn_text.
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
        // A panic result is the error (PANIC.md §4.6): a C++ caller that drops
        // it drops the error with it.
        if f->panic_result != &null { s += "[[nodiscard]] "; }
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
        if f->panic_result != &null { return self._spell->_type(f->panic_result); }   // PanicLowering's result (PANIC.md §4.1).
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
        // An instance over a value C++ computes (`Buf<twice(1)>`, EVAL.md
        // 0.2) may be the very specialization another spelling names
        // (`Buf<2>`), and C++ rejects two explicit instantiations of one: no
        // line; it is instantiated implicitly where used (its bodies are
        // visible, as every template's are).
        for var i: usize = 0; i < ie->args.size(); ++i {
            var v = dyn_cast::<TypeExpr>(ie->args[i]);
            if (v != &null) && v->is_value && (!v->is_exact()) { return; }
        }
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
        self._instance_layout_asserts(d, ie);
    }

    /// A type-id-tagged instance's elements (the Panic lang item, PANIC.md
    /// §1.3): `__kairo_tid<E>` specialized with the id Sema computed
    /// (InstanceEntry::type_ids). Written after tier 0, before anything can
    /// use one: a specialization after a use would be ill-formed. Each is
    /// written once per C++ TU (tid_seen; a header's guarded by its
    /// spelling's key): several instances, and a kcc include chain, share
    /// an element.
    priv fn _type_id_specs(self, d: *Decl, ie: *InstanceEntry) {
        var en = dyn_cast::<EnumDecl>(d);
        if (en == &null) || (!en->adt_explicit_tags) { return; }
        var p = adt_pack_param(en);
        if ie == &null { return; }
        if (p == usize(-1)) || (ie->type_ids.size() + p != ie->args.size()) {
            self._ice(self._at(d), "InterfaceEmitter: a type-id-tagged instance without an id per element; EnumLayoutQuery::sweep records them");
        }
        var u = builtin_info(BuiltinKind::U32)->cxx;
        var header = (self._plan->mode() == PlanMode::Header);
        for var i: usize = 0; i < ie->type_ids.size(); ++i {
            var key = ie->type_keys[i];
            var seen = false;
            for var j: usize = 0; j < self.tid_seen.size(); ++j { if self.tid_seen[j] == key { seen = true; break; } }
            if seen { continue; }
            self.tid_seen.push_back(key);
            var g = LowerTargets::type_id_guard(key);
            if header { self._cg->sink->directive(self._at(d), "#ifndef " + g); }
            if header { self._cg->sink->directive(self._at(d), "#define " + g); }
            // Its Kairo name too, what the C++ view's what() prints (PANIC.md
            // §4.6): one text per element, so every TU's specialization agrees.
            var nm = ("") if (i >= ie->type_names.size()) else (ie->type_names[i]);
            self._cg->sink->spell(self._at(d), "template <> struct " + LowerTargets::type_id_trait() + "<" + self._spell->_type(ie->args[p + i])
                                  + "> { static constexpr " + u + " value = 0x" + hex32(ie->type_ids[i]) + "u; "
                                  + "static constexpr const char* " + LowerTargets::type_id_name() + " = " + CXXSpell::c_string(nm) + "; };");
            if header { self._cg->sink->directive(self._at(d), "#endif"); }
        }
    }

    /// The layout Sema predicted for a generic ADT's instance
    /// (InstanceEntry::adt_shape / adt_size; EnumLayoutQuery::sweep), pinned
    /// where the instance is named: C++ picks the layout itself (the
    /// specialization's constraint), so a disagreement is a hard error here
    /// instead of Sema reading a field that is not where it thinks. A
    /// niche-filled instance is its payload struct and nothing else, and is
    /// standard-layout, so it is passed and returned as its one field is.
    priv fn _instance_layout_asserts(self, d: *Decl, ie: *InstanceEntry) {
        var en = dyn_cast::<EnumDecl>(d);
        if (en == &null) || (!en->is_adt) || (ie->adt_shape == 0) { return; }
        var x = self._spell->qual_name(d) + self._spell->args_str(&(ie->args));
        if ie->adt_size != 0 {
            self._cg->sink->spell(self._at(d), "static_assert(sizeof(" + x + ") == " + f"{ie->adt_size}" + ");");
            self._cg->sink->brk();
        }
        if ie->adt_shape != 2 { return; }
        var pv = en->variants[usize(adt_niche_payload_variant(en))];
        var ps = x + "::" + LowerTargets::adt_payload_type(self._spell->leaf(static_cast::<*Decl>(pv)));
        self._cg->sink->spell(self._at(d), "static_assert(sizeof(" + x + ") == sizeof(" + ps + ") && __is_standard_layout(" + x + "));");
        self._cg->sink->brk();
    }

    priv fn _ret_subst(self, f: *FunctionDecl, ie: *InstanceEntry) -> string {
        if f->panic_result != &null { return self._spell->_type(f->panic_result); }   // PanicLowering's result (PANIC.md §4.1).
        if f->is_noreturn || (f->return_type == &null) { return "void"; }
        return self._spell->return_spelling(f, ie);
    }
}
