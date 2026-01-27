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

#ifndef __HELIX_TOOLCHAIN_CORE_TYPES_HH__
#define __HELIX_TOOLCHAIN_CORE_TYPES_HH__

///
/// \file Core/Types.hh
/// \brief Common type and function aliases for Helix core and standard
/// interoperability.
///
/// \details
/// This header provides unified type aliases and helper functions for
/// threading, synchronization, and memory management primitives used across the
/// Helix toolchain. It re-exports key C++ standard library types and functions
/// through the `libcxx` namespace, ensuring consistent usage of atomic
/// operations, smart pointers, and concurrency constructs throughout the
/// project.
///
/// The intent is to:
///   - Reduce namespace verbosity across the Helix codebase.
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
/// Part of the Helix Project under the Attribution 4.0 International License
/// (CC BY 4.0). Redistribution and modification are permitted with attribution.
///
/// \see libcxx, helix::std, helix::ThreadPool
///

#include <include/core.hh>

#include <bit>
#include <execution>
#include <memory>
#include <memory_resource>
#include <mutex>
#include <new>
#include <cwchar>

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#   include <immintrin.h>        // SSE, AVX, AVX2, AVX512 intrinsics
#   include <emmintrin.h>        // SSE2 baseline
#   include <tmmintrin.h>        // SSSE3
#   define _thread_pause() _mm_pause()
#   define _simd_available() 1
#   define _x86_64_simd
#elif defined(__aarch64__) || defined(_M_ARM64)
#   include <arm_acle.h>         // __yield()
#   include <arm_neon.h>         // NEON intrinsics
#   define _thread_pause() __yield()
#   define _simd_available() 1
#   define _aarch64_simd
#elif defined(__riscv)
#   define _thread_pause() asm volatile("pause" ::: "memory")
#   define _simd_available() 0
#else
#   include <thread>
#   define _thread_pause() ::std::this_thread::yield()
#   define _simd_available() 0
#endif

namespace helix::std {
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
/// semantics via the Helix `libcxx` backend.
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
/// \brief Alias for unique locking mechanism providing scoped ownership.
///
/// \see libcxx::unique_lock
///
using UniqueLock = libcxx::unique_lock<Mutex>;

///
/// \brief Alias for RAII-style lock guard.
///
/// \see libcxx::lock_guard
///
using LockGuard = libcxx::lock_guard<Mutex>;

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
/// Helix's type system and avoiding direct dependency on `std`.
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
using const_ptr = const T*;

///
/// \brief Restrict qualifier macro for pointer optimization.
///
#if defined(__GNUC__) || defined(__clang__)
#  define __RESTRICT__ __restrict__
#elif defined(_MSC_VER)
#  define __RESTRICT__ __restrict
#else
#  define __RESTRICT__
#endif

///
/// \brief Alias for restrict-qualified pointer type.
///
/// \tparam T Underlying pointer type.
/// \see __RESTRICT__
///
template<typename T>
using restrict_ptr = T* __RESTRICT__;

template <typename T, typename E>
class Expected {
    union {
        T value;
        E error;
    };
    bool has_value;

  public:
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

    constexpr T       &operator*()       & { return value; }
    constexpr const T &operator*() const & { return value; }
    constexpr T      &&operator*()      && { return libcxx::move(value); }

    constexpr T       *operator->()       { return &value; }
    constexpr const T *operator->() const { return &value; }

    constexpr E       &err()       & { return error; }
    constexpr const E &err() const & { return error; }
    constexpr E      &&err()      && { return libcxx::move(error); }

    constexpr T      &value_or(T &default_value) & {
        return has_value ? value : default_value;
    }
    
    constexpr T      value_or(T &&default_value) && {
        return has_value ? libcxx::move(value) : libcxx::move(default_value);
    }
    
    constexpr T      value_or(const T &default_value) const & {
        return has_value ? value : default_value;
    }
    
    constexpr T      value_or(T &&default_value) const & {
        return has_value ? value : libcxx::move(default_value);
    }
    
    constexpr E      err_or(E &default_error) & {
        return has_value ? default_error : error;
    }
    
    constexpr E      err_or(E &&default_error) && {
        return has_value ? libcxx::move(default_error) : libcxx::move(error);
    }
    
    constexpr E      err_or(const E &default_error) const & {
        return has_value ? default_error : error;
    }
    
    constexpr E      err_or(E &&default_error) const & {
        return has_value ? default_error : libcxx::move(error);
    }
};

template <typename T>
class Expected<T, std::null_t> {
    union {
        T value;
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

    constexpr T       &operator*()       & { return value; }
    constexpr const T &operator*() const & { return value; }
    constexpr T      &&operator*()      && { return libcxx::move(value); }

    constexpr T       *operator->()       { return &value; }
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

///
/// \note
/// This header may be expanded to include additional abstractions or
/// cross-platform primitives.
///

}  // namespace helix::std

#endif  // __HELIX_TOOLCHAIN_CORE_TYPES_HH__