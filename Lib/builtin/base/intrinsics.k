/// --- The Kairo Project ---------------- Lib/builtin/base/intrinsics.k --- ///
///
///   \brief The compiler intrinsics: memory, layout, traits, bits, overflow,
///          optimizer hooks, termination, atomics and the target.
///
///   \detail
///     Each is one of three things:
///       - a forward to a `kairo_rt_*` helper in Lib/rt/intrinsics.h (C++,
///         header-only, always_inline), for a clang builtin that is type-
///         checked per call, takes a type, or shares the intrinsic's name;
///       - answered by the compiler (the Kairo-only traits, declared in
///         module.k as lang items: EnumLayoutLowering);
///       - plain Kairo (size_of / align_of, target_info).
///     Not declared here because a wrapper would change what they mean, so
///     they are clang's own builtins under their own names, called directly:
///     `__builtin_alloca(size)` / `__builtin_alloca_with_align(size, bits)`
///     (the memory belongs to the caller's frame) and the coroutine builtins
///     (`__builtin_coro_resume`, `_destroy`, `_done`, `_promise`, `_noop`,
///     `_size`, `_align`, `_frame`: the last three mean something only
///     inside the coroutine itself).
///
///     The families (each `__builtin_*` below is documented where it is declared):
///       - memory: `copy`, `move_mem`, `set_mem`, `compare_mem`, `construct_at`, `destruct_at`,
///         `bitcast`, `launder`, `assume_aligned`, `size_of`, `align_of`, `dynamic_size`,
///         `dynamic_align`;
///       - traits: `is_*` and `has_*` queries on types, answered at compile time (the Kairo-only
///         ones are in module.k);
///       - bits: `ctz`, `clz`, `popcount`, `bswap`, `rotl`, `rotr`, and the checked
///         `add_overflow`, `sub_overflow`, `mul_overflow`;
///       - atomics: `atomic_load`, `store`, `exchange`, `cas`, the `fetch_*` operations, the
///         fences and `atomic_is_lock_free`, ordered by `MemoryOrder`;
///       - target: `__builtin_target_info()` and the `TargetInfo` it returns;
///       - also: optimizer hooks (`expect`, `assume`, `unreachable`, `prefetch`, ...) and
///         termination (`trap`, `abort`, `crash`, `signal`).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "rt/intrinsics.h"
ffi "c"   import "rt/crash.h"

// --- language enums ---------------------------------------------------------

/// The memory ordering of an atomic operation or fence, with the C11 / C++11 meaning.
///
/// The discriminants are `__ATOMIC_RELAXED` .. `__ATOMIC_SEQ_CST`, so a value converts straight
/// to clang's `int` order argument.
pub enum MemoryOrder derives i32 {
    Relaxed = 0, Consume = 1, Acquire = 2, Release = 3, AcqRel = 4, SeqCst = 5,
}

eval if defined!(__unix__) {
    /// A POSIX signal number, for `__builtin_signal`. The values are the Linux numbering.
    ///
    /// On non-unix targets only `SIGINT`, `SIGILL`, `SIGABRT`, `SIGFPE`, `SIGSEGV` and `SIGTERM`
    /// exist.
    pub enum SIGNAL derives i32 {
        SIGHUP  = 1,  SIGINT    = 2,  SIGQUIT = 3,  SIGILL    = 4,
        SIGTRAP = 5,  SIGABRT   = 6,  SIGBUS  = 7,  SIGFPE    = 8,
        SIGKILL = 9,  SIGUSR1   = 10, SIGSEGV = 11, SIGUSR2   = 12,
        SIGPIPE = 13, SIGALRM   = 14, SIGTERM = 15, SIGSTKFLT = 16,
        SIGCHLD = 17, SIGCONT   = 18, SIGSTOP = 19, SIGTSTP   = 20,
        SIGTTIN = 21, SIGTTOU   = 22, SIGURG  = 23, SIGXCPU   = 24,
        SIGXFSZ = 25, SIGVTALRM = 26, SIGPROF = 27, SIGWINCH  = 28,
        SIGIO   = 29, SIGPWR    = 30, SIGSYS  = 31,
    }
} else {
    /// A signal number, for `__builtin_signal`. Non-unix targets have only the C standard signals
    /// (`SIGINT`, `SIGILL`, `SIGABRT`, `SIGFPE`, `SIGSEGV`, `SIGTERM`).
    pub enum SIGNAL derives i32 {
        SIGINT  = 2,
        SIGILL  = 4,
        SIGABRT = 6,
        SIGFPE  = 8,
        SIGSEGV = 11,
        SIGTERM = 15,
    }
}

// --- memory: raw operations -------------------------------------------------

/// Copies `size` bytes from `src` to `dst`; the regions must not overlap. Maps to
/// `__builtin_memcpy`.
///
/// \safety Both pointers must be valid for `size` bytes (even when `size` is 0, clang assumes
/// they are non-null), and the regions must not overlap; use `__builtin_move_mem` if they might.
pub inline fn __builtin_copy(dst: unsafe *u8, src: unsafe *const u8, size: usize) {
    unsafe { __builtin_memcpy(dst, src, size) }
}
/// Copies `size` bytes from `src` to `dst`; the regions may overlap. Maps to `__builtin_memmove`.
///
/// \safety Both pointers must be valid for `size` bytes.
pub inline fn __builtin_move_mem(dst: unsafe *u8, src: unsafe *const u8, size: usize) {
    unsafe { __builtin_memmove(dst, src, size) }
}
/// Sets `size` bytes at `ptr` to `value`. Maps to `__builtin_memset`.
///
/// \safety `ptr` must be valid for writes of `size` bytes.
pub inline fn __builtin_set_mem(ptr: unsafe *u8, value: byte, size: usize) {
    unsafe { __builtin_memset(ptr, value as u8, size) }
}
/// Compares `size` bytes of `a` and `b` as unsigned bytes. Returns a negative, zero or positive
/// value. Maps to `__builtin_memcmp`.
///
/// \safety Both pointers must be valid for `size` bytes.
pub inline fn __builtin_compare_mem(a: unsafe *const u8, b: unsafe *const u8, size: usize) -> i32 {
    unsafe { return __builtin_memcmp(a, b, size) }
}

/// Placement construction: builds a `T` from `args` in the storage at `ptr` and returns a pointer
/// to it. Maps to placement `new` (`kairo_rt_construct_at`).
///
/// \safety `ptr` must be valid for `sizeof T` bytes and aligned to `alignof T`, and must not
/// already hold a live object that needs destroying.
pub fn <T, ...A> __builtin_construct_at(ptr: unsafe *u8, ...args: A) -> *T {
    unsafe { return kairo_rt_construct_at<T>(ptr, args...) as *T }
}
/// Runs `T`'s destructor on `*ptr` and leaves the storage as it is. Maps to an explicit `p->~T()`.
///
/// \safety `ptr` must point at a live `T`; it must not be used or destroyed again afterwards.
pub fn <T> __builtin_destruct_at(ptr: *T) {
    unsafe { kairo_rt_destruct_at(ptr as unsafe *T) }
}
/// Reinterprets the object representation of `v` as a `T`. Maps to `__builtin_bit_cast`.
///
/// `__builtin_bit_cast` is a clang keyword, so no C++ declaration can carry the name directly.
///
/// \note `T` and `From` must be the same size and trivially copyable; clang rejects the call
/// otherwise.
pub fn <T, From> __builtin_bitcast(v: From) -> T {
    return kairo_rt_bit_cast<T, From>(v)
}
/// Returns a pointer to the `T` that now lives at `ptr`'s address, after the storage was reused for
/// a new object. Maps to `__builtin_launder`.
///
/// \safety A `T` must live at `ptr`'s address.
pub fn <T> __builtin_launder(ptr: *T) -> *T {
    unsafe { return kairo_rt_launder(ptr as unsafe *T) as *T }
}
/// Tells the optimizer that `ptr` is aligned to `align` and returns it. Implemented as an
/// `__builtin_assume` on the address bits, so unlike clang's own form `align` need not be a
/// constant.
///
/// \param align  A power of two.
/// \safety `ptr` must really be `align`-aligned; otherwise the behaviour is undefined.
pub inline fn __builtin_assume_aligned(ptr: unsafe *u8, align: usize) -> unsafe *u8 {
    unsafe { return kairo_rt_assume_aligned(ptr, align as u64) }
}

// --- layout -----------------------------------------------------------------

/// Returns `sizeof T`. Evaluated at compile time.
pub eval fn <T> __builtin_size_of() -> usize { return sizeof T }
/// Returns `alignof T`. Evaluated at compile time.
pub eval fn <T> __builtin_align_of() -> usize { return alignof T }
/// Returns the size of the object `p` points at, which may be a class derived from `T`: read
/// through `T`'s hidden virtual when `T` has a virtual destructor, `sizeof T` otherwise. The
/// compiler writes the body.
///
/// \safety Read it before the destructor runs, and only for a live object.
pub inline fn <T> __builtin_dynamic_size(p: *T) -> usize { return sizeof T }
/// Returns the alignment of the object `p` points at; see `__builtin_dynamic_size`.
///
/// \safety Read it before the destructor runs, and only for a live object.
pub inline fn <T> __builtin_dynamic_align(p: *T) -> usize { return alignof T }

// --- traits: shape, layout and declaration facts, expression probes --------
// C++ answers each (clang's type traits); the Kairo-only ones are module.k's.

/// Returns true when `T` and `U` are the same type.
pub eval fn <T, U> __builtin_is_same() -> bool { return kairo_rt_is_same<T, U>() }
/// Returns true when `T` is `void`.
pub eval fn <T> __builtin_is_void() -> bool { return kairo_rt_is_void<T>() }
/// Returns true when `T` is a pointer, safe or unsafe alike; `__builtin_is_safe_pointer` tells
/// them apart.
pub eval fn <T> __builtin_is_pointer() -> bool { return kairo_rt_is_pointer<T>() }
/// Returns true when `T` is an array type.
pub eval fn <T> __builtin_is_array() -> bool { return kairo_rt_is_array<T>() }
/// Returns true when `T` is a function type.
pub eval fn <T> __builtin_is_function() -> bool { return kairo_rt_is_function<T>() }
/// Returns true when `T` is a plain enum. An ADT enum is a C++ struct, so it answers false
/// (`__builtin_is_adt_enum`).
pub eval fn <T> __builtin_is_enum() -> bool { return kairo_rt_is_enum<T>() }
/// Returns true when `T` is a union.
pub eval fn <T> __builtin_is_union() -> bool { return kairo_rt_is_union<T>() }
/// Returns true when `T` is an integer type.
pub eval fn <T> __builtin_is_integral() -> bool { return kairo_rt_is_integral<T>() }
/// Returns true when `T` is a floating-point type.
pub eval fn <T> __builtin_is_floating_point() -> bool { return kairo_rt_is_floating_point<T>() }
/// Returns true when `T` is a signed arithmetic type.
pub eval fn <T> __builtin_is_signed() -> bool { return kairo_rt_is_signed<T>() }
/// Returns true when `T` is an unsigned arithmetic type.
pub eval fn <T> __builtin_is_unsigned() -> bool { return kairo_rt_is_unsigned<T>() }

/// Returns true when `T` can be copied with `__builtin_copy`. Maps to `__is_trivially_copyable`.
pub eval fn <T> __builtin_is_trivially_copyable() -> bool { return kairo_rt_is_trivially_copyable<T>() }
/// Returns true when destroying a `T` runs no code. Maps to `__is_trivially_destructible`.
pub eval fn <T> __builtin_is_trivially_destructible() -> bool { return kairo_rt_is_trivially_destructible<T>() }
/// Returns true when a `T` can be trivially constructed from one `A`. Maps to
/// `__is_trivially_constructible(T, A)`.
///
/// Exactly one argument type: an imported template does not yet take a forwarded pack, so the
/// no-argument form is `__builtin_is_trivially_default_constructible`.
pub eval fn <T, A> __builtin_is_trivially_constructible() -> bool {
    return kairo_rt_is_trivially_constructible1<T, A>()
}
/// Returns true when `T()` runs no code. Maps to `__is_trivially_constructible(T)`.
pub eval fn <T> __builtin_is_trivially_default_constructible() -> bool {
    return kairo_rt_is_trivially_constructible0<T>()
}
/// Returns true when assigning a `U` to a `T` runs no non-trivial code. Maps to
/// `__is_trivially_assignable`.
pub eval fn <T, U> __builtin_is_trivially_assignable() -> bool { return kairo_rt_is_trivially_assignable<T, U>() }
/// Returns true when a `T` can be moved by copying its bytes and skipping the old object's
/// destructor. Maps to `__builtin_is_cpp_trivially_relocatable`.
pub eval fn <T> __builtin_is_trivially_relocatable() -> bool { return kairo_rt_is_trivially_relocatable<T>() }
/// Returns true when `T` has standard layout. Maps to `__is_standard_layout`.
pub eval fn <T> __builtin_is_standard_layout() -> bool { return kairo_rt_is_standard_layout<T>() }
/// Returns true when `T` is an aggregate. Maps to `__is_aggregate`.
pub eval fn <T> __builtin_is_aggregate() -> bool { return kairo_rt_is_aggregate<T>() }
/// Returns true when `T` is a class with no non-static data members. Maps to `__is_empty`.
pub eval fn <T> __builtin_is_empty() -> bool { return kairo_rt_is_empty<T>() }
/// Returns true when `T` has a virtual member. Maps to `__is_polymorphic`.
pub eval fn <T> __builtin_is_polymorphic() -> bool { return kairo_rt_is_polymorphic<T>() }
/// Returns true when `T` has a pure virtual member. Maps to `__is_abstract`.
pub eval fn <T> __builtin_is_abstract() -> bool { return kairo_rt_is_abstract<T>() }
/// Returns true when `T` is a final class. Maps to `__is_final`.
pub eval fn <T> __builtin_is_final() -> bool { return kairo_rt_is_final<T>() }
/// Returns true when `T` has a virtual destructor. Maps to `__has_virtual_destructor`.
pub eval fn <T> __builtin_has_virtual_destructor() -> bool { return kairo_rt_has_virtual_destructor<T>() }
/// Returns true when `B` is a base class of `D`. Maps to `__is_base_of`.
pub eval fn <B, D> __builtin_is_base_of() -> bool { return kairo_rt_is_base_of<B, D>() }

/// Returns true when `F` converts implicitly to `T`. Maps to `__is_convertible`.
pub eval fn <F, T> __builtin_is_convertible() -> bool { return kairo_rt_is_convertible<F, T>() }
/// Returns true when a `T` can be constructed from one `A`. Maps to `__is_constructible(T, A)`.
///
/// Exactly one argument type; see `__builtin_is_trivially_constructible`.
pub eval fn <T, A> __builtin_is_constructible() -> bool { return kairo_rt_is_constructible1<T, A>() }
/// Returns true when `T()` is well formed. Maps to `__is_constructible(T)`.
pub eval fn <T> __builtin_is_default_constructible() -> bool { return kairo_rt_is_constructible0<T>() }
/// Returns true when a `U` can be assigned to a `T`. Maps to `__is_assignable`.
pub eval fn <T, U> __builtin_is_assignable() -> bool { return kairo_rt_is_assignable<T, U>() }
/// Returns true when `T` is a complete type at the point of evaluation (`requires { sizeof(T); }`).
///
/// False for a class still being defined, e.g. a member of type `Vector<Self>`. Clang caches a
/// constraint's answer, so a constraint that asks `!is_complete || ...` is answered `true` for the
/// recursive case and judged for real everywhere else.
pub eval fn <T> __builtin_is_complete() -> bool { return kairo_rt_is_complete<T>() }
/// Returns true when a `T` can be destroyed. Maps to `__is_destructible`.
pub eval fn <T> __builtin_is_destructible() -> bool { return kairo_rt_is_destructible<T>() }

// --- bit operations (on the unsigned type of T's width) ---------------------
// Plain `fn`, not `eval fn`: an eval fn is C++ consteval and would refuse a
// run-time value. They are constexpr in C++, so constant arguments still fold.

/// Counts trailing zero bits of `v`, viewed as the unsigned type of `T`'s width. `ctz(0)` is the
/// bit width. Maps to `__builtin_ctzg`.
///
/// Plain `fn`, not `eval fn`, so it accepts run-time values; it is `constexpr` in C++, so
/// constant arguments still fold.
pub fn <T> __builtin_ctz(v: T) -> u32 { return kairo_rt_ctz(v) }
/// Counts leading zero bits of `v`, viewed as the unsigned type of `T`'s width. `clz(0)` is the
/// bit width. Maps to `__builtin_clzg`.
pub fn <T> __builtin_clz(v: T) -> u32 { return kairo_rt_clz(v) }
/// Counts the set bits of `v`, viewed as the unsigned type of `T`'s width. Maps to
/// `__builtin_popcountg`.
pub fn <T> __builtin_popcount(v: T) -> u32 { return kairo_rt_popcount(v) }
/// Reverses the byte order of `v`. A 1-byte `T` is returned unchanged. Maps to
/// `__builtin_bswap16` / `32` / `64`.
pub fn <T> __builtin_bswap(v: T) -> T { return kairo_rt_bswap(v) }
/// Rotates `v` left by `n` bits; `n` is taken modulo the bit width of `T`.
pub fn <T> __builtin_rotl(v: T, n: u32) -> T { return kairo_rt_rotl(v, n) }
/// Rotates `v` right by `n` bits; `n` is taken modulo the bit width of `T`.
pub fn <T> __builtin_rotr(v: T, n: u32) -> T { return kairo_rt_rotr(v, n) }

// --- overflow-checked arithmetic --------------------------------------------
// `result` receives the wrapped value; the return is whether it overflowed.

/// Computes `a + b`, stores the wrapped result in `*result` and returns true when the exact value
/// did not fit in `T`. Maps to `__builtin_add_overflow`.
///
/// \param result  Receives the wrapped value even when the call returns true.
pub fn <T> __builtin_add_overflow(a: T, b: T, result: *T) -> bool {
    unsafe { return kairo_rt_add_overflow(a, b, result as unsafe *T) }
}
/// Computes `a - b`, stores the wrapped result in `*result` and returns true when the exact value
/// did not fit in `T`. Maps to `__builtin_sub_overflow`.
///
/// \param result  Receives the wrapped value even when the call returns true.
pub fn <T> __builtin_sub_overflow(a: T, b: T, result: *T) -> bool {
    unsafe { return kairo_rt_sub_overflow(a, b, result as unsafe *T) }
}
/// Computes `a * b`, stores the wrapped result in `*result` and returns true when the exact value
/// did not fit in `T`. Maps to `__builtin_mul_overflow`.
///
/// \param result  Receives the wrapped value even when the call returns true.
pub fn <T> __builtin_mul_overflow(a: T, b: T, result: *T) -> bool {
    unsafe { return kairo_rt_mul_overflow(a, b, result as unsafe *T) }
}

// --- codegen and optimizer hooks --------------------------------------------

/// Returns `cond`, hinting that it is usually `expected`. Maps to `__builtin_expect`.
pub inline fn __builtin_expect(cond: bool, expected: bool) -> bool { return kairo_rt_expect(cond, expected) }
/// Returns `cond`, hinting its likely value from the probability `p` that it equals `expected`.
///
/// Only the direction of the hint is kept (`p >= 0.5`): clang takes an exact probability only as
/// a literal, and `p` is a run-time value here. Maps to `__builtin_expect`.
pub inline fn __builtin_expect_prob(cond: bool, expected: bool, p: f64) -> bool {
    return kairo_rt_expect_prob(cond, expected, p)
}
/// Tells the optimizer that control never reaches this call. Maps to `__builtin_unreachable`.
///
/// \safety Reaching it is undefined behaviour.
pub inline fn __builtin_unreachable() -> ! { kairo_rt_unreachable() }
/// Aborts execution immediately with a trap instruction (`ud2`, `brk`, ...). Maps to
/// `__builtin_trap`. Prints nothing and runs no handlers.
pub inline fn __builtin_trap() -> ! { kairo_rt_trap() }
/// Stops in an attached debugger and otherwise continues. Maps to `__builtin_debugtrap`.
pub inline fn __builtin_debugtrap() { kairo_rt_debugtrap() }
/// Tells the optimizer that `cond` is true at this point. Maps to `__builtin_assume`.
///
/// \safety If `cond` is false the behaviour is undefined. `cond` is not evaluated for effects
/// the program relies on.
pub inline fn __builtin_assume(cond: bool) { kairo_rt_assume(cond) }
/// Hints that the cache line holding `ptr` will be accessed soon. Maps to `__builtin_prefetch`;
/// never faults, even for an invalid address.
///
/// \param rw        0 for a read (default), anything else for a write.
/// \param locality  0 (no reuse) to 3 (keep in all cache levels, the default); other values are
/// treated as 3.
pub inline fn __builtin_prefetch(ptr: unsafe *const u8, rw: i32 = 0, locality: i32 = 3) {
    unsafe { kairo_rt_prefetch(ptr, rw, locality) }
}
/// Returns true when evaluated during constant evaluation and false at run time. Maps to
/// `__builtin_is_constant_evaluated`.
pub inline fn __builtin_is_constant_evaluated() -> bool { return kairo_rt_is_constant_evaluated() }
/// Returns true when the optimizer can fold `v` to a compile-time constant at this call. A false
/// result proves nothing. Maps to `__builtin_constant_p`.
pub fn <T> __builtin_constant_p(v: T) -> bool { return kairo_rt_constant_p(v) }

// --- termination -------------------------------------------------------------

/// Writes `msg[0..len)` and a newline to stderr, then terminates the process with `exit_code` via
/// `_Exit` (no atexit handlers, no destructors). Never returns.
///
/// \param exit_code  The process exit status.
/// \safety `msg` must be valid for reads of `len` bytes.
pub inline fn __builtin_crash(msg: *const u8, len: usize, exit_code: i32) -> ! {
    unsafe { kairo_rt_crash_exit(msg as unsafe *const u8, len, exit_code) }
}
/// Writes `msg[0..len)` and a newline to stderr, then raises `signal` at its default action.
/// Never returns.
///
/// \safety `msg` must be valid for reads of `len` bytes.
pub inline fn __builtin_signal(msg: *const u8, len: usize, signal: SIGNAL) -> ! {
    unsafe { kairo_rt_signal(msg as unsafe *const u8, len, signal as i32) }
}
/// Terminates the process abnormally. Maps to `__builtin_abort`; never returns.
pub inline fn __builtin_abort() -> ! { kairo_rt_abort() }

// --- atomics -----------------------------------------------------------------
// Pass the order as a constant: the helper is inlined and clang folds it;
// a run-time order compiles to a switch.

/// Atomically reads `*ptr`. Maps to `__atomic_load_n`.
///
/// Pass `order` as a constant so the inlined helper folds it; a run-time order compiles to a
/// switch.
///
/// \param order  `Relaxed`, `Consume`, `Acquire` or `SeqCst`.
pub fn <T> __builtin_atomic_load(ptr: *const T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_load(ptr as unsafe *const T, order as i32) }
}
/// Atomically writes `v` to `*ptr`. Maps to `__atomic_store_n`.
///
/// \param order  `Relaxed`, `Release` or `SeqCst`.
pub fn <T> __builtin_atomic_store(ptr: *T, v: T, order: MemoryOrder) {
    unsafe { kairo_rt_atomic_store(ptr as unsafe *T, v, order as i32) }
}
/// Atomically replaces `*ptr` with `v` and returns the previous value. Maps to
/// `__atomic_exchange_n`.
pub fn <T> __builtin_atomic_exchange(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_exchange(ptr as unsafe *T, v, order as i32) }
}
/// Compare-and-swap: if `*ptr == *expected`, stores `desired` and returns true; otherwise copies
/// `*ptr` into `*expected` and returns false. Maps to `__atomic_compare_exchange_n`.
///
/// \param weak  A weak exchange may fail spuriously; use it in a retry loop.
/// \param succ  The order when the exchange happens.
/// \param fail  The order of the load when it does not; it may not be `Release` or `AcqRel` nor
/// stronger than `succ`.
pub fn <T> __builtin_atomic_cas(
    ptr: *T, expected: *T, desired: T, weak: bool,
    succ: MemoryOrder, fail: MemoryOrder
) -> bool {
    unsafe {
        return kairo_rt_atomic_cas(ptr as unsafe *T, expected as unsafe *T, desired, weak,
                                   succ as i32, fail as i32)
    }
}
/// Atomically applies `+` to `*ptr` with `v` and returns the value `*ptr` had before. Maps to
/// `__atomic_fetch_add`.
pub fn <T> __builtin_atomic_fetch_add(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_add(ptr as unsafe *T, v, order as i32) }
}
/// Atomically applies `-` to `*ptr` with `v` and returns the value `*ptr` had before. Maps to
/// `__atomic_fetch_sub`.
pub fn <T> __builtin_atomic_fetch_sub(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_sub(ptr as unsafe *T, v, order as i32) }
}
/// Atomically applies `&` to `*ptr` with `v` and returns the value `*ptr` had before. Maps to
/// `__atomic_fetch_and`.
pub fn <T> __builtin_atomic_fetch_and(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_and(ptr as unsafe *T, v, order as i32) }
}
/// Atomically applies `|` to `*ptr` with `v` and returns the value `*ptr` had before. Maps to
/// `__atomic_fetch_or`.
pub fn <T> __builtin_atomic_fetch_or(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_or(ptr as unsafe *T, v, order as i32) }
}
/// Atomically applies `^` to `*ptr` with `v` and returns the value `*ptr` had before. Maps to
/// `__atomic_fetch_xor`.
pub fn <T> __builtin_atomic_fetch_xor(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_xor(ptr as unsafe *T, v, order as i32) }
}
/// Atomically applies `max` to `*ptr` with `v` and returns the value `*ptr` had before. Maps to
/// `__atomic_fetch_max`.
pub fn <T> __builtin_atomic_fetch_max(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_max(ptr as unsafe *T, v, order as i32) }
}
/// Atomically applies `min` to `*ptr` with `v` and returns the value `*ptr` had before. Maps to
/// `__atomic_fetch_min`.
pub fn <T> __builtin_atomic_fetch_min(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_min(ptr as unsafe *T, v, order as i32) }
}
/// A full memory fence with the given ordering. Maps to `__atomic_thread_fence`.
pub inline fn __builtin_atomic_fence(order: MemoryOrder) { kairo_rt_atomic_fence(order as i32) }
/// A compiler-only fence with the given ordering, against a signal handler on the same thread; it
/// emits no instruction. Maps to `__atomic_signal_fence`.
pub inline fn __builtin_atomic_signal_fence(order: MemoryOrder) { kairo_rt_atomic_signal_fence(order as i32) }
/// Returns true when atomic operations on a `T` are always lock-free. Maps to
/// `__atomic_always_lock_free(sizeof(T), 0)`.
pub eval fn <T> __builtin_atomic_is_lock_free() -> bool { return kairo_rt_atomic_is_lock_free<T>() }

// --- the target ----------------------------------------------------------------
// From clang's predefined macros for the target, and `__kairo_env_<env>__`,
// which the driver defines from the triple (nothing else tells musl from glibc).

/// The CPU architecture family of the compilation target.
pub enum TargetArch { Unknown, X86, X86_64, Arm, AArch64, RiscV32, RiscV64, Wasm32, Wasm64, PowerPC64, LoongArch64 }
/// The operating system of the compilation target; `Freestanding` when none is detected.
pub enum TargetOS   { Unknown, Linux, Windows, MacOS, IOS, FreeBSD, NetBSD, OpenBSD, Wasi, Emscripten, Android, Freestanding }
/// The ABI environment of the compilation target (libc / toolchain flavour). `Unknown` when the
/// driver did not define one for the triple.
pub enum TargetEnv  { Unknown, Gnu, Musl, Msvc, MinGW, Android, Eabi }

/// A description of the compilation target, from `__builtin_target_info()`.
pub struct TargetInfo {
    /// The architecture family.
    var arch:     TargetArch
    /// The operating system.
    var os:       TargetOS
    /// The ABI environment.
    var env:      TargetEnv
    /// The pointer width in bits.
    var ptr_bits: u32
    /// True unless the target is big-endian.
    var little_endian: bool
}

extend TargetInfo {
    /// Returns true for Linux.
    pub eval fn is_linux(const self) -> bool   { return self.os == TargetOS::Linux }
    /// Returns true for Windows.
    pub eval fn is_windows(const self) -> bool { return self.os == TargetOS::Windows }
    /// Returns true for macOS.
    pub eval fn is_macos(const self) -> bool   { return self.os == TargetOS::MacOS }
    /// Returns true for macOS or iOS.
    pub eval fn is_apple(const self) -> bool   { return (self.os == TargetOS::MacOS) || (self.os == TargetOS::IOS) }
    /// Returns true for FreeBSD, NetBSD or OpenBSD.
    pub eval fn is_bsd(const self) -> bool {
        return (self.os == TargetOS::FreeBSD) || (self.os == TargetOS::NetBSD) || (self.os == TargetOS::OpenBSD)
    }
    /// Returns true for Linux, Android, Apple and BSD targets.
    pub eval fn is_unix(const self) -> bool {
        return (self.os == TargetOS::Linux) || (self.os == TargetOS::Android) || self.is_apple() || self.is_bsd()
    }
    /// Returns true for wasm32 or wasm64.
    pub eval fn is_wasm(const self) -> bool { return (self.arch == TargetArch::Wasm32) || (self.arch == TargetArch::Wasm64) }
    /// Returns true when pointers are 64 bits wide.
    pub eval fn is_64bit(const self) -> bool { return self.ptr_bits == 64 }
    /// Returns true when the environment is musl.
    pub eval fn is_musl(const self) -> bool { return self.env == TargetEnv::Musl }
}

/// Returns a `TargetInfo` for the compilation target. Evaluated at compile time from clang's
/// predefined macros and `__kairo_env_<env>__`, which the driver defines from the triple (nothing
/// else tells musl from glibc).
pub eval fn __builtin_target_info() -> TargetInfo {
    var a = TargetArch::Unknown
    eval if defined!(__x86_64__)      { a = TargetArch::X86_64 }
    eval if defined!(__i386__)        { a = TargetArch::X86 }
    eval if defined!(__aarch64__)     { a = TargetArch::AArch64 }
    eval if defined!(__arm__)         { a = TargetArch::Arm }
    eval if defined!(__riscv) {
        eval if sizeof usize == 8 { a = TargetArch::RiscV64 } else { a = TargetArch::RiscV32 }
    }
    eval if defined!(__wasm32__)      { a = TargetArch::Wasm32 }
    eval if defined!(__wasm64__)      { a = TargetArch::Wasm64 }
    eval if defined!(__powerpc64__)   { a = TargetArch::PowerPC64 }
    eval if defined!(__loongarch64)   { a = TargetArch::LoongArch64 }

    var o = TargetOS::Freestanding
    eval if defined!(__linux__)       { o = TargetOS::Linux }
    eval if defined!(__ANDROID__)     { o = TargetOS::Android }
    eval if defined!(_WIN32)          { o = TargetOS::Windows }
    eval if defined!(__APPLE__) {
        eval if defined!(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__) { o = TargetOS::IOS } else { o = TargetOS::MacOS }
    }
    eval if defined!(__FreeBSD__)     { o = TargetOS::FreeBSD }
    eval if defined!(__NetBSD__)      { o = TargetOS::NetBSD }
    eval if defined!(__OpenBSD__)     { o = TargetOS::OpenBSD }
    eval if defined!(__wasi__)        { o = TargetOS::Wasi }
    eval if defined!(__EMSCRIPTEN__)  { o = TargetOS::Emscripten }

    var e = TargetEnv::Unknown
    eval if defined!(__kairo_env_gnu__)     { e = TargetEnv::Gnu }
    eval if defined!(__kairo_env_musl__)    { e = TargetEnv::Musl }
    eval if defined!(__kairo_env_msvc__)    { e = TargetEnv::Msvc }
    eval if defined!(__kairo_env_android__) { e = TargetEnv::Android }
    eval if defined!(__kairo_env_eabi__)    { e = TargetEnv::Eabi }
    eval if defined!(__MINGW32__)           { e = TargetEnv::MinGW }

    var le = true
    eval if defined!(__BIG_ENDIAN__) { le = false }
    return TargetInfo { arch: a, os: o, env: e, ptr_bits: (sizeof usize * 8) as u32, little_endian: le }
}
