/// --- The Kairo Project --------------------------- Native/KPrelude.hh --- ///
///
///   The base every Compiler/Native header includes instead of lib-helix's
///   <include/core.hh>. Native is plain C++ on the C++ standard library; it
///   must compile in both worlds that import it:
///
///     Stage 0   compiles Compiler/ with lib-helix's core.hh force-included,
///               so its names (kairo::string, kairo::std::null_t, the global
///               u8..usize aliases, std::Function, std::endl) already exist
///               before the first Native line.
///     Stage 1   ffi-imports these headers through clang with no lib-helix on
///               any path; nothing but the C++ standard library is there.
///
///   KAIRO_NATIVE_STAGE0 says which, and is the ONLY switch Native uses. It
///   keys on __has_include rather than on a lib-helix macro so a Stage 1 TU
///   that happens to put lib-helix on a path still gets one consistent world
///   (the Stage 0 one, which is a superset).
///
///   What is defined here unconditionally is a REDECLARATION of what
///   lib-helix declares, to the same entity: a namespace alias and a type
///   alias may be redeclared to the same target, so Stage 0 sees no conflict
///   and Stage 1 gets the definition. Anything lib-helix DEFINES (a class, a
///   variable) would be a redefinition and stays behind the switch.
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
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>

#if __has_include(<include/core.hh>)
#include <include/core.hh>
#define KAIRO_NATIVE_STAGE0 1
#else
#define KAIRO_NATIVE_STAGE0 0
#endif

/// lib-helix's spelling of C++'s std inside namespace kairo, where a bare
/// `std::` means kairo::std. Identical to lib-helix's own declaration.
namespace kairo {
namespace libcxx = ::std;
}

#if !KAIRO_NATIVE_STAGE0
// The fixed-width names Native is written in. Global, as lib-helix has them,
// so the headers read the same in both worlds. usize is size_t, not u64: it
// is what Stage 1 lowers Kairo's usize to, and the two differ on hosts where
// uint64_t is unsigned long long but size_t is unsigned long.
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
#endif

namespace kairo::native {
/// The bytes of any string-like argument, as a view. A Native entry point
/// that takes text is a template over this, so ONE signature accepts
/// whatever the caller's world calls a string: lib-helix's kairo::string in
/// Stage 0, the Kairo builtin string in Stage 1 (both have raw() + size();
/// raw() is char in one and u8 in the other, hence the cast), a literal, a
/// ::std::string, or an llvm::StringRef (data() + size()). The size is always
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

/// Writes \p v to \p f exactly (no locale, no NUL scan). C stdio, as lib-helix's
/// print family did, so it orders with every other stdio writer to \p f.
inline void write_bytes(::std::FILE *f, ::std::string_view v) noexcept {
    if (!v.empty()) {
        ::std::fwrite(v.data(), 1, v.size(), f);
    }
}
}  // namespace kairo::native

#endif  // __KAIRO_NATIVE_KPRELUDE_HH__
