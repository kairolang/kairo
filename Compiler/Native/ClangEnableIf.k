/// --- The Kairo Project ----------------------- Native/ClangEnableIf.k --- ///
///
///   A C/C++ function's `__attribute__((enable_if(cond, msg)))` conditions,
///   as far as they are decided without the call's arguments: overload
///   resolution removes a candidate whose condition is false and prefers
///   one whose conditions all hold over one that has none, as clang does
///   (SemaOverload.cpp: CheckEnableIf, compareEnableIfAttrs). libc++'s
///   `_LIBCPP_PREFERRED_OVERLOAD` is `enable_if(true, "")`, which is how its
///   C++ `memchr` / `strstr` overloads beat the C library's declarations.
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
ffi "c++" import "clang/AST/Expr.h"

/// What a function's enable_if attributes decide before its arguments are
/// known (EnableIfState as a u8).
pub enum EnableIfState derives u8 {
    /// No enable_if attribute.
    None = 0,
    /// Every condition is a constant and true.
    Satisfied,
    /// Some condition is a constant and false: the function is no candidate.
    Failed,
    /// No condition is false, but one depends on a parameter (a template's,
    /// or the function's own): only clang, at the call, can decide it.
    Undecided,
}

/// Does `s` name a parameter of a function? Such a condition is clang's to
/// evaluate with the call's arguments (EvaluateWithSubstitution); evaluated
/// without them, `__builtin_object_size(p, 0)` folds to its unknown answer
/// and would decide the condition wrongly.
fn names_param(s: unsafe *const clang::Stmt) -> bool {
    if s == &null {
        return false
    }

    var unsafe *d = llvm::dyn_cast<clang::DeclRefExpr>(s)
    if d != &null && llvm::isa<clang::ParmVarDecl>(d->getDecl()) {
        return true
    }

    for child in s->children() {
        if names_param(child) {
            return true
        }
    }

    return false
}

/// The enable_if state of `decl` (a clang::Decl the owning header set still
/// holds; null is allowed). A failed condition's message goes to `why` ("" when
/// the attribute gives none). Read off the most recent redeclaration, which
/// carries every enable_if of the chain: the attribute is inheritable.
///
/// The caller holds the owning HeaderSet's sema_lock(), as for
/// clang_decl_purity: the redeclaration chain can be growing on another
/// Sema thread.
pub fn clang_enable_if(decl: unsafe *const void, @inout why: string) -> u8 {
    if decl == &null {
        return EnableIfState::None as u8
    }

    var unsafe *d  = unsafe (decl as unsafe *const clang::Decl)
    var unsafe *ft = llvm::dyn_cast<clang::FunctionTemplateDecl>(d)
    if ft != &null {
        d = ft->getTemplatedDecl()
    }

    var unsafe *fd = llvm::dyn_cast_or_null<clang::FunctionDecl>(d)
    if fd == &null {
        return EnableIfState::None as u8
    }

    // Through the Redeclarable base: FunctionDecl's `using
    // redeclarable_base::getMostRecentDecl` hides NamedDecl's in C++, and
    // Kairo's member lookup sees both.
    var unsafe *chain = unsafe (fd as unsafe *const clang::Redeclarable<clang::FunctionDecl>)
    fd = chain->getMostRecentDecl()

    if !fd->hasAttr<clang::EnableIfAttr>() {
        return EnableIfState::None as u8
    }

    var state = EnableIfState::Satisfied
    for a in fd->specific_attrs<clang::EnableIfAttr>() {
        var unsafe *cond = a->getCond()
        if cond == &null || cond->isValueDependent() || names_param(cond) {
            state = EnableIfState::Undecided
            continue
        }

        var holds = false
        if !cond->EvaluateAsBooleanCondition(&holds, fd->getASTContext()) {
            state = EnableIfState::Undecided
            continue
        }

        if !holds {
            var msg = a->getMessage()
            why = string(
                unsafe ((msg.data() as unsafe *const u8) as *const u8),
                msg.size(),
            )

            return EnableIfState::Failed as u8
        }
    }

    return state as u8
}
