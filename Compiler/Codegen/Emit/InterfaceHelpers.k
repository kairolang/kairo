/// --- The Kairo Project -------------- Codegen/Emit/InterfaceHelpers.k --- ///
///
///   InterfaceEmitter, part: helper blocks. The runtime C++ a TU defines
///   once, ahead of the declarations that use it, each behind a HelperBlock
///   bit: the panic API and its sets, raw slots, union-storage locals,
///   forwarding, the no-panic wrappers, niche traits and pack unions.
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

import AST::DeclFacts
import AST::EnumNiche::enum_has_niche_trait
import AST::LangItems::{
    LangMembers,
    LowerTargets,
    WellKnownType,
}
import AST::Node::Base::Decl
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    builtin_info,
}
import AST::Node::Casting::dyn_cast
import AST::Node::Declarations
import Codegen::Emit::InterfaceEmitter::{
    HelperBlock,
    InterfaceEmitter,
}
import Codegen::Emit::InterfaceEnums
import Codegen::Emit::Spell
import Codegen::EmitPlan::{
    ExtScope,
    PlanMode,
    PlanTier,
}
import Config::Target::ObjectFormat
import Token::TokenKind::TokenKind

extend InterfaceEmitter {
    /// The Panic lang item's preamble (Compiler/Spec/Panic.md#layout, §1.3):
    ///   `__kairo_tid<E>`        incomplete: an element type with no
    ///                           specialization (no id from Sema) is a
    ///                           compile error, never a silent tag 0;
    ///   `__kairo_type_id<E>`    the id, read off the specialization;
    ///   `__kairo_unit`, `__kairo_nv<T>`   T, or an empty struct for void;
    ///   `__kairo_max_align<P...>(f)`      max(f, alignof(P)...).
    prot fn _panic_helpers(self, en: unsafe *Declarations::EnumDecl) {
        var u  = builtin_info(BuiltinKind::U32)->cxx.copy()
        var at = self._tu_at()
        var ti = LowerTargets::type_id_trait()
        self._cg->sink->spell(at, "template <class E> struct " + ti + ";")
        self._cg->sink->spell(
            at,
            "template <class E> inline constexpr " + u + " " + LowerTargets::type_id() + " = " + ti + "<E>::value;",
        )

        self._cg->sink->spell(
            at,
            "struct " + LowerTargets::unit_type() + " {};",
        )

        var vs = LowerTargets::void_unit_trait()
        self._cg->sink->spell(
            at,
            "template <class T> struct " + vs + " { using type = T; };",
        )

        self._cg->sink->spell(
            at,
            "template <> struct " + vs + "<void> { using type = " + LowerTargets::unit_type() + "; };",
        )

        self._cg->sink->spell(
            at,
            "template <class T> using " + LowerTargets::void_unit() + " = typename " + vs + "<T>::type;",
        )

        self._cg->sink->spell(
            at,
            "template <class... P> constexpr " + u + " " + LowerTargets::max_align() + "(" + u + " f) noexcept { " + u + " a = f; ((a = (alignof(P) > a) ? static_cast<" + u + ">(alignof(P)) : a), ...); return a; }",
        )

        self._cg->sink->brk()
        self._raw_slot_helpers(self._plan->mode() == PlanMode::Header)
        self._fwd_helpers(en)
        self._pset_helpers()
    }

    /// `__kairo_pset<P, T, E...>` (Compiler/Spec/Panic.md#generic-bodies): a panic result whose set
    /// names a type parameter, ordered by C++ at each instance -- the
    /// elements deduplicated and sorted by type id, Sema's canonical order
    /// (§1.3), so a generic function's `Panic<i32, T, A>` at T = B is the
    /// `Panic<i32, A, B>` (or at T = A the `Panic<i32, A>`) every concrete
    /// former of that set names. Insertion over a type list; two types with
    /// one id are a collision (Sema reports one it can see; this stops one
    /// only C++ sees, an instance a kcc host makes). Every element needs its
    /// `__kairo_tid`: one nobody gave an id is a compile error, never tag 0.
    priv fn _pset_helpers(self) {
        var at  = self._tu_at()
        var tl  = LowerTargets::panic_set_list()
        var ins = LowerTargets::panic_set_insert()
        var ia  = LowerTargets::panic_set_insert_at()
        var cn  = LowerTargets::panic_set_cons()
        var so  = LowerTargets::panic_set_sort()
        var ap  = LowerTargets::panic_set_apply()
        var al  = LowerTargets::panic_set_alias()
        var tid = "::" + LowerTargets::type_id()
        var tp  = "template <class, class...> class P"
        self._cg->sink->spell(at, "template <class... E> struct " + tl + " {};")
        self._cg->sink->spell(
            at,
            "template <class H, class L> struct " + cn + ";",
        )

        self._cg->sink->spell(
            at,
            "template <class H, class... R> struct " + cn + "<H, " + tl + "<R...>> { using type = " + tl + "<H, R...>; };",
        )

        self._cg->sink->spell(
            at,
            "template <class X, class L> struct " + ins + ";",
        )

        self._cg->sink->spell(
            at,
            "template <int C, class X, class H, class... R> struct " + ia + ";",
        )

        self._cg->sink->spell(
            at,
            "template <class X> struct " + ins + "<X, " + tl + "<>> { using type = " + tl + "<X>; };",
        )

        self._cg->sink->spell(
            at,
            "template <class X, class H, class... R> struct " + ia + "<-1, X, H, R...> { using type = " + tl + "<X, H, R...>; };",
        )

        self._cg->sink->spell(
            at,
            "template <class X, class H, class... R> struct " + ia + "<0, X, H, R...> { " + "static_assert(__is_same(X, H), \"two types with one panic type id cannot be in one panic set\"); using type = " + tl + "<H, R...>; };",
        )

        self._cg->sink->spell(
            at,
            "template <class X, class H, class... R> struct " + ia + "<1, X, H, R...> { using type = typename " + cn + "<H, typename " + ins + "<X, " + tl + "<R...>>::type>::type; };",
        )

        self._cg->sink->spell(
            at,
            "template <class X, class H, class... R> struct " + ins + "<X, " + tl + "<H, R...>> : " + ia + "<(" + tid + "<X> < " + tid + "<H>) ? -1 : ((" + tid + "<X> == " + tid + "<H>) ? 0 : 1), X, H, R...> {};",
        )

        self._cg->sink->spell(
            at,
            "template <class L, class... E> struct " + so + " { using type = L; };",
        )

        self._cg->sink->spell(
            at,
            "template <class L, class X, class... E> struct " + so + "<L, X, E...> : " + so + "<typename " + ins + "<X, L>::type, E...> {};",
        )

        self._cg->sink->spell(
            at,
            "template <" + tp + ", class T, class L> struct " + ap + ";",
        )

        self._cg->sink->spell(
            at,
            "template <" + tp + ", class T, class... E> struct " + ap + "<P, T, " + tl + "<E...>> { using type = P<T, E...>; };",
        )

        self._cg->sink->spell(
            at,
            "template <" + tp + ", class T, class... E> using " + al + " = typename " + ap + "<P, T, typename " + so + "<" + tl + "<>, E...>::type>::type;",
        )

        self._cg->sink->brk()
    }

    /// `__kairo_raw<T>` (Compiler/Spec/Panic.md#paniclowering): storage for a T that the path
    /// which never fills it never builds -- a union, so its empty
    /// constructor and destructor leave the member alone. Filled once by
    /// placement into `__kairo_b` (EmitIR, PanicOp::SlotPut: the box brings
    /// its own placement `new`, so no <new>), read once by `__kairo_take()`,
    /// which moves the value out and destroys the box: from there the value
    /// is an ordinary local, which every exit destroys.
    prot fn _raw_slot_helpers(self, header: bool) {
        // Written with the Panic helpers or alone (a C++ arm's slot), once
        // per C++ TU: its own guard in a header, either way.
        if self.written.has(HelperBlock::RawSlot) {
            return
        }

        self.written.set(HelperBlock::RawSlot)
        var at = self._tu_at()
        if header {
            self._cg->sink->directive(
                at,
                "#ifndef " + LowerTargets::raw_slot_guard(),
            )
        }

        if header {
            self._cg->sink->directive(
                at,
                "#define " + LowerTargets::raw_slot_guard(),
            )
        }

        var bx = LowerTargets::raw_box()
        var bm = LowerTargets::raw_box_member()
        var bv = LowerTargets::raw_box_value()
        var rs = LowerTargets::raw_slot()
        var nx = self._adt_noexcept()
        self._cg->sink->spell(
            at,
            "template <class T> struct " + bx + " { static void* operator new(decltype(sizeof(0)), void* p) noexcept { return p; } T " + bv + "; };",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "template <class T> union " + rs + " { " + bx + "<T> " + bm + "; " + rs + "() noexcept {} ~" + rs + "() noexcept {} " + rs + "(const " + rs + "&) = delete; " + "T " + LowerTargets::raw_take() + "()" + nx + " { T r(static_cast<T&&>(" + bm + "." + bv + ")); " + bm + ".~" + bx + "<T>(); return r; } };",
        )

        self._cg->sink->brk()
        if header {
            self._cg->sink->directive(at, "#endif")
        }
    }

    /// Union storage for a local whose destructor is not C++'s to run
    /// (Compiler/Spec/Lowering.md#union-storage-locals). `__kairo_ul<T>` has
    /// no constructor, so it is an aggregate and `__kairo_ul<T> s{e}`
    /// copy-initializes `v` from `e` exactly as `T x = e` would, a prvalue
    /// built in place; its destructor does nothing. `__end()` runs the
    /// object's destructor (`x.finally()`); `__kairo_ulf<T>` adds the
    /// `live` flag its `__end()` clears and its `__drop` tests. The cleanup
    /// attribute runs `__kairo_ul_run` on the `__kairo_ulh` declared after
    /// the object, so it is armed only once the object is built: clang
    /// accepts no template (it never instantiates one named there) and no
    /// qualified name as a cleanup function, so the one function it names
    /// calls the type's `__drop` through the hook.
    prot fn _union_local_helpers(self, header: bool) {
        if self.written.has(HelperBlock::UnionLocal) {
            return
        }

        self.written.set(HelperBlock::UnionLocal)
        var at = self._tu_at()
        if header {
            self._cg->sink->directive(
                at,
                "#ifndef " + LowerTargets::union_local_guard(),
            )

            self._cg->sink->directive(
                at,
                "#define " + LowerTargets::union_local_guard(),
            )
        }

        var ul = LowerTargets::union_local()
        var uf = LowerTargets::union_local_flagged()
        var uh = LowerTargets::union_local_hook()
        var ob = LowerTargets::union_local_obj()
        var en = LowerTargets::union_local_end()
        var dr = LowerTargets::union_local_drop()
        var kl = LowerTargets::union_local_kill()
        var pt = LowerTargets::union_local_place()
        var ds = LowerTargets::union_local_destroy()
        // The destroy takes an array as well (a generic body's T may be
        // one): elements last to first, as C++ destroys an array.
        self._cg->sink->spell(
            at,
            "struct " + pt + " {}; inline void* operator new(decltype(sizeof(0)), void* p, " + pt + ") noexcept { return p; } inline void operator delete(void*, void*, " + pt + ") noexcept {} " + "template <class T> inline void " + ds + "(T& x) noexcept { x.~T(); } template <class T, decltype(sizeof(0)) N> inline void " + ds + "(T (&a)[N]) noexcept { for (decltype(sizeof(0)) i = N; i > 0; --i) { " + ds + "(a[i - 1]); } }",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "template <class T> union " + ul + " { T " + ob + "; ~" + ul + "() {} void " + en + "() noexcept { " + ds + "(" + ob + "); } static void " + dr + "(void* p) noexcept { " + ds + "(static_cast<" + ul + "*>(p)->" + ob + "); } };",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "template <class T> struct " + uf + " { " + ul + "<T> s; bool live; void " + en + "() noexcept { live = false; " + ds + "(s." + ob + "); } void " + kl + "() noexcept { if (live) { live = false; " + ds + "(s." + ob + "); } } static void " + dr + "(void* p) noexcept { static_cast<" + uf + "*>(p)->" + kl + "(); } };",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "struct " + uh + " { void* p; void (*d)(void*) noexcept; }; inline void " + LowerTargets::union_local_run() + "(" + uh + "* h) noexcept { h->d(h->p); }",
        )

        self._cg->sink->brk()
        if header {
            self._cg->sink->directive(at, "#endif")
        }
    }

    /// `__kairo_fwd<R, A>(s)` (Compiler/Spec/Panic.md#preamble-helpers): the panic result `s` as the
    /// result R, whose set holds every type `s` can hold here (an error
    /// only, unless A). The same type: moved. The same size and payload
    /// offset, both trivially copied: the bytes, tag and site word and all
    /// (the payload sits at one offset in both, and an error's tag is its
    /// type id in every set). Otherwise one case per element of `s`'s set
    /// (`__kairo_fwd_k`), testing the tag and moving the payload into R's
    /// element of the same type (`__kairo_pidx`), the site word copied. An
    /// element R does not hold is never the tag here, so it gets no case.
    /// Generic over the record (`P<T, E...>`), so no name of the lang item
    /// is spelled; its members are, read off `en`.
    priv fn _fwd_helpers(self, en: unsafe *Declarations::EnumDecl) {
        var at  = self._tu_at()
        var u   = builtin_info(BuiltinKind::U32)->cxx.copy()
        var nx  = self._adt_noexcept()
        var vt  = "::" + LowerTargets::adt_variant_tag()
        var fw  = LowerTargets::panic_fwd()
        var fk  = LowerTargets::panic_fwd_step()
        var px  = LowerTargets::panic_elem_index()
        var tag = LowerTargets::adt_tag_field()
        var tt  = LowerTargets::adt_tag_type()
        var off = LowerTargets::adt_payload_offset()
        var tid = "::" + LowerTargets::type_id()
        var nv  = "::" + LowerTargets::void_unit()
        var get = LowerTargets::adt_pack_get()
        if en->adt_site_field == &null {
            self._ice(
                self._at(unsafe (en as unsafe *Decl)),
                "InterfaceEmitter: the Panic lang item without its site slot; EnumLayoutLowering::_knobs sets it",
            )
        }

        var site = self._spell->leaf(en->adt_site_field)
        var ok:     unsafe *Declarations::EnumVariantDecl = &null
        var err:    unsafe *Declarations::EnumVariantDecl = &null
        var errpos: usize                                 = 0
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v->is_pack_expansion {
                err    = v
                errpos = i
            } else if ok == &null {
                ok = v
            }
        }

        if ok == &null || err == &null || ok->adt_member == &null || err->adt_member == &null {
            self._ice(
                self._at(unsafe (en as unsafe *Decl)),
                "InterfaceEmitter: the Panic lang item without its Ok and pack Err variants; lang_item.k pins the shape",
            )
        }

        var okn  = self._spell->leaf(ok)
        var okm  = self._spell->leaf(ok->adt_member)
        var okf  = self._spell->leaf(unsafe (ok->payload[0] as unsafe *Decl))
        var okt  = LowerTargets::adt_payload_type(okn)
        var erm  = self._spell->leaf(err->adt_member)
        var erf  = self._spell->leaf(unsafe (err->payload[0] as unsafe *Decl))
        var ert  = LowerTargets::adt_payload_type(self._spell->leaf(err))
        var npos = "static_cast<" + u + ">(-1)"
        var tp   = "template <class, class...> class P"

        self._cg->sink->spell(
            at,
            "template <class X, " + tp + ", class U, class... F> constexpr " + u + " " + px + "(P<U, F...>*) noexcept { " + u + " k = 0, i = " + npos + "; ((__is_same(X, F) ? (void)(i = k) : (void)0, ++k), ...); return i; }",
        )

        self._cg->sink->brk()
        // One element: built into R's element of its type when the tag is
        // its id (the last element is the tag without a test).
        self._cg->sink->spell(
            at,
            "template <class R, " + u + " K, " + tp + ", class T, class... E> R " + fk + "(P<T, E...>& s)" + nx + " { " + "using X = " + LowerTargets::clang_pack_element() + "<K, E...>; " + "constexpr " + u + " J = " + px + "<X>(static_cast<R*>(nullptr)); " + "if constexpr (J == " + npos + ") { if constexpr (K + 1 < sizeof...(E)) { return " + fk + "<R, K + 1>(s); } else { " + LowerTargets::clang_unreachable() + "(); } } " + "else { if constexpr (K + 1 < sizeof...(E)) { if (static_cast<" + u + ">(s." + tag + ") != " + tid + "<X>) { return " + fk + "<R, K + 1>(s); } } " + "return R(" + vt + "<" + f"{errpos}" + ">{}, " + vt + "<J>{}, s." + site + ", [&]()" + nx + " -> typename R::template " + ert + "<X> { " + "return { static_cast<X&&>(s." + erm + ".template " + get + "<K>()." + erf + ") }; }); } }",
        )

        self._cg->sink->brk()
        var bits = "(sizeof(R) == sizeof(S) && R::" + off + " == S::" + off + " && __is_trivially_copyable(R) && __is_trivially_copyable(S)" + " && (!A || __is_same(" + nv + "<T>, decltype(static_cast<R*>(nullptr)->" + okm + "." + okf + "))))"
        self._cg->sink->spell(
            at,
            "template <class R, bool A, " + tp + ", class T, class... E> R " + fw + "(P<T, E...>& s)" + nx + " { " + "using S = P<T, E...>; " + "if constexpr (__is_same(R, S)) { return static_cast<S&&>(s); } " + "else if constexpr " + bits + " { return " + LowerTargets::clang_bit_cast() + "(R, s); } " + "else { if constexpr (A) { if (s." + tag + " == S::" + tt + "::" + okn + ") { return R(" + vt + "<0>{}, [&]()" + nx + " -> typename R::" + okt + " { " + "return { static_cast<" + nv + "<T>&&>(s." + okm + "." + okf + ") }; }); } } " + "if constexpr (sizeof...(E) == 0) { " + LowerTargets::clang_unreachable() + "(); } else { return " + fk + "<R, 0>(s); } } }",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "template <class R, bool A, " + tp + ", class T, class... E> R " + fw + "(P<T, E...>&& s)" + nx + " { return " + fw + "<R, A>(s); }",
        )

        self._cg->sink->brk()
        // A `fn` value converted to a `fn` type whose set is wider
        // (conversion by subset): the call's result as R -- a panic result
        // forwarded whole, a plain value (or nothing) as Ok. `F&&`: a
        // witness forwarding to a structural conformer passes a
        // temporary lambda; the wrapper's held value is an lvalue.
        var pc = LowerTargets::panic_call_as()
        self._cg->sink->spell(
            at,
            "template <class R, class F, class... A> R " + pc + "(F&& f, A&&... a)" + nx + " { " + "using V = decltype(f(static_cast<A&&>(a)...)); " + "if constexpr (requires { V::" + off + "; } && requires (V& v) { v." + site + "; }) { return " + fw + "<R, true>(f(static_cast<A&&>(a)...)); } " + "else if constexpr (__is_same(V, void)) { f(static_cast<A&&>(a)...); return R(" + vt + "<0>{}, [&]()" + nx + " -> typename R::" + okt + " { return {}; }); } " + "else { return R(" + vt + "<0>{}, [&]()" + nx + " -> typename R::" + okt + " { return { f(static_cast<A&&>(a)...) }; }); } }",
        )

        self._cg->sink->brk()
    }

    /// `struct __kairo_panic_site`, the record of the panic site table, once
    /// per C++ TU (a header guards it).
    prot fn _site_type(self, header: bool) {
        if self.written.has(HelperBlock::SiteType) {
            return
        }

        var u = builtin_info(BuiltinKind::U32)->cxx.copy()
        if header {
            self._cg->sink->directive(
                self._tu_at(),
                "#ifndef " + LowerTargets::panic_site_guard(),
            )
        }

        if header {
            self._cg->sink->directive(
                self._tu_at(),
                "#define " + LowerTargets::panic_site_guard(),
            )
        }

        self._cg->sink->spell(
            self._tu_at(),
            "struct " + LowerTargets::panic_site_type() + " { " + u + " id; " + u + " line; " + u + " col; const char* file; };",
        )

        if header {
            self._cg->sink->directive(self._tu_at(), "#endif")
        }

        self.written.set(HelperBlock::SiteType)
    }

    /// The C++ view of a panic result (Compiler/Spec/Panic.md#the-c-view): what a C++ caller of
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
    prot fn _panic_api(self, en: unsafe *Declarations::EnumDecl, header: bool) {
        var at = self._tu_at()
        var u = builtin_info(BuiltinKind::U32)->cxx.copy()
        var sz = "decltype(sizeof(0))"
        var st = "::" + LowerTargets::panic_site_type()
        var pn = self._spell->qual_name(en)
        var pt = pn + "<T, E...>"
        var tag = LowerTargets::adt_tag_field()
        var tt = LowerTargets::adt_tag_type()
        var get = LowerTargets::adt_pack_get()
        var px = "::" + LowerTargets::panic_elem_index()
        var tid = "::" + LowerTargets::type_id()
        var npos                                       = "static_cast<" + u + ">(-1)"
        var ok:  unsafe *Declarations::EnumVariantDecl = &null
        var err: unsafe *Declarations::EnumVariantDecl = &null
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v->is_pack_expansion {
                err = v
            } else if ok == &null {
                ok = v
            }
        }

        if ok == &null
            || err == &null
            || ok->adt_member == &null
            || err->adt_member == &null
            || en->adt_site_field == &null {
            self._ice(
                self._at(en),
                "InterfaceEmitter: the Panic lang item without its Ok, pack Err and site; lang_item.k pins the shape",
            )
        }

        var site = self._spell->leaf(en->adt_site_field)
        var okn  = self._spell->leaf(ok)
        var okv = self._spell->leaf(ok->adt_member) + "." + self._spell->leaf(
            unsafe (ok->payload[0] as unsafe *Decl),
        )

        var erm = self._spell->leaf(err->adt_member)
        var erf = self._spell->leaf(unsafe (err->payload[0] as unsafe *Decl))
        var api = LowerTargets::panic_api_ns()
        var im  = LowerTargets::panic_api_impl()
        var ss  = "::" + api + "::" + LowerTargets::panic_api_source_site()
        var b0  = LowerTargets::panic_sites_begin_sym()
        var b1  = LowerTargets::panic_sites_end_sym()
        // Unresolved: no target read yet (a hand-built invocation), which
        // this has always treated as ELF.
        var        fmt = ObjectFormat::Unresolved
        var unsafe *ci = self._cg->ctx->ci
        if ci != &null {
            fmt = ci->target.object_format_kind
        }

        if header {
            self._cg->sink->directive(
                at,
                "#ifndef " + LowerTargets::panic_api_guard(),
            )
        }

        if header {
            self._cg->sink->directive(
                at,
                "#define " + LowerTargets::panic_api_guard(),
            )
        }

        self._site_type(header)
        // The table's bounds. ELF: the linker's __start_/__stop_, weak so a
        // program with no site links. Mach-O: section$start/end. Any other
        // format has none here yet: no site is ever found.
        if fmt == ObjectFormat::Elf || fmt == ObjectFormat::Unresolved {
            self._cg->sink->spell(
                at,
                "extern \"C\" { [[gnu::weak]] extern const " + st + " " + LowerTargets::panic_sites_start() + "[]; " + "[[gnu::weak]] extern const " + st + " " + LowerTargets::panic_sites_stop() + "[]; }",
            )

            b0 = LowerTargets::panic_sites_start()
            b1 = LowerTargets::panic_sites_stop()
        } else if fmt == ObjectFormat::MachO {
            self._cg->sink->spell(
                at,
                "extern const " + st + " " + b0 + "[] __asm(\"" + LowerTargets::panic_sites_start_macho() + "\");",
            )

            self._cg->sink->spell(
                at,
                "extern const " + st + " " + b1 + "[] __asm(\"" + LowerTargets::panic_sites_stop_macho() + "\");",
            )
        } else {
            b0 = "nullptr"
            b1 = "nullptr"
        }

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "template <class E> struct " + LowerTargets::panic_msg_trait() + ";",
        )

        self._cg->sink->brk()

        var cnt = "unsigned long"
        var s   = "namespace " + api + " { "
        s += "template <class E> inline constexpr " + u + " " + LowerTargets::panic_api_type_id() + " = " + tid + "<E>; "
        s += "template <class... E> struct " + LowerTargets::panic_api_types() + " {}; "
        s += "template <class P> struct " + LowerTargets::panic_api_set() + "; "
        s += "template <class T, class... E> struct " + LowerTargets::panic_api_set() + "<" + pt + "> { using value_type = T; using types = ::" + api + "::" + LowerTargets::panic_api_types() + "<E...>; " + "static constexpr " + u + " size = sizeof...(E); static constexpr " + u + " payload_offset = " + pt + "::" + LowerTargets::adt_payload_offset() + "; }; "
        s += "struct " + LowerTargets::panic_api_source_site() + " { const char* file; " + u + " line; " + u + " col; }; "
        // The machinery: the table walk and what()'s text, sized by a first
        // pass with no buffer (o null) and written by a second.
        s += "struct " + im + " { "
        s += "static const " + st + "* first() noexcept { return " + b0 + "; } "
        s += "static const " + st + "* last() noexcept { return " + b1 + "; } "
        s += "static " + ss + " site_of(" + u + " id) noexcept { if (id != 0) { for (const " + st + "* r = first(); r != last(); ++r) { if (r->id == id) { return " + ss + "{r->file, r->line, r->col}; } } } return " + ss + "{nullptr, 0, 0}; } "
        s += "static " + sz + " put(char* o, " + sz + " n, const char* x, " + sz + " k) noexcept { if (o) { for (" + sz + " i = 0; i < k; ++i) { o[n + i] = x[i]; } } return n + k; } "
        s += "static " + sz + " putu(char* o, " + sz + " n, " + u + " v) noexcept { char b[10]; int k = 0; do { b[k++] = static_cast<char>(48 + v % 10); v /= 10; } while (v); " + "while (k) { if (o) { o[n] = b[k - 1]; } ++n; --k; } return n; } "
        s += "static " + sz + " len(const char* x) noexcept { " + sz + " n = 0; while (x[n]) { ++n; } return n; } "
        s += "static bool same(const " + st + "* a, const " + st + "* b) noexcept { if ((a->line != b->line) || (a->col != b->col)) { return false; } " + "const char* x = a->file; const char* y = b->file; while (*x && (*x == *y)) { ++x; ++y; } return *x == *y; } "
        s += "static " + sz + " text(char* o, const unsigned char* m, " + sz + " ml, bool hm, const char* name, " + u + " site) noexcept { " + sz + " n = 0; " + "if (hm) { n = put(o, n, reinterpret_cast<const char*>(m), ml); n = put(o, n, \" [\", 2); } " + "n = put(o, n, name, len(name)); bool one = true; " + "if (site != 0) { for (const " + st + "* r = first(); r != last(); ++r) { if (r->id != site) { continue; } bool dup = false; " + "for (const " + st + "* q = first(); q != r; ++q) { if ((q->id == site) && same(q, r)) { dup = true; break; } } if (dup) { continue; } " + "n = one ? put(o, n, \" at \", 4) : put(o, n, \" | \", 3); one = false; " + "n = put(o, n, r->file, len(r->file)); n = put(o, n, \":\", 1); n = putu(o, n, r->line); n = put(o, n, \":\", 1); n = putu(o, n, r->col); } } " + "if (hm) { n = put(o, n, \"]\", 1); } return n; } "
        s += "}; "
        s += "template <class T, class... E> bool " + LowerTargets::panic_api_ok() + "(const " + pt + "& p) noexcept { return p." + tag + " == " + pt + "::" + tt + "::" + okn + "; } "
        s += "template <class T, class... E> auto& " + LowerTargets::panic_api_value() + "(" + pt + "& p) noexcept { return p." + okv + "; } "
        s += "template <class T, class... E> const auto& " + LowerTargets::panic_api_value() + "(const " + pt + "& p) noexcept { return p." + okv + "; } "
        s += "template <class X, class T, class... E> bool " + LowerTargets::panic_api_is() + "(const " + pt + "& p) noexcept { " + "if constexpr (" + px + "<X>(static_cast<" + pt + "*>(nullptr)) == " + npos + ") { return false; } " + "else { return static_cast<" + u + ">(p." + tag + ") == " + tid + "<X>; } } "
        var nin = "static_assert(J != " + npos + ", \"::" + api + "::" + LowerTargets::panic_api_error() + "<E>: E is not in this panic set\"); "
        s += "template <class X, class T, class... E> X& " + LowerTargets::panic_api_error() + "(" + pt + "& p) noexcept { " + "constexpr " + u + " J = " + px + "<X>(static_cast<" + pt + "*>(nullptr)); " + nin + "return p." + erm + ".template " + get + "<J>()." + erf + "; } "
        s += "template <class X, class T, class... E> const X& " + LowerTargets::panic_api_error() + "(const " + pt + "& p) noexcept { " + "constexpr " + u + " J = " + px + "<X>(static_cast<" + pt + "*>(nullptr)); " + nin + "return p." + erm + ".template " + get + "<J>()." + erf + "; } "
        s += "template <class T, class... E> " + ss + " " + LowerTargets::panic_api_site() + "(const " + pt + "& p) noexcept { return " + im + "::site_of(p." + site + "); } "
        s += "}"
        self._cg->sink->spell(at, s)
        self._cg->sink->brk()

        // The throwing half.
        var throwing = header || self.cxx_exceptions
        if throwing {
            if header {
                self._cg->sink->directive(at, "#if __cpp_exceptions")
            }

            self._cg->sink->system_header(at, "exception")
            var eb  = LowerTargets::panic_api_error_base()
            var et  = LowerTargets::panic_api_error_type()
            var w   = LowerTargets::panic_api_text()
            var bld = LowerTargets::panic_api_build()
            var drp = LowerTargets::panic_api_drop()
            var th  = LowerTargets::panic_api_throw()
            var nm = "::" + LowerTargets::type_id_trait() + "<E>::" + LowerTargets::type_id_name()
            var tw = self._cg->tu != &null
                && self._cg->tu->global_scope != &null
                && self._cg->tu->global_scope->well_known()->two_word()
            // `m.data()`, `m.size()` on the message; on the two-word library
            // they are extension members, static members of string's scope
            // (`S::data(&m)`), named through a dependent alias so lookup waits
            // for the instance, by which time the scope is defined.
            var sd = "m." + LangMembers::string_data(tw) + "()"
            var sl = "m." + LangMembers::string_size(tw) + "()"
            var xs = if (tw) => (self._string_scope(LangMembers::string_data(tw))) else => ""
            var dp = "__kairo_dep"
            if !xs.empty() {
                var q = "::" + api + "::" + dp + "<E, " + xs + ">::type::"
                sd = q.copy() + LangMembers::string_data(tw) + "(&m)"
                sl = q + LangMembers::string_size(tw) + "(&m)"
            }

            // The base is default-built in the copy (std::exception holds
            // nothing).
            // The memory orders by value (relaxed 0, acq_rel 4): a kcc
            // include's tokens are past the preprocessor, so the
            // __ATOMIC_* macros would not expand.
            var t = "namespace " + api + " { "
            if !xs.empty() {
                t += "template <class D, class T> struct " + dp + " { using type = T; }; "
            }

            t += "struct " + eb + " : public " + LowerTargets::cxx_exception_base() + " { " + u + " type; " + u + " site; "
            t += eb.copy() + "(const " + eb + "& o) noexcept : type(o.type), site(o.site), " + w + "(o." + w + ") { if (" + w + ") { " + LowerTargets::clang_atomic_fetch_add() + "(" + w + ", 1, 0); } } "
            t += eb.copy() + "& operator=(const " + eb + "& o) noexcept { if (o." + w + ") { " + LowerTargets::clang_atomic_fetch_add() + "(o." + w + ", 1, 0); } " + drp + "(); type = o.type; site = o.site; " + w + " = o." + w + "; return *this; } "
            t += "~" + eb + "() override { " + drp + "(); } "
            t += "const char* what() const noexcept override { return " + w + " ? reinterpret_cast<const char*>(" + w + " + 1) : \"\"; } "
            t += "protected: " + eb + "(" + u + " t, " + u + " s) noexcept : type(t), site(s) {} "
            t += cnt.copy() + "* " + w + " = nullptr; "
            t += "void " + drp + "() noexcept { if (" + w + " && (" + LowerTargets::clang_atomic_sub_fetch() + "(" + w + ", 1, 4) == 0)) { " + LowerTargets::clang_free() + "(" + w + "); } " + w + " = nullptr; } "
            t += "void " + bld + "(const unsigned char* m, " + sz + " ml, bool hm, const char* name) noexcept { " + sz + " n = ::" + api + "::" + im + "::text(nullptr, m, ml, hm, name, site); " + w + " = static_cast<" + cnt + "*>(" + LowerTargets::clang_malloc() + "(sizeof(" + cnt + ") + n + 1)); if (!" + w + ") { return; } *" + w + " = 1; " + "char* o = reinterpret_cast<char*>(" + w + " + 1); ::" + api + "::" + im + "::text(o, m, ml, hm, name, site); o[n] = 0; } "
            t += "}; "
            t += "template <class E> struct " + et + " : public ::" + api + "::" + eb + " { E " + LowerTargets::panic_api_error() + "; "
            t += "template <class A> " + et + "(A&& e, " + u + " s) noexcept : " + eb + "(" + tid + "<E>, s), " + LowerTargets::panic_api_error() + "(static_cast<A&&>(e)) { " + "const E& x = this->" + LowerTargets::panic_api_error() + "; " + "if constexpr (requires (const E& y) { y." + LowerTargets::op_panic() + "(); }) { auto m = x." + LowerTargets::op_panic() + "(); this->" + bld + "(" + sd + ", " + sl + ", true, " + nm + "); } " + "else if constexpr (requires (const E& y) { ::" + LowerTargets::panic_msg_trait() + "<E>::" + LowerTargets::panic_msg_get() + "(y); }) { " + "auto m = ::" + LowerTargets::panic_msg_trait() + "<E>::" + LowerTargets::panic_msg_get() + "(x); this->" + bld + "(" + sd + ", " + sl + ", true, " + nm + "); } " + "else { this->" + bld + "(nullptr, 0, false, " + nm + "); } } }; "
            // The error the result holds, thrown as panic_error<X>: moved
            // out of an rvalue result, copied out of an lvalue one.
            t += "struct " + th + " { "
            t += "template <" + u + " K, bool M, class T, class... E> [[noreturn]] static void raise(" + pt + "& p) { using X = " + LowerTargets::clang_pack_element() + "<K, E...>; " + "if constexpr (K + 1 < sizeof...(E)) { if (static_cast<" + u + ">(p." + tag + ") != " + tid + "<X>) { raise<K + 1, M>(p); } } " + "if constexpr (M) { throw ::" + api + "::" + et + "<X>(static_cast<X&&>(p." + erm + ".template " + get + "<K>()." + erf + "), p." + site + "); } " + "else { throw ::" + api + "::" + et + "<X>(static_cast<const X&>(p." + erm + ".template " + get + "<K>()." + erf + "), p." + site + "); } } "
            t += "template <bool M, class T, class... E> static T value(" + pt + "& p) { " + "if (p." + tag + " != " + pt + "::" + tt + "::" + okn + ") { if constexpr (sizeof...(E) > 0) { raise<0, M>(p); } else { " + LowerTargets::clang_unreachable() + "(); } } " + "if constexpr (!__is_same(T, void)) { if constexpr (M) { return static_cast<T&&>(p." + okv + "); } else { return p." + okv + "; } } } "
            t += "}; "
            t += "template <class T, class... E> T " + LowerTargets::panic_api_value_or_throw() + "(" + pt + "&& p) { return " + th + "::template value<true>(p); } "
            t += "template <class T, class... E> T " + LowerTargets::panic_api_value_or_throw() + "(const " + pt + "& p) { return " + th + "::template value<false>(const_cast<" + pt + "&>(p)); } "
            t += "}"
            self._cg->sink->spell(at, t)
            self._cg->sink->brk()
            if header {
                self._cg->sink->directive(at, "#endif")
            }
        }

        // A Panic instance is what a duck call must not return (Compiler/Spec/Generics.md#duck-regime,
        // EmitIR::_call): the trait's one true case, after its primary.
        self._nopanic_helpers()
        self._cg->sink->spell(
            at,
            "template <class T, class... E> struct " + LowerTargets::nopanic_trait() + "<" + pt + "> { static constexpr bool value = true; };",
        )

        self._cg->sink->brk()
        if header {
            self._cg->sink->directive(at, "#endif")
        }
    }

    /// `(::__kairo_nopanic(), t.f())` (LowerTargets::nopanic_call): a member
    /// call through a `<T: type>` parameter, whose callee only the instance
    /// knows. A panicking one would hand the duck body a panic result it
    /// cannot handle (its sites are SC116E, Compiler/Spec/Generics.md#duck-regime), and a discarded
    /// one would drop the error. Operators on a `: type` operand and an
    /// unbound free call go the same way. The tag's `operator,`
    /// stops it at the instance and yields the value as it came: an lvalue
    /// stays one (T is `X&`), and an rvalue comes back BY VALUE (T is `X`),
    /// at the cost of one move -- returned as `T&&`, a prvalue's temporary
    /// died with the wrapper's full-expression, and EmitIR binds operands
    /// with `auto&&` (_dep_binary), which then dangled. Elided, the move
    /// would need the site spelled twice (once in a decltype); a
    /// `void` call cannot bind `T&&` and takes the builtin comma, whose
    /// left operand is a call so it is no unused value. `__kairo_is_panic`
    /// is false but for a Panic instance (_panic_api specializes it). Once
    /// per C++ TU (a header: under its own guard): a duck body needs it whether or not
    /// its TU defines Panic.
    prot fn _nopanic_helpers(self) {
        if self.written.has(HelperBlock::Nopanic) {
            return
        }

        self.written.set(HelperBlock::Nopanic)
        var at     = self._tu_at()
        var tg     = LowerTargets::nopanic_tag()
        var ip     = LowerTargets::nopanic_trait()
        var header = self._plan->mode() == PlanMode::Header
        if header {
            self._cg->sink->directive(
                at,
                "#ifndef " + LowerTargets::nopanic_guard(),
            )
        }

        if header {
            self._cg->sink->directive(
                at,
                "#define " + LowerTargets::nopanic_guard(),
            )
        }

        self._cg->sink->spell(
            at,
            "template <class T> struct " + ip + " { static constexpr bool value = false; };",
        )

        self._cg->sink->spell(
            at,
            "template <class T> struct " + ip + "<T&> : " + ip + "<T> {};",
        )

        self._cg->sink->spell(
            at,
            "template <class T> struct " + ip + "<T&&> : " + ip + "<T> {};",
        )

        self._cg->sink->spell(
            at,
            "template <class T> struct " + ip + "<const T> : " + ip + "<T> {};",
        )

        self._cg->sink->spell(at, "struct " + tg + " {};")
        self._cg->sink->spell(
            at,
            "constexpr " + tg + " " + LowerTargets::nopanic_call() + "() noexcept { return {}; }",
        )

        self._cg->sink->spell(
            at,
            "template <class T> constexpr void " + LowerTargets::nopanic_of() + "() noexcept { " + "static_assert(!" + ip + "<T>::value, \"a call through a '<T: type>' parameter that may panic is not yet supported (C++-checked generics)\"); }",
        )

        self._cg->sink->spell(
            at,
            "template <class T> constexpr T operator,(" + tg + ", T&& v) noexcept { " + "static_assert(!" + ip + "<T>::value, \"a call through a '<T: type>' parameter that may panic is not yet supported (C++-checked generics)\"); " + "return static_cast<T&&>(v); }",
        )

        self._cg->sink->brk()
        if header {
            self._cg->sink->directive(at, "#endif")
        }
    }

    /// An extension's `op panic` (Compiler/Spec/Panic.md#error-types) as the C++ view reads it:
    /// `__kairo_pmsg<T>::get(e)`, which calls the scope's static member. A
    /// type's own `op panic` is a member the C++ view finds by itself; an
    /// extension's lives in a scope only Kairo can name. At global scope,
    /// after the scope's definition. A generic target's member is a
    /// template, which no specialization of one type can name: left out
    /// (what() falls back to the type name).
    prot fn _scope_panic_msg(self, sc: unsafe *ExtScope) {
        for var i: usize = 0; i < sc->members.size(); ++i {
            var unsafe *m = sc->members[i]
            if !m->is_operator
                || m->op_token.size() != 1
                || m->op_token[0].kind != TokenKind::KwPanic {
                continue
            }

            if self._spell->template_head(unsafe (m as unsafe *Decl)).size() != 0 {
                continue
            }

            var ty = ""
            if sc->target_ty != &null {
                ty = self._spell->_type(sc->target_ty)
            } else if sc->target != &null && self._spell->template_head(sc->target).size() == 0 {
                ty = self._spell->qual_name(sc->target)
            }

            if ty.size() == 0 {
                continue
            }

            var at = self._at(unsafe (m as unsafe *Decl))
            var pm = LowerTargets::panic_msg_trait()
            // A template, so its body (which returns a `string`) is compiled
            // where it is used: the string may still be incomplete here.
            self._cg->sink->spell(
                at,
                "template <class E> struct " + pm + "; template <> struct " + pm + "<" + ty + "> { template <class X = " + ty + "> static auto " + LowerTargets::panic_msg_get() + "(const X& e) noexcept { return " + self._scope_qual(
                    sc,
                ) + "::" + LowerTargets::op_panic() + "(e); } };",
            )

            self._cg->sink->brk()
        }
    }

    /// The Panic lang item, when a plan entry defines it here: an ADT with
    /// a lang item's layout knobs (as _needs_pack_union asks).
    prot fn _panic_enum_defined(self) -> unsafe *Declarations::EnumDecl {
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

            var unsafe *en = dyn_cast<Declarations::EnumDecl>(e->decl)
            if en != &null
                && en->is_adt
                && (en->adt_explicit_tags || en->adt_void_unit || en->adt_payload_offset != &null) {
                return en
            }
        }

        return &null
    }

    /// The niche trait, written once per TU (guarded in a header): count 0
    /// for anything without one, a pointer's null, and an ADT record's own
    /// answer (`__kairo_niche_count`, its `(__kairo_np, i)` constructor and
    /// `__kairo_niche_test`). A plain enum's is specialized after it
    /// (_enum_niche_trait). EnumLayoutQuery::niche_of is the same table.
    prot fn _niche_helpers(self, header: bool) {
        var at = self._tu_at()
        var w  = builtin_info(BuiltinKind::U64)->cxx.copy()
        var nt = LowerTargets::niche_trait()
        var c  = LowerTargets::niche_trait_count()
        var pt = LowerTargets::niche_trait_pattern()
        var ts = LowerTargets::niche_trait_test()
        var np = LowerTargets::niche_ctor_tag()
        if header {
            self._cg->sink->directive(
                at,
                "#ifndef " + LowerTargets::niche_guard(),
            )
        }

        if header {
            self._cg->sink->directive(
                at,
                "#define " + LowerTargets::niche_guard(),
            )
        }

        self._cg->sink->spell(
            at,
            "struct " + np + " { explicit " + np + "() = default; };",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "template <class T> struct " + nt + " { static constexpr " + w + " " + c + " = 0; };",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "template <class T> struct " + nt + "<T*> { static constexpr " + w + " " + c + " = 1; static T* " + pt + "(" + w + ") noexcept { return nullptr; } static bool " + ts + "(T* const& v, " + w + ") noexcept { return v == nullptr; } };",
        )

        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "template <class T> requires requires { T::" + LowerTargets::niche_count() + "; } struct " + nt + "<T> { static constexpr " + w + " " + c + " = T::" + LowerTargets::niche_count() + "; static T " + pt + "(" + w + " i) noexcept { return T(::" + np + "{}, i); } " + "static bool " + ts + "(const T& v, " + w + " i) noexcept { return T::" + LowerTargets::niche_test() + "(v, i); } };",
        )

        self._cg->sink->brk()
        if header {
            self._cg->sink->directive(at, "#endif")
        }
    }

    /// An enum is defined here: a plain one with a niche trait, or any ADT.
    /// A header skips what it includes, as run() does.
    prot fn _needs_niche_helpers(self) -> bool {
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

            var unsafe *en = dyn_cast<Declarations::EnumDecl>(e->decl)
            if en == &null {
                continue
            }

            if en->is_adt || enum_has_niche_trait(en) {
                return true
            }
        }

        return false
    }

    /// An ADT with a pack-expanded variant is defined here (as
    /// _needs_niche_helpers asks).
    prot fn _needs_pack_union(self) -> bool {
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

            var unsafe *en = dyn_cast<Declarations::EnumDecl>(e->decl)
            if en != &null && en->is_adt && DeclFacts::adt_pack_variant(en) != &null {
                return true
            }
        }

        return false
    }

    /// The qualified extension scope of the String lang record that
    /// declares member `name`, when this plan carries it, else "".
    priv fn _string_scope(self, const name: string) -> string {
        var *gs = self._cg->tu->global_scope
        if gs == &null {
            return ""
        }

        var unsafe *sd = gs->well_known()->get(WellKnownType::String)
        if sd == &null {
            return ""
        }

        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var unsafe *x = self._plan->entries[i].scope
            if x == &null || x->target != Spell::Speller::rep(sd) {
                continue
            }

            for var k: usize = 0; k < x->members.size(); ++k {
                if DeclFacts::decl_name(unsafe (x->members[k] as unsafe *Decl)) == name {
                    return "::" + self._spell->ns_join(&x->ns) + "::" + x->name
                }
            }
        }

        return ""
    }
}
