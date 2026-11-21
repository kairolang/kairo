/// --- The Kairo Project --------------------------- Native/Prelude.hh --- ///
///
///   The base every Compiler/Native header includes. Native is plain C++ on
///   the C++ standard library: a `.k` file ffi-imports these headers through
///   clang, and nothing else is on the include path.
///
///   It gives the folder the fixed-width names it is written in (u8 .. usize),
///   `kairo::libcxx` for C++'s std inside namespace kairo (where a bare
///   `std::` means kairo::std), and the string and stderr helpers in
///   kairo::native.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_NATIVE_KPRELUDE_HH__
#define __KAIRO_NATIVE_KPRELUDE_HH__

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>

#if defined(_WIN32)
#include <io.h>
#else
#include <unistd.h>
#endif

/// C++'s std inside namespace kairo, where a bare `std::` means kairo::std.
namespace kairo {
namespace libcxx = ::std;
}

// The fixed-width names Native is written in, global so every header reads
// the same. usize is size_t, not u64: it is what Kairo's usize lowers to, and
// the two differ on hosts where uint64_t is unsigned long long but size_t is
// unsigned long.
using u8    = ::std::uint8_t;
using i8    = ::std::int8_t;
using u16   = ::std::uint16_t;
using i16   = ::std::int16_t;
using u32   = ::std::uint32_t;
using i32   = ::std::int32_t;
using u64   = ::std::uint64_t;
using i64   = ::std::int64_t;
using f32   = float;
using f64   = double;
using usize = ::std::size_t;
using isize = ::std::ptrdiff_t;

namespace kairo::native {
/// The bytes of any string-like argument, as a view. A Native entry point
/// that takes text is a template over this, so ONE signature accepts the
/// Kairo builtin string (raw() + size(); raw() is u8, hence the cast), a
/// literal, a ::std::string, or an llvm::StringRef (data() + size()). No
/// Native header can name the Kairo string type. The size is always
/// explicit: an embedded NUL is a byte like any other.
inline ::std::string_view bytes(const char *s) noexcept {
    return s != nullptr ? ::std::string_view(s) : ::std::string_view();
}
inline ::std::string_view bytes(::std::string_view s) noexcept { return s; }
inline ::std::string_view bytes(const ::std::string &s) noexcept { return s; }

template <class S>
    requires requires(const S &s) {
        s.raw();
        s.size();
    }
inline ::std::string_view bytes(const S &s) noexcept {
    return {reinterpret_cast<const char *>(s.raw()),
            static_cast<::std::size_t>(s.size())};
}

template <class S>
    requires(
        !requires(const S &s) { s.raw(); } &&
        requires(const S &s) {
            s.data();
            s.size();
        } && !::std::is_convertible_v<const S &, ::std::string_view>)
inline ::std::string_view bytes(const S &s) noexcept {
    return {reinterpret_cast<const char *>(s.data()),
            static_cast<::std::size_t>(s.size())};
}

/// The pair a status line on stderr registers so that other writers in this
/// folder can keep their text off its row: stderr_hold() takes the line off
/// the screen and keeps it off until stderr_release(). ProgressMeter
/// (Native/Progress.k) registers its hold() / release(); with nothing registered
/// both calls do nothing. Function pointers, so a header that writes to
/// stderr needs no declaration of the meter.
struct StderrGuard {
    ::std::atomic<void (*)()> hold{nullptr};
    ::std::atomic<void (*)()> release{nullptr};
};

inline StderrGuard &stderr_guard() noexcept {
    static StderrGuard g;
    return g;
}

inline void stderr_hold() noexcept {
    if (auto *f = stderr_guard().hold.load(::std::memory_order_acquire)) { f(); }
}

inline void stderr_release() noexcept {
    if (auto *f = stderr_guard().release.load(::std::memory_order_acquire)) { f(); }
}

/// Whether stderr is a terminal: the test for colour and for a status line.
inline bool stderr_is_tty() noexcept {
#if defined(_WIN32)
    return _isatty(_fileno(stderr)) != 0;
#else
    return ::isatty(2) != 0;
#endif
}

/// Writes \p v to \p f exactly (no locale, no NUL scan). C stdio, so it
/// orders with every other stdio writer to \p f.
inline void write_bytes(::std::FILE *f, ::std::string_view v) noexcept {
    if (!v.empty()) {
        ::std::fwrite(v.data(), 1, v.size(), f);
    }
}
}  // namespace kairo::native

#endif  // __KAIRO_NATIVE_KPRELUDE_HH__
