/// --- The Kairo Project ------------------------------ Native/Types.hh --- ///
///
///   The C++ base layer under the compiler: ownership aliases, std re-exports,
///   SmallFunction, Expected, StackBuf, target queries and the ICE hook.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_TOOLCHAIN_CORE_TYPES_HH__
#define __KAIRO_TOOLCHAIN_CORE_TYPES_HH__

///
/// \file Types.hh
/// \brief Common type and function aliases for Kairo core and standard
/// interoperability.
///
/// \details
/// This header provides unified type aliases and helper functions for
/// threading, synchronization, and memory management primitives used across the
/// Kairo Compiler. It re-exports key C++ standard library types and functions
/// through the `libcxx` namespace, ensuring consistent usage of atomic
/// operations, smart pointers, and concurrency constructs throughout the
/// project.
///
/// The intent is to:
///   - Reduce namespace verbosity across the Kairo codebase.
///   - Provide a centralized alias layer for dependency control.
///   - Simplify future migration to custom runtime or allocator
///   implementations.
///
/// ### Scope
/// This file includes aliases for:
///   - **Threading primitives** (atomic, mutex, condition variable, thread)
///   - **Smart pointers** (unique_ptr, shared_ptr, weak_ptr)
///   - **Synchronization constructs** (locks, promises, futures)
///
/// \see libcxx, kairo::std, kairo::ThreadPool
///

#include "Prelude.hh"

#include <atomic>
#include <bit>
#include <chrono>
#include <condition_variable>
#include <cwchar>
#include <memory>
#include <mutex>
#include <new>
#include <shared_mutex>
#include <source_location>
#include <thread>

#if defined(_WIN32)
#include "Win32.hh"   // never <windows.h> here: see Win32.hh
#elif defined(__APPLE__)
#include <mach-o/dyld.h>
#elif defined(__linux__)
#include <unistd.h>
#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
#include <sys/sysctl.h>
#endif

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || \
    defined(_M_IX86)
#include <emmintrin.h>  // SSE2 baseline
#include <immintrin.h>  // SSE, AVX, AVX2, AVX512 intrinsics
#include <tmmintrin.h>  // SSSE3
#define _thread_pause() _mm_pause()
#define _simd_available() 1
#define _x86_64_simd
#elif defined(__aarch64__) || defined(_M_ARM64)
#include <arm_acle.h>  // __yield()
#include <arm_neon.h>  // NEON intrinsics
#define _thread_pause() __yield()
#define _simd_available() 1
#define _aarch64_simd
#elif defined(__riscv)
// The raw encoding of `pause` (a FENCE hint): the mnemonic needs Zihintpause in
// the target features, which the rv64gc baseline lacks; cores without it run it as
// a no-op fence.
#define _thread_pause() asm volatile(".4byte 0x0100000f" ::: "memory")
#define _simd_available() 0
#else
#include <thread>
#define _thread_pause() libcxx::this_thread::yield()
#define _simd_available() 0
#endif

namespace kairo {
/// `_thread_pause()` as a function: a C macro is no name a Kairo file can use.
inline void thread_pause() noexcept { _thread_pause(); }

}  // namespace kairo

#include <llvm/ADT/StringRef.h>

namespace kairo {
/// A string's bytes as an llvm::StringRef. The size is passed explicitly: a
/// strlen stops at an embedded NUL. Templated on the string (native::bytes),
/// since no Native header can name the Kairo string. The return type is
/// concrete on purpose: Kairo cannot type a call whose return is a defaulted
/// template parameter (`template <class R = llvm::StringRef>`).
template <class S>
inline llvm::StringRef sref(const S &s) {
    auto v = native::bytes(s);
    return llvm::StringRef(v.data(), v.size());
}

}  // namespace kairo

#include "Log.hh"

namespace kairo {
/// \brief Owning pointer. This object is responsible for the lifetime of the
///        pointee. Must be explicitly freed in the destructor or op delete.
///        Non-null by convention.
///
/// \invariant Must appear in op delete / destructor cleanup.
/// \invariant Must never be copied without transferring ownership.
/// \example
///   own<MacroSymbolTable> _macro_table; ///< freed in op delete
template <typename T>
using own = T *;

/// \brief Observing pointer. Non-owning reference to an object whose lifetime
///        is guaranteed by another owner. This pointer must not outlive the
///        owning object. Non-null by convention.
///
/// \invariant Must never be passed to std::destroy or freed.
/// \invariant Should be accompanied by a comment stating who owns the pointee
///            and what lifetime guarantee applies.
/// \example
///   obs<SourceManager> _sm; ///< owned by CompilerInstance, outlives this
template <typename T>
using obs = T *;

/// \brief View pointer. Non-owning pointer into the interior of a larger
///        allocation owned elsewhere. Distinct from obs<T> which points to
///        a complete object view<T> points into the middle of a buffer,
///        array, or arena-allocated slab. The pointed-to memory is valid only
///        as long as the containing allocation is alive.
///
/// \invariant Must never be passed to std::destroy or freed.
/// \invariant Must never be used to access before the view start or after
///            the view end bounds are the caller's responsibility.
/// \invariant Should be accompanied by a comment stating what allocation
///            backs this view and who owns it.
/// \example
///   view<Token> _body; ///< slice into TokenBuffer owned by TCM
template <typename T>
using view = T *;

///
/// \class SmallFunction
/// \brief Fixed-capacity callable wrapper for small, move-only lambdas.
///
/// \tparam InlineSize Size in bytes of the inline storage buffer (default: 64).
///
/// \details
/// The `SmallFunction` class provides a minimal type-erased wrapper around
///     small callable objects such as lambdas, functors, or stateless function
///     objects that fit within an inline buffer of size `InlineSize`.
///
/// Unlike `std::function`, this class:
///     - Avoids heap allocation entirely for supported callables.
///     - Requires that the stored callable fits in the static buffer.
///     - Is move-only, ensuring safe ownership transfer in concurrent contexts.
///
/// ### Internal Layout
/// Each instance contains:
///     - An aligned inline buffer (`_storage`) where the callable is
///       constructed in place.
///     - Function pointers `_call` and `_destroy` used for type-erased
///       invocation and cleanup.
///
/// ### Performance Characteristics
///     - **O(1)** construction, move, destruction, and invocation.
///     - No virtual dispatch or RTTI.
///     - No dynamic memory allocation.
///     - Cache-friendly and trivially relocatable.
///
/// \warning
///     - Not copyable (move-only).
///     - The callable must fit within `InlineSize` bytes; otherwise, a static
///       assertion fails.
///     - Undefined behavior if invoked after move-from or reset.
///
/// \example
/// ```cpp
/// kairo::SmallFunction<> f = [] { printf("Hello"); };
/// f(); // prints "Hello"
/// ```
///
/// \see ThreadPool, std::function
///
template <size_t InlineSize = 64>
class SmallFunction {
  private:
    /// Forward declaration of internal storage struct.
    struct Storage;

    /// Type-erased function pointer types for call and destructor.
    using CallFn = void (*)(const void *);
    using DtorFn = void (*)(void *);

    Storage _storage{};          ///< Inline storage for callable.
    CallFn  _call    = nullptr;  ///< Type-erased call function.
    DtorFn  _destroy = nullptr;  ///< Type-erased destructor function.

    ///
    /// \struct Storage
    /// \brief Internal aligned storage buffer for callable placement.
    ///
    /// \details
    /// Provides statically allocated space for storing callable
    ///     objects of up to `InlineSize` bytes.
    ///     Aligned to `max_align_t` for safety across platforms.
    ///
    struct Storage {
        alignas(libcxx::max_align_t) libcxx::byte data[InlineSize];
    };

    ///
    /// \brief Constructs a callable in the internal buffer.
    ///
    /// \tparam F Type of the callable.
    /// \param f Callable instance to store.
    ///
    /// \details
    ///     Performs placement-new into `_storage.data` and sets up
    ///     function pointers for later invocation and destruction.
    ///
    template <typename F>
    void emplace(F &&f);

    ///
    /// \brief Transfers ownership of callable data from another instance.
    ///
    /// \param other Source `SmallFunction` to move from.
    ///
    /// \details
    /// Copies raw storage memory, moves function pointers, and clears
    ///     the source. The move is shallow, as callable contents are already
    ///     inline.
    ///
    void move_from(SmallFunction &&other) noexcept;

  public:
    ///
    /// \brief Default constructor (creates an empty callable).
    ///
    /// \details
    /// Initializes an empty `SmallFunction` with no stored callable.
    ///     Invocation of an empty function is a no-op.
    ///
    SmallFunction() noexcept = default;

    ///
    /// \brief Destructor.
    ///
    /// \details
    /// Destroys any stored callable if one exists, invoking its destructor
    ///     using the `_destroy` function pointer.
    ///     After destruction, both `_call` and `_destroy` are reset to null.
    ///
    ~SmallFunction();

    ///
    /// \brief Constructs a `SmallFunction` from any callable object.
    ///
    /// \tparam F Type of the callable (deduced automatically).
    /// \param f Callable object to store.
    ///
    /// \details
    /// Constructs the callable in-place within the inline buffer and
    ///     generates lightweight, type-erased function pointers for invocation
    ///     and destruction.
    ///
    /// \warning
    /// If `sizeof(F)` exceeds `InlineSize`, compilation fails.
    ///
    template <typename F>
    SmallFunction(F &&f);

    ///
    /// \brief Move constructor.
    ///
    /// \param other Source `SmallFunction` to move from.
    ///
    /// \details
    /// Transfers ownership of the callable and metadata from another
    ///     `SmallFunction`, resetting the source to an empty state.
    ///
    SmallFunction(SmallFunction &&other) noexcept;

    ///
    /// \brief Move assignment operator.
    ///
    /// \param other Source `SmallFunction` to move from.
    /// \return Reference to `*this`.
    ///
    /// \details
    /// Clears the current callable (if any) and transfers ownership
    ///     from another `SmallFunction`.
    ///
    SmallFunction &operator=(SmallFunction &&other) noexcept;

    ///
    /// \brief Copy operations are deleted.
    ///
    /// \details
    /// Copying `SmallFunction` would require duplicating opaque callable
    ///     state, which is unsafe without dynamic type reconstruction.
    ///
    SmallFunction(const SmallFunction &)            = delete;
    SmallFunction &operator=(const SmallFunction &) = delete;

    ///
    /// \brief Invokes the stored callable if one exists.
    ///
    /// \details
    /// Performs a direct type-erased call through `_call`.
    /// If no callable is present, the function returns silently.
    ///
    /// \note Invocation is noexcept if the stored callable is noexcept.
    ///
    void operator()() const;

    ///
    /// \brief Resets and destroys the stored callable.
    ///
    /// \details
    /// Calls the stored destructor function (if any) and clears both
    ///     function pointers. After `reset()`, the instance becomes empty and
    ///     safe to reuse.
    ///
    void reset() noexcept;

    ///
    /// \brief Checks whether a callable is stored.
    ///
    /// \return `true` if callable exists, `false` otherwise.
    ///
    [[nodiscard]] bool valid() const noexcept;
};
}  // namespace kairo

namespace kairo::std {
///
/// \brief Byte type alias for low-level memory operations.
/// \see libcxx::byte
///
using Byte = libcxx::byte;

///
/// \brief Atomic type alias for thread-safe integral or pointer operations.
///
/// \tparam T Underlying value type.
///
/// \see libcxx::atomic
///
template <typename T>
using Atomic = libcxx::atomic<T>;

///
/// \brief Alias for memory ordering enumeration used with atomic operations.
///
/// \see libcxx::memory_order
///
using MemoryOrder = libcxx::memory_order;

///
/// \brief Thread management class alias.
///
/// \detail
/// Represents a single thread of execution, mirroring `std::thread`
/// semantics via the Kairo `libcxx` backend.
///
/// \see libcxx::thread
///
using Thread = libcxx::thread;

///
/// \brief Alias for mutual exclusion primitive.
///
/// \see libcxx::mutex
///
using Mutex = libcxx::mutex;

///
/// \brief Alias for a mutex the owning thread may re-lock.
///
/// \see libcxx::recursive_mutex
///
using RecursiveMutex = libcxx::recursive_mutex;

///
/// \brief Alias for shared mutex
///
/// \see libcxx::shared_mutex
///
using SharedMutex = libcxx::shared_mutex;

///
/// \brief Alias for unique locking mechanism providing scoped ownership.
///
/// \see libcxx::unique_lock
///
template <typename M>
using UniqueLock = libcxx::unique_lock<M>;

///
/// \brief Alias for shared locking mechanism allowing multiple concurrent
/// readers.
///
/// \see libcxx::shared_lock
///
template <typename M>
using SharedLock = libcxx::shared_lock<M>;

///
/// \brief Alias for RAII-style lock guard.
///
/// \see libcxx::lock_guard
///
template <typename M>
using LockGuard = libcxx::lock_guard<M>;

/// \brief `new T(args...)` / `delete p`, for the compiler's raw pointers.
///
/// \details Not @create / @destroy, which go through Kairo's allocator and
///          hand out safe pointers: the tree is raw-pointer based, and a
///          pointer must be freed by the same allocator that made it, on
///          whichever side of the boundary.
template <typename T, typename... Args>
T *create(Args &&...args) {
    return new T(::std::forward<Args>(args)...);
}

template <typename T>
void destroy(T *ptr) {
    delete ptr;
}

/// \brief A std::string copy of a Kairo string.
///
/// \details Built from the bytes and their count (native::bytes), never
///          c_str(), so an embedded NUL survives.
template <class S>
::std::string to_std_string(const S &s) {
    auto v = native::bytes(s);
    return ::std::string(v.data(), v.size());
}

/// \brief A Kairo string copied from a std::string (the reverse of to_std_string).
///
/// \details S is the Kairo string type, passed by the caller as
///          `from_std_string<string>(x)`: no Native header can name the Kairo
///          builtin string. Copies the bytes and their count, so an embedded NUL
///          survives. The Kairo string has no implicit C++ converting
///          constructor, so `string(std_string)` is written through this.
template <class S>
S from_std_string(const ::std::string &s) {
    return S(reinterpret_cast<const unsigned char *>(s.data()), static_cast<::std::size_t>(s.size()));
}

///
/// \brief Alias for const-qualified pointer type.
///
/// \tparam T Underlying pointer type.
///
template <typename T>
using ConstPtr = const T *;

///
/// \brief Restrict qualifier macro for pointer optimization.
///
#if defined(__GNUC__) || defined(__clang__)
#define __RESTRICT__ __restrict__
#elif defined(_MSC_VER)
#define __RESTRICT__ __restrict
#else
#define __RESTRICT__
#endif

///
/// \brief Alias for restrict-qualified pointer type.
///
/// \tparam T Underlying pointer type.
/// \see __RESTRICT__
///
template <typename T>
using restrict_ptr = T *__RESTRICT__;

template <typename T, typename E>
class Expected {
    union {
        T value;
        E error;
    };
    bool has_value;

  public:
    /// An error state holding a value-initialized E: the destructor destroys
    /// whichever member `has_value` names, so one of them is always alive.
    constexpr Expected()
        : error()
        , has_value(false) {}

    constexpr Expected(const T &val)
        : value(val)
        , has_value(true) {}

    constexpr Expected(T &&val)
        : value(libcxx::move(val))
        , has_value(true) {}

    constexpr Expected(const E &err)
        : error(err)
        , has_value(false) {}

    constexpr Expected(E &&err)
        : error(libcxx::move(err))
        , has_value(false) {}

    constexpr Expected(const Expected &other)
        : has_value(other.has_value) {
        if (has_value) {
            libcxx::construct_at(&value, other.value);
        } else {
            libcxx::construct_at(&error, other.error);
        }
    }

    constexpr Expected(Expected &&other) noexcept
        : has_value(other.has_value) {
        if (has_value) {
            libcxx::construct_at(&value, libcxx::move(other.value));
        } else {
            libcxx::construct_at(&error, libcxx::move(other.error));
        }
    }

    constexpr ~Expected() {
        if (has_value) {
            libcxx::destroy_at(&value);
        } else {
            libcxx::destroy_at(&error);
        }
    }

    constexpr Expected &operator=(const Expected &other) {
        if (this != &other) {
            this->~Expected();
            libcxx::construct_at(this, other);
        }
        return *this;
    }

    constexpr Expected &operator=(Expected &&other) noexcept {
        if (this != &other) {
            this->~Expected();
            libcxx::construct_at(this, libcxx::move(other));
        }
        return *this;
    }

    constexpr explicit operator bool() const { return has_value; }
    constexpr bool     check() const { return has_value; }

    constexpr T       &operator*()       &{ return value; }
    constexpr const T &operator*() const & { return value; }
    constexpr T      &&operator*()      &&{ return libcxx::move(value); }

    constexpr T       *operator->() { return &value; }
    constexpr const T *operator->() const { return &value; }

    constexpr E       &err()       &{ return error; }
    constexpr const E &err() const & { return error; }
    constexpr E      &&err()      &&{ return libcxx::move(error); }

    constexpr T &value_or(T &default_value) & {
        return has_value ? value : default_value;
    }

    constexpr T value_or(T &&default_value) && {
        return has_value ? libcxx::move(value) : libcxx::move(default_value);
    }

    constexpr T value_or(const T &default_value) const & {
        return has_value ? value : default_value;
    }

    constexpr T value_or(T &&default_value) const & {
        return has_value ? value : libcxx::move(default_value);
    }

    constexpr E err_or(E &default_error) & {
        return has_value ? default_error : error;
    }

    constexpr E err_or(E &&default_error) && {
        return has_value ? libcxx::move(default_error) : libcxx::move(error);
    }

    constexpr E err_or(const E &default_error) const & {
        return has_value ? default_error : error;
    }

    constexpr E err_or(E &&default_error) const & {
        return has_value ? default_error : libcxx::move(error);
    }
};

template <typename F>
inline void
sleep_while(F &&condition)  // NOLINT(cppcoreguidelines-missing-std-forward)
    requires(libcxx::is_invocable_r_v<bool, libcxx::decay_t<F>>)
{
    for (u16 i = 0; i < 1000 && condition(); ++i) {
        _thread_pause();
    }
    if (!condition()) {
        return;
    }

    for (u16 i = 0; i < 64 && condition(); ++i) {
        libcxx::this_thread::yield();
    }
    if (!condition()) {
        return;
    }

    for (u16 i = 0; i < 256 && condition(); ++i) {
        libcxx::this_thread::sleep_for(libcxx::chrono::microseconds(1));
    }
    if (!condition()) {
        return;
    }

    while (condition()) {
        libcxx::this_thread::sleep_for(libcxx::chrono::microseconds(100));
    }
}

/// The triple this compiler targets when none is given: the host's arch and
/// OS, with the vendor and environment Kairo ships for it. Compiler policy,
/// not a host query, which is why it stays here rather than in std::env.
/// A C string so both worlds can wrap it in their own string type.
inline const char *default_target_triple_cstr() noexcept {
#if defined(__aarch64__) || defined(_M_ARM64)
#if defined(__APPLE__)
    return "aarch64-apple-macosx11.0.0";
#elif defined(__linux__)
    return "aarch64-unknown-linux-musl";
#elif defined(_WIN32)
    return "aarch64-pc-windows-gnu";
#else
    return "aarch64-unknown-unknown";
#endif
#elif defined(__x86_64__) || defined(_M_X64)
#if defined(__APPLE__)
    return "x86_64-apple-macosx10.15.0";
#elif defined(__linux__)
    return "x86_64-unknown-linux-musl";
#elif defined(_WIN32)
    return "x86_64-pc-windows-gnu";
#else
    return "x86_64-unknown-unknown";
#endif
#elif defined(__riscv)
#if defined(__riscv_xlen) && (__riscv_xlen == 64)
    return "riscv64-unknown-linux-musl";
#else
    return "riscv32-unknown-linux-musl";
#endif
#elif defined(__wasm32__)
    return "wasm32-unknown-unknown";
#elif defined(__wasm64__)
    return "wasm64-unknown-unknown";
#else
    return "unknown-unknown-unknown";
#endif
}

inline const char *thread_model_cstr() noexcept {
#if defined(_WIN32)
    return "win32";
#elif defined(__wasm32__) || defined(__wasm64__)
    return "single";
#else
    return "posix";
#endif
}

/// The allocator has no memory for \p bytes. There is no carrying on, and it
/// is not a compiler bug to report: one line on stderr, then abort. For the
/// allocations in this folder whose result is used unchecked on a hot path.
[[noreturn]] inline void out_of_memory(size_t bytes) noexcept {
    ::std::fprintf(stderr, "error: out of memory (allocating %zu bytes)\n", bytes);
    ::std::fflush(stderr);
    ::std::abort();
}

/// StackBuf<T, N> inline scratch buffer for parser hot paths.
/// Trivially destructible T only. No copy, no move. Stack-local only.
template <typename T, unsigned N>
class StackBuf {
    static_assert(N > 0);
    static_assert(libcxx::is_trivially_destructible_v<T>);

    alignas(T) unsigned char inline_buf[sizeof(T) * N]{};
    T       *_data = reinterpret_cast<T *>(inline_buf);
    uint32_t _size = 0;
    uint32_t _cap  = N;

    [[nodiscard]] bool _is_inline() const {
        return _data == reinterpret_cast<const T *>(inline_buf);
    }

    void _grow() {
        uint32_t new_cap = _cap * 2;
        T       *buf     = static_cast<T *>(malloc(sizeof(T) * new_cap));
        if (buf == nullptr) [[unlikely]] {
            out_of_memory(sizeof(T) * new_cap);
        }
        libcxx::memcpy(buf, _data, sizeof(T) * _size);
        if (!_is_inline()) {
            libcxx::free(_data);
        }
        _data = buf;
        _cap  = new_cap;
    }

  public:
    StackBuf() = default;
    ~StackBuf() {
        if (!_is_inline()) {
            libcxx::free(_data);
        }
    }

    StackBuf(const StackBuf &)            = delete;
    StackBuf &operator=(const StackBuf &) = delete;
    StackBuf(StackBuf &&)                 = delete;
    StackBuf &operator=(StackBuf &&)      = delete;

    void push_back(T val) {
        if (__builtin_expect(static_cast<long>(_size == _cap), 0) != 0) {
            _grow();
        }
        _data[_size++] = val;
    }

    
    T                     *data() const     { return const_cast<T *>(_data); }
    [[nodiscard]] uint32_t size() const     { return _size; }
    [[nodiscard]] bool     is_empty() const { return _size == 0; }
    void                   clear()          { _size = 0; }

    T       &operator[](uint32_t i)       { return _data[i]; }
    const T &operator[](uint32_t i) const { return _data[i]; }
};

/// \brief prints the ICE banner and aborts. shared by every entry point.
/// \details not for direct use: go through ice_fail (the Kairo ice_if! /
///          ice_fail! macros) so the message stays out of the hot path.
///
///          stderr through C stdio: stderr is unbuffered, so the banner is
///          out before abort(). Buffered stdout is NOT flushed (abort drops
///          it). Templated on the message (native::bytes) so one body takes
///          a Kairo string, a literal or an llvm::StringRef.
/// \brief what runs before an ICE aborts: the driver's flush of every
///        diagnostic still buffered (per-TU sinks and the engine's console
///        consumer), in the configured format.
/// \details abort() skips the end-of-run flush, so without it a crashed run
///          printed the ICE banner and nothing else -- not even the ordinary
///          errors reported before it, which are usually what explains it.
///          One slot, set by CompilerInstance::execute for its run; taken
///          (exchanged out) before it is called, so an ICE inside the flush
///          aborts plainly instead of recursing.
using ice_flush_fn = void (*)(void *);
struct IceFlushHook {
    ::std::atomic<ice_flush_fn> fn{nullptr};
    ::std::atomic<void *>       ctx{nullptr};
};
inline IceFlushHook &ice_flush_hook() {
    static IceFlushHook h;
    return h;
}
/// Registers \p f, called with \p ctx before an ICE aborts; null clears it.
inline void set_ice_flush_hook(ice_flush_fn f, void *ctx) {
    ice_flush_hook().ctx.store(ctx);
    ice_flush_hook().fn.store(f);
}
/// Clears the hook; Kairo has no null function value to pass to set_ice_flush_hook.
inline void clear_ice_flush_hook() {
    ice_flush_hook().fn.store(nullptr);
    ice_flush_hook().ctx.store(nullptr);
}

template <class S>
[[noreturn]] inline void ice_abort(const S &msg, const ::std::source_location &location) {
    if (ice_flush_fn f = ice_flush_hook().fn.exchange(nullptr)) { f(ice_flush_hook().ctx.load()); }
    native::write_bytes(stderr, "Kairo Internal Compiler Error: ");
    native::write_bytes(stderr, native::bytes(msg));
    native::write_bytes(stderr, "\nThis is a bug in the Kairo compiler.\nLocation: ");
    native::write_bytes(stderr, location.file_name());
    ::std::fprintf(stderr, ":%u:%u\n", static_cast<unsigned>(location.line()),
                   static_cast<unsigned>(location.column()));
    native::write_bytes(stderr,
                        "Please report it: https://github.com/kairolang/kairo/issues, with the "
                        "generated log files and a minimal reproduction if possible.\n");
    ::std::abort();
}

/// \brief unconditional internal compiler error, never returns.
/// \details a C++ macro does not cross an ffi import, so the guard is a Kairo
///          macro over this function, which keeps the message on the failing
///          path:
///
///              macro ice_if!(cond, msg) { if cond { kairo::std::ice_fail(msg) } }
///              macro ice_fail!(msg)     { kairo::std::ice_fail(msg) }
///
///          The location is the emitted C++ call site, not the Kairo line.
template <class S>
[[noreturn]] inline void ice_fail(const S &msg, const ::std::source_location location = ::std::source_location::current()) {
    ice_abort(msg, location);
}

}  // namespace kairo::std

#endif  // __KAIRO_TOOLCHAIN_CORE_TYPES_HH__