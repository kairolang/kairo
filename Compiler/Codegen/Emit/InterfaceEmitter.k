/// --- The Kairo Project -------------- Codegen/Emit/InterfaceEmitter.k --- ///
///
///   \brief Emit an EmitPlan as C++ declarations. Two callers, one emitter
///          (Compiler/Spec/Codegen.md#plan-modes): Backend for a TU's preamble
///              (TokenSink),
///          EmitCXXHeader for the module's interop header (TextSink).
///
///   \par Where its parts are
///     This file holds the class: its fields, construction, run() (the
///     walk over the plan's tiers), the header prologue, the namespace
///     wrapping and the helpers every part uses. The rest of its methods
///     are `extend InterfaceEmitter` blocks, one file per concern, reaching
///     the fields as `prot` (Codegen/module.k makes Codegen/ one module); a
///     helper only its own part calls stays `priv` there:
///       InterfaceRecords.k    forward declarations, record definitions
///       InterfaceDerived.k    derived comparisons and assignment, unions
///       InterfaceHelpers.k    the runtime helper blocks (HelperBlock)
///       InterfaceEnums.k      plain enums, ADT enums, niche records
///       InterfaceInterop.k    C++ factories and allocation operators
///       InterfaceFields.k     field initializers, ctor slots, static fields
///       InterfaceFunctions.k  functions, extension scopes, instantiations
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
///     monomorphizer (Compiler/Spec/Codegen.md#remaining-work). No initializer
///         at all is `{}`: Kairo
///     has no uninitialized variable. Not inside a nested record's braces:
///     `T Outer::Inner::s = ...;` is a namespace-scope declaration.
///
///   \par What is NOT emitted (each an ICE naming its owner)
///     Named unions (later; an anonymous one is written inline as the field
///     that declares it), interfaces (no entity; witnesses MISSING), the
///     initializer of an eval array-typed field (FeatureGateCheck
///     rejects it), packs in expansion position, structural containers (the
///     container migration). Parameter defaults are not declared:
///     CallLowering's thunks supply them at every call.
///
///   Import law: CodegenContext only.
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

import AST::AttrFacts::AttrFacts
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::DeclFacts
import AST::EnumNiche::enum_has_niche_trait
import AST::Kind::DeclKind::DeclKind
import AST::LangItems::{
    LowerTargets,
    fmt_put_name,
    format_kind_of,
}
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::Decl
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    builtin_info,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
}
import AST::Node::Declarations
import AST::VisibilityFacts::{
    default_visibility_of,
    is_operator_fn,
    tu_module_dir,
}
import Codegen::CodegenContext::{
    CodegenContext,
    CodegenPhase,
}
import Codegen::CodegenICE::codegen_ice
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::EmitWitness::EmitWitness
import Codegen::Emit::InterfaceDerived
import Codegen::Emit::InterfaceEnums
import Codegen::Emit::InterfaceFields
import Codegen::Emit::InterfaceFunctions
import Codegen::Emit::InterfaceHelpers
import Codegen::Emit::InterfaceInterop
import Codegen::Emit::InterfaceRecords
import Codegen::Emit::Spell::{
    Speller,
    VIS_INTERNAL,
    VIS_NONE,
    VIS_PRIV,
    VIS_PROT,
    VIS_PUB,
}
import Codegen::EmitPlan::{
    EmitPlan,
    ExtScope,
    PlanEntry,
    PlanMode,
    PlanNeed,
    PlanTier,
}
import Location::SourceRange::SourceRange
import Support::FlagSet::{
    FlagBit,
    FlagSet,
}

/// A helper block a C++ TU holds at most once (run() writes each): a
/// definition, so a second copy is a redefinition, and an include's token
/// stream has no `#ifndef` to guard it with. One set, not a bool apiece:
/// the host TU's copy (Backend/IncludeEmitter.k) is handed to each emitter
/// and taken back whole, so a block added here cannot be missed by the
/// copy or by the reset at TU end.
pub enum HelperBlock derives u16 {
    Helpers      = 1 << 0,  ///< The lowering helpers (__kairo_tmp, ...).
    CtorSlots    = 1 << 1,  ///< _ctor_slot_helpers.
    FnValue      = 1 << 2,  ///< _fn_value_helper (`::__kairo_fn`).
    FmtDyn       = 1 << 3,  ///< _fmt_dyn_helper.
    EvalHelpers  = 1 << 4,  ///< `eval for` / eval generators.
    NicheHelpers = 1 << 5,  ///< _niche_helpers.
    PackUnion    = 1 << 6,  ///< _pack_union.
    PanicHelpers = 1 << 7,  ///< _panic_helpers.
    SiteType     = 1 << 8,  ///< _site_type.
    PanicApi     = 1 << 9,  ///< _panic_api.
    RawSlot      = 1 << 10, ///< _raw_slot_helpers.
    Nopanic      = 1 << 11, ///< _nopanic_helpers.
    CxxAlloc     = 1 << 12, ///< _cxx_alloc_helpers.
    UnionLocal   = 1 << 13, ///< _union_local_helpers.
    InstanceMove = 1 << 14, ///< LowerTargets::instance_move.
}

/// HelperBlock's variants are its FlagSet's bits (Support/FlagSet.k).
extend HelperBlock impl FlagBit<u16> {
    inline fn bit(const self) -> u16 {
        return self as u16
    }
}

pub class InterfaceEmitter {
    prot var _cg:    unsafe *CodegenContext
    prot var _plan:  unsafe *EmitPlan
    prot var _spell: unsafe *Speller
    /// Header mode: the module's own ffi includes, as directive lines, from
    /// EmitCXXHeader (which may see the HeaderSet; this file may not).
    priv var _ffi_lines: cxx::std::vector<string>

    /// The host C++ TU already holds the lowering helpers / the const-field
    /// constructor helpers: an earlier `#include "*.k"` in it wrote them
    /// (Backend/IncludeEmitter.k). They are definitions, and a token stream
    /// has no `#ifndef` to guard them with, so they are left out. run() marks
    /// each once it writes it, for the next include to read.
    pub var written: FlagSet<HelperBlock, u16>
    /// The host C++ TU compiles with exceptions (a kcc include: its
    /// LangOptions), so it gets the throwing half of the C++ view
    /// (_panic_api). A header decides with `#if __cpp_exceptions`; an
    /// object's own TU never throws and never gets it.
    pub var cxx_exceptions: bool = false
    /// The `__kairo_tid` specializations already written into this C++ TU
    /// (their keys): a token stream carries no guard, so a kcc include
    /// chain carries this from one include to the next (IncludedDecls).
    pub var tid_seen: cxx::std::vector<u64>
    /// The long compile-time strings (EmitPlan::big_strs, Compiler/Spec/Eval.md
    /// §11) already defined in this C++ TU, for the same reason.
    pub var estr_seen: cxx::std::vector<u64>
    /// The body emitter the caller runs after this one (EmitPlan::early,
    /// Compiler/Spec/Eval.md#value-nodes): tier 1 hands it each early item to define in place, and
    /// it skips them later. Null (`--print-cxx`'s preamble dump): a local
    /// one defines them.
    pub var ir: unsafe *EmitIR = &null
    /// The instances a kcc include's plan named but does not instantiate
    /// (IncludeEmitter prunes tier 3): their type-id specializations are
    /// still the host's to see.
    pub var pruned_insts: cxx::std::vector<unsafe *InstanceEntry>
    /// The value-parameter templates tier 1 has forward-declared
    /// (_vp_fwd_decls), each once.
    prot var _vp_declared: cxx::std::vector<unsafe *Decl>

    pub fn InterfaceEmitter(self, cg: unsafe *CodegenContext, plan: unsafe *EmitPlan) {
        self._cg    = cg
        self._plan  = plan
        self._spell = plan->spell()
    }

    fn set_ffi_lines(self, lines: cxx::std::vector<string>) {
        self._ffi_lines = lines
    }

    /// `__kairo_fmt_put`, LowerTargets::fmt_dyn: the put a generic body's
    /// f-string hole gets at each instance, chosen from the value's C++
    /// type in LiteralTyping's order -- a builtin's own row (spelled from
    /// builtin_info, so the rows are the types EmitIR writes), a string, a
    /// pointer's address, a plain enum's discriminant, a record's `repr()`,
    /// its `op as` string, its address -- and a static_assert for anything
    /// else, which is that instance's error. Only the types every target
    /// names are rows: a type clang refuses on the target (`__int128`,
    /// `_Float16`, `__bf16`, `__float128`, a wide `_BitInt`) is an error
    /// even in a discarded `if constexpr`, and byte and the soft floats are
    /// Kairo records a TU may not declare. Those values fall through to the
    /// enum / class rows or the assert. FIXME(FMT-DYN-WIDE): rows for them
    /// gated on the target.
    priv fn _fmt_dyn_helper(self) -> string {
        var kinds = cxx::std::vector<BuiltinKind>()
        kinds.push_back(BuiltinKind::Bool)
        kinds.push_back(BuiltinKind::Char)
        kinds.push_back(BuiltinKind::I8)
        kinds.push_back(BuiltinKind::I16)
        kinds.push_back(BuiltinKind::I32)
        kinds.push_back(BuiltinKind::I64)
        kinds.push_back(BuiltinKind::U8)
        kinds.push_back(BuiltinKind::U16)
        kinds.push_back(BuiltinKind::U32)
        kinds.push_back(BuiltinKind::U64)
        kinds.push_back(BuiltinKind::USize)
        kinds.push_back(BuiltinKind::ISize)
        kinds.push_back(BuiltinKind::F32)
        kinds.push_back(BuiltinKind::F64)

        var sz  = builtin_info(BuiltinKind::USize)->cxx.copy()
        var byt = builtin_info(BuiltinKind::U8)->cxx.copy()
        var out = "template <class B, class T> inline void " + LowerTargets::fmt_dyn() + "(B& b, T&& v, const " + byt + "* n, " + sz + " nl, unsigned long long s) {" + " using U = __remove_cvref(T); using S = __remove_cvref(decltype(b.finish()));"
        out += " if constexpr (__is_same(U, char)) b.put_u8(static_cast<" + byt + ">(v), s);"
        for var i: usize = 0; i < kinds.size(); ++i {
            var k = kinds[i]
            out += " else if constexpr (__is_same(U, " + builtin_info(
                k,
            )->cxx + ")) b." + fmt_put_name(format_kind_of(k)) + "(v, s);"
        }

        out += " else if constexpr (__is_same(U, S)) b.put_str(v, s);"
        out += " else if constexpr (__is_pointer(U)) b.put_ptr(reinterpret_cast<" + sz + ">(v), n, nl, s);"
        out += " else if constexpr (__is_enum(U)) b.put_i64(static_cast<long long>(v), s);"
        out += " else if constexpr (requires { v.repr(); }) b.put_str(v.repr(), s);"
        out += " else if constexpr (__is_class(U) && requires { static_cast<S>(v); }) b.put_str(static_cast<S>(v), s);"
        out += " else if constexpr (__is_class(U)) b.put_ptr(reinterpret_cast<" + sz + ">(" + LowerTargets::clang_addressof() + "(v)), n, nl, s);"
        out += " else static_assert(sizeof(U) == 0, \"an f-string hole in a generic body has no formatter for this instance's type\"); }"
        return out
    }

    /// ICE naming the Kairo source at \p at (CodegenICE).
    prot fn _ice(self, at: SourceRange, const msg: string) {
        codegen_ice(self._cg->ctx, at, msg)
    }

    /// # Entry point

    pub fn run(self) {
        self._cg->require_phase(CodegenPhase::Planned)
        var header = self._plan->mode() == PlanMode::Header
        if header {
            self._header_prologue()
        }

        // A rebuilding `op =` calls the global placement `::new`, which only
        // <new> declares: asked for ahead of every class, and only by a TU
        // or header that writes one (_needs_new). Outside the guard below:
        // a header that needs it may follow one that defined the guard
        // without it.
        if self._needs_new() {
            self._cg->sink->system_header(
                self._tu_at(),
                LowerTargets::cxx_new_header(),
            )
        }

        // A header carries the module's inline and template bodies too
        // (EmitPlan::visible_bodies), so it needs these as much as a
        // preamble. Guarded there: one C++ TU may include several Kairo
        // headers, and __kairo_tmp is a DEFINITION. An include's token
        // stream cannot be guarded; HelperBlock::Helpers stands in for the macro.
        if !self.written.has(HelperBlock::Helpers) {
            self._cg->sink->unanchored(true)
            if header {
                self._cg->sink->directive(
                    self._tu_at(),
                    "#ifndef " + LowerTargets::lower_helpers_guard(),
                )
            }

            if header {
                self._cg->sink->directive(
                    self._tu_at(),
                    "#define " + LowerTargets::lower_helpers_guard(),
                )
            }

            // The array-prvalue alias, once per TU, ahead of every body that
            // can name it.
            self._cg->sink->spell(
                self._tu_at(),
                "template <class T, decltype(sizeof(0)) N> using " + LowerTargets::array_alias() + " = T[N];",
            )

            self._cg->sink->brk()
            // The materialized-temporary helper: the one place it is spelled.
            // A forwarding reference binds the prvalue, so the address is the
            // temporary's, which lives to the end of the full-expression.
            self._cg->sink->spell(
                self._tu_at(),
                "template <class T> auto* " + LowerTargets::tmp_addr() + "(T&& t) { return " + LowerTargets::clang_addressof() + "(t); }",
            )


            self._cg->sink->brk()
            // The non-deduced spelling of a type (InterfaceFunctions::_forwarder).
            self._cg->sink->spell(
                self._tu_at(),
                "template <class T> struct " + LowerTargets::nondeduced() + " { using type = T; };",
            )

            self._cg->sink->brk()
            // An ADT's variant tags: `E(::__kairo_vt<I>{}, ...)` picks variant I's
            // constructor. The explicit default constructor keeps a bare `{}`
            // from converting into a tag.
            self._cg->sink->spell(
                self._tu_at(),
                "template <" + builtin_info(
                    BuiltinKind::U32,
                )->cxx + " I> struct " + LowerTargets::adt_variant_tag() + " { explicit " + LowerTargets::adt_variant_tag() + "() = default; };",
            )

            self._cg->sink->brk()
            // Construction and destruction in place. `new (p) T(...)` finds T's
            // own placement operator new first (an ADT payload declares one),
            // which needs no <new>, so it is never `::new`.
            self._cg->sink->spell(
                self._tu_at(),
                "template <class T, class... A> inline void " + LowerTargets::construct_at() + "(T* p, A&&... a) { new (p) T(static_cast<A&&>(a)...); }",
            )

            self._cg->sink->brk()
            self._cg->sink->spell(
                self._tu_at(),
                "template <class T> inline void " + LowerTargets::destroy_at() + "(T* p) noexcept { p->~T(); }",
            )

            self._cg->sink->brk()
            // An integer division's zero-divisor crash (EmitIR::_div_form).
            // Cold and noreturn: the check is one predicted branch, and in a
            // constant expression the call makes it non-constant, so an eval
            // division by zero is a compile error.
            self._cg->sink->spell(
                self._tu_at(),
                "extern \"C\" [[noreturn, gnu::cold]] void " + LowerTargets::div_zero_fn() + "() noexcept;",
            )

            self._cg->sink->brk()

            if header {
                self._cg->sink->directive(self._tu_at(), "#endif")
            }

            self._cg->sink->unanchored(false)
            self.written.set(HelperBlock::Helpers)
        }

        // A constructor that initializes a field in place (_ctor_slot_helpers).
        // Only when one is planned, so no other TU's text changes; guarded
        // apart from the helpers above, which an earlier header may have
        // defined without these.
        if !self.written.has(HelperBlock::CtorSlots) && self._needs_ctor_slots() {
            self._cg->sink->unanchored(true)
            self._ctor_slot_helpers(header)
            self._cg->sink->unanchored(false)
            self.written.set(HelperBlock::CtorSlots)
        }

        // A deferred f-string hole's put (EmitPlan::needs_fmt_dyn), guarded
        // on its own for the same reason.
        if !self.written.has(HelperBlock::FmtDyn) && self._plan->needs_fmt_dyn {
            self._cg->sink->unanchored(true)
            if header {
                self._cg->sink->directive(
                    self._tu_at(),
                    "#ifndef " + LowerTargets::fmt_dyn_guard(),
                )
            }

            if header {
                self._cg->sink->directive(
                    self._tu_at(),
                    "#define " + LowerTargets::fmt_dyn_guard(),
                )
            }

            self._cg->sink->spell(self._tu_at(), self._fmt_dyn_helper())
            self._cg->sink->brk()
            if header {
                self._cg->sink->directive(self._tu_at(), "#endif")
            }

            self._cg->sink->unanchored(false)
            self.written.set(HelperBlock::FmtDyn)
        }

        // The instance-decided move (EmitPlan::needs_instance_move), guarded
        // on its own for the same reason: the same test the instance check
        // reads as "cannot be copied".
        if !self.written.has(HelperBlock::InstanceMove) && self._plan->needs_instance_move {
            self._cg->sink->unanchored(true)
            if header {
                self._cg->sink->directive(
                    self._tu_at(),
                    "#ifndef " + LowerTargets::instance_move_guard(),
                )

                self._cg->sink->directive(
                    self._tu_at(),
                    "#define " + LowerTargets::instance_move_guard(),
                )
            }

            self._cg->sink->spell(
                self._tu_at(),
                "template <class T> constexpr decltype(auto) " + LowerTargets::instance_move() + "(T& v) noexcept { if constexpr (__is_constructible(T, T&)) { return static_cast<T&>(v); } else { return static_cast<T&&>(v); } }",
            )

            self._cg->sink->brk()
            if header {
                self._cg->sink->directive(self._tu_at(), "#endif")
            }

            self._cg->sink->unanchored(false)
            self.written.set(HelperBlock::InstanceMove)
        }

        // A Kairo `fn` value (EmitPlan::needs_fn_value), guarded on its own
        // for the same reason.
        if !self.written.has(HelperBlock::FnValue) && self._plan->needs_fn_value {
            self._cg->sink->unanchored(true)
            self._fn_value_helper(header)
            self._cg->sink->unanchored(false)
            self.written.set(HelperBlock::FnValue)
        }

        // `eval for` and eval generators (Compiler/Spec/Eval.md#eval-for), only where one is:
        // every other TU's text is unchanged.
        if !self.written.has(HelperBlock::EvalHelpers) && self._needs_eval_helpers() {
            self._cg->sink->unanchored(true)
            if header {
                self._cg->sink->directive(
                    self._tu_at(),
                    "#ifndef " + LowerTargets::eval_helpers_guard(),
                )
            }

            if header {
                self._cg->sink->directive(
                    self._tu_at(),
                    "#define " + LowerTargets::eval_helpers_guard(),
                )
            }

            // `eval for` and eval generators (Compiler/Spec/Eval.md#eval-for): the index pack an
            // expansion runs over, the compile-time buffer a generator
            // pushes into (a transient constexpr allocation, freed before
            // the constant escapes), and the literal array its values are
            // copied into. Plain text, needing no header.
            var sz = "decltype(sizeof(0))"
            self._cg->sink->spell(
                self._tu_at(),
                "template <class T, T... I> struct " + LowerTargets::eval_iseq() + " {};",
            )

            self._cg->sink->brk()
            var eb = LowerTargets::eval_buf()
            var bp = LowerTargets::eval_buf_data()  // EmitIR reads these three.
            var bn = LowerTargets::eval_buf_count()
            var bu = LowerTargets::eval_buf_push()
            self._cg->sink->spell(self._tu_at(),
                "template <class T> struct " + eb + " { T* " + bp + " = nullptr; " + sz + " " + bn + " = 0; " + sz + " cap = 0; " +
                "constexpr " + eb + "() = default; " +
                "constexpr " + eb + "(" + eb + "&& o) : " + bp + "(o." + bp + "), " + bn + "(o." + bn + "), cap(o.cap) { o." + bp + " = nullptr; o." + bn + " = 0; o.cap = 0; } " +
                eb + "(const " + eb + "&) = delete; " +
                // `::new` / `::delete[]`: in C++-facing text a Kairo record
                // has its own operator new (_cxx_alloc_ops), which constant
                // evaluation refuses; only the global one may run there.
                "constexpr void " + bu + "(T v) { if (" + bn + " == cap) { " + sz + " c = cap ? cap * 2 : 8; T* q = ::new T[c]; " +
                "for (" + sz + " i = 0; i < " + bn + "; ++i) q[i] = " + bp + "[i]; ::delete[] " + bp + "; " + bp + " = q; cap = c; } " + bp + "[" + bn + "++] = v; } " +
                "constexpr ~" + eb + "() { ::delete[] " + bp + "; } };")
            self._cg->sink->brk()
            self._cg->sink->spell(
                self._tu_at(),
                "template <class T, " + sz + " N> struct " + LowerTargets::eval_arr() + " { T " + LowerTargets::eval_arr_values() + "[N ? N : 1]; };",
            )

            self._cg->sink->brk()
            // A string literal C++ reads at compile time (Compiler/Spec/Eval.md#strings-at-compile-time): its
            // bytes and a NUL, keyed on the bytes, so one literal is one
            // object wherever it is spelled.
            self._cg->sink->spell(
                self._tu_at(),
                "template <unsigned char... C> inline constexpr unsigned char " + LowerTargets::eval_str() + "[sizeof...(C) + 1] = {C..., 0};",
            )

            self._cg->sink->brk()
            if header {
                self._cg->sink->directive(self._tu_at(), "#endif")
            }

            self._cg->sink->unanchored(false)
            self.written.set(HelperBlock::EvalHelpers)
        }

        // Each long compile-time string (Compiler/Spec/Eval.md#value-nodes): ahead of every type
        // and body, which may spell it (a consteval body, an eval binding,
        // a value argument), foreign ones included.
        self._big_strs(header)

        // The niche trait (_niche_helpers), wherever an enum is defined: a
        // plain enum's specialization of it follows the enum, and an ADT's
        // record answers it.
        if !self.written.has(HelperBlock::NicheHelpers) && self._needs_niche_helpers() {
            self._cg->sink->unanchored(true)
            self._niche_helpers(header)
            self._cg->sink->unanchored(false)
            self.written.set(HelperBlock::NicheHelpers)
        }

        // What a record's C++ operator new / delete call (_cxx_alloc_ops),
        // ahead of the first record C++-facing text defines.
        if !self.written.has(HelperBlock::CxxAlloc) && self._needs_cxx_alloc() {
            self._cg->sink->unanchored(true)
            self._cxx_alloc_helpers(header)
            self._cg->sink->unanchored(false)
            self.written.set(HelperBlock::CxxAlloc)
        }

        // A pack-expanded variant's payload union (_pack_union), wherever an
        // ADT with one is defined.
        if !self.written.has(HelperBlock::PackUnion) && self._needs_pack_union() {
            self._cg->sink->unanchored(true)
            if header {
                self._cg->sink->directive(
                    self._tu_at(),
                    "#ifndef " + LowerTargets::adt_pack_guard(),
                )
            }

            if header {
                self._cg->sink->directive(
                    self._tu_at(),
                    "#define " + LowerTargets::adt_pack_guard(),
                )
            }

            self._pack_union()
            if header {
                self._cg->sink->directive(self._tu_at(), "#endif")
            }

            self._cg->sink->unanchored(false)
            self.written.set(HelperBlock::PackUnion)
        }

        // The Panic lang item's layout helpers (_panic_helpers), wherever an
        // ADT with its knobs is defined.
        if !self.written.has(HelperBlock::PanicHelpers) && self._panic_enum_defined() != &null {
            self._cg->sink->unanchored(true)
            if header {
                self._cg->sink->directive(
                    self._tu_at(),
                    "#ifndef " + LowerTargets::panic_helpers_guard(),
                )
            }

            if header {
                self._cg->sink->directive(
                    self._tu_at(),
                    "#define " + LowerTargets::panic_helpers_guard(),
                )
            }

            self._panic_helpers(self._panic_enum_defined())
            if header {
                self._cg->sink->directive(self._tu_at(), "#endif")
            }

            self._cg->sink->unanchored(false)
            self.written.set(HelperBlock::PanicHelpers)
        }

        // A `try`'s raw slot with no Panic lang item defined here (a C++
        // exception arm's value, EmitPlan::needs_raw_slot).
        if !self.written.has(HelperBlock::RawSlot) && self._plan->needs_raw_slot {
            self._cg->sink->unanchored(true)
            self._raw_slot_helpers(header)
            self._cg->sink->unanchored(false)
        }

        // Union storage for locals a site ends early (EmitPlan::needs_union_local).
        if !self.written.has(HelperBlock::UnionLocal) && self._plan->needs_union_local {
            self._cg->sink->unanchored(true)
            self._union_local_helpers(header)
            self._cg->sink->unanchored(false)
        }

        // The duck-call wrapper's tag (EmitPlan::needs_nopanic).
        if !self.written.has(HelperBlock::Nopanic) && self._plan->needs_nopanic {
            self._cg->sink->unanchored(true)
            self._nopanic_helpers()
            self._cg->sink->unanchored(false)
        }

        // The record type of the TU's panic site table (EmitIR::_panic_sites,
        // Compiler/Spec/Panic.md#site-ids), when it has sites. The C++ view reads the table too
        // (_panic_api writes it then).
        if !self.written.has(HelperBlock::SiteType) && self._cg->tu->panic_sites.size() > 0 {
            self._cg->sink->unanchored(true)
            self._site_type(header)
            self._cg->sink->unanchored(false)
        }

        // A record of `main`'s file befriends it as `::main`, a qualified
        // name, which needs a declaration ahead of the record: the
        // definition's own head, at global scope (EmitIR::_free_fn).
        if self._plan->main_friend != &null {
            var unsafe *mf = self._plan->main_friend
            self._cg->sink->spell(
                self._fwd_at(mf),
                self._main_decl_text(mf, false),
            )

            self._cg->sink->brk()
        }

        var i: usize = 0
        var n        = self._plan->entries.size()

        // tier 0: consecutive same-namespace entries share one wrapper.
        while i < n && self._plan->entries[i].tier == PlanTier::FwdDecls {
            var *e = &self._plan->entries[i]
            var ns = self._entry_ns(e)
            // The unnamed nesting is part of the wrapper, so a run shares one
            // only if it agrees on that too: grouping on the segments alone
            // would put a `priv` decl in a `pub` decl's namespace.
            var anon   = self._entry_anon(e)
            var opened = self._ns_open(e->decl, &ns, anon)
            while i < n && self._plan->entries[i].tier == PlanTier::FwdDecls {
                var *f  = &self._plan->entries[i]
                var fns = self._entry_ns(f)
                if !self._same_ns(&ns, &fns) {
                    break
                }

                if self._entry_anon(f) != anon {
                    break
                }

                if header && !f->own && f->need == PlanNeed::Complete {
                    i += 1
                    continue
                } // included.

                if f->scope != &null {
                    self._cg->sink->spell(
                        self._at(f->decl),
                        "struct " + f->scope->name + ";",
                    )
                } else if f->witness != &null && f->is_concept {
                    // Guarded in a header, as the primary is: a definition.
                    var g = LowerTargets::concept_guard(
                        Speller::_path_ident(f->witness->key),
                    )

                    if header {
                        self._cg->sink->directive(self._tu_at(), "#ifndef " + g)
                    }

                    if header {
                        self._cg->sink->directive(self._tu_at(), "#define " + g)
                    }

                    EmitWitness(self._cg, self._spell).concept_def(f->witness)
                    if header {
                        self._cg->sink->directive(self._tu_at(), "#endif")
                    }
                } else if f->witness != &null && f->witness->std_hash {
                    // A class definition, so guarded in a header as a concept is.
                    var g = LowerTargets::witness_guard(
                        "decl_" + Speller::_path_ident(f->witness->key),
                    )

                    if header {
                        self._cg->sink->directive(self._tu_at(), "#ifndef " + g)
                    }

                    if header {
                        self._cg->sink->directive(self._tu_at(), "#define " + g)
                    }

                    EmitWitness(self._cg, self._spell).fwd(f->witness)
                    if header {
                        self._cg->sink->directive(self._tu_at(), "#endif")
                    }
                } else if f->witness != &null {
                    EmitWitness(self._cg, self._spell).fwd(f->witness)
                } else if !self._plan->value_param_record(f->decl, &null) {
                    // A template over a class-typed value parameter (Compiler/Spec/Eval.md
                    // 7e) cannot be declared before that class is complete:
                    // tier 1 declares it right after the class (_vp_fwd_decls).
                    self._fwd_decl(f->decl)
                }

                i += 1
            }

            self._ns_close(opened)
        }

        // The C++ view of a panic result (_panic_api), after the forward
        // declarations: its templates name the Panic lang item.
        if !self.written.has(HelperBlock::PanicApi) && self._panic_enum_defined() != &null {
            self._cg->sink->unanchored(true)
            self._panic_api(self._panic_enum_defined(), header)
            self._cg->sink->unanchored(false)
            self.written.set(HelperBlock::PanicApi)
        }

        // Each type-id-tagged instance's element ids (_type_id_specs), at
        // global scope after the forward declarations they name and before
        // any definition or body could use one.
        for var j: usize = 0; j < n; ++j {
            var *te = &self._plan->entries[j]
            if te->tier == PlanTier::Instantiations {
                self._type_id_specs(te->decl, te->inst)
            }
        }

        // A kcc include writes no instantiation, but its host instantiates
        // every Panic it uses: IncludeEmitter hands over the ones it pruned.
        for var j: usize = 0; j < self.pruned_insts.size(); ++j {
            var unsafe *pe = self.pruned_insts[j]
            self._type_id_specs(pe->primary, pe)
        }

        // The early items (EmitPlan::early, Compiler/Spec/Eval.md#value-nodes) are defined among
        // the records below; declared first, so a body may call one defined
        // after it, and read an eval binding whose definition follows. A
        // method is declared by its class. One whose own signature computes
        // from another early item (`eval fn f(a: [i32; g(1)])`) evaluates
        // that item where it is declared: it is declared once those are
        // defined instead (_late_decls), and EmitPlan::_early puts every
        // item that calls it after them too.
        var late   = cxx::std::vector<unsafe *Declarations::FunctionDecl>()
        var late_d = cxx::std::vector<unsafe *Decl>()
        var todo   = cxx::std::vector<unsafe *Decl>() // the early items tier 1 below still defines.
        for var j: usize = i; j < n && self._plan->entries[j].tier == PlanTier::Definitions; ++j {
            var *te = &self._plan->entries[j]
            if te->eval_item != &null && (!header || te->own) {
                todo.push_back(te->eval_item)
            }
        }

        for var j: usize = i; j < n && self._plan->entries[j].tier == PlanTier::Definitions; ++j {
            var *ee = &self._plan->entries[j]
            if ee->eval_item == &null || header && !ee->own {
                continue
            }

            var unsafe *ev = dyn_cast<Declarations::VariableDecl>(ee->eval_item)
            if ev != &null {
                self._wrapped(ee->decl, fn () { self._global_var_decl(ev) })
                continue
            }

            var unsafe *ef = dyn_cast<Declarations::FunctionDecl>(ee->eval_item)
            if ef == &null || DeclFacts::decl_extension_of(ee->eval_item) != &null {
                continue
            }

            var unsafe *fdc = ef->semantic_dc
            if fdc != &null && fdc->is_type_scope() {
                continue
            }

            if self._spell->is_main(ee->eval_item) {
                continue
            }

            var sig = cxx::std::vector<unsafe *Decl>()
            self._plan->sig_items(ef, unsafe &sig)
            if sig.size() > 0 {
                late.push_back(ef)
                late_d.push_back(ee->decl)
                continue
            }

            self._wrapped(ee->decl, fn () { self._free_fn_decl(ef, &null) })
        }

        self._late_decls(&late, &late_d, &todo)

        // The functions a record's friend line names qualified
        // (EmitPlan::friend_early), declared ahead of every record. A header
        // declares only its own module's: another's come with the header
        // that defines the record.
        for var j: usize = 0; j < self._plan->friend_early.size(); ++j {
            var unsafe *fe = self._plan->friend_early[j]
            if header && Speller::fid_of(unsafe (fe as unsafe *Decl)) != self._plan->home() {
                continue
            }

            self._wrapped(
                unsafe (fe as unsafe *Decl),
                fn () { self._free_fn_decl(fe, &null) },
            )
        }

        // tier 1
        var t0_end: usize = 0
        while t0_end < n && self._plan->entries[t0_end].tier == PlanTier::FwdDecls {
            t0_end += 1
        }

        self._vp_declared.clear()
        while i < n && self._plan->entries[i].tier == PlanTier::Definitions {
            self._vp_fwd_decls(t0_end, i, header)
            var unsafe *e = unsafe &self._plan->entries[i]
            i += 1
            if header && !e->own { // its header was included.
                continue
            }

            if e->eval_item != &null {
                if self.ir != &null {
                    self.ir->early(e->eval_item)
                } else {
                    var local_ir = EmitIR(self._cg)
                    local_ir.early(e->eval_item)
                }

                var left = cxx::std::vector<unsafe *Decl>()
                for var k: usize = 0; k < todo.size(); ++k {
                    if todo[k] != e->eval_item {
                        left.push_back(todo[k])
                    }
                }

                todo = left
                self._late_decls(&late, &late_d, &todo)
                continue
            }

            if e->scope != &null {
                var opened = self._ns_open(e->decl, &e->scope->ns, false)
                self._scope_def(e->scope)
                self._ns_close(opened)
                self._scope_panic_msg(e->scope)
                continue
            }

            if e->witness != &null {
                // Written by every header that reaches it, so guarded there
                // as a tuple record is: two headers in one C++ TU.
                var g = LowerTargets::witness_guard(
                    Speller::_path_ident(e->witness->key),
                )

                if header {
                    self._cg->sink->directive(self._tu_at(), "#ifndef " + g)
                }

                if header {
                    self._cg->sink->directive(self._tu_at(), "#define " + g)
                }

                if e->witness->std_hash {
                    var sns     = Speller::std_ns()
                    var sopened = self._ns_open(e->decl, &sns, false)
                    EmitWitness(self._cg, self._spell).def(e->witness)
                    self._ns_close(sopened)
                } else {
                    self._wrapped(
                        e->decl,
                        fn () { EmitWitness(self._cg, self._spell).def(e->witness) },
                    )
                }

                if header {
                    self._cg->sink->directive(self._tu_at(), "#endif")
                }

                continue
            }

            // A tuple record is defined by every TU and header that reaches
            // it (EmitPlan::_entry marks it own), so a HEADER's definition
            // is guarded: two headers in one C++ TU would define it twice.
            // A preamble includes nothing and is a token stream, which
            // carries no directive (the helpers above are guarded the same
            // way).
            var unsafe *tup  = dyn_cast<Declarations::StructDecl>(e->decl)
            var        guard = header && (tup != &null && tup->tuple_arity > 0)
            if guard {
                self._cg->sink->directive(
                    self._tu_at(),
                    "#ifndef " + LowerTargets::tuple_guard(
                        tup->tuple_arity as usize,
                    ),
                )

                self._cg->sink->directive(
                    self._tu_at(),
                    "#define " + LowerTargets::tuple_guard(
                        tup->tuple_arity as usize,
                    ),
                )
            }

            self._wrapped(
                e->decl,
                fn () {
                    self._type_def(e->decl)
                    self._static_defs(e->decl)
                },
            )

            if guard {
                self._cg->sink->directive(self._tu_at(), "#endif")
            }

            // A plain enum's niche: the trait's explicit specialization, at
            // global scope, right after the definition every use of it needs.
            var unsafe *pe = dyn_cast<Declarations::EnumDecl>(e->decl)
            if pe != &null && enum_has_niche_trait(pe) {
                self._enum_niche_trait(pe)
            }
        }

        // Any left (its class is not defined in this stream): declared
        // before the functions, which may name it.
        self._vp_fwd_decls(t0_end, i, header)

        // tier 2
        while i < n && self._plan->entries[i].tier == PlanTier::Functions {
            var *e = &self._plan->entries[i]
            i += 1
            if header && !e->own {
                continue
            }

            // EmitIR defines main at global scope as `int main`; a prior
            // declaration buys nothing, and inside the file's namespace it
            // would declare a different function.
            if self._spell->is_main(e->decl) {
                continue
            }

            if e->decl->kind == DeclKind::VariableDecl {
                self._wrapped(
                    e->decl,
                    fn () { self._global_var_decl(cast<Declarations::VariableDecl>(e->decl)) },
                )

                continue
            }

            self._wrapped(
                e->decl,
                fn () { self._free_fn_decl(cast<Declarations::FunctionDecl>(e->decl), &null) },
            )
        }

        // tier 3
        while i < n && self._plan->entries[i].tier == PlanTier::Instantiations {
            var *e = &self._plan->entries[i]
            i += 1
            if e->is_home { // definitions come after the bodies; see emit_home_instantiations
                continue
            }

            self._instantiation(e)
        }
    }

    /// Explicit instantiation DEFINITIONS, emitted by the backend after every
    /// body: an explicit instantiation only instantiates members defined
    /// before it.
    fn emit_home_instantiations(self) {
        self._cg->require_phase(CodegenPhase::Planned)
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var *e = &self._plan->entries[i]
            if e->tier != PlanTier::Instantiations || !e->is_home {
                continue
            }

            self._instantiation(e)
        }
    }

    /// # Header prologue

    /// `#pragma once`, then one `#include` per foreign module reached at
    /// Complete, or whose FUNCTION is declared: only an inline or template
    /// body names a foreign function, and tier 2 leaves a foreign one to its
    /// own header. Kairo forbids import cycles, so the include graph is a DAG.
    priv fn _header_prologue(self) {
        var at = self._tu_at()
        self._cg->sink->directive(at, "#pragma once")
        self._abi_guard(at)
        // The module's ffi headers first: its declarations and its inline
        // bodies name what they declare, exactly as the module's own TU did.
        for var i: usize = 0; i < self._ffi_lines.size(); ++i {
            self._cg->sink->directive(at, self._ffi_lines[i])
        }

        var seen = cxx::std::vector<string>()
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var *e = &self._plan->entries[i]
            if e->own {
                continue
            }

            if e->tier == PlanTier::Instantiations {
                continue
            }

            if e->need != PlanNeed::Complete && e->tier != PlanTier::Functions {
                continue
            }

            var p   = self._spell->header_path(Speller::tu_of(e->decl))
            var dup = false
            for var j: usize = 0; j < seen.size(); ++j {
                if seen[j] == p {
                    dup = true
                    break
                }
            }

            if dup {
                continue
            }

            seen.push_back(p)
            var line = "#include \""
            line += p
            line += "\""
            self._cg->sink->directive(at, line)
        }
    }

    /// A header that defines a `@relocatable` record refuses a compiler
    /// without `trivial_abi`: that compiler would pass the record through
    /// memory where Kairo's object code passes it in registers, and the two
    /// would link and corrupt each other's arguments.
    priv fn _abi_guard(self, at: SourceRange) {
        var found = false
        for var i: usize = 0; i < self._plan->entries.size() && !found; ++i {
            var *e = &self._plan->entries[i]
            found = e->own
                && e->decl != &null
                && e->scope == &null
                && e->witness == &null
                && self._holds_relocatable(e->decl)
        }

        if !found {
            return
        }

        self._cg->sink->directive(
            at,
            "#if !defined(__clang__) || !__has_cpp_attribute(clang::trivial_abi)",
        )

        self._cg->sink->directive(
            at,
            "#error \"Kairo headers require the Kairo Clang toolchain (trivial_abi)\"",
        )

        self._cg->sink->directive(at, "#endif")
    }

    /// \p d, or a record nested in it, is `@relocatable`.
    priv fn _holds_relocatable(self, d: unsafe *Decl) -> bool {
        if !self._is_type(d) {
            return false
        }

        if AttrFacts::is_relocatable(d) {
            return true
        }

        var unsafe *dc = Speller::dc_of(d)
        if dc == &null {
            return false
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd != &null && self._holds_relocatable(nd) {
                return true
            }
        }

        return false
    }

    /// The C++ is compiled for the Microsoft C++ ABI.
    prot fn _ms_abi(self) -> bool {
        return self._cg->opts.target_triple.ends_with("-msvc")
    }

    /// # Namespace wrapping

    priv fn _same_ns(self,
                     @inout a: cxx::std::vector<string>,
                     @inout b: cxx::std::vector<string>) -> bool {
        if a.size() != b.size() {
            return false
        }

        for var i: usize = 0; i < a.size(); ++i {
            if a[i] != b[i] {
                return false
            }
        }

        return true
    }

    /// Returns how many braces were opened: the named namespace, plus an
    /// unnamed one nested in it for a decl with no linkage outside its file.
    priv fn _ns_open(self,
                     d:         unsafe *Decl,
                     @inout ns: cxx::std::vector<string>,
                     anon:      bool) -> u32 {
        var at     = self._at(d)
        var n: u32 = 0
        if ns.size() > 0 {
            var s = "namespace "
            s += self._spell->ns_join(&ns)
            s += " {"
            self._cg->sink->spell(at, s)
            n += 1
        }

        if anon {
            self._cg->sink->spell(at, "namespace {")
            n += 1
        }

        return n
    }

    priv fn _ns_close(self, n: u32) {
        // Closing braces anchored on nothing better than the TU: the wrapper
        // has no bytes of its own.
        for var i: u32 = 0; i < n; ++i {
            self._cg->sink->spell(self._tu_at(), "}")
        }

        if n > 0 {
            self._cg->sink->brk()
        }
    }

    /// The early fns held back from the declarations ahead of tier 1 (their
    /// signature computes from another early item), each declared once no
    /// item its signature needs is still in \p todo; one defined meanwhile
    /// needs no declaration. Taken off \p late either way.
    priv fn _late_decls(self,
                        @inout late:   cxx::std::vector<unsafe *Declarations::FunctionDecl>,
                        @inout late_d: cxx::std::vector<unsafe *Decl>,
                        @inout todo:   cxx::std::vector<unsafe *Decl>) {
        var keep   = cxx::std::vector<unsafe *Declarations::FunctionDecl>()
        var keep_d = cxx::std::vector<unsafe *Decl>()
        for var k: usize = 0; k < late.size(); ++k {
            var unsafe *f      = (late)[k]
            var unsafe *fd     = unsafe (f as unsafe *Decl)
            var        defined = true
            for var t: usize = 0; t < todo.size(); ++t {
                if (todo)[t] == fd {
                    defined = false
                    break
                }
            }

            if defined {
                continue
            }

            var sig = cxx::std::vector<unsafe *Decl>()
            self._plan->sig_items(f, unsafe &sig)
            var ready = true
            for var a: usize = 0; a < sig.size() && ready; ++a {
                for var t: usize = 0; t < todo.size(); ++t {
                    if (todo)[t] == sig[a] {
                        ready = false
                        break
                    }
                }
            }

            if !ready {
                keep.push_back(f)
                keep_d.push_back((late_d)[k])
                continue
            }

            self._wrapped((late_d)[k], fn () { self._free_fn_decl(f, &null) })
        }

        (late)   = keep
        (late_d) = keep_d
    }

    prot fn _wrapped(self, d: unsafe *Decl, body: fn()) {
        // A definition of a C++-declared function declares nothing, so it
        // opens no namespace either (it is not in the module's).
        var unsafe *df = dyn_cast<Declarations::FunctionDecl>(d)
        if df != &null && Speller::defines_foreign(df) {
            return
        }

        var ns     = self._spell->ns_segments(d)
        var opened = self._ns_open(d, &ns, Speller::is_anon(d))
        body()
        self._ns_close(opened)
    }

    /// A plan entry's namespace: an extension scope's own, else its decl's.
    priv fn _entry_ns(self, e: *PlanEntry) -> cxx::std::vector<string> {
        if e->scope != &null {
            return e->scope->ns
        }

        if e->witness != &null && e->witness->std_hash {
            return Speller::std_ns()
        }

        return self._spell->ns_segments(e->decl)
    }

    /// An extension scope is never in the unnamed namespace: its members
    /// are reached as `::N::__kairo_ext_X::m` from other TUs' preambles,
    /// and a priv member is AccessCheck's to hide, not linkage's.
    priv fn _entry_anon(self, e: *PlanEntry) -> bool {
        if e->scope != &null {
            return false
        }

        return Speller::is_anon(e->decl)
    }

    prot fn _scope_qual(self, s: unsafe *ExtScope) -> string {
        var q = ""
        for var i: usize = 0; i < s->ns.size(); ++i {
            q += "::"
            q += s->ns[i]
        }

        return q + "::" + s->name
    }


    prot fn _at(self, d: unsafe *Decl) -> SourceRange {
        return Speller::at(d)
    }

    /// Byte 0 of the TU: the anchor for tokens that have no bytes of their
    /// own (a directive, a namespace's closing brace).
    prot fn _tu_at(self) -> SourceRange {
        // Unreachable for an empty TU (the driver skips it on EmitPlan::
        // is_empty), but a zero-byte file has no byte 0: anchor at the end
        // position instead, which a zero-length range may name.
        var fid = self._cg->tu->fid
        if self._cg->ctx->sm->get_file_size(fid) == 0 {
            return self._cg->ctx->sm->get_range(fid, 0, 0)
        }

        return self._cg->ctx->sm->get_range(fid, 0, 1)
    }

    prot fn _is_type(self, d: unsafe *Decl) -> bool {
        return d->kind == DeclKind::ClassDecl
            || d->kind == DeclKind::StructDecl
            || d->kind == DeclKind::EnumDecl
            || d->kind == DeclKind::UnionDecl
    }

    /// Emit an access specifier when the member's visibility differs from
    /// the running one. `prot` is `protected`.
    /// \p default_priv: an unmarked member of this kind is private (a class's
    /// variables, and nothing else).
    prot fn _access(self, cur: u8, want_in: u8, default_priv: bool, at: SourceRange) -> u8 {
        var want = want_in
        if want == VIS_NONE() {
            want = if (default_priv) => (VIS_PRIV()) else => VIS_PUB()
        }

        if want == cur {
            return cur
        }

        if want == VIS_PUB() {
            self._cg->sink->spell(at, "public:")
        }

        if want == VIS_PROT() {
            self._cg->sink->spell(at, "protected:")
        }

        if want == VIS_PRIV() {
            self._cg->sink->spell(at, "private:")
        }

        self._cg->sink->brk()
        return want
    }

    /// Every base is public in C++, whatever the edge says: a private base
    /// refuses the upcast Kairo allows through a `derives priv` edge from
    /// another file, and makes the checked downcast return null at run time
    /// -- a silent miscompile. AccessCheck enforces the edge in Kairo.
    prot fn _base_access(self, v: u8) -> string {
        return "public"
    }

    /// The access a member is written at: Kairo's own, with the record
    /// befriending its file (_friends). Speller::cxx_vis has the rule and
    /// the members that stay public whatever they say; this adds the module
    /// (AST/VisibilityFacts.k), which C++ has no access level for:
    ///
    ///   - `prot` in a module, written or by default, is `public:`: the
    ///     module's other files are no friends, and neither is a C++ TU
    ///     instantiating a template body of the module that reaches it.
    ///     Kairo's AccessCheck keeps it to the module; C++ outside the
    ///     module is kept from the module's `prot` top-level declarations
    ///     only (EmitPlan::_hidden), not from such a member.
    ///   - an unmarked member that is `priv` by default is `private:` in
    ///     what C++ includes (a header, `#include "x.k"`), which may not see
    ///     it; the module's own object keeps the old spelling, a class's
    ///     variables private and the rest public, so nothing Kairo-made
    ///     outside the record's friends loses access to it.
    ///     Not an operator: C++ probes those (VisibilityFacts::is_operator_fn).
    prot fn _cxx_vis(self, d: unsafe *Decl) -> u8 {
        var v = self._spell->cxx_vis(d)
        if d == &null || d->is_implicit || v == VIS_PUB() || v == VIS_INTERNAL() {
            return v
        }

        if v == VIS_NONE() {
            var dv = default_visibility_of(d)
            if dv == VisibilityKind::Public {
                return v
            }

            if dv == VisibilityKind::Protected {
                return VIS_PUB()
            }

            if is_operator_fn(d) {
                return v
            }

            return if (self._plan->mode() != PlanMode::Preamble) => (VIS_PRIV()) else => v
        }

        if v == VIS_PROT() && !tu_module_dir(Speller::tu_of(d)).empty() {
            return VIS_PUB()
        }

        return v
    }

    prot fn _is_ctor(self, m: unsafe *Declarations::FunctionDecl, owner: unsafe *Decl) -> bool {
        if m->is_operator {
            return false
        }

        return self._spell->leaf(unsafe (m as unsafe *Decl)) == self._spell->leaf(
            owner,
        )
    }
}
