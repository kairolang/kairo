///--- The Helix Project ----------------------------------------------------///
///                                                                          ///
///   Part of the Helix Project, under the Attribution 4.0 International     ///
///   license (CC BY 4.0).  You are allowed to use, modify, redistribute,    ///
///   and create derivative works, even for commercial purposes, provided    ///
///   that you give appropriate credit, and indicate if changes were made.   ///
///                                                                          ///
///   For more information on the license terms and requirements, please     ///
///     visit: https://creativecommons.org/licenses/by/4.0/                  ///
///                                                                          ///
///   SPDX-License-Identifier: CC-BY-4.0                                     ///
///   Copyright (c) 2024 The Helix Project (CC BY 4.0)                       ///
///                                                                          ///
///------------------------------------------------------------ HELIX -------///

#ifndef __HELIX_TOOLCHAIN_CORE_SMALLFUNCTION_HH__
#   define __HELIX_TOOLCHAIN_CORE_SMALLFUNCTION_HH__

///
/// \file Core/SmallFunction.hh
/// \brief Inline small callable wrapper with zero dynamic allocations.
///
/// \details
/// This header defines `helix::SmallFunction`, a lightweight, type-erased
/// callable container designed to store and invoke small function objects
/// without heap allocation. It provides deterministic performance, no heap
/// fragmentation, and lock-free invocation semantics.
///
/// The implementation behaves similarly to `std::function`, but:
///   - Stores the callable **inline** in a fixed-size buffer (`InlineSize`).
///   - Does **not** allocate dynamically.
///   - Is **move-only** (no copies).
///   - Erases type information at compile-time with minimal overhead.
///
/// This design is especially suitable for real-time job systems, thread pools,
/// schedulers, and other concurrent execution frameworks where minimizing
/// allocation latency and contention is critical.
///
/// \note The file also defines `_thread_pause()` across architectures for
/// low-latency busy-waiting.
///
/// \see helix::ThreadPool, std::function
///

#include <cstring>
#include <include/core.hh>
#include <type_traits>
#include <utility>

#if defined(_WIN32)
#   include <windows.h>
#elif defined(__linux__)
#   include <pthread.h>
#   include <sched.h>
#elif defined(__APPLE__)
#   include <mach/mach_init.h>
#   include <mach/thread_act.h>
#   include <pthread.h>
#else
#   include <thread>
#endif

#if defined(__x86_64__)
#   include <immintrin.h>
#   define _thread_pause() _mm_pause()
#elif defined(__aarch64__)
#   include <arm_acle.h>
#   define _thread_pause() __yield()
#elif defined(__riscv)
#   define _thread_pause() asm volatile("pause" ::: "memory")
#else
#   include <thread>
#   define _thread_pause() libcxx::this_thread::yield()
#endif

namespace helix {
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
/// helix::SmallFunction<> f = [] { printf("Hello"); };
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
    ~SmallFunction() { reset(); }

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
    SmallFunction(F &&f) {
        emplace(libcxx::forward<F>(f));
    }

    ///
    /// \brief Move constructor.
    ///
    /// \param other Source `SmallFunction` to move from.
    ///
    /// \details
    /// Transfers ownership of the callable and metadata from another
    ///     `SmallFunction`, resetting the source to an empty state.
    ///
    SmallFunction(SmallFunction &&other) noexcept {
        move_from(std::Memory::move(other));
    }

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
    SmallFunction &operator=(SmallFunction &&other) noexcept {
        if (this != &other) {
            reset();
            move_from(std::Memory::move(other));
        }

        return *this;
    }

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
    /// \detail
    /// Performs a direct type-erased call through `_call`.
    /// If no callable is present, the function returns silently.
    ///
    /// \note Invocation is noexcept if the stored callable is noexcept.
    ///
    void operator()() const {
        if (_call != nullptr) {
            _call(&_storage.data);
        }
    }

    ///
    /// \brief Resets and destroys the stored callable.
    ///
    /// \detail
    /// Calls the stored destructor function (if any) and clears both
    ///     function pointers. After `reset()`, the instance becomes empty and
    ///     safe to reuse.
    ///
    void reset() noexcept {
        if (_destroy != nullptr) {
            _destroy(&_storage.data);
        }

        _call    = nullptr;
        _destroy = nullptr;
    }

    ///
    /// \brief Checks whether a callable is stored.
    ///
    /// \return `true` if callable exists, `false` otherwise.
    ///
    [[nodiscard]] bool valid() const noexcept { return _call != nullptr; }

  private:
    ///
    /// \struct Storage
    /// \brief Internal aligned storage buffer for callable placement.
    ///
    /// \detail
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
    /// \detail
    ///     Performs placement-new into `_storage.data` and sets up
    ///     function pointers for later invocation and destruction.
    ///
    template <typename F>
    void emplace(F &&f) {
        using FnT = libcxx::decay_t<F>;
        static_assert(sizeof(FnT) <= InlineSize,
                      "Callable too large for SmallFunction inline storage");

        new (static_cast<void *>(_storage.data)) FnT(libcxx::forward<F>(f));

        _call = [](const void *s) noexcept {
            (*reinterpret_cast<const FnT *>(s))();
        };

        _destroy = [](void *s) noexcept { reinterpret_cast<FnT *>(s)->~FnT(); };
    }

    ///
    /// \brief Transfers ownership of callable data from another instance.
    ///
    /// \param other Source `SmallFunction` to move from.
    ///
    /// \detail
    /// Copies raw storage memory, moves function pointers, and clears
    ///     the source. The move is shallow, as callable contents are already
    ///     inline.
    ///
    void move_from(SmallFunction &&other) noexcept {
        std::Memory::copy(&_storage, &other._storage, sizeof(Storage));
        _call    = other._call;
        _destroy = other._destroy;

        other._call    = nullptr;
        other._destroy = nullptr;
    }
};
}  // namespace helix

#endif  // __HELIX_TOOLCHAIN_CORE_SMALLFUNCTION_HH__