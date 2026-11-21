/// --- The Kairo Project ------------------------- Native/ClangPurity.k --- ///
///
///   What clang already knows about a C/C++ function's side effects:
///   FnPurityCheck lets a `const fn` / `@pure` call such a function when
///   clang itself marks it const / pure, instead of treating every call into
///   C++ as an effect.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/AST/Attr.h"
ffi "c++" import "clang/AST/Decl.h"
ffi "c++" import "clang/AST/DeclTemplate.h"
ffi "c++" import "clang/Basic/Builtins.h"

/// The purity clang gives `decl` (a clang::Decl the owning header set still
/// holds; null is allowed): 0 none, 1 const (`[[gnu::const]]`), 2 pure
/// (`[[gnu::pure]]`). Read off the attributes on any redeclaration, which
/// already reflect OUR invocation: clang adds ConstAttr to a library builtin
/// such as `abs` itself, and withholds it from `sqrt` under -fmath-errno
/// (the builtin table calls that one const only "ignoring errno").
///
/// The caller holds the owning HeaderSet's sema_lock(): the redecls() walk
/// reads chains another Sema thread's fill can be extending. Go through
/// ForeignInstantiate::decl_purity, which takes it.
pub fn clang_decl_purity(decl: unsafe *const void) -> u8 {
    if decl == &null {
        return 0
    }

    var unsafe *d  = unsafe (decl as unsafe *const clang::Decl)
    var unsafe *ft = llvm::dyn_cast<clang::FunctionTemplateDecl>(d)
    if ft != &null {
        d = ft->getTemplatedDecl()
    }

    var unsafe *fd = llvm::dyn_cast_or_null<clang::FunctionDecl>(d)
    if fd == &null {
        return 0
    }

    // Through the Redeclarable base: FunctionDecl's `using
    // redeclarable_base::redecls` hides Decl::redecls in C++, and Kairo's
    // member lookup sees both.
    var unsafe *chain = unsafe (fd as unsafe *const clang::Redeclarable<clang::FunctionDecl>)
    var        pure   = false
    for r in chain->redecls() {
        if r->hasAttr<clang::ConstAttr>() {
            return 1
        }

        if r->hasAttr<clang::PureAttr>() {
            pure = true
        }
    }

    return if pure => 2 else => 0
}

/// The same for a function Kairo minted from a clang builtin (BuiltinImport:
/// no clang decl, only the builtin ID). Generic builtins only; a target
/// builtin's ID means nothing without its target. `sqrt`'s entry is not
/// const here (only "const ignoring errno"), which is what -fmath-errno
/// makes it.
pub fn clang_builtin_purity(id: u32) -> u8 {
    if id == 0 || id >= (clang::Builtin::FirstTSBuiltin as u32) {
        return 0
    }

    static const ctx: clang::Builtin::Context = clang::Builtin::Context()
    if ctx.isConst(id) {
        return 1
    }

    if ctx.isPure(id) {
        return 2
    }

    return 0
}
