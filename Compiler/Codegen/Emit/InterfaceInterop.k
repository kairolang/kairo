/// --- The Kairo Project -------------- Codegen/Emit/InterfaceInterop.k --- ///
///
///   InterfaceEmitter, part: the C++ interop members. The factories C++ code
///   constructs ADT variants with
///   (Compiler/Spec/Interop.md#constructing-adt-variants-from-c) and a record's
///   C++ allocation operators
///   (Compiler/Spec/Codegen.md#c-allocation-operators).
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

import AST::Context::DeclContext::DeclContext
import AST::DeclFacts
import AST::LangItems::{
    ABORT_EXIT_CODE,
    GlobalAllocFn,
    LowerTargets,
    cxx_std_name,
}
import AST::Node::Base::Decl
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Types::FixedArrayType
import Codegen::Emit::InterfaceEmitter::InterfaceEmitter
import Codegen::Emit::InterfaceEnums
import Codegen::Emit::Spell::Speller
import Codegen::EmitPlan::{
    PlanMode,
    PlanTier,
}
import Location::SourceRange::SourceRange

extend InterfaceEmitter {
    /// # C++ factories (Compiler/Spec/Interop.md#constructing-adt-variants-from-c)
    ///
    /// `static E V(fields...)` per variant of ADT \p en, for C++ that
    /// includes the module (a header, `#include "x.k"`): the tag form
    /// `E{::__kairo_vt<I>{}, ...}` is the record's internal shape, not an API.
    /// Never in the module's own object (PlanMode::Preamble): no Kairo code
    /// calls them, and each would be a body every Kairo TU compiles for
    /// nothing. Written into both bodies an ADT can have (_adt_def and
    /// _niche_record, the generic one's partial specialization included),
    /// so the name resolves whichever layout C++ picks.
    ///
    /// Each is a member TEMPLATE over an unused, defaulted parameter, which
    /// keeps the call spelling `E::V(...)` and is load-bearing twice:
    ///   - a generic ADT's header names its instances `extern template`,
    ///     and the module's object -- the explicit instantiation -- has no
    ///     factories; a plain inline member of such an instance is only
    ///     referenced from the C++ TU, never emitted (undefined symbol at
    ///     -O0). A member template is not covered by the explicit
    ///     instantiation, so the C++ TU instantiates it itself.
    ///   - a non-generic payload that is not movable (or not copyable) must
    ///     not break the whole header: the payload the lambda builds is
    ///     spelled through the dummy parameter, so the move out of the
    ///     by-value parameter is checked at a call, not at definition.
    ///
    /// Not written: a pack-expanded variant (one name, one expansion per
    /// payload type: no single signature), a variant with an array field (a
    /// C++ parameter of array type is a pointer), and the panic result type
    /// (adt_site_field / adt_void_unit: its site slot and `void` payload
    /// have their own C++ view, Compiler/Spec/Panic.md).
    prot fn _adt_factories(self,
                           en:       unsafe *Declarations::EnumDecl,
                           lay:      unsafe *Declarations::StructDecl,
                           const nm: string,
                           generic:  bool) {
        if self._plan->mode() == PlanMode::Preamble {
            return
        }

        if en->adt_site_field != &null || en->adt_void_unit {
            return
        }

        var unsafe *d    = unsafe (en as unsafe *Decl)
        var        mk    = LowerTargets::adt_factory_param()
        var        nx    = self._adt_noexcept()
        var        vt    = "::" + LowerTargets::adt_variant_tag()
        var        names = self._adt_factory_names(en, lay, nm, mk)
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v == &null || names[i].is_empty() {
                continue
            }

            var tag  = vt + f"<{i}>" + "{}"
            var head = "template <class " + mk + " = void> static " + nm + " " + names[i] + "("
            if v->adt_member == &null {
                self._cg->sink->spell(
                    v->name.range,
                    head + ")" + nx + " { return " + nm + "(" + tag + "); }",
                )

                continue
            }

            // Parameters as the field constructor spells them (_field_ctor):
            // by value, each moved on unless its move is its copy. A field
            // named like the record or the dummy would shadow the name the
            // body spells, so only its parameter moves aside.
            var ps   = ""
            var vals = ""
            for var j: usize = 0; j < v->payload.size(); ++j {
                var unsafe *f = v->payload[j]
                var        pn = self._spell->leaf(unsafe (f as unsafe *Decl))
                while pn == nm || pn == mk {
                    pn += "_"
                }

                var t = self._spell->decl(f->type_, "", &null, d)
                if j > 0 {
                    ps += ", "
                    vals += ", "
                }

                ps += self._spell->decl(f->type_, pn, &null, d)
                vals += if (self._scalar(f->type_)) => (pn)
                        else => "static_cast<" + t + "&&>(" + pn + ")"
            }

            var body = ""
            if v->adt_ctor == Declarations::AdtCtorForm::Fields {
                // The field constructor (a prefix-tagged record's included,
                // which writes the tag itself): every field moves as bytes.
                body = nm + "(" + tag + ", " + vals + ")"
            } else {
                // The lambda constructor builds the payload in place, as a
                // generic body's site does (EmitIR: `T(tag, [&]() -> P {
                // return {...}; })`). A generic record's payload is a
                // dependent type already; a concrete one is made dependent
                // on the dummy (see above).
                var p = self._spell->leaf(self._payload_struct_of(v))
                if !generic {
                    p = "__type_pack_element<0, " + p + ", " + mk + ">"
                }

                body = nm + "(" + tag + ", [&]()" + nx + " -> " + p + " { return { " + vals + " }; })"
            }

            self._cg->sink->spell(
                v->name.range,
                head + ps + ")" + nx + " { return " + body + "; }",
            )
        }
    }

    /// # C++ allocation operators (Compiler/Spec/Codegen.md#c-allocation-operators)
    ///
    /// Class-scope `operator new` / `operator delete` for record \p d (a
    /// class, a struct, an ADT enum; generic or not), so a C++ `new X` /
    /// `delete p` / `new X[n]` / `delete[] p` takes its storage from Kairo's
    /// allocator rather than C++'s global heap, and a C++ global `operator
    /// new` override does not reach a Kairo object. Written where the record
    /// is C++-facing (PlanMode Header / Include), like _adt_factories, never
    /// in the module's own object: no Kairo code spells a C++ new-expression
    /// on a record (create / destroy call the allocator themselves).
    ///
    /// Which allocator: the program's GLOBAL one, the kairo_global_* symbols
    /// (Lib/rt/global_alloc.h) Kairo's `Global` calls when a program sets
    /// one and the runtime defines weakly as `System` when none does. Not
    /// the scope stack: a C++ `delete` inside an open AllocatorScope must
    /// still give a global block back to the global heap
    /// (c-cpp-memory.mdx). Always the global one: a class cannot declare
    /// its own allocator (SC149E).
    ///
    /// Pairing with create / destroy: a single object asks for (sizeof X,
    /// alignof X), the size and alignment `create<X>` asks for and
    /// `destroy` frees with, so a C++ `delete` of a Kairo-created object (no
    /// scope open) and a Kairo `destroy` of a C++-newed one each free a
    /// block the way it was made. Arrays never cross to Kairo; they ask for
    /// at least 2 * sizeof(void*) so the array cookie is aligned. The
    /// sized `operator delete` is the only usual one declared: C++ then
    /// always passes the size (and gives every `new X[n]` a cookie to
    /// remember it), which System's small-block free needs.
    ///
    /// Failure: the throwing forms never return null (they are not
    /// noexcept, so the new-expression has no null test) and never throw:
    /// they crash with Kairo's out-of-memory message and exit code 134, as
    /// the default OOM hook does (`__kairo_cxx_got`). `new (std::nothrow)
    /// X` returns null, as `try_create` does. The placement form is
    /// declared too: a class-scope `operator new` hides the global ones, and
    /// `new (p) X(...)` (`__kairo_construct_at`, C++ users) must still work.
    ///
    /// Each is `exclude_from_explicit_instantiation`: a generic record's
    /// header names its instances `extern template`, and the module's
    /// explicit instantiation (Preamble text) has no operators, so C++ must
    /// instantiate them itself (the reason _adt_factories are templates;
    /// an allocation function may not be one).
    prot fn _cxx_alloc_ops(self, d: unsafe *Decl, const nm: string, at: SourceRange) {
        if self._plan->mode() == PlanMode::Preamble {
            return
        }

        if DeclFacts::decl_ffi_tag_target(d) != &null {
            return
        }

        var z  = LowerTargets::cxx_size_t()
        var av = "::" + cxx_std_name() + "::" + LowerTargets::cxx_align_val_t()
        var nt = "const ::" + cxx_std_name() + "::" + LowerTargets::cxx_nothrow_t() + "&"
        var x   = LowerTargets::attr_exclude_from_instantiation() + "static "
        var got = "::" + LowerTargets::cxx_alloc_got()
        // The allocator: always the program's global one. A class cannot
        // declare its own (SC149E), so there is nothing to route to.
        var alloc_fn = "::" + LowerTargets::global_alloc_symbol(
            GlobalAllocFn::Alloc,
        )

        var free_fn = "::" + LowerTargets::global_alloc_symbol(
            GlobalAllocFn::Free,
        )

        var one = "alignof(" + nm + ")"
        var arr = "(alignof(" + nm + ") > 2 * sizeof(void*) ? alignof(" + nm + ") : 2 * sizeof(void*))"
        var forms: cxx::std::vector<string>
        for var k: usize = 0; k < 2; ++k {
            var fnm = if (k == 0) => ("operator new") else => "operator new[]"
            var al  = if (k == 0) => (one) else => arr
            forms.push_back(
                x + "void* " + fnm + "(" + z + " n) { return " + got + "(" + alloc_fn + "(n ? n : 1, " + al + "), false); }",
            )

            forms.push_back(
                x + "void* " + fnm + "(" + z + " n, " + av + " a) { return " + got + "(" + alloc_fn + "(n ? n : 1, static_cast<" + z + ">(a)), false); }",
            )

            forms.push_back(
                x + "void* " + fnm + "(" + z + " n, " + nt + ") noexcept { return " + got + "(" + alloc_fn + "(n ? n : 1, " + al + "), true); }",
            )

            forms.push_back(
                x + "void* " + fnm + "(" + z + " n, " + av + " a, " + nt + ") noexcept { return " + got + "(" + alloc_fn + "(n ? n : 1, static_cast<" + z + ">(a)), true); }",
            )

            forms.push_back(
                x + "void* " + fnm + "(" + z + ", void* p) noexcept { return p; }",
            )
        }

        for var k: usize = 0; k < 2; ++k {
            var fnm = if (k == 0) => ("operator delete") else => "operator delete[]"
            var al  = if (k == 0) => (one) else => arr
            forms.push_back(
                x + "void " + fnm + "(void* p, " + z + " n) noexcept { if (p) " + free_fn + "(static_cast<unsigned char*>(p), n ? n : 1, " + al + "); }",
            )

            forms.push_back(
                x + "void " + fnm + "(void* p, " + z + " n, " + av + " a) noexcept { if (p) " + free_fn + "(static_cast<unsigned char*>(p), n ? n : 1, static_cast<" + z + ">(a)); }",
            )
        }

        for var i: usize = 0; i < forms.size(); ++i {
            self._cg->sink->spell(at, forms[i])
        }
    }

    /// What _cxx_alloc_ops calls, once per header or host TU: the allocator
    /// and crash entry points (C linkage, the runtime's; declared exactly as
    /// rt/global_alloc.h and rt/crash.h do, so a TU with both agrees: GNU
    /// `noreturn`, which may follow a first declaration without it, unlike
    /// `[[noreturn]]`, which clang then refuses), the
    /// two library types the operator signatures name (opaque, so the
    /// header needs no <new>; <new> before or after defines the same
    /// ones), and the null test the throwing forms share.
    prot fn _cxx_alloc_helpers(self, header: bool) {
        var at = self._tu_at()
        var z  = LowerTargets::cxx_size_t()
        if header {
            self._cg->sink->directive(
                at,
                "#ifndef " + LowerTargets::cxx_alloc_guard(),
            )
        }

        if header {
            self._cg->sink->directive(
                at,
                "#define " + LowerTargets::cxx_alloc_guard(),
            )
        }

        self._cg->sink->spell(
            at,
            "namespace " + cxx_std_name() + " { enum class " + LowerTargets::cxx_align_val_t() + " : " + z + "; struct " + LowerTargets::cxx_nothrow_t() + "; }",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "extern \"C\" unsigned char* " + LowerTargets::global_alloc_symbol(
                GlobalAllocFn::Alloc,
            ) + "(" + z + " size, " + z + " align) noexcept;",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "extern \"C\" void " + LowerTargets::global_alloc_symbol(
                GlobalAllocFn::Free,
            ) + "(unsigned char* ptr, " + z + " size, " + z + " align) noexcept;",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "extern \"C\" __attribute__((noreturn)) void " + LowerTargets::rt_crash_exit() + "(const unsigned char* msg, " + z + " len, int code) noexcept;",
        )

        self._cg->sink->brk()
        // The default OOM hook's message and status (alloc_raw.k default_oom).
        // The message has no byte a C string literal must escape.
        var oom = LowerTargets::oom_message()
        self._cg->sink->spell(
            at,
            "inline void* " + LowerTargets::cxx_alloc_got() + "(unsigned char* p, bool nothrow) noexcept { " + "if (" + LowerTargets::clang_expect() + "(p == nullptr, 0) && !nothrow) ::" + LowerTargets::rt_crash_exit() + "(reinterpret_cast<const unsigned char*>(\"" + oom + "\"), " + f"{oom.size()}" + ", " + f"{ABORT_EXIT_CODE}" + "); " + "return p; }",
        )

        self._cg->sink->brk()
        if header {
            self._cg->sink->directive(at, "#endif")
        }
    }

    /// A record C++-facing text defines (as _needs_niche_helpers asks): it
    /// gets _cxx_alloc_ops. Never in the module's own object.
    prot fn _needs_cxx_alloc(self) -> bool {
        if self._plan->mode() == PlanMode::Preamble {
            return false
        }

        var header = self._plan->mode() == PlanMode::Header
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var *e = &self._plan->entries[i]
            if e->tier != PlanTier::Definitions
                || e->scope != &null
                || e->witness != &null
                || e->eval_item != &null {
                continue
            }

            if header && !e->own {
                continue
            }

            if isa<Declarations::ClassDecl>(e->decl) || isa<Declarations::StructDecl>(e->decl) {
                return true
            }

            var unsafe *en = dyn_cast<Declarations::EnumDecl>(e->decl)
            if en != &null && en->is_adt {
                return true
            }
        }

        return false
    }

    /// The C++ name of each variant's factory (_adt_factories), by variant
    /// index; empty for a variant that gets none. A factory is named exactly
    /// after its variant unless that name is already taken in the record --
    /// the record's own name (a member may not share it), a template
    /// parameter (shadowing one is ill-formed), any member the record
    /// writes, or the dummy parameter -- in which case it gets `_` appended,
    /// repeated while the result is taken (Speller::
    /// decide_tops). Unclashed variants claim their names first, so a
    /// variant literally named `V_` keeps it and the clashing `V` moves on
    /// to `V__`: the answer depends on the set of names, not their order.
    priv fn _adt_factory_names(self,
                               en:       unsafe *Declarations::EnumDecl,
                               lay:      unsafe *Declarations::StructDecl,
                               const nm: string,
                               const mk: string) -> cxx::std::vector<string> {
        var unsafe *d                              = unsafe (en as unsafe *Decl)
        var        taken: cxx::std::vector<string>
        taken.push_back(nm)
        taken.push_back(mk)
        var gps = Speller::template_params(d)
        for var i: usize = 0; i < gps.size(); ++i {
            taken.push_back(
                self._spell->tok_name(gps[i]->name, Speller::fid_of(d)),
            )
        }

        // Every member the record is written with: its nested types and
        // fields (EnumLayoutLowering's), the union members a variant's
        // payload lives in, the role functions, and the members the
        // emitter spells itself (the niche and Null surfaces).
        var unsafe *dc = unsafe (lay as unsafe *DeclContext)
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd == &null {
                continue
            }

            if isa<Declarations::UnionDecl>(nd) && cast<Declarations::UnionDecl>(nd)->is_anonymous {
                continue
            }

            taken.push_back(self._spell->leaf(nd))
        }

        for var i: usize = 0; i < lay->fields.size(); ++i {
            var unsafe *f = lay->fields[i]
            if f != &null && !f->is_anonymous_union {
                taken.push_back(self._spell->leaf(unsafe (f as unsafe *Decl)))
            }
        }

        for var i: usize = 0; i < lay->methods.size(); ++i {
            var unsafe *m = lay->methods[i]
            if m != &null {
                taken.push_back(self._spell->leaf(unsafe (m as unsafe *Decl)))
            }
        }

        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v != &null && v->adt_member != &null {
                taken.push_back(self._spell->leaf(v->adt_member))
            }
        }

        taken.push_back(LowerTargets::adt_tag_field())
        taken.push_back(LowerTargets::adt_tag_type())
        taken.push_back(LowerTargets::adt_destroy())
        taken.push_back(LowerTargets::adt_construct_from())
        taken.push_back(LowerTargets::adt_which())
        taken.push_back(LowerTargets::niche_count())
        taken.push_back(LowerTargets::niche_test())
        // The Null surface's names are not reserved (`is_null`), so
        // only the record that has that surface takes them.
        for var i: usize = 0; i < lay->methods.size(); ++i {
            var unsafe *m = lay->methods[i]
            if m != &null && Declarations::adt_role_is_nullable(m->adt_role) {
                taken.push_back(LowerTargets::nullable_is_null())
                taken.push_back(LowerTargets::nullable_value())
                break
            }
        }

        var out:    cxx::std::vector<string>
        var clash:  cxx::std::vector<u8> // 1 where the variant's own name was taken
        var members                          = taken.size()
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v   = en->variants[i]
            var        keep = v != &null && !v->is_pack_expansion
            if keep {
                for var j: usize = 0; j < v->payload.size(); ++j {
                    var unsafe *t = v->payload[j]->type_
                    if t == &null
                        || t->canonical == &null
                        || isa<FixedArrayType>(canon_unqual(t->canonical)) {
                        keep = false
                        break
                    }
                }
            }

            if !keep {
                out.push_back("")
                clash.push_back(0)
                continue
            }

            var n   = self._spell->leaf(unsafe (v as unsafe *Decl))
            var hit = false
            for var k: usize = 0; k < members; ++k {
                if taken[k] == n {
                    hit = true
                    break
                }
            }

            out.push_back(n)
            clash.push_back(if (hit) => (1 as u8) else => (0 as u8))
            if !hit {
                taken.push_back(n)
            }
        }

        for var i: usize = 0; i < out.size(); ++i {
            if clash[i] == 0 {
                continue
            }

            var n = out[i].copy()
            while true {
                var hit = false
                for var k: usize = 0; k < taken.size(); ++k {
                    if taken[k] == n {
                        hit = true
                        break
                    }
                }

                if !hit {
                    break
                }

                n += "_"
            }

            out[i] = n.copy()
            taken.push_back(n)
        }

        return out
    }
}
