/// --- The Kairo Project --------------------------- Native/ClangDiag.k --- ///
///
///   Questions about a clang::Diagnostic's arguments: an argument is a raw
///   u64 whose meaning depends on its kind (ak_nameddecl holds a
///   NamedDecl*).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/AST/Decl.h"
ffi "c++" import "clang/AST/DeclCXX.h"
ffi "c++" import "clang/AST/DeclTemplate.h"
ffi "c++" import "clang/Basic/Diagnostic.h"

/// Why a record can be copied only from a non-const lvalue: `rec` is the
/// record a diagnostic named, `ctor` the user-declared copy constructor
/// (`X(X&)`, C++ of a Kairo `@copy fn X(self, other: Self)`) that forces it,
/// and `field` the by-value field of `rec` (or of a record it holds) through
/// which `ctor`'s record is reached, null when `ctor` is `rec`'s own. All
/// null: no such record.
pub struct MutableCopyCause {
    pub var rec:   unsafe *const clang::CXXRecordDecl      = &null
    pub var ctor:  unsafe *const clang::CXXConstructorDecl = &null
    pub var field: unsafe *const clang::FieldDecl          = &null
}

module detail {
    /// How far the search follows bases and fields of a record, and how far
    /// it follows template arguments of a type. A record nested deeper than
    /// this is not explained; nothing else depends on the limits.
    eval kMutableCopyRecordDepth: u32 = 8
    eval kMutableCopyTypeDepth:   u32 = 6

    /// The mutable copy constructor of the record `t` holds by value
    /// (through arrays), for mutable_copy_ctor's walk of bases and fields.
    fn mutable_copy_through(t_in:  clang::QualType,
                            depth: u32) -> unsafe *const clang::CXXConstructorDecl {
        var        t   = t_in.getCanonicalType()
        var unsafe *at = llvm::dyn_cast<clang::ArrayType>(t.getTypePtr())
        while at != &null {
            t  = at->getElementType().getCanonicalType()
            at = llvm::dyn_cast<clang::ArrayType>(t.getTypePtr())
        }

        var unsafe *frd = t->getAsCXXRecordDecl()
        var inner: unsafe *const clang::FieldDecl = &null
        return if frd == &null => &null else => mutable_copy_ctor(frd, unsafe &inner, depth + 1)
    }

    /// The copy constructor that makes `rd_in` copy only from a non-const
    /// lvalue: its own user-declared `X(X&)` when it declares no copy that
    /// takes a const source and no move, or, when it declares no copy or
    /// move at all, that of a base or by-value field (C++ then makes the
    /// implicit copy `X(X&)` and defines the implicit move as deleted, so
    /// neither a const object nor an rvalue has a constructor). `via`
    /// receives the first field on that path.
    pub fn mutable_copy_ctor(rd_in: unsafe *const clang::CXXRecordDecl,
                             via:   unsafe *unsafe *const clang::FieldDecl,
                             depth: u32) -> unsafe *const clang::CXXConstructorDecl {
        if rd_in == &null || depth > kMutableCopyRecordDepth {
            return &null
        }

        var unsafe *rd = rd_in->getDefinition()
        if rd == &null || rd->isUnion() || rd->isLambda() {
            return &null
        }

        if rd->hasUserDeclaredMoveConstructor() {
            return &null
        }

        if rd->hasUserDeclaredCopyConstructor() {
            var nc: unsafe *const clang::CXXConstructorDecl = &null
            for c in rd->ctors() {
                var q: u32 = 0
                if c->isImplicit() || c->isDeleted() || !c->isCopyConstructor(&q) {
                    continue
                }

                if ((q as u64) & (clang::Qualifiers::Const as u64)) != 0 {
                    return &null
                }

                if nc == &null {
                    nc = c
                }
            }

            return nc
        }

        for b in rd->bases() {
            var unsafe *c = mutable_copy_through(b.getType(), depth)
            if c != &null {
                return c
            }
        }

        for f in rd->fields() {
            if f->getType()->isReferenceType() {
                continue
            }

            var unsafe *c = mutable_copy_through(f->getType(), depth)
            if c != &null {
                if via != &null && *via == &null {
                    *via = f
                }

                return c
            }
        }

        return &null
    }

    /// Fills `out` when `rd` itself copies only from a non-const lvalue.
    pub fn mutable_copy_of_record(rd:         unsafe *const clang::CXXRecordDecl,
                                  @inout out: MutableCopyCause) -> bool {
        var via: unsafe *const clang::FieldDecl = &null
        var unsafe *c = mutable_copy_ctor(rd, unsafe &via, 0)
        if c == &null {
            return false
        }

        out.rec   = rd
        out.ctor  = c
        out.field = via
        return true
    }

    pub fn mutable_copy_in_args(al:         unsafe *const clang::TemplateArgumentList,
                                @inout out: MutableCopyCause,
                                depth:      u32) {
        if al == &null {
            return
        }

        for a in al->asArray() {
            if out.ctor != &null {
                return
            }

            if a.getKind() == clang::TemplateArgument::Type {
                mutable_copy_in_type(a.getAsType(), &out, depth + 1)
            }

            if a.getKind() == clang::TemplateArgument::Pack {
                for p in a.pack_elements() {
                    if p.getKind() == clang::TemplateArgument::Type {
                        mutable_copy_in_type(p.getAsType(), &out, depth + 1)
                    }
                }
            }
        }
    }

    /// `t_in` through references, pointers, arrays and qualifiers; a record
    /// that copies only from a non-const lvalue is the answer, a template
    /// specialization is searched through its type arguments
    /// (`allocator<X>`).
    pub fn mutable_copy_in_type(t_in: clang::QualType, @inout out: MutableCopyCause, depth: u32) {
        if t_in.isNull() || out.ctor != &null || depth > kMutableCopyTypeDepth {
            return
        }

        var t = t_in.getCanonicalType()
        loop {
            var unsafe *r = llvm::dyn_cast<clang::ReferenceType>(t.getTypePtr())
            if r != &null {
                t = r->getPointeeType().getCanonicalType()
                continue
            }

            var unsafe *p = llvm::dyn_cast<clang::PointerType>(t.getTypePtr())
            if p != &null {
                t = p->getPointeeType().getCanonicalType()
                continue
            }

            var unsafe *a = llvm::dyn_cast<clang::ArrayType>(t.getTypePtr())
            if a != &null {
                t = a->getElementType().getCanonicalType()
                continue
            }

            break
        }

        var unsafe *rd = t->getAsCXXRecordDecl()
        if rd == &null {
            return
        }

        if mutable_copy_of_record(rd, &out) {
            return
        }

        var unsafe *cs = llvm::dyn_cast<clang::ClassTemplateSpecializationDecl>(
            rd,
        )

        if cs != &null {
            mutable_copy_in_args(unsafe &cs->getTemplateArgs(), &out, depth)
        }
    }
}

/// The first record among `info`'s arguments that copies only from a
/// non-const lvalue (MutableCopyCause): a type argument, or the type
/// arguments of a specialization a declaration argument is or belongs to
/// (`'std::vector<X>::push_back'`, `'construct<X, const X &>'`). Read off the
/// real C++ classes the TU is compiled with, so the cause is exact; whether
/// the record is a Kairo one is the caller's question (where `ctor` is).
pub fn clang_diag_mutable_copy(const info: clang::Diagnostic) -> MutableCopyCause {
    var   out     = MutableCopyCause()
    const n:  u32 = info.getNumArgs()
    for var i: u32 = 0; i < n && out.ctor == &null; ++i {
        const k = info.getArgKind(i)
        if k == clang::DiagnosticsEngine::ak_qualtype {
            detail::mutable_copy_in_type(
                clang::QualType::getFromOpaquePtr(
                    unsafe (info.getRawArg(i) as unsafe *void),
                ),
                &out,
                0,
            )

            continue
        }

        if k != clang::DiagnosticsEngine::ak_nameddecl {
            continue
        }

        var unsafe *d = unsafe (info.getRawArg(i) as unsafe *const clang::NamedDecl)
        if d == &null {
            continue
        }

        var unsafe *fd = llvm::dyn_cast<clang::FunctionDecl>(d)
        if fd != &null {
            detail::mutable_copy_in_args(
                fd->getTemplateSpecializationArgs(),
                &out,
                0,
            )

            if out.ctor == &null {
                var unsafe *md = llvm::dyn_cast<clang::CXXMethodDecl>(fd)
                if md != &null {
                    var unsafe *p = md->getParent()
                    var unsafe *cs = llvm::dyn_cast<clang::ClassTemplateSpecializationDecl>(
                        p,
                    )

                    if cs != &null {
                        detail::mutable_copy_in_args(
                            unsafe &cs->getTemplateArgs(),
                            &out,
                            0,
                        )
                    } else {
                        detail::mutable_copy_of_record(p, &out)
                    }
                }
            }

            continue
        }

        var unsafe *td = llvm::dyn_cast<clang::TypeDecl>(d)
        if td != &null {
            var unsafe *rd = llvm::dyn_cast<clang::CXXRecordDecl>(td)
            if rd != &null {
                var unsafe *cs = llvm::dyn_cast<clang::ClassTemplateSpecializationDecl>(
                    rd,
                )

                if cs != &null {
                    detail::mutable_copy_in_args(
                        unsafe &cs->getTemplateArgs(),
                        &out,
                        0,
                    )
                }

                if out.ctor == &null {
                    detail::mutable_copy_of_record(rd, &out)
                }
            }
        }
    }

    return out
}

/// The first parameter of `c` (a copy constructor's source).
pub fn clang_ctor_source(c: unsafe *const clang::CXXConstructorDecl) -> unsafe *const clang::ParmVarDecl {
    return if c == &null || c->getNumParams() == 0 => &null else => c->getParamDecl(0)
}

/// True when one of `info`'s arguments names a namespace. ClangDiagAdapter
/// drops clang's "'X' declared here" note about one that lies in a `.k`
/// file: every namespace there is a module namespace codegen wrote, with no
/// declaration the user could open.
pub fn clang_diag_names_namespace(const info: clang::Diagnostic) -> bool {
    const n: u32 = info.getNumArgs()
    for var i: u32 = 0; i < n; ++i {
        if info.getArgKind(i) != clang::DiagnosticsEngine::ak_nameddecl {
            continue
        }

        var unsafe *d = unsafe (info.getRawArg(i) as unsafe *const clang::NamedDecl)
        if d != &null && llvm::isa<clang::NamespaceDecl>(d) {
            return true
        }
    }

    return false
}
