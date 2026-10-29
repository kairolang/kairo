/// --- The Kairo Project -------------------- Lib/builtin/base/intrinsics.k --- ///
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
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "rt/intrinsics.h"
ffi "c"   import "rt/crash.h"

// --- language enums ---------------------------------------------------------

/// The discriminants are __ATOMIC_RELAXED .. __ATOMIC_SEQ_CST.
pub enum MemoryOrder derives i32 {
    Relaxed = 0, Consume = 1, Acquire = 2, Release = 3, AcqRel = 4, SeqCst = 5,
}

eval if defined!(__unix__) {
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

pub inline fn __builtin_copy(dst: unsafe *u8, src: unsafe *const u8, size: usize) {
    unsafe { __builtin_memcpy(dst, src, size) }
}
pub inline fn __builtin_move_mem(dst: unsafe *u8, src: unsafe *const u8, size: usize) {
    unsafe { __builtin_memmove(dst, src, size) }
}
pub inline fn __builtin_set_mem(ptr: unsafe *u8, value: byte, size: usize) {
    unsafe { __builtin_memset(ptr, value as u8, size) }
}
pub inline fn __builtin_compare_mem(a: unsafe *const u8, b: unsafe *const u8, size: usize) -> i32 {
    unsafe { return __builtin_memcmp(a, b, size) }
}

/// Placement construction: a T built from args in the storage at ptr.
pub fn <T, ...A> __builtin_construct_at(ptr: unsafe *u8, ...args: A) -> *T {
    unsafe { return kairo_rt_construct_at<T>(ptr, args...) as *T }
}
/// Runs T's destructor on *ptr, leaving the storage.
pub fn <T> __builtin_destruct_at(ptr: *T) {
    unsafe { kairo_rt_destruct_at(ptr as unsafe *T) }
}
/// `__builtin_bit_cast` is a clang keyword, so no C++ declaration can carry it.
pub fn <T, From> __builtin_bitcast(v: From) -> T {
    return kairo_rt_bit_cast<T, From>(v)
}
pub fn <T> __builtin_launder(ptr: *T) -> *T {
    unsafe { return kairo_rt_launder(ptr as unsafe *T) as *T }
}
pub inline fn __builtin_assume_aligned(ptr: unsafe *u8, align: usize) -> unsafe *u8 {
    unsafe { return kairo_rt_assume_aligned(ptr, align as u64) }
}

// --- layout -----------------------------------------------------------------

pub eval fn <T> __builtin_size_of() -> usize { return sizeof T }
pub eval fn <T> __builtin_align_of() -> usize { return alignof T }

// --- traits: shape, layout and declaration facts, expression probes --------
// C++ answers each (clang's type traits); the Kairo-only ones are module.k's.

pub eval fn <T, U> __builtin_is_same() -> bool { return kairo_rt_is_same<T, U>() }
pub eval fn <T> __builtin_is_void() -> bool { return kairo_rt_is_void<T>() }
/// True for safe and unsafe pointers alike; __builtin_is_safe_pointer tells them apart.
pub eval fn <T> __builtin_is_pointer() -> bool { return kairo_rt_is_pointer<T>() }
pub eval fn <T> __builtin_is_array() -> bool { return kairo_rt_is_array<T>() }
pub eval fn <T> __builtin_is_function() -> bool { return kairo_rt_is_function<T>() }
/// Plain enums only: an ADT enum is a C++ struct (__builtin_is_adt_enum).
pub eval fn <T> __builtin_is_enum() -> bool { return kairo_rt_is_enum<T>() }
pub eval fn <T> __builtin_is_union() -> bool { return kairo_rt_is_union<T>() }
pub eval fn <T> __builtin_is_integral() -> bool { return kairo_rt_is_integral<T>() }
pub eval fn <T> __builtin_is_floating_point() -> bool { return kairo_rt_is_floating_point<T>() }
pub eval fn <T> __builtin_is_signed() -> bool { return kairo_rt_is_signed<T>() }
pub eval fn <T> __builtin_is_unsigned() -> bool { return kairo_rt_is_unsigned<T>() }

pub eval fn <T> __builtin_is_trivially_copyable() -> bool { return kairo_rt_is_trivially_copyable<T>() }
pub eval fn <T> __builtin_is_trivially_destructible() -> bool { return kairo_rt_is_trivially_destructible<T>() }
/// One argument type: an imported template does not yet take a forwarded
/// pack, so the no-argument form is __builtin_is_trivially_default_constructible.
pub eval fn <T, A> __builtin_is_trivially_constructible() -> bool {
    return kairo_rt_is_trivially_constructible1<T, A>()
}
pub eval fn <T> __builtin_is_trivially_default_constructible() -> bool {
    return kairo_rt_is_trivially_constructible0<T>()
}
pub eval fn <T, U> __builtin_is_trivially_assignable() -> bool { return kairo_rt_is_trivially_assignable<T, U>() }
pub eval fn <T> __builtin_is_trivially_relocatable() -> bool { return kairo_rt_is_trivially_relocatable<T>() }
pub eval fn <T> __builtin_is_standard_layout() -> bool { return kairo_rt_is_standard_layout<T>() }
pub eval fn <T> __builtin_is_aggregate() -> bool { return kairo_rt_is_aggregate<T>() }
pub eval fn <T> __builtin_is_empty() -> bool { return kairo_rt_is_empty<T>() }
pub eval fn <T> __builtin_is_polymorphic() -> bool { return kairo_rt_is_polymorphic<T>() }
pub eval fn <T> __builtin_is_abstract() -> bool { return kairo_rt_is_abstract<T>() }
pub eval fn <T> __builtin_is_final() -> bool { return kairo_rt_is_final<T>() }
pub eval fn <T> __builtin_has_virtual_destructor() -> bool { return kairo_rt_has_virtual_destructor<T>() }
pub eval fn <B, D> __builtin_is_base_of() -> bool { return kairo_rt_is_base_of<B, D>() }

pub eval fn <F, T> __builtin_is_convertible() -> bool { return kairo_rt_is_convertible<F, T>() }
/// One argument type (see __builtin_is_trivially_constructible).
pub eval fn <T, A> __builtin_is_constructible() -> bool { return kairo_rt_is_constructible1<T, A>() }
pub eval fn <T> __builtin_is_default_constructible() -> bool { return kairo_rt_is_constructible0<T>() }
pub eval fn <T, U> __builtin_is_assignable() -> bool { return kairo_rt_is_assignable<T, U>() }
pub eval fn <T> __builtin_is_destructible() -> bool { return kairo_rt_is_destructible<T>() }

// --- bit operations (on the unsigned type of T's width) ---------------------
// Plain `fn`, not `eval fn`: an eval fn is C++ consteval and would refuse a
// run-time value. They are constexpr in C++, so constant arguments still fold.

/// ctz(0) is the bit width.
pub fn <T> __builtin_ctz(v: T) -> u32 { return kairo_rt_ctz(v) }
/// clz(0) is the bit width.
pub fn <T> __builtin_clz(v: T) -> u32 { return kairo_rt_clz(v) }
pub fn <T> __builtin_popcount(v: T) -> u32 { return kairo_rt_popcount(v) }
pub fn <T> __builtin_bswap(v: T) -> T { return kairo_rt_bswap(v) }
pub fn <T> __builtin_rotl(v: T, n: u32) -> T { return kairo_rt_rotl(v, n) }
pub fn <T> __builtin_rotr(v: T, n: u32) -> T { return kairo_rt_rotr(v, n) }

// --- overflow-checked arithmetic --------------------------------------------
// `result` receives the wrapped value; the return is whether it overflowed.

pub fn <T> __builtin_add_overflow(a: T, b: T, result: *T) -> bool {
    unsafe { return kairo_rt_add_overflow(a, b, result as unsafe *T) }
}
pub fn <T> __builtin_sub_overflow(a: T, b: T, result: *T) -> bool {
    unsafe { return kairo_rt_sub_overflow(a, b, result as unsafe *T) }
}
pub fn <T> __builtin_mul_overflow(a: T, b: T, result: *T) -> bool {
    unsafe { return kairo_rt_mul_overflow(a, b, result as unsafe *T) }
}

// --- codegen and optimizer hooks --------------------------------------------

pub inline fn __builtin_expect(cond: bool, expected: bool) -> bool { return kairo_rt_expect(cond, expected) }
/// Keeps the hint's direction (p >= 0.5); clang takes the exact probability
/// only as a literal.
pub inline fn __builtin_expect_prob(cond: bool, expected: bool, p: f64) -> bool {
    return kairo_rt_expect_prob(cond, expected, p)
}
pub inline fn __builtin_unreachable() -> ! { kairo_rt_unreachable() }
pub inline fn __builtin_trap() -> ! { kairo_rt_trap() }
pub inline fn __builtin_debugtrap() { kairo_rt_debugtrap() }
pub inline fn __builtin_assume(cond: bool) { kairo_rt_assume(cond) }
pub inline fn __builtin_prefetch(ptr: unsafe *const u8, rw: i32 = 0, locality: i32 = 3) {
    unsafe { kairo_rt_prefetch(ptr, rw, locality) }
}
pub inline fn __builtin_is_constant_evaluated() -> bool { return kairo_rt_is_constant_evaluated() }
pub fn <T> __builtin_constant_p(v: T) -> bool { return kairo_rt_constant_p(v) }

// --- termination -------------------------------------------------------------

/// Writes msg[0..len) and a newline to stderr, then _Exit(exit_code).
pub inline fn __builtin_crash(msg: *const u8, len: usize, exit_code: i32) -> ! {
    unsafe { kairo_rt_crash_exit(msg as unsafe *const u8, len, exit_code) }
}
/// Writes the message, then raises `signal` at its default action.
pub inline fn __builtin_signal(msg: *const u8, len: usize, signal: SIGNAL) -> ! {
    unsafe { kairo_rt_signal(msg as unsafe *const u8, len, signal as i32) }
}
pub inline fn __builtin_abort() -> ! { kairo_rt_abort() }

// --- atomics -----------------------------------------------------------------
// Pass the order as a constant: the helper is inlined and clang folds it;
// a run-time order compiles to a switch.

pub fn <T> __builtin_atomic_load(ptr: *const T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_load(ptr as unsafe *const T, order as i32) }
}
pub fn <T> __builtin_atomic_store(ptr: *T, v: T, order: MemoryOrder) {
    unsafe { kairo_rt_atomic_store(ptr as unsafe *T, v, order as i32) }
}
pub fn <T> __builtin_atomic_exchange(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_exchange(ptr as unsafe *T, v, order as i32) }
}
pub fn <T> __builtin_atomic_cas(
    ptr: *T, expected: *T, desired: T, weak: bool,
    succ: MemoryOrder, fail: MemoryOrder
) -> bool {
    unsafe {
        return kairo_rt_atomic_cas(ptr as unsafe *T, expected as unsafe *T, desired, weak,
                                   succ as i32, fail as i32)
    }
}
pub fn <T> __builtin_atomic_fetch_add(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_add(ptr as unsafe *T, v, order as i32) }
}
pub fn <T> __builtin_atomic_fetch_sub(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_sub(ptr as unsafe *T, v, order as i32) }
}
pub fn <T> __builtin_atomic_fetch_and(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_and(ptr as unsafe *T, v, order as i32) }
}
pub fn <T> __builtin_atomic_fetch_or(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_or(ptr as unsafe *T, v, order as i32) }
}
pub fn <T> __builtin_atomic_fetch_xor(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_xor(ptr as unsafe *T, v, order as i32) }
}
pub fn <T> __builtin_atomic_fetch_max(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_max(ptr as unsafe *T, v, order as i32) }
}
pub fn <T> __builtin_atomic_fetch_min(ptr: *T, v: T, order: MemoryOrder) -> T {
    unsafe { return kairo_rt_atomic_fetch_min(ptr as unsafe *T, v, order as i32) }
}
pub inline fn __builtin_atomic_fence(order: MemoryOrder) { kairo_rt_atomic_fence(order as i32) }
pub inline fn __builtin_atomic_signal_fence(order: MemoryOrder) { kairo_rt_atomic_signal_fence(order as i32) }
pub eval fn <T> __builtin_atomic_is_lock_free() -> bool { return kairo_rt_atomic_is_lock_free<T>() }

// --- the target ----------------------------------------------------------------
// From clang's predefined macros for the target, and `__kairo_env_<env>__`,
// which the driver defines from the triple (nothing else tells musl from glibc).

pub enum TargetArch { Unknown, X86, X86_64, Arm, AArch64, RiscV32, RiscV64, Wasm32, Wasm64, PowerPC64, LoongArch64 }
pub enum TargetOS   { Unknown, Linux, Windows, MacOS, IOS, FreeBSD, NetBSD, OpenBSD, Wasi, Emscripten, Android, Freestanding }
pub enum TargetEnv  { Unknown, Gnu, Musl, Msvc, MinGW, Android, Eabi }

pub struct TargetInfo {
    var arch:     TargetArch
    var os:       TargetOS
    var env:      TargetEnv
    var ptr_bits: u32
    var little_endian: bool
}

extend TargetInfo {
    pub eval fn is_linux(const self) -> bool   { return self.os == TargetOS::Linux }
    pub eval fn is_windows(const self) -> bool { return self.os == TargetOS::Windows }
    pub eval fn is_macos(const self) -> bool   { return self.os == TargetOS::MacOS }
    pub eval fn is_apple(const self) -> bool   { return (self.os == TargetOS::MacOS) || (self.os == TargetOS::IOS) }
    pub eval fn is_bsd(const self) -> bool {
        return (self.os == TargetOS::FreeBSD) || (self.os == TargetOS::NetBSD) || (self.os == TargetOS::OpenBSD)
    }
    pub eval fn is_unix(const self) -> bool {
        return (self.os == TargetOS::Linux) || (self.os == TargetOS::Android) || self.is_apple() || self.is_bsd()
    }
    pub eval fn is_wasm(const self) -> bool { return (self.arch == TargetArch::Wasm32) || (self.arch == TargetArch::Wasm64) }
    pub eval fn is_64bit(const self) -> bool { return self.ptr_bits == 64 }
    pub eval fn is_musl(const self) -> bool { return self.env == TargetEnv::Musl }
}

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
