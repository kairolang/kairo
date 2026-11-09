#pragma once
//===----------------------------------------------------------------------===//
///
/// \file KClangPurity.hh
/// \brief What clang already knows about a C/C++ function's side effects:
///        FnPurityCheck lets a `const fn` / `@pure` call such a function when
///        clang itself marks it const / pure, instead of treating every call
///        into C++ as an effect.
///
/// Part of the Kairo Project, under the Apache License v2.0 with the
/// Kairo Runtime Library Exception.
///
/// See: https://www.kairolang.org/LICENSE
/// SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
/// Copyright (c) 2026 Dhruvan Kartik
///
//===----------------------------------------------------------------------===//

#include "clang/AST/Attr.h"
#include "clang/AST/Decl.h"
#include "clang/AST/DeclTemplate.h"
#include "clang/Basic/Builtins.h"

namespace kairo {

/// The purity clang gives \p decl (a clang::Decl the owning header set still
/// holds; null is allowed): 0 none, 1 const (`[[gnu::const]]`), 2 pure
/// (`[[gnu::pure]]`). Read off the attributes on any redeclaration, which
/// already reflect OUR invocation: clang adds ConstAttr to a library builtin
/// such as `abs` itself, and withholds it from `sqrt` under -fmath-errno
/// (the builtin table calls that one const only "ignoring errno").
inline unsigned char clang_decl_purity(const void *decl) noexcept {
    if (decl == nullptr) { return 0; }
    const auto *d = static_cast<const clang::Decl *>(decl);
    if (const auto *ft = llvm::dyn_cast<clang::FunctionTemplateDecl>(d)) { d = ft->getTemplatedDecl(); }
    const auto *fd = llvm::dyn_cast_or_null<clang::FunctionDecl>(d);
    if (fd == nullptr) { return 0; }
    bool pure = false;
    for (const clang::FunctionDecl *r : fd->redecls()) {
        if (r->hasAttr<clang::ConstAttr>()) { return 1; }
        if (r->hasAttr<clang::PureAttr>()) { pure = true; }
    }
    return pure ? 2 : 0;
}

/// The same for a function Kairo minted from a clang builtin (BuiltinImport:
/// no clang decl, only the builtin ID). Generic builtins only; a target
/// builtin's ID means nothing without its target. `sqrt`'s entry is not
/// const here (only "const ignoring errno"), which is what -fmath-errno makes it.
inline unsigned char clang_builtin_purity(unsigned id) noexcept {
    if (id == 0 || id >= clang::Builtin::FirstTSBuiltin) { return 0; }
    static const clang::Builtin::Context ctx;
    if (ctx.isConst(id)) { return 1; }
    if (ctx.isPure(id))  { return 2; }
    return 0;
}

}  // namespace kairo
