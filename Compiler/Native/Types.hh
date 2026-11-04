/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
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

#include "KPrelude.hh"

#include <atomic>
#include <bit>
#include <chrono>
#include <condition_variable>
#include <cwchar>
#include <execution>
#include <future>
#include <memory>
#include <memory_resource>
#include <mutex>
#include <new>
#include <shared_mutex>
#include <source_location>
#include <thread>
#include <tuple>

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
#define _thread_pause() libcxx::this_thread::yield()
#define _simd_available() 0
#endif

namespace kairo {
/// `_thread_pause()` as a function: a C macro is no name a Kairo file can use.
inline void thread_pause() noexcept { _thread_pause(); }

#if !KAIRO_NATIVE_STAGE0
/// \brief Calls a C++ callable object: Stage 0's `f(args...)` on a functor.
///
/// \details An imported C++ functor (a class with operator(), such as
///          SmallFunction<64>) is not callable as `f()` from Kairo (SC062E;
///          user decision 2026-11-03, no language change). The self-host
///          migration writes `kairo::invoke(unsafe &f, args...)` instead. A
///          pointer, because passing the C++ variable itself would move it
///          (TODO(CXX-LVALUE-ARG)).
template <class F, class... Args>
decltype(auto) invoke(F *f, Args &&...args) {
    return (*f)(::std::forward<Args>(args)...);
}
#endif
}  // namespace kairo

#include <llvm/ADT/StringRef.h>

namespace kairo {
/// A string's bytes as an llvm::StringRef. The size is passed explicitly: the
/// old `.raw()` crossings relied on strlen, which stops at an embedded NUL.
/// Templated on the string (native::bytes): Stage 0 passes lib-helix's
/// string, Stage 1 the builtin one, and neither is nameable from the other
/// world. The return type is concrete on purpose: it used to be a defaulted
/// template parameter (`template <class R = llvm::StringRef>`), and Stage 1
/// cannot type a call whose return is one (the call reaches codegen unbound).
/// The forward-declaration trick that template served is moot: KLog.hh, below,
/// includes LLVM anyway.
template <class S>
inline llvm::StringRef sref(const S &s) {
    auto v = native::bytes(s);
    return llvm::StringRef(v.data(), v.size());
}

}  // namespace kairo

#include "KLog.hh"

/// One byte of a byte string (kairo `char` is `unsigned char`). Replaces the
/// old WIDE_STR, which is gone so any leftover use fails to compile.
#define KBYTE(c) static_cast<unsigned char>(c)

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

/// \brief Const lvalue reference alias (const T&) for FFI signatures.
///        Required to exactly match C++ virtual method signatures.
///
/// \invariant Parameter-position only. Never store a cref member.
template <typename T>
using cref = const T &;

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

#if !KAIRO_NATIVE_STAGE0
/// \brief `new T(args...)` / `delete p`: Stage 0's std::create / std::destroy.
///
/// \details lib-helix defines both in this namespace for Stage 0
///          (runtime/__memory/allocation.hh), so they exist only for Stage 1
///          here. The self-host migration maps std::create<T>(a) and
///          std::destroy(p) to these (Scripts/Migration/stage0_alloc.py,
///          TODO(RAW-ALLOC)) rather than to @create / @destroy, which go
///          through Kairo's allocator and hand out safe pointers: the tree
///          is raw-pointer based, and a pointer must be freed by the same
///          allocator that made it, on whichever side of the boundary.
template <typename T, typename... Args>
T *create(Args &&...args) {
    return new T(::std::forward<Args>(args)...);
}

template <typename T>
void destroy(T *ptr) {
    delete ptr;
}

/// \brief A std::string copy of a Kairo string: Stage 0's `s.std_string()`.
///
/// \details lib-helix's string had a std_string() member; Stage 1's string
///          does not. Built from the bytes and their count (native::bytes),
///          never c_str(), so an embedded NUL survives. The self-host
///          migration rewrites `x.std_string()` to this (TODO(STD-STRING):
///          Stage 1.5 drops the std::string uses).
template <class S>
::std::string to_std_string(const S &s) {
    auto v = native::bytes(s);
    return ::std::string(v.data(), v.size());
}

/// \brief std::getline through pointers: Stage 0's `getline(stream, line)`.
///
/// \details In Stage 1 a move-only C++ variable passed to a C++ call is
///          moved (Kairo has no std::move; user decision 2026-11-03), so a
///          stream handed to std::getline's `istream&` would be gone after
///          the first line. The self-host migration passes pointers here
///          instead (TODO(CXX-LVALUE-ARG)). Returns the stream's state, as
///          `if (std::getline(s, l))` reads it.
template <class Stream, class Str>
bool getline(Stream *stream, Str *line) {
    return static_cast<bool>(::std::getline(*stream, *line));
}
#endif

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

#if KAIRO_NATIVE_STAGE0
/// Stage 0 only: lib-helix's null_t is its tag, and Stage 1 code spells an
/// absent value `T?` (the self-host migration rewrites the three Nullable
/// fields to it), so there is no Stage 1 Nullable to keep in step.
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
#endif  // KAIRO_NATIVE_STAGE0

#if KAIRO_NATIVE_STAGE0
/// Stage 0 only: std::Function is lib-helix's. The F&& overload below takes
/// any callable, a Stage 1 closure included.
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
#endif  // KAIRO_NATIVE_STAGE0

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

#if KAIRO_NATIVE_STAGE0
// Stage 0 only, all three: they are written against lib-helix
// (std::to_string, std::endl, kairo::string), and each has a Stage 1 home in
// Kairo's std rather than here:
//
//   eprint / eprintln  std::io::eprint / std::io::eprintln (Lib/std/io.k),
//                      one string each; a multi-argument call becomes one
//                      f-string. eprintln(..., std::endl("")) is how Stage 0
//                      spelled "no newline": that is std::io::eprint.
//   get_exe_path       std::env::exe_path (Lib/std/env.k).
//
// The self-host migration rewrites the call sites; nothing here is kept in
// step with them.
template <typename... Args>
void eprint(Args &&...t) {
    if constexpr (sizeof...(t) == 0) {
        return;
    }
    
    ((([&]() { // fixed so now thers no more UB with large strings
           auto str = std::to_string(t);
           fwrite(str.raw(), 1, str.size(), stderr);
       }())),
     ...);

     // no newlines
}

template <typename... Args>
void eprintln(Args &&...t) {
    if constexpr (sizeof...(t) == 0) {
        fputc('\n', stderr);
        return;
    }
    
    ((([&]() { // fixed so now thers no more UB with large strings
           auto str = std::to_string(t);
           fwrite(str.raw(), 1, str.size(), stderr);
       }())),
     ...);
    
    if constexpr (sizeof...(t) > 0) {
        using LastArg =
            libcxx::tuple_element_t<sizeof...(t) - 1, tuple<Args...>>;
        if constexpr (!std::Meta::same_as<
                          std::Meta::const_volatile_removed<LastArg>,
                          std::endl>) {
            fputc('\n', stderr);
        }
    }
}

/// This binary's absolute path as UTF-8, '/'-separated on every host; ""
/// when the OS will not say. A string, not a filesystem::path: every caller
/// hands it to llvm::sys::path, which takes the bytes as they are.
inline kairo::string get_exe_path() noexcept {
#if defined(_WIN32)
    wchar_t buf[32768];
    DWORD   len = GetModuleFileNameW(nullptr, buf, 32768);
    if (len == 0 || len == 32768) {
        return {};
    }
    int n = WideCharToMultiByte(CP_UTF8, 0, buf, static_cast<int>(len), nullptr, 0, nullptr, nullptr);
    if (n <= 0) {
        return {};
    }
    libcxx::string out(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, buf, static_cast<int>(len), out.data(), n, nullptr, nullptr);
    for (auto &c : out) {
        if (c == '\\') {
            c = '/';
        }
    }
    return kairo::string(out.data(), out.size());

#elif defined(__APPLE__)
    char     buf[4096];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) {
        return {};
    }
    char real[PATH_MAX];
    if (::realpath(buf, real) == nullptr) {
        return {};
    }
    return kairo::string(real, libcxx::strlen(real));

#elif defined(__linux__)
    char buf[4096];
    auto len = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (len == -1) {
        return {};
    }
    return kairo::string(buf, static_cast<size_t>(len));

#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    char   buf[4096];
    int    mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1};
    size_t size   = sizeof(buf);
    if (sysctl(mib, 4, buf, &size, nullptr, 0) == -1) {
        return {};
    }
    return kairo::string(buf, libcxx::strlen(buf));

#else
    return {};
#endif
}

#endif  // KAIRO_NATIVE_STAGE0

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

#if KAIRO_NATIVE_STAGE0
inline string get_default_target_triple() noexcept {
    return default_target_triple_cstr();
}

inline string get_thread_model() noexcept { return thread_model_cstr(); }
#endif  // KAIRO_NATIVE_STAGE0

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
/// \details not for direct use   go through ICE_IF / ICE_FAIL (Stage 0) or
///          ice_if! / ice_fail! (Stage 1) so the message stays out of the hot
///          path (see the macros below).
///
///          stderr through C stdio, as lib-helix's eprintln did: stderr is
///          unbuffered, so the banner is out before abort(). Buffered stdout
///          is NOT flushed (abort drops it), exactly as before. Templated on
///          the message (native::bytes) so one body takes either world's
///          string, a literal or an llvm::StringRef.
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

/// \brief asserts a compiler invariant; aborts with \p msg if it does not hold.
///
/// \details NOT [[noreturn]]   this returns on the success path, which is the
///          common one. Marking it noreturn would be a promise the function
///          breaks on every passing call.
///
/// \warning prefer the ICE_IF macro. Calling this directly constructs \p msg
///          before the predicate is tested, and Stage 0 lowers every "..." to
///          string("..."), so a literal here costs a strlen + malloc + free on
///          EVERY call including the ones that pass. That cost is invisible at
///          one call per file and ruinous at one per token; it was ~115ns/token
///          in the lexer before the macro landed.
template <class S>
inline void INTERNAL_ICE(bool condition, const S &msg, const ::std::source_location location = ::std::source_location::current()) {
    if (condition) [[likely]] { return; }
    ice_abort(msg, location);
}

/// \brief unconditional internal compiler error. never returns.
/// \details for unreachable branches and invariants with no boolean form.
///          Being [[noreturn]] lets callers omit a trailing return and silences
///          "non-void function does not return a value" in switch defaults.
template <class S>
[[noreturn]] inline void INTERNAL_ICE(const S &msg, const ::std::source_location location = ::std::source_location::current()) {
    ice_abort(msg, location);
}

/// \brief the Stage 1 entry point: unconditional ICE, never returns.
/// \details a C++ macro does not cross an ffi import, so Stage 1 code cannot
///          call ICE_IF / ICE_FAIL. Its spelling is a Kairo macro over this
///          function, which keeps the message on the failing path:
///
///              macro ice_if!(cond, msg) { if cond { kairo::std::ice_fail(msg) } }
///              macro ice_fail!(msg)     { kairo::std::ice_fail(msg) }
///
///          The location is the emitted C++ call site, not the Kairo line.
template <class S>
[[noreturn]] inline void ice_fail(const S &msg, const ::std::source_location location = ::std::source_location::current()) {
    ice_abort(msg, location);
}

/// \brief guards a compiler invariant. aborts with \p msg if \p cond is true.
///
/// \details the message expression lives inside the branch body, so Stage 0's
///          string("") lowering only materializes on the failing path. The
///          success path is a compare and a predicted-not-taken branch, nothing
///          more   no allocation, no strlen, no temporary.
///
///          Deliberately NOT compiled out under NDEBUG. An INTERNAL_ICE means a compiler
///          invariant is already broken; running past it in a release build
///          emits silently wrong object code. The macro is cheap enough that
///          there is nothing to buy by removing it.
///
#define ICE_IF(cond, msg) \
    do { if (cond) [[unlikely]] { ::kairo::std::INTERNAL_ICE(msg); } } while (0)

/// \brief unconditional internal compiler error. never returns.
/// \details for unreachable branches, unimplemented paths, and invariants that
///          have no boolean form. Resolves to the [[noreturn]] overload, so it
///          satisfies the compiler in a non-void function without a dummy return.
#define ICE_FAIL(msg) \
    do { ::kairo::std::INTERNAL_ICE(msg); } while (0)
///
/// \note
/// This header may be expanded to include additional abstractions or
/// cross-platform primitives.
///

}  // namespace kairo::std

#endif  // __KAIRO_TOOLCHAIN_CORE_TYPES_HH__