/* --- The Kairo Project ------------------------- Lib/rt/intrinsics.h --- */
/*
 *   The C++ side of the compiler intrinsics Lib/builtin/base/intrinsics.k
 *   declares: one `kairo_rt_*` helper per intrinsic whose clang builtin is
 *   type-checked per call (no signature Kairo can import), takes a type
 *   operand, or has the same name as the Kairo intrinsic (so the Kairo body
 *   could not reach it). Header-only and always_inline: an argument clang
 *   wants constant (a memory order, a prefetch hint) is constant again once
 *   the call is inlined, so the switches below fold away.
 *
 *   Part of the Kairo Project, under the Apache License v2.0 with the
 *   Kairo Runtime Library Exception.
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 */
#pragma once

#include <new>
#define KAIRO_RT_INL __attribute__((always_inline)) inline

/* --- memory ------------------------------------------------------------ */

template <class T, class... A>
KAIRO_RT_INL T *kairo_rt_construct_at(unsigned char *p, A &&...a) {
    return ::new (static_cast<void *>(p)) T(static_cast<A &&>(a)...);
}
template <class T> KAIRO_RT_INL void kairo_rt_destruct_at(T *p) { p->~T(); }
template <class T, class F> KAIRO_RT_INL constexpr T kairo_rt_bit_cast(F v) { return __builtin_bit_cast(T, v); }
template <class T> KAIRO_RT_INL constexpr T *kairo_rt_launder(T *p) { return __builtin_launder(p); }
KAIRO_RT_INL unsigned char *kairo_rt_assume_aligned(unsigned char *p, unsigned long long a) {
    /* clang's own form wants a constant alignment; this one holds for any.
       The alignment crosses as u64: an imported size_t is not Kairo's usize
       on every target, and usize converts to nothing implicitly. */
    __builtin_assume((reinterpret_cast<__UINTPTR_TYPE__>(p) & (a - 1)) == 0);
    return p;
}

/* --- layout and traits ------------------------------------------------- */

#define KAIRO_RT_TRAIT1(name, expr) \
    template <class T> KAIRO_RT_INL constexpr bool kairo_rt_##name() { return expr; }
#define KAIRO_RT_TRAIT2(name, expr) \
    template <class T, class U> KAIRO_RT_INL constexpr bool kairo_rt_##name() { return expr; }

KAIRO_RT_TRAIT2(is_same, __is_same(T, U))
KAIRO_RT_TRAIT1(is_void, __is_void(T))
KAIRO_RT_TRAIT1(is_pointer, __is_pointer(T))
KAIRO_RT_TRAIT1(is_array, __is_array(T))
KAIRO_RT_TRAIT1(is_function, __is_function(T))
KAIRO_RT_TRAIT1(is_enum, __is_enum(T))
KAIRO_RT_TRAIT1(is_union, __is_union(T))
KAIRO_RT_TRAIT1(is_integral, __is_integral(T))
KAIRO_RT_TRAIT1(is_floating_point, __is_floating_point(T))
KAIRO_RT_TRAIT1(is_signed, __is_signed(T))
KAIRO_RT_TRAIT1(is_unsigned, __is_unsigned(T))
KAIRO_RT_TRAIT1(is_trivially_copyable, __is_trivially_copyable(T))
KAIRO_RT_TRAIT1(is_trivially_destructible, __is_trivially_destructible(T))
KAIRO_RT_TRAIT1(is_trivially_relocatable, __builtin_is_cpp_trivially_relocatable(T))
KAIRO_RT_TRAIT1(is_standard_layout, __is_standard_layout(T))
KAIRO_RT_TRAIT1(is_aggregate, __is_aggregate(T))
KAIRO_RT_TRAIT1(is_empty, __is_empty(T))
KAIRO_RT_TRAIT1(is_polymorphic, __is_polymorphic(T))
KAIRO_RT_TRAIT1(is_abstract, __is_abstract(T))
KAIRO_RT_TRAIT1(is_final, __is_final(T))
KAIRO_RT_TRAIT1(has_virtual_destructor, __has_virtual_destructor(T))
KAIRO_RT_TRAIT1(is_destructible, __is_destructible(T))
KAIRO_RT_TRAIT2(is_base_of, __is_base_of(T, U))
KAIRO_RT_TRAIT2(is_convertible, __is_convertible(T, U))
KAIRO_RT_TRAIT2(is_trivially_assignable, __is_trivially_assignable(T &, U))
KAIRO_RT_TRAIT2(is_assignable, __is_assignable(T &, U))
/* Fixed arity: Kairo cannot yet pass a pack to an imported template. */
KAIRO_RT_TRAIT1(is_trivially_constructible0, __is_trivially_constructible(T))
KAIRO_RT_TRAIT2(is_trivially_constructible1, __is_trivially_constructible(T, U))
KAIRO_RT_TRAIT1(is_constructible0, __is_constructible(T))
KAIRO_RT_TRAIT2(is_constructible1, __is_constructible(T, U))
template <class T> KAIRO_RT_INL constexpr bool kairo_rt_atomic_is_lock_free() { return __atomic_always_lock_free(sizeof(T), 0); }

/* --- bits: on the unsigned type of T's width ---------------------------- */

#define KAIRO_RT_U(T) __make_unsigned(T)
template <class T> KAIRO_RT_INL constexpr unsigned kairo_rt_ctz(T v) {
    return (unsigned)__builtin_ctzg((KAIRO_RT_U(T))v, (int)(sizeof(T) * 8));
}
template <class T> KAIRO_RT_INL constexpr unsigned kairo_rt_clz(T v) {
    return (unsigned)__builtin_clzg((KAIRO_RT_U(T))v, (int)(sizeof(T) * 8));
}
template <class T> KAIRO_RT_INL constexpr unsigned kairo_rt_popcount(T v) {
    return (unsigned)__builtin_popcountg((KAIRO_RT_U(T))v);
}
template <class T> KAIRO_RT_INL constexpr T kairo_rt_bswap(T v) {
    using U = KAIRO_RT_U(T);
    U u = (U)v;
    if constexpr (sizeof(T) == 1) return v;
    else if constexpr (sizeof(T) == 2) return (T)__builtin_bswap16(u);
    else if constexpr (sizeof(T) == 4) return (T)__builtin_bswap32(u);
    else if constexpr (sizeof(T) == 8) return (T)__builtin_bswap64(u);
    else return (T)__builtin_bswapg(u);
}
template <class T> KAIRO_RT_INL constexpr T kairo_rt_rotl(T v, unsigned n) {
    using U = KAIRO_RT_U(T);
    constexpr unsigned w = sizeof(T) * 8;
    U u = (U)v; n %= w;
    return (T)(U)(n == 0 ? u : (U)((u << n) | (u >> (w - n))));
}
template <class T> KAIRO_RT_INL constexpr T kairo_rt_rotr(T v, unsigned n) {
    using U = KAIRO_RT_U(T);
    constexpr unsigned w = sizeof(T) * 8;
    U u = (U)v; n %= w;
    return (T)(U)(n == 0 ? u : (U)((u >> n) | (u << (w - n))));
}

/* --- overflow-checked arithmetic ---------------------------------------- */

template <class T> KAIRO_RT_INL constexpr bool kairo_rt_add_overflow(T a, T b, T *r) { return __builtin_add_overflow(a, b, r); }
template <class T> KAIRO_RT_INL constexpr bool kairo_rt_sub_overflow(T a, T b, T *r) { return __builtin_sub_overflow(a, b, r); }
template <class T> KAIRO_RT_INL constexpr bool kairo_rt_mul_overflow(T a, T b, T *r) { return __builtin_mul_overflow(a, b, r); }

/* --- codegen and optimizer hooks ---------------------------------------- */

KAIRO_RT_INL bool kairo_rt_expect(bool c, bool e) { return __builtin_expect((long)c, (long)e) != 0; }
KAIRO_RT_INL bool kairo_rt_expect_prob(bool c, bool e, double p) {
    /* clang wants the probability as a literal; through a call it is a run-time
       double, so the hint keeps its direction only. */
    return __builtin_expect((long)c, (long)(p >= 0.5 ? e : !e)) != 0;
}
[[noreturn]] KAIRO_RT_INL void kairo_rt_unreachable() { __builtin_unreachable(); }
[[noreturn]] KAIRO_RT_INL void kairo_rt_trap() { __builtin_trap(); }
[[noreturn]] KAIRO_RT_INL void kairo_rt_abort() { __builtin_abort(); }
KAIRO_RT_INL void kairo_rt_debugtrap() { __builtin_debugtrap(); }
KAIRO_RT_INL void kairo_rt_assume(bool c) { __builtin_assume(c); }
KAIRO_RT_INL void kairo_rt_prefetch(const unsigned char *p, int rw, int loc) {
    if (rw == 0) {
        switch (loc) { case 0: __builtin_prefetch(p, 0, 0); break; case 1: __builtin_prefetch(p, 0, 1); break;
                       case 2: __builtin_prefetch(p, 0, 2); break; default: __builtin_prefetch(p, 0, 3); break; }
    } else {
        switch (loc) { case 0: __builtin_prefetch(p, 1, 0); break; case 1: __builtin_prefetch(p, 1, 1); break;
                       case 2: __builtin_prefetch(p, 1, 2); break; default: __builtin_prefetch(p, 1, 3); break; }
    }
}
KAIRO_RT_INL constexpr bool kairo_rt_is_constant_evaluated() { return __builtin_is_constant_evaluated(); }
template <class T> KAIRO_RT_INL constexpr bool kairo_rt_constant_p(T v) { return __builtin_constant_p(v); }

/* --- atomics: the order is an int, constant once inlined ----------------- */

template <class T> KAIRO_RT_INL T kairo_rt_atomic_load(const T *p, int o) { return __atomic_load_n(p, o); }
template <class T> KAIRO_RT_INL void kairo_rt_atomic_store(T *p, T v, int o) { __atomic_store_n(p, v, o); }
template <class T> KAIRO_RT_INL T kairo_rt_atomic_exchange(T *p, T v, int o) { return __atomic_exchange_n(p, v, o); }
template <class T>
KAIRO_RT_INL bool kairo_rt_atomic_cas(T *p, T *e, T d, bool weak, int s, int f) {
    return __atomic_compare_exchange_n(p, e, d, weak, s, f);
}
#define KAIRO_RT_FETCH(op) \
    template <class T> KAIRO_RT_INL T kairo_rt_atomic_fetch_##op(T *p, T v, int o) { return __atomic_fetch_##op(p, v, o); }
KAIRO_RT_FETCH(add) KAIRO_RT_FETCH(sub) KAIRO_RT_FETCH(and) KAIRO_RT_FETCH(or)
KAIRO_RT_FETCH(xor) KAIRO_RT_FETCH(max) KAIRO_RT_FETCH(min)
KAIRO_RT_INL void kairo_rt_atomic_fence(int o) { __atomic_thread_fence(o); }
KAIRO_RT_INL void kairo_rt_atomic_signal_fence(int o) { __atomic_signal_fence(o); }

/* --- coroutines: none. `__builtin_coro_*` keep clang's own names and are
   called directly: coro_promise's alignment must be a literal, and size /
   align / frame only mean something inside the coroutine itself. */

#undef KAIRO_RT_TRAIT1
#undef KAIRO_RT_TRAIT2
#undef KAIRO_RT_FETCH
