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

#ifndef __KAIRO_TOOLCHAIN_CORE_SMALLFUNCTION_HH__
#define __KAIRO_TOOLCHAIN_CORE_SMALLFUNCTION_HH__

///
/// \file SmallFunction.hh
/// \brief Inline small callable wrapper with zero dynamic allocations.
///
/// \details
/// This header defines `kairo::SmallFunction`, a lightweight, type-erased
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
/// \see kairo::ThreadPool, std::function
///

#include <include/core.hh>

#include "Types.hh"

#if defined(_WIN32)
#include <windows.h>
#elif defined(__linux__)
#include <pthread.h>
#include <sched.h>
#elif defined(__APPLE__)
#include <mach/mach_init.h>
#include <mach/thread_act.h>
#include <pthread.h>
#else
#include <thread>
#endif

namespace kairo {
template <size_t InlineSize>
SmallFunction<InlineSize>::~SmallFunction() {
    reset();
}

template <size_t InlineSize>
template <typename F>
SmallFunction<InlineSize>::SmallFunction(F &&f) {
    emplace(libcxx::forward<F>(f));
}


template <size_t InlineSize>
SmallFunction<InlineSize>::SmallFunction(SmallFunction &&other) noexcept {
    move_from(std::Memory::move(other));
}

template <size_t InlineSize>
SmallFunction<InlineSize> &
SmallFunction<InlineSize>::operator=(SmallFunction &&other) noexcept {
    if (this != &other) {
        reset();
        move_from(std::Memory::move(other));
    }
    return *this;
}

template <size_t InlineSize>
void SmallFunction<InlineSize>::operator()() const {
    if (_call != nullptr) {
        _call(&_storage.data);
    }
}

template <size_t InlineSize>
void SmallFunction<InlineSize>::reset() noexcept {
    if (_destroy != nullptr) {
        _destroy(&_storage.data);
    }
    _call    = nullptr;
    _destroy = nullptr;
}

template <size_t InlineSize>
bool SmallFunction<InlineSize>::valid() const noexcept {
    return _call != nullptr;
}

template <size_t InlineSize>
template <typename F>
void SmallFunction<InlineSize>::emplace(F &&f) {
    using FnT = libcxx::decay_t<F>;
    static_assert(sizeof(FnT) <= InlineSize,
                  "Callable too large for SmallFunction inline storage");

    new (static_cast<void *>(_storage.data)) FnT(libcxx::forward<F>(f));

    _call = [](const void *s) noexcept {
        (*reinterpret_cast<const FnT *>(s))();
    };

    _destroy = [](void *s) noexcept {
        reinterpret_cast<FnT *>(s)->~FnT();
    };
}

template <size_t InlineSize>
void SmallFunction<InlineSize>::move_from(SmallFunction &&other) noexcept {
    std::Memory::copy(&_storage, &other._storage, sizeof(Storage));
    _call    = other._call;
    _destroy = other._destroy;

    other._call    = nullptr;
    other._destroy = nullptr;
}
}  // namespace kairo

#endif  // __KAIRO_TOOLCHAIN_CORE_SMALLFUNCTION_HH__