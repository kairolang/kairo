/// --- The Kairo Project ----------------------- Native/ClangCompat.hh --- ///
///
///   The clang APIs whose spelling differs between the LLVM releases the
///   tree builds against (22.1 and 23.1).
///
///   WHY C++: Kairo resolves and types both branches of a function-body
///   `eval if` that does not fold, so a member that exists in only one
///   release cannot be named from Kairo behind a version test. The
///   preprocessor can, so the difference lives here and the Kairo code calls
///   one spelling.
///
///   Every test is on LLVM_VERSION_MAJOR, never on __has_include of a header
///   only one release has: an include root the build does not list falls
///   back to the host's /usr/include, which may hold another LLVM's headers.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_NATIVE_CLANGCOMPAT_HH__
#define __KAIRO_NATIVE_CLANGCOMPAT_HH__

#include <llvm/Config/llvm-config.h>
#include <clang/AST/PrettyPrinter.h>

// USR generation moved out of clangIndex into clangUnifiedSymbolResolution in
// 23; the namespace (clang::index) and the functions are unchanged.
#if LLVM_VERSION_MAJOR >= 23
#include <clang/UnifiedSymbolResolution/USRGeneration.h>
#else
#include <clang/Index/USRGeneration.h>
#endif

namespace kairo::clang_compat {

/// The depth / position parameter type of TemplateTypeParmDecl::Create and
/// NonTypeTemplateParmDecl::Create: `int` from 23, `unsigned` before.
#if LLVM_VERSION_MAJOR >= 23
using template_parm_index = int;
#else
using template_parm_index = unsigned;
#endif

/// Prints an anonymous tag as `(anonymous struct)`, without the source
/// location of its definition.
inline void anonymous_tags_plain(clang::PrintingPolicy &pol) noexcept {
#if LLVM_VERSION_MAJOR >= 23
    pol.AnonymousTagNameStyle = llvm::to_underlying(clang::PrintingPolicy::AnonymousTagMode::Plain);
#else
    pol.AnonymousTagLocations = false;
#endif
}

} // namespace kairo::clang_compat

#endif // __KAIRO_NATIVE_CLANGCOMPAT_HH__
