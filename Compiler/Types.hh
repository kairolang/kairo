///--- The Kairo Project ----------------------------------------------------///
///                                                                          ///
///   Part of the Kairo Project, under the Attribution 4.0 International     ///
///   license (CC BY 4.0).  You are allowed to use, modify, redistribute,    ///
///   and create derivative works, even for commercial purposes, provided    ///
///   that you give appropriate credit, and indicate if changes were made.   ///
///                                                                          ///
///   For more information on the license terms and requirements, please     ///
///     visit: https://creativecommons.org/licenses/by/4.0/                  ///
///                                                                          ///
///   SPDX-License-Identifier: CC-BY-4.0                                     ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                       ///
///                                                                          ///
///------------------------------------------------------------ KAIRO -------///

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
/// \note
/// Part of the Kairo Project under the Attribution 4.0 International License
/// (CC BY 4.0). Redistribution and modification are permitted with attribution.
///
/// \see libcxx, kairo::std, kairo::ThreadPool
///

#include <bit>
#include <cwchar>
#include <execution>
#include <include/core.hh>
#include <memory>
#include <memory_resource>
#include <mutex>
#include <new>

#if defined(_WIN32)
#include <windows.h>
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
#define _thread_pause() asm volatile("pause" ::: "memory")
#define _simd_available() 0
#else
#include <thread>
#define _thread_pause() ::std::this_thread::yield()
#define _simd_available() 0
#endif

#include "KLog.hh"

namespace kairo {
/// \brief Owning pointer. This object is responsible for the lifetime of the
///        pointee. Must be explicitly freed in the destructor or op delete.
///        Non-null by convention if the pointee may be absent, use Oot<T>.
///
/// \invariant Must appear in op delete / destructor cleanup.
/// \invariant Must never be copied without transferring ownership.
/// \example
///   own<MacroSymbolTable> _macro_table; ///< freed in op delete
template <typename T>
using own = T *;

template <typename T>
using const_own = const T *;

template <typename T>
using volatile_own = volatile T *;

/// \brief Observing pointer. Non-owning reference to an object whose lifetime
///        is guaranteed by another owner. This pointer must not outlive the
///        owning object. Non-null by convention if the pointee may be absent,
///        use opt<T>.
///
/// \invariant Must never be passed to std::destroy or freed.
/// \invariant Should be accompanied by a comment stating who owns the pointee
///            and what lifetime guarantee applies.
/// \example
///   obs<SourceManager> _sm; ///< owned by CompilerInstance, outlives this
template <typename T>
using obs = T *;

template <typename T>
using const_obs = const T *;

template <typename T>
using volatile_obs = volatile T *;

/// \brief Optional observing pointer. Non-owning reference that may be null.
///        Used when the pointee is either absent or conditionally available.
///        Callers must null-check before dereferencing.
///
/// \invariant Must never be passed to std::destroy or freed.
/// \invariant Must be null-checked at every dereference site.
/// \example
///   opt<DiagEngine> _diag; ///< null until initialize() is called
template <typename T>
using opt = T *;

template <typename T>
using const_opt = const T *;

template <typename T>
using volatile_opt = volatile T *;

/// \brief Optional owning pointer. Owns the pointee if non-null. Responsible
///        for freeing it in the destructor. Used when the owned object is
///        lazily initialized or conditionally present.
///
/// \invariant Must be freed in op delete if non-null: if (_p) std::destroy(_p)
/// \invariant Must be null-checked before dereferencing.
/// \invariant Must never be copied without transferring ownership.
/// \example
///   oot<ImmediateTable> _imm; ///< null until initialize() called, owned
template <typename T>
using oot = T *;

template <typename T>
using const_oot = const T *;

template <typename T>
using volatile_oot = volatile T *;

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

template <typename T>
using const_view = const T *;

template <typename T>
using volatile_view = volatile T *;

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

///
/// \brief Alias for condition variable used in thread synchronization.
///
/// \see libcxx::condition_variable
///
using ConditionVariable = libcxx::condition_variable;

///
/// \brief Alias for `std::once_flag`, used for one-time initialization.
///
/// \see libcxx::once_flag
///
using OnceFlag = libcxx::once_flag;

///
/// \brief Alias for future representing an asynchronous computation result.
///
/// \see libcxx::future
///
using Future = libcxx::future<void>;

///
/// \brief Alias for promise associated with an asynchronous operation.
///
/// \see libcxx::promise
///
using Promise = libcxx::promise<void>;

///
/// \brief Alias for unique ownership smart pointer.
///
/// \tparam T Managed object type.
///
/// \see libcxx::unique_ptr
///
template <typename T>
using UniquePtr = libcxx::unique_ptr<T>;

///
/// \brief Alias for shared ownership smart pointer.
///
/// \tparam T Managed object type.
///
/// \see libcxx::shared_ptr
///
template <typename T>
using SharedPtr = libcxx::shared_ptr<T>;

///
/// \brief Alias for weak reference to a shared object.
///
/// \tparam T Managed object type.
///
/// \see libcxx::weak_ptr
///
template <typename T>
using WeakPtr = libcxx::weak_ptr<T>;

///
/// \brief Constructs a shared pointer using perfect forwarding.
///
/// \tparam T Object type to construct.
/// \tparam Args Argument types for constructor.
/// \param args Arguments forwarded to the constructor of `T`.
/// \return A new `SharedPtr<T>` managing the allocated object.
///
/// \detail
/// Wrapper around `libcxx::make_shared`, ensuring consistency within
/// Kairo's type system and avoiding direct dependency on `std`.
///
template <typename T, typename... Args>
constexpr SharedPtr<T> create_shared(Args &&...args) {
    return libcxx::make_shared<T>(libcxx::forward<Args>(args)...);
}

///
/// \brief Constructs a unique pointer using perfect forwarding.
///
/// \tparam T Object type to construct.
/// \tparam Args Argument types for constructor.
/// \param args Arguments forwarded to the constructor of `T`.
/// \return A new `UniquePtr<T>` managing the allocated object.
///
/// \see make_shared
///
template <typename T, typename... Args>
constexpr UniquePtr<T> create_unique(Args &&...args) {
    return libcxx::make_unique<T>(libcxx::forward<Args>(args)...);
}

///
/// \brief Null pointer type alias for uniformity.
///
using nullptr_t = decltype(nullptr);

///
/// \brief Alias for const-qualified pointer type.
///
/// \tparam T Underlying pointer type.
///
template <typename T>
using ConstPtr = const T *;

///
/// \brief Alias for volatile-qualified pointer type.
///
/// \tparam T Underlying pointer type.
///
template <typename T>
using VolatilePtr = volatile T *;

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
    constexpr Expected()
        : has_value(false) {}

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

template <typename T>
class Expected<T, std::null_t> {
    union {
        T    value;
        char dummy;
    };
    bool has_value;

  public:
    constexpr Expected()
        : dummy{}
        , has_value(false) {}

    constexpr Expected(std::null_t)
        : dummy{}
        , has_value(false) {}

    constexpr Expected(const T &val)
        : value(val)
        , has_value(true) {}

    constexpr Expected(T &&val)
        : value(libcxx::move(val))
        , has_value(true) {}

    constexpr Expected(const Expected &other)
        : dummy{}
        , has_value(other.has_value) {
        if (has_value) {
            libcxx::construct_at(&value, other.value);
        }
    }

    constexpr Expected(Expected &&other) noexcept
        : dummy{}
        , has_value(other.has_value) {
        if (has_value) {
            libcxx::construct_at(&value, libcxx::move(other.value));
        }
    }

    constexpr ~Expected() {
        if (has_value) {
            libcxx::destroy_at(&value);
        }
    }

    constexpr Expected &operator=(const Expected &other) {
        if (this != &other) {
            this->~Expected();
            has_value = other.has_value;
            if (has_value) {
                libcxx::construct_at(&value, other.value);
            }
        }
        return *this;
    }

    constexpr Expected &operator=(Expected &&other) noexcept {
        if (this != &other) {
            this->~Expected();
            has_value = other.has_value;
            if (has_value) {
                libcxx::construct_at(&value, libcxx::move(other.value));
            }
        }
        return *this;
    }

    constexpr Expected &operator=(std::null_t) {
        this->~Expected();
        has_value = false;
        return *this;
    }

    constexpr explicit operator bool() const { return has_value; }
    constexpr bool     check() const { return has_value; }

    constexpr T       &operator*()       &{ return value; }
    constexpr const T &operator*() const & { return value; }
    constexpr T      &&operator*()      &&{ return libcxx::move(value); }

    constexpr T       *operator->() { return &value; }
    constexpr const T *operator->() const { return &value; }

    // No err() methods - there's no error to return

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
};

template <typename T>
using Nullable = Expected<T, std::null_t>;

template <typename Rt, typename... Tp>
inline void sleep_while(std::Function<Rt, Tp...> condition) {
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

template <typename... Args>
void eprint(Args &&...t) {
    if constexpr (sizeof...(t) == 0) {
        fwprintf(stderr, L"\n");
        return;
    }
    
    ((([&]() { // fixed so now thers no more UB with large strings
           auto str = std::to_string(t);
           fwprintf(stderr, L"%ls", str.raw());
       }())),
     ...);
    
    if constexpr (sizeof...(t) > 0) {
        using LastArg =
            libcxx::tuple_element_t<sizeof...(t) - 1, tuple<Args...>>;
        if constexpr (!std::Meta::same_as<
                          std::Meta::const_volatile_removed<LastArg>,
                          std::endl>) {
            fwprintf(stderr, L"\n");
        }
    }
}

inline libcxx::filesystem::path get_exe_path() noexcept {
#if defined(_WIN32)
    wchar_t buf[32768];
    DWORD   len = GetModuleFileNameW(nullptr, buf, 32768);
    if (len == 0 || len == 32768) {
        return {};
    }
    return libcxx::filesystem::path(buf);

#elif defined(__APPLE__)
    char     buf[4096];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) {
        return {};
    }
    return libcxx::filesystem::canonical(buf);

#elif defined(__linux__)
    char buf[4096];
    auto len = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (len == -1) {
        return {};
    }
    buf[len] = '\0';
    return libcxx::filesystem::path(buf);

#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    char   buf[4096];
    int    mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1};
    size_t size   = sizeof(buf);
    if (sysctl(mib, 4, buf, &size, nullptr, 0) == -1) {
        return {};
    }
    return libcxx::filesystem::path(buf);

#else
    return {};
#endif
}

inline string get_default_target_triple() noexcept {
#if defined(__aarch64__) || defined(_M_ARM64)
#if defined(__APPLE__)
    return L"aarch64-apple-macosx11.0.0";
#elif defined(__linux__)
    return L"aarch64-unknown-linux-gnu";
#elif defined(_WIN32)
    return L"aarch64-pc-windows-msvc";
#else
    return L"aarch64-unknown-unknown";
#endif
#elif defined(__x86_64__) || defined(_M_X64)
#if defined(__APPLE__)
    return L"x86_64-apple-macosx10.15.0";
#elif defined(__linux__)
    return L"x86_64-unknown-linux-gnu";
#elif defined(_WIN32)
    return L"x86_64-pc-windows-msvc";
#else
    return L"x86_64-unknown-unknown";
#endif
#elif defined(__riscv)
#if defined(__riscv_xlen) && (__riscv_xlen == 64)
    return L"riscv64-unknown-linux-gnu";
#else
    return L"riscv32-unknown-linux-gnu";
#endif
#elif defined(__wasm32__)
    return L"wasm32-unknown-unknown";
#elif defined(__wasm64__)
    return L"wasm64-unknown-unknown";
#else
    return L"unknown-unknown-unknown";
#endif
}

inline string get_thread_model() noexcept {
#if defined(_WIN32)
    return L"win32";
#elif defined(__wasm32__) || defined(__wasm64__)
    return L"single";
#else
    return L"posix";
#endif
}

///
/// \note
/// This header may be expanded to include additional abstractions or
/// cross-platform primitives.
///

}  // namespace kairo::std

#endif  // __KAIRO_TOOLCHAIN_CORE_TYPES_HH__