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
#include "clang/AST/DeclCXX.h"
#include "clang/AST/DeclTemplate.h"
#include "clang/Basic/Diagnostic.h"

namespace kairo {

/// Why a record can be copied only from a non-const lvalue: `rec` is the
/// record a diagnostic named, `ctor` the user-declared copy constructor
/// (`X(X&)`, C++ of a Kairo `@copy fn X(self, other: Self)`) that forces it,
/// and `field` the by-value field of `rec` (or of a record it holds) through
/// which `ctor`'s record is reached, null when `ctor` is `rec`'s own. All
/// null: no such record.
struct MutableCopyCause {
    const clang::CXXRecordDecl      *rec   = nullptr;
    const clang::CXXConstructorDecl *ctor  = nullptr;
    const clang::FieldDecl          *field = nullptr;
};

namespace detail {

/// The copy constructor that makes \p rd copy only from a non-const lvalue:
/// its own user-declared `X(X&)` when it declares no copy that takes a const
/// source and no move, or, when it declares no copy or move at all, that of
/// a base or by-value field (C++ then makes the implicit copy `X(X&)` and
/// defines the implicit move as deleted, so neither a const object nor an
/// rvalue has a constructor). \p via receives the first field on that path.
inline const clang::CXXConstructorDecl *
mutable_copy_ctor(const clang::CXXRecordDecl *rd, const clang::FieldDecl **via, unsigned depth) noexcept {
    if (rd == nullptr || depth > 8) { return nullptr; }
    rd = rd->getDefinition();
    if (rd == nullptr || rd->isUnion() || rd->isLambda()) { return nullptr; }
    if (rd->hasUserDeclaredMoveConstructor()) { return nullptr; }
    if (rd->hasUserDeclaredCopyConstructor()) {
        const clang::CXXConstructorDecl *nc = nullptr;
        for (const auto *c : rd->ctors()) {
            unsigned q = 0;
            if (c->isImplicit() || c->isDeleted() || !c->isCopyConstructor(q)) { continue; }
            if ((q & clang::Qualifiers::Const) != 0) { return nullptr; }
            if (nc == nullptr) { nc = c; }
        }
        return nc;
    }
    auto through = [&](clang::QualType t) -> const clang::CXXConstructorDecl * {
        t = t.getCanonicalType();
        while (const auto *at = llvm::dyn_cast<clang::ArrayType>(t.getTypePtr())) {
            t = at->getElementType().getCanonicalType();
        }
        const auto *frd = t->getAsCXXRecordDecl();
        const clang::FieldDecl *inner = nullptr;
        return frd == nullptr ? nullptr : mutable_copy_ctor(frd, &inner, depth + 1);
    };
    for (const auto &b : rd->bases()) {
        if (const auto *c = through(b.getType())) { return c; }
    }
    for (const auto *f : rd->fields()) {
        if (f->getType()->isReferenceType()) { continue; }
        if (const auto *c = through(f->getType())) {
            if (via != nullptr && *via == nullptr) { *via = f; }
            return c;
        }
    }
    return nullptr;
}

inline void mutable_copy_in_type(clang::QualType t, MutableCopyCause &out, unsigned depth) noexcept;

inline void mutable_copy_in_args(const clang::TemplateArgumentList *al, MutableCopyCause &out, unsigned depth) noexcept {
    if (al == nullptr) { return; }
    for (const auto &a : al->asArray()) {
        if (out.ctor != nullptr) { return; }
        if (a.getKind() == clang::TemplateArgument::Type) { mutable_copy_in_type(a.getAsType(), out, depth + 1); }
        if (a.getKind() == clang::TemplateArgument::Pack) {
            for (const auto &p : a.pack_elements()) {
                if (p.getKind() == clang::TemplateArgument::Type) { mutable_copy_in_type(p.getAsType(), out, depth + 1); }
            }
        }
    }
}

/// \p t through references, pointers, arrays and qualifiers; a record that
/// copies only from a non-const lvalue is the answer, a template
/// specialization is searched through its type arguments (`allocator<X>`).
inline void mutable_copy_in_type(clang::QualType t, MutableCopyCause &out, unsigned depth) noexcept {
    if (t.isNull() || out.ctor != nullptr || depth > 6) { return; }
    t = t.getCanonicalType();
    for (;;) {
        if (const auto *r = llvm::dyn_cast<clang::ReferenceType>(t.getTypePtr())) { t = r->getPointeeType().getCanonicalType(); continue; }
        if (const auto *p = llvm::dyn_cast<clang::PointerType>(t.getTypePtr())) { t = p->getPointeeType().getCanonicalType(); continue; }
        if (const auto *a = llvm::dyn_cast<clang::ArrayType>(t.getTypePtr())) { t = a->getElementType().getCanonicalType(); continue; }
        break;
    }
    const auto *rd = t->getAsCXXRecordDecl();
    if (rd == nullptr) { return; }
    const clang::FieldDecl *via = nullptr;
    if (const auto *c = mutable_copy_ctor(rd, &via, 0)) {
        out.rec = rd;
        out.ctor = c;
        out.field = via;
        return;
    }
    if (const auto *cs = llvm::dyn_cast<clang::ClassTemplateSpecializationDecl>(rd)) {
        mutable_copy_in_args(&cs->getTemplateArgs(), out, depth);
    }
}

}  // namespace detail

/// The first record among \p info's arguments that copies only from a
/// non-const lvalue (MutableCopyCause): a type argument, or the type
/// arguments of a specialization a declaration argument is or belongs to
/// (`'std::vector<X>::push_back'`, `'construct<X, const X &>'`). Read off the
/// real C++ classes the TU is compiled with, so the cause is exact; whether
/// the record is a Kairo one is the caller's question (where `ctor` is).
inline MutableCopyCause clang_diag_mutable_copy(const clang::Diagnostic &info) noexcept {
    MutableCopyCause out;
    for (unsigned i = 0, n = info.getNumArgs(); i < n && out.ctor == nullptr; ++i) {
        auto k = info.getArgKind(i);
        if (k == clang::DiagnosticsEngine::ak_qualtype) {
            detail::mutable_copy_in_type(
                clang::QualType::getFromOpaquePtr(reinterpret_cast<void *>(info.getRawArg(i))), out, 0);
            continue;
        }
        if (k != clang::DiagnosticsEngine::ak_nameddecl) { continue; }
        const auto *d = reinterpret_cast<const clang::NamedDecl *>(info.getRawArg(i));
        if (d == nullptr) { continue; }
        if (const auto *fd = llvm::dyn_cast<clang::FunctionDecl>(d)) {
            detail::mutable_copy_in_args(fd->getTemplateSpecializationArgs(), out, 0);
            if (out.ctor == nullptr) {
                if (const auto *md = llvm::dyn_cast<clang::CXXMethodDecl>(fd)) {
                    const auto *p = md->getParent();
                    if (const auto *cs = llvm::dyn_cast<clang::ClassTemplateSpecializationDecl>(p)) {
                        detail::mutable_copy_in_args(&cs->getTemplateArgs(), out, 0);
                    } else {
                        const clang::FieldDecl *via = nullptr;
                        if (const auto *c = detail::mutable_copy_ctor(p, &via, 0)) {
                            out.rec = p;
                            out.ctor = c;
                            out.field = via;
                        }
                    }
                }
            }
            continue;
        }
        if (const auto *td = llvm::dyn_cast<clang::TypeDecl>(d)) {
            if (const auto *rd = llvm::dyn_cast<clang::CXXRecordDecl>(td)) {
                if (const auto *cs = llvm::dyn_cast<clang::ClassTemplateSpecializationDecl>(rd)) {
                    detail::mutable_copy_in_args(&cs->getTemplateArgs(), out, 0);
                }
                if (out.ctor == nullptr) {
                    const clang::FieldDecl *via = nullptr;
                    if (const auto *c = detail::mutable_copy_ctor(rd, &via, 0)) {
                        out.rec = rd;
                        out.ctor = c;
                        out.field = via;
                    }
                }
            }
        }
    }
    return out;
}

/// The first parameter of \p c (a copy constructor's source).
inline const clang::ParmVarDecl *clang_ctor_source(const clang::CXXConstructorDecl *c) noexcept {
    return c == nullptr || c->getNumParams() == 0 ? nullptr : c->getParamDecl(0);
}

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
