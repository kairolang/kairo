/// --- The Kairo Project ------------------- Codegen/Interface/Fields.k --- ///
///
///   InterfaceEmitter, part: fields. A field's default member initializer,
///   the slot declarations of a constructor that initializes const fields in
///   place (EmitIR.k's header has the shape), and static fields, defined after
///   the outermost record as inline variables.
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
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    RecordType,
    builtin_info,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Types::{
    FixedArrayType,
    FunctionPointerType,
    PointerType,
}
import Codegen::Interface::InterfaceEmitter::InterfaceEmitter
import Codegen::Plan::EmitPlan::PlanTier
import Codegen::Spell::Spell::Speller

extend InterfaceEmitter {
    /// A field's C++ default member initializer, from what
    /// FieldInitLowering made of its Kairo one: a constant as it is, or a
    /// call of the member function holding the expression, named by leaf (a
    /// default member initializer sees the whole class, that member's later
    /// declaration included). Either way the text names nothing outside the
    /// record, so the class stays a pure function of the decl.
    prot fn _field_default(self, f: unsafe *Declarations::FieldDecl) -> string {
        match f->init_fold {
            case Declarations::FieldFold::Int {
                var c = Declarations::IntConst{}
                c.ok  = true
                c.neg = f->init_neg
                c.mag = f->init_mag
                return " = " + self._enum_value(c)
            } case Declarations::FieldFold::True {
                return " = true"
            } case Declarations::FieldFold::False {
                return " = false"
            } case Declarations::FieldFold::Null {
                return " = nullptr"
            } case Declarations::FieldFold::Thunk {
                return " = " + self._spell->leaf(f->init_thunk) + "()"
            }

            // An array, leaf element by leaf element (FieldInitLowering,
            // Arrays), braced per dimension of the field's type.
            case Declarations::FieldFold::Elems {
                var unsafe *at = canon_unqual(f->type_->canonical)
                // A length that is a value parameter is not known here: the
                // flat list, which C++ brace elision reads row-major.
                if self._param_extent(at) {
                    var flat = " = {"
                    for var i: usize = 0; i < f->init_elems.size(); ++i {
                        if i > 0 {
                            flat += ", "
                        }

                        flat += self._spell->leaf(f->init_elems[i]) + "()"
                    }

                    return flat + "}"
                }

                var next: usize = 0
                var s = " = " + self._elems_braced(f, at, unsafe &next)
                if next != f->init_elems.size() {
                    self._ice(
                        f->name.range,
                        "InterfaceEmitter: an array field's element thunks do not fill its type",
                    )
                }

                return s
            } default {
                0
            }
        }

        // An initializer still on the field is one FieldInitLowering leaves
        // (an eval array field), which FeatureGateCheck rejects.
        if f->init != &null {
            self._ice(
                f->name.range,
                "InterfaceEmitter: initializer of an array-typed field reached codegen; FeatureGateCheck rejects it",
            )
        }

        return ""
    }

    /// Some dimension of array type `t` has a value parameter's length.
    priv fn _param_extent(self, t: unsafe *Type) -> bool {
        var unsafe *a = dyn_cast<FixedArrayType>(t)
        if a == &null {
            return false
        }

        if a->extent_param != &null {
            return true
        }

        return self._param_extent(canon_unqual(a->element))
    }

    /// `{t0(), t1()}` for array type `at`, each leaf the next of `f`'s
    /// element thunks (row-major, FieldInitLowering), an inner array its own
    /// braces: `{{t0(), t1()}, {t2(), t3()}}`. Brace elision would accept
    /// the flat list too; the nesting says what the Kairo literal said.
    priv fn _elems_braced(self,
                          f:    unsafe *Declarations::FieldDecl,
                          at:   unsafe *Type,
                          next: unsafe *usize) -> string {
        var unsafe *a = dyn_cast<FixedArrayType>(at)
        if a == &null {
            self._ice(
                f->name.range,
                "InterfaceEmitter: an element-lowered field whose type is no array",
            )

            return ""
        }

        var unsafe *el   = canon_unqual(a->element)
        var        inner = el != &null && isa<FixedArrayType>(el)
        var        s     = "{"
        for var i: u64 = 0; i < (a->size_bits as u64); ++i {
            if i > 0 {
                s += ", "
            }

            if inner {
                s += self._elems_braced(f, el, next)
                continue
            }

            if *next >= f->init_elems.size() {
                self._ice(
                    f->name.range,
                    "InterfaceEmitter: an array field has fewer element thunks than its type has elements",
                )

                return ""
            }

            s += self._spell->leaf(f->init_elems[*next]) + "()"
            *next += 1
        }

        return s + "}"
    }

    /// True when `f`, a field with no initializer, is value-initialized
    /// by a `{}` default member initializer: a number, a pointer, a plain
    /// enum, a union, a type parameter, an array of those. variables.mdx: a binding
    /// of a type with a default and no initializer is zero-initialized, and
    /// C++ default-initialization leaves a scalar member indeterminate in
    /// every constructor that does not name it -- a user one with an empty
    /// body included. On the class, not in each constructor, so the
    /// implicit one and a split one's untouched fields read 0 as well. A
    /// mem-initializer (a split constructor's) replaces it.
    /// Left alone: a const field (every constructor builds it; CtorInitCheck),
    /// a class or struct (its own constructor builds it, and one with no default
    /// would make `{}` ill-formed though every constructor builds it), an
    /// enum with payloads (likewise), an imported C++ type and anything
    /// else not listed (clang's to decide, as for a local), and a union's
    /// members (C++ allows at most one initializer there).
    prot fn _zero_by_default(self, f: unsafe *Declarations::FieldDecl) -> bool {
        if f->is_const() || f->init != &null || f->type_ == &null {
            return false
        }

        var unsafe *c = if (f->type_->canonical != &null) => (f->type_->canonical) else => f->type_
        c = canon_unqual(c)
        while c != &null && isa<FixedArrayType>(c) {
            c = canon_unqual(cast<FixedArrayType>(c)->element)
        }

        if c == &null {
            return false
        }

        match c->kind {
            case TypeKind::BuiltinType {
                return true
            } case TypeKind::PointerType {
                return true
            } case TypeKind::FunctionPointerType {
                return true
            }

            // As `T v;` already did, `T v{}` asks the instance for a
            // default; a class template instantiates it only for a
            // constructor that leaves `v` to it.
            case TypeKind::GenericParamType {
                return true
            } case TypeKind::SubstGenericParamType {
                return true
            } case TypeKind::AssocType {
                return true
            } case TypeKind::RecordType {
                0
            } default {
                return false
            }
        }

        var unsafe *rd = cast<RecordType>(c)->decl
        if rd != &null && DeclFacts::decl_is_instance(rd) {
            rd = DeclFacts::decl_pattern(rd)
        }

        rd = Speller::rep(rd)
        if rd == &null {
            return false
        }

        // A union's members are trivial (unions.mdx), and its first is
        // zeroed by its own `{}` (_record_def).
        if isa<Declarations::UnionDecl>(rd) {
            return true
        }

        if !isa<Declarations::EnumDecl>(rd) {
            return false
        }

        return !cast<Declarations::EnumDecl>(rd)->is_adt
    }

    /// # Const fields in a constructor

    /// True when some record the plan defines has a split constructor, or
    /// a body returns out of an expansion copy (EmitPlan::needs_ef_slot).
    prot fn _needs_ctor_slots(self) -> bool {
        if self._plan->needs_ef_slot {
            return true
        }

        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var *e = &self._plan->entries[i]
            if e->tier != PlanTier::Definitions
                || e->scope != &null
                || e->witness != &null
                || e->eval_item != &null {
                continue
            }

            if self._has_split_ctor(e->decl) {
                return true
            }
        }

        return false
    }

    priv fn _has_split_ctor(self, d: unsafe *Decl) -> bool {
        if d == &null || (!isa<Declarations::ClassDecl>(d)) && !isa<Declarations::StructDecl>(d) {
            return false
        }

        var methods = DeclFacts::decl_methods(d)
        for var i: usize = 0; i < methods.size(); ++i {
            if methods[i] != &null && methods[i]->ci_split > 0 {
                return true
            }
        }

        var unsafe *dc = Speller::dc_of(d)
        if dc == &null {
            return false
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd != &null && self._has_split_ctor(Speller::rep(nd)) {
                return true
            }
        }

        return false
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
    /// asks T for `operator=`. Both take a reference and build the value
    /// with one move or copy (`const T&` for an lvalue of a copyable type;
    /// a class template's member is instantiated only where called).
    /// `take()` hands the value to the field's initializer; for a T whose
    /// moved-from object need not be destroyed (`::__kairo_dm<T>`) it also
    /// leaves the slot unset, so the slot's destructor skips the husk.
    /// An eval constructor's slots live inside one constant evaluation,
    /// where C++23 allows no placement new (C++26 does) but does allow a
    /// transient `new`/`delete`: there (`if consteval`) the value is a heap
    /// box `__p`, which the slot's destructor frees before the evaluation
    /// ends. Every member reads the value through `__v()`, which picks the
    /// arm. The run-time arm is unchanged and never sees `__p`; clang emits
    /// no code for the compile-time one.
    prot fn _ctor_slot_helpers(self, header: bool) {
        var at = self._tu_at()
        if header {
            self._cg->sink->directive(
                at,
                "#ifndef " + LowerTargets::ctor_slot_guard(),
            )
        }

        if header {
            self._cg->sink->directive(
                at,
                "#define " + LowerTargets::ctor_slot_guard(),
            )
        }

        self._cg->sink->spell(
            at,
            "template <class T> using " + LowerTargets::lref() + " = T&;",
        )

        self._cg->sink->brk()
        var sl = LowerTargets::ctor_slot()
        var sz = builtin_info(BuiltinKind::USize)->cxx.copy()
        var t  = "template <class T> struct " + sl + " {"
        t += " struct __b { T v; static void* operator new(" + sz + ", void* p) noexcept { return p; } };"
        t += " struct __h { T v; };"
        t += " union { __b b; };"
        t += " __h* __p = nullptr;"
        // The members EmitIR calls, one spelling each (LowerTargets).
        var st = LowerTargets::ctor_slot_set()
        var si = LowerTargets::ctor_slot_init()
        var dm = LowerTargets::dm_trait()
        t += " bool " + st + " = false;"
        t += " constexpr " + sl + "() noexcept {}"
        t += " " + sl + "(const " + sl + "&) = delete;"
        t += " " + sl + "& operator=(const " + sl + "&) = delete;"
        t += " constexpr ~" + sl + "() { if consteval { delete __p; } else { if (" + st + ") { b.~__b(); } } }"
        t += " constexpr T& __v() noexcept { if consteval { return __p->v; } else { return b.v; } }"
        var sp = LowerTargets::ctor_slot_put()
        t += " constexpr void " + si + "(T&& u) { if consteval { __p = new __h{static_cast<T&&>(u)}; } else { new (static_cast<void*>(&b)) __b{static_cast<T&&>(u)}; } " + st + " = true; }"
        t += " constexpr void " + si + "(const T& u) { if consteval { __p = new __h{u}; } else { new (static_cast<void*>(&b)) __b{u}; } " + st + " = true; }"
        t += " constexpr void " + sp + "(T&& u) { if (" + st + ") { __v() = static_cast<T&&>(u); } else { " + si + "(static_cast<T&&>(u)); } }"
        t += " constexpr void " + sp + "(const T& u) { if (" + st + ") { __v() = u; } else { " + si + "(u); } }"
        t += " constexpr T& " + LowerTargets::ctor_slot_get() + "() noexcept { return __v(); }"
        t += " constexpr T&& " + LowerTargets::ctor_slot_take() + "() noexcept { if (::" + dm + "<T>) { " + st + " = false; } return static_cast<T&&>(__v()); }"
        t += " };"
        self._cg->sink->spell(at, t)
        self._cg->sink->brk()
        // A prvalue handed to `init` / `put` (EmitIR::_slot_value): built in
        // place, as `T u = e` would be, in storage whose destructor runs
        // only for a type whose moved-from object must be destroyed. A
        // named union, since an aggregate's anonymous union with a
        // non-trivial member has a deleted destructor; constexpr
        // throughout, as an eval constructor's slots are.
        self._cg->sink->spell(
            at,
            "template <class T> struct " + LowerTargets::dm_temp() + " { struct __b { T v; }; union __u { __b b; constexpr ~__u() {} } s; constexpr ~" + LowerTargets::dm_temp() + "() { if (!::" + dm + "<T>) { s.b.~__b(); } } };",
        )

        self._cg->sink->brk()
        // An array field's slot. `init(T u)` would take a decayed pointer and
        // an array has no `=`, so this one builds its elements from the
        // array's, moved from a prvalue (a list literal) or copied from an
        // lvalue, or one at a time (`init_at`), and has no `put`:
        // CtorInitCheck allows one write. The field's mem-initializer reads
        // `take()[i]` per element (EmitIR).
        var a = "template <class T, " + sz + " N> struct " + sl + "<T[N]> {"
        a += " using __a = T[N];"
        a += " template <class I, I... K> struct __q {};"
        a += " struct __b { T v[N]; static void* operator new(" + sz + ", void* p) noexcept { return p; } };"
        a += " struct __h { T v[N]; };"
        a += " union { __b b; };"
        a += " __h* __p = nullptr;"
        a += " bool " + st + " = false;"
        a += " constexpr " + sl + "() noexcept {}"
        a += " " + sl + "(const " + sl + "&) = delete;"
        a += " " + sl + "& operator=(const " + sl + "&) = delete;"
        a += " constexpr ~" + sl + "() { if consteval { delete __p; } else { if (" + st + ") { b.~__b(); } } }"
        a += " constexpr __a& __v() noexcept { if consteval { return __p->v; } else { return b.v; } }"
        a += " template <" + sz + "... K> constexpr void __mv(__a& u, __q<" + sz + ", K...>) { if consteval { __p = new __h{{static_cast<T&&>(u[K])...}}; } else { new (static_cast<void*>(&b)) __b{{static_cast<T&&>(u[K])...}}; } " + st + " = true; }"
        a += " template <" + sz + "... K> constexpr void __cp(const __a& u, __q<" + sz + ", K...>) { if consteval { __p = new __h{{u[K]...}}; } else { new (static_cast<void*>(&b)) __b{{u[K]...}}; } " + st + " = true; }"
        a += " constexpr void " + si + "(__a&& u) { __mv(u, " + LowerTargets::make_index_seq() + "<__q, " + sz + ", N>{}); }"
        a += " constexpr void " + si + "(const __a& u) { __cp(u, " + LowerTargets::make_index_seq() + "<__q, " + sz + ", N>{}); }"
        // Element by element (CtorInitCheck): each element is built once,
        // in place, in its own box (no <new>), and the array counts as built
        // when the last one is. A constructor never leaves S_pre with part of
        // it built (it cannot panic or return there, and every path builds
        // every element), so a partly built array is never destroyed.
        // At compile time an element has no box of its own to be built in:
        // the array is made whole first, which needs T's default (a T with
        // none cannot be built this way in a constant evaluation, and clang
        // says so where the evaluation stops).
        a += " struct __e { T v; static void* operator new(" + sz + ", void* p) noexcept { return p; } };"
        a += " " + sz + " __n = 0;"
        a += " constexpr void " + LowerTargets::ctor_slot_init_at() + "(" + sz + " k, T u) { if consteval { if constexpr (__is_constructible(__h)) { if (__p == nullptr) { __p = new __h{}; } __p->v[k] = static_cast<T&&>(u); } } else { new (static_cast<void*>(&b.v[k])) __e{static_cast<T&&>(u)}; } if (++__n == N) { " + st + " = true; } }"
        a += " constexpr __a& " + LowerTargets::ctor_slot_get() + "() noexcept { return __v(); }"
        a += " constexpr __a&& " + LowerTargets::ctor_slot_take() + "() noexcept { return static_cast<__a&&>(__v()); }"
        a += " };"
        self._cg->sink->spell(at, a)
        self._cg->sink->brk()
        if header {
            self._cg->sink->directive(at, "#endif")
        }
    }

    /// `::__kairo_fn<R(A...)>`, the C++ type of a Kairo `fn(A) -> R` value
    /// (Speller, Compiler/Spec/Codegen.md#emitir Closures). Three words: the
    /// function every call goes through (`__c`), the closure's operations
    /// (`__t`), and one word of state (`__s`). One of:
    ///   - empty (a default-constructed `fn` local, constexpr): `__c` null;
    ///   - a plain function, held in `__s`: a named function, or a closure
    ///     that captures nothing (`+[](...){...}`). `__t` is null, or
    ///     `__flat` when the function is speculatable (the `__kairo_spec`
    ///     constructor, EmitIR::_fn_spec_value), which `is_spec()` reads.
    ///     The fact travels with every copy of the value, and a value made
    ///     any other way says no;
    ///   - a small closure, its captures held in `__s` itself:
    ///     `small([...](...){...})`. EmitIR picks this form for a closure
    ///     whose captures are scalars it never writes, so the lambda is not
    ///     `mutable` and a call can read the captures from a copy. One that
    ///     does not fit the word is copied to the heap, bit for bit;
    ///   - a heap lambda, its address in `__s`, with its copy and destroy
    ///     operations: any other closure that captures, adopted by
    ///     `own(new auto([...](...){...}))`. The lambda is built in its heap
    ///     slot from the prvalue (no temporary, so each captured copy is
    ///     made once and destroyed once).
    /// A call is one indirect call of `__c`, with no test of the kind: a
    /// plain function is reached through `__pcall`, which forwards to it.
    /// `__c` takes the arguments and then the state BY VALUE, so the `fn`
    /// value's own address never leaves the caller: a value the optimizer
    /// can see whole (a local, an array element) keeps its calls direct and
    /// inlinable. A scalar argument is passed as itself, in a register; any
    /// other as the reference the caller already holds, so no argument is
    /// copied or moved an extra time on the way through.
    /// The speculatable fact is in `__t`, not in a second forwarder: two
    /// forwarders with the same body may be folded into one by a linker's
    /// identical code folding (`--icf-mode all`), and every plain function
    /// would then read as speculatable.
    /// Copying copies the lambda (each copy keeps its own captured copies,
    /// as copying a C++ lambda does); a lambda with a move-only capture
    /// cannot be copied, and copying one traps. Converting to `R(*)(A...)`
    /// -- a C callee's parameter, a C struct's field -- yields the function,
    /// and traps on a capturing closure, which has none. No library header:
    /// `new`/`delete` of a lambda need none, and `__builtin_trap` and
    /// `__builtin_memcpy` are clang's.
    prot fn _fn_value_helper(self, header: bool) {
        var at = self._tu_at()
        var fv = LowerTargets::fn_value()
        if header {
            self._cg->sink->directive(
                at,
                "#ifndef " + LowerTargets::fn_value_guard(),
            )
        }

        if header {
            self._cg->sink->directive(
                at,
                "#define " + LowerTargets::fn_value_guard(),
            )
        }

        self._cg->sink->spell(at, "template <class S> class " + fv + ";")
        self._cg->sink->brk()
        self._cg->sink->spell(
            at,
            "struct " + LowerTargets::fn_value_spec() + " {};",
        )

        self._cg->sink->brk()
        // A raw `unsafe fn`: the plain function pointer, as one name.
        self._cg->sink->spell(
            at,
            "template <class S> using " + LowerTargets::raw_fn() + " = S*;",
        )

        self._cg->sink->brk()
        // The call path is a Kairo frame: noexcept unless -funwind, as the
        // closures it holds are.
        var nx = (if (self._cg->opts.unwind) => ("") else => " noexcept")
        var t  = "template <class R, class... A> class " + fv + "<R(A...)> {"
        // The plain function it holds is a Kairo one (every Kairo function
        // is noexcept), so the pointer type says so: a call through it is
        // a call, not an invoke with a terminate landing pad.
        t += " using __ptr = R (*)(A...)" + nx + ";"
        if nx.size() > 0 {
            t += " using __xptr = R (*)(A...);"
        }

        // How the call path passes an argument: a scalar as itself, the rest
        // by reference. `__is_scalar` needs no complete type, so a `fn`
        // field naming its own record is laid out inside that record.
        t += " template <class T> struct __arg { using t = T&&; };"
        t += " template <class T> requires (__is_scalar(T)) struct __arg<T> { using t = T; };"
        // The state: a heap lambda's address, a function, or a small
        // closure's own bytes. One word with trivial copies, so it is
        // passed in a register.
        t += " struct __st { union { void* p; __ptr f;"
        if nx.size() > 0 {
            t += " __xptr x;"
        }

        t += " };"
        t += " constexpr __st() noexcept : p(nullptr) {}"
        t += " constexpr __st(__ptr g) noexcept : f(g) {} };"
        t += " using __inv = R (*)(typename __arg<A>::t..., __st)" + nx + ";"
        // copy builds a Kairo lambda, whose captures copy with Kairo
        // (noexcept) constructors. A throwing pointer would put a terminate
        // landing pad in every Kairo function that copies a `fn` value
        // (set_oom_handler); noexcept moves the one `new` can need into
        // __copy, out of line. Both null (__flat): nothing to copy or
        // destroy, the mark of a speculatable plain function.
        t += " struct __ops { void* (*copy)(const void*)" + nx + "; void (*drop)(void*) noexcept; };"
        t += " template <class F> static R __call(typename __arg<A>::t... a, __st s)" + nx + " { return (*static_cast<F*>(s.p))(static_cast<A&&>(a)...); }"
        t += " template <class F> static void* __copy(const void* o)" + nx + " {"
        t += " if constexpr (requires (const F& f) { F(f); }) { return new F(*static_cast<const F*>(o)); }"
        t += " else { " + LowerTargets::clang_trap() + "(); } }"
        t += " template <class F> static void __drop(void* o) noexcept { delete static_cast<F*>(o); }"
        t += " template <class F> static constexpr __ops __ops_of{&__copy<F>, &__drop<F>};"
        t += " static constexpr __ops __flat{nullptr, nullptr};"
        // A small closure is called on the bytes the call was handed, as a
        // const object: it writes none of its captures (EmitIR::
        // _closure_small), and a lambda that did would not compile here.
        t += " template <class F> static R __scall(typename __arg<A>::t... a, __st s)" + nx + " {"
        t += " alignas(F) unsigned char b[sizeof(F)]; __builtin_memcpy(b, &s, sizeof(F));"
        t += " return (*reinterpret_cast<const F*>(b))(static_cast<A&&>(a)...); }"
        t += " static R __pcall(typename __arg<A>::t... a, __st s)" + nx + " { return s.f(static_cast<A&&>(a)...); }"
        // A C++ function that may throw: __rcall is a noexcept frame
        // around a call C++ knows may throw, so clang gives it the
        // terminate landing pad. Held as the noexcept __ptr instead, the
        // call had none, and a throw unwound the Kairo frames above with
        // no cleanups (UB) -- or, with no LSDA there, reached a C++ catch
        // past them.
        if nx.size() > 0 {
            t += " static R __rcall(typename __arg<A>::t... a, __st s) noexcept { return s.x(static_cast<A&&>(a)...); }"
        }

        t += " __inv __c = nullptr;"
        t += " const __ops* __t = nullptr;"
        t += " __st __s;"
        t += " public:"
        // constexpr, so a namespace-scope `fn` value initialized from a
        // function (or a captureless closure) is constant-initialized: no
        // constructor call at startup, and no static-init order hazard for
        // another TU's initializer that calls through it. The destructor
        // stays a runtime one (it may delete a heap lambda), so C++ still
        // registers it at exit; that is the only startup work left.
        t += " constexpr " + fv + "() noexcept {}"
        t += " constexpr " + fv + "(__ptr f) noexcept : __c(&__pcall), __s(f) {}"
        // A C++ function that is not noexcept (a host's `int f(int)`, kcc's
        // #include "x.k" callers) still becomes a `fn` value, called through
        // the __rcall thunk: a throw out of it ends in terminate at the `fn`
        // value's own noexcept frame, as at any Kairo frame (c-cpp-
        // exceptions.mdx). A template, so the exact-match constructor above
        // wins for every Kairo function.
        if nx.size() > 0 {
            t += " template <class = void> " + fv + "(R (*f)(A...)) noexcept : __c(&__rcall) { __s.x = f; }"
        }

        // constexpr, as the constructor above: the mark is the address of a
        // static, so a namespace-scope `fn` value stays constant-initialized.
        t += " constexpr " + fv + "(__ptr f, " + LowerTargets::fn_value_spec() + ") noexcept : __c(&__pcall), __t(&__flat), __s(f) {}"
        t += " constexpr bool " + LowerTargets::fn_value_is_spec() + "() const noexcept { return __t && !__t->drop; }"
        t += " template <class F> static " + fv + " " + LowerTargets::fn_value_own() + "(F* o) noexcept { " + fv + " r; r.__c = &__call<F>; r.__t = &__ops_of<F>; r.__s.p = o; return r; }"
        // Held in place when it fits the word, else on the heap: its
        // copies are bitwise either way, so which one is not observable.
        t += " template <class F> static " + fv + " " + LowerTargets::fn_value_small() + "(const F& f) noexcept {"
        t += " static_assert(__is_trivially_copyable(F) && __is_trivially_destructible(F));"
        t += " " + fv + " r;"
        t += " if constexpr (sizeof(F) <= sizeof(__st) && alignof(F) <= alignof(__st)) { __builtin_memcpy(static_cast<void*>(&r.__s), &f, sizeof(F)); r.__c = &__scall<F>; }"
        t += " else { r.__c = &__call<F>; r.__t = &__ops_of<F>; r.__s.p = new F(f); }"
        t += " return r; }"
        // `__t` with no operations (__flat) is a plain function: its state
        // copies as its bits and is never destroyed.
        t += " " + fv + "(const " + fv + "& o)" + nx + " : __c(o.__c), __t(o.__t), __s(o.__s) { if (__t && __t->copy) { __s.p = __t->copy(o.__s.p); } }"
        // A heap lambda moves out and leaves the source empty; anything
        // else is its bits, and the source keeps them.
        t += " " + fv + "(" + fv + "&& o) noexcept : __c(o.__c), __t(o.__t), __s(o.__s) { if (o.__t && o.__t->drop) { o.__c = nullptr; o.__t = nullptr; } }"
        t += " " + fv + "& operator=(" + fv + " o) noexcept {"
        t += " __inv c = __c; const __ops* q = __t; __st s = __s;"
        t += " __c = o.__c; __t = o.__t; __s = o.__s; o.__c = c; o.__t = q; o.__s = s; return *this; }"
        t += " ~" + fv + "() { if (__t && __t->drop) { __t->drop(__s.p); } }"
        // Always inline: out of line it is a call to a wrapper before the
        // indirect call it exists to make. Inlined, the caller makes the
        // indirect call itself, and a `-> !` call site's unreachable
        // (EmitIR::_call) follows it rather than the wrapper's call, so the
        // wrapper's own return path is gone too.
        t += " " + LowerTargets::attr_always_inline() + "R operator()(A... a) const" + nx + " { return __c(static_cast<typename __arg<A>::t>(a)..., __s); }"
        // A held C++ function converts back to itself: whatever calls it
        // through the C pointer type is C++, not a noexcept Kairo frame.
        var raw_back = (if (nx.size() > 0) => (" if (__c == &__rcall) { return reinterpret_cast<__ptr>(__s.x); }")
                        else => "")
        t += " operator __ptr() const noexcept { if (__c == &__pcall) { return __s.f; }" + raw_back + " if (__c) { " + LowerTargets::clang_trap() + "(); } return nullptr; }"
        t += " };"
        self._cg->sink->spell(at, t)
        self._cg->sink->brk()
        if header {
            self._cg->sink->directive(at, "#endif")
        }
    }

    /// In the class, for split constructor `m` (FunctionDecl::ci_split):
    ///   struct __kairo_ciK;
    ///   auto __kairo_ctor_preK(__kairo_ciK&& __kairo_s, __kairo_lref<P> p...) -> __kairo_ciK&;
    ///   R(__kairo_ciK&& __kairo_s, __kairo_lref<P> p...);
    /// The pre-function is a member: it runs once the bases are built and
    /// reads their fields through `this`.
    /// The slot record is only declared: its members name the types of
    /// locals the class itself never needs complete, and it is defined
    /// beside the bodies (EmitIR::_split_ctor). The trailing return keeps a
    /// generic owner's out-of-line definition free of `typename`.
    prot fn _split_ctor_decls(self, m: unsafe *Declarations::FunctionDecl, owner: unsafe *Decl) {
        var at = self._at(m)
        var ci = LowerTargets::ctor_slots(m->ci_index)
        var sa = LowerTargets::ctor_slot_arg()
        var ps = self._lref_params(m, owner)
        // The halves run where the constructor runs: an eval one's at
        // compile time only, so they are `consteval` with it (Compiler/Spec/Eval.md#eval-fn),
        // and C++ wants every declaration to say so.
        var ce = (if (m->is_eval()) => ("consteval ")
                  else => (if (m->is_constexpr()) => ("constexpr ") else => ""))
        self._cg->sink->spell(at, "struct " + ci + ";")
        self._cg->sink->spell(
            at,
            ce.copy() + "auto " + LowerTargets::ctor_pre(
                m->ci_index,
            ) + "(" + ci + "&& " + sa + ps + ") -> " + ci + "&;",
        )

        self._cg->sink->spell(
            at,
            ce + self._spell->leaf(owner) + "(" + ci + "&& " + sa + ps + ");",
        )
    }

    /// `, __kairo_lref<P> p` per parameter but `self`, in order.
    priv fn _lref_params(self,
                         m:     unsafe *Declarations::FunctionDecl,
                         owner: unsafe *Decl) -> string {
        var s = ""
        for var i: usize = 0; i < m->params.size(); ++i {
            var unsafe *p = m->params[i]
            if p == &null || p->is_self {
                continue
            }

            s += ", ::" + LowerTargets::lref() + "<" + self._spell->param_type(
                p,
                &null,
                owner,
            ) + "> "
            s += self._spell->tok_name(
                p->name,
                Speller::fid_of(unsafe (m as unsafe *Decl)),
            )
        }

        return s
    }

    /// The definitions of `d`'s static fields and of every nested record's,
    /// after `d`'s closing brace (file header, Static fields). `d` is the
    /// outermost record of a tier-1 entry; anything else has no statics.
    prot fn _static_defs(self, d: unsafe *Decl) {
        if !self._has_statics(d) {
            return
        }

        var fields = DeclFacts::decl_fields(d)
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *f = fields[i]
            if f == &null || !f->is_static() || f->is_anonymous_union {
                continue
            }

            self._static_def(f, d)
        }

        var unsafe *dc = Speller::dc_of(d)
        if dc == &null {
            return
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd == &null {
                continue
            }

            if self._has_statics(nd) {
                self._static_defs(Speller::rep(nd))
            }
        }
    }

    /// The kinds that declare static fields: a class, a struct or a union.
    priv fn _has_statics(self, d: unsafe *Decl) -> bool {
        return isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)
    }

    /// `[template <...>] inline [constinit] [thread_local] T R::s = init;`.
    /// The initializer of a static member's definition is in its class's
    /// scope, so a thunk is called by leaf, as a default calls it.
    priv fn _static_def(self, f: unsafe *Declarations::FieldDecl, owner: unsafe *Decl) {
        // A thunked eval field is defined after its consteval thunk's body,
        // which a constant expression needs DEFINED (EmitIR::_eval_field_def).
        if f->is_eval() && f->init_fold == Declarations::FieldFold::Thunk {
            return
        }

        var s = self._spell->owner_template_head(owner)
        s += "inline "
        var folded = f->init_fold == Declarations::FieldFold::Int
            || f->init_fold == Declarations::FieldFold::True
            || f->init_fold == Declarations::FieldFold::False
            || f->init_fold == Declarations::FieldFold::Null
        if f->is_eval() {
            s += "constexpr "
        } else if folded {
            s += "constinit "
        }

        if f->is_thread {
            s += "thread_local "
        }

        // The class body declared it `static const T s;` (`static const`
        // member); C++ rejects a definition whose type drops the const.
        var nm = self._spell->owner_qual(owner) + "::" + self._spell->leaf(
            unsafe (f as unsafe *Decl),
        )

        s += if (f->is_const() || f->is_eval()) => (self._spell->const_decl(
                 f->type_,
                 nm,
             ))
             else => self._spell->decl(f->type_, nm)
        if f->init_fold == Declarations::FieldFold::None {
            if f->init != &null {
                self._ice(
                    f->name.range,
                    "InterfaceEmitter: a static field's initializer reached codegen unlowered; FieldInitLowering lowers every one",
                )
            }

            s += "{}"
        } else {
            s += self._field_default(f)
        }

        s += ";"
        self._cg->sink->spell(f->name.range, s)
        // Compiler/Spec/Eval.md#deferred-conditions: the value an `eval if` was decided on (EmitIR::_global_var).
        var pin = DeclFacts::decl_fold_pin(f)
        if pin.size() > 0 {
            self._cg->sink->spell(
                f->name.range,
                "static_assert(" + nm + " == " + pin + ", \"EVAL.md 4.2b: an eval if was decided on this constant; Kairo's type facts and clang disagree on its value\");",
            )
        }
    }

    /// A C++ enumerator value. The 64-bit minimum has no literal (its
    /// magnitude is no long long), so it is spelled as an expression; a
    /// magnitude past the long long range takes `u`, which keeps clang from
    /// warning that the literal is too large for a signed type.
    prot fn _enum_value(self, c: Declarations::IntConst) -> string {
        var min_mag = (1 as u64) << (63 as u64)
        if c.neg {
            if c.mag == min_mag {
                return "(-9223372036854775807 - 1)"
            }

            return f"-{c.mag}"
        }

        if c.mag >= min_mag {
            return f"{c.mag}u"
        }

        return f"{c.mag}"
    }
}
