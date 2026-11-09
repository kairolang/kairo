#pragma once
//===----------------------------------------------------------------------===//
///
/// \file KClangDiag.hh
/// \brief Questions about a clang::Diagnostic's arguments that Kairo cannot
///        ask itself: an argument is a raw uint64_t whose meaning depends on
///        its kind (ak_nameddecl holds a NamedDecl*).
///
/// Part of the Kairo Project, under the Apache License v2.0 with the
/// Kairo Runtime Library Exception.
///
/// See: https://www.kairolang.org/LICENSE
/// SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
/// Copyright (c) 2026 Dhruvan Kartik
///
//===----------------------------------------------------------------------===//

#include "clang/AST/Decl.h"
#include "clang/Basic/Diagnostic.h"

namespace kairo {

/// True when one of \p info's arguments names a namespace. ClangDiagAdapter
/// drops clang's "'X' declared here" note about one that lies in a `.k` file:
/// every namespace there is a module namespace codegen wrote, with no
/// declaration the user could open.
inline bool clang_diag_names_namespace(const clang::Diagnostic &info) noexcept {
    for (unsigned i = 0, n = info.getNumArgs(); i < n; ++i) {
        if (info.getArgKind(i) != clang::DiagnosticsEngine::ak_nameddecl) { continue; }
        const auto *d = reinterpret_cast<const clang::NamedDecl *>(info.getRawArg(i));
        if (d != nullptr && llvm::isa<clang::NamespaceDecl>(d)) { return true; }
    }
    return false;
}

}  // namespace kairo
