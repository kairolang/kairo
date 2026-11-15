#pragma once
//===----------------------------------------------------------------------===//
///
/// \file KCxxMoveWalk.hh
/// \brief Whether a C++ function moves out of what one of its reference or
///        pointer parameters refers to, read off its body: MoveCheck asks
///        it of each C++ call that passes a MOVE value by `T&` / `T*`
///        (Compiler/Spec/Ownership.md, "C++ bodies").
///
///   The question is "does an expression that refers to the parameter's
///   object reach a `T&&` parameter of some call or constructor call", not
///   a flow analysis: any path counts, and a move followed by a reassignment
///   still counts (`std::swap` moves both of its arguments by this rule).
///
///   What refers to the object (granularity: the whole object):
///     - the parameter itself (a `T&`), or `*p` / `p->m` / `p[i]` for a `T*`,
///       and `*this` / `this->m` for the implicit object;
///     - a member of any of those (`p.m`), so moving a field moves the object;
///     - a local reference or pointer initialised from one (`T& r = p;`);
///     - a cast to a reference of it (`static_cast<T&&>(p)`), and the result
///       of a call that returns a reference and takes it by reference
///       (`std::move(p)`, `std::forward<T>(p)`, `p.front()`).
///
///   Such an expression bound to a parameter whose type, in the INSTANTIATED
///   callee, is an rvalue reference to non-const is a move. `std::move(b)`
///   on an lvalue instantiates `move<X&>(X&)`, so it is never the move
///   itself: its result is, once it binds the `X&&` of a constructor.
///   `std::forward<T>(x)` returns `T&&` only for a non-reference T, which is
///   why the walk reads instances, never patterns.
///
///   Bound to a `U&` / `U*` (U not const) parameter, or used as the object
///   of a non-const member call, it is followed into that callee, to
///   `max_depth` calls, with a per-(function, parameter) cache. A callee
///   with no visible body (declared only, an extern template's member, a
///   body that does not instantiate for these arguments), a virtual call,
///   or a call through a pointer, given the object, makes the answer
///   Unknown unless some other path moves: Moves over Unknown over None.
///
///   Instantiation: a template instance's body is instantiated on demand
///   with diagnostics suppressed; an error during it makes that callee
///   Unknown. The caller holds ForeignInstantiate's lock and then the
///   owning HeaderSet's sema_lock() (clang::Sema is single-threaded).
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
#include "clang/AST/Expr.h"
#include "clang/AST/ExprCXX.h"
#include "clang/AST/ExprConcepts.h"
#include "clang/AST/Stmt.h"
#include "clang/Basic/Diagnostic.h"
#include "clang/Sema/Sema.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/SmallPtrSet.h"

#include <cstdint>
#include <string>
#include <utility>

namespace kairo {

/// One answer. `kind`: 0 the body does not move it, 1 it moves it, 2 not
/// known (a body or a call that cannot be inspected; `why` says which).
struct CxxMoveAnswer {
    unsigned char kind = 0;
    /// Unknown: 1 no visible body, 2 virtual call, 3 call through a pointer,
    /// 4 depth limit, 5 the body does not instantiate for these arguments.
    unsigned char why = 0;
    /// Moves: the expression that moves. Unknown: the call that cannot be
    /// inspected (invalid when it is the function asked about).
    clang::SourceLocation begin, end;
    const clang::FunctionDecl *inside = nullptr;      ///< the function whose body holds `begin`.
    const clang::FunctionDecl *blocker = nullptr; ///< Unknown 1/2/5: the callee that cannot be read.

    bool in_is(const clang::FunctionDecl *f) const {
        return inside != nullptr && f != nullptr && inside->getCanonicalDecl() == f->getCanonicalDecl();
    }
    bool blocker_is(const clang::FunctionDecl *f) const {
        return blocker != nullptr && f != nullptr && blocker->getCanonicalDecl() == f->getCanonicalDecl();
    }

    ::std::string in_name() const { return inside ? inside->getQualifiedNameAsString() : ::std::string(); }
    ::std::string blocker_name() const {
        return blocker ? blocker->getQualifiedNameAsString() : ::std::string();
    }
};

/// The cache: (function, parameter) -> answer, for one build. Keys are
/// clang decls of sets that stay pinned for the build (HeaderSet::ast()
/// pins a set it is asked of), so a key never outlives its decl.
class CxxMoveCache {
public:
    llvm::DenseMap<::std::pair<const clang::FunctionDecl *, int>, CxxMoveAnswer> done;
    unsigned queries = 0;
    unsigned instantiated = 0;
};

class CxxMoveWalk {
    clang::Sema &S;
    CxxMoveCache &C;
    unsigned max_depth;
    llvm::DenseSet<::std::pair<const clang::FunctionDecl *, int>> active;
    bool capped = false; ///< some answer below hit the depth limit: not cached.

    /// The walk of one body for one root.
    struct Body {
        llvm::SmallPtrSet<const clang::ValueDecl *, 4> objs; ///< refer to the object.
        llvm::SmallPtrSet<const clang::ValueDecl *, 4> ptrs; ///< point at it.
        bool this_root = false;
        const clang::FunctionDecl *fn = nullptr;
        unsigned depth = 0;
        CxxMoveAnswer moved;   ///< kind 1 once found.
        CxxMoveAnswer unknown; ///< the first Unknown met.
    };

public:
    CxxMoveWalk(clang::Sema &s, CxxMoveCache &c, unsigned depth) : S(s), C(c), max_depth(depth) {}

    /// The question for a call from Kairo: parameter \p idx of \p fd (-1 the
    /// implicit object). One a body cannot move out of -- by value, `T&&`
    /// (the call itself moves), a reference or pointer to const, a const
    /// method -- is None without reading anything; a virtual method is
    /// Unknown, since an override is what runs.
    CxxMoveAnswer top(const clang::FunctionDecl *fd, int idx) {
        CxxMoveAnswer none;
        if (fd == nullptr) { return none; }
        const auto *md = llvm::dyn_cast<clang::CXXMethodDecl>(fd);
        if (idx < 0) {
            if (md == nullptr || md->isStatic() || md->isConst()) { return none; }
            if (md->getRefQualifier() == clang::RQ_RValue) { return none; }
        } else {
            if ((unsigned)idx >= fd->getNumParams()) { return none; }
            clang::QualType pt = fd->getParamDecl((unsigned)idx)->getType();
            if (!mutable_ref(pt) && !mutable_ptr(pt)) { return none; }
        }
        if (md != nullptr && md->isVirtual() && !md->hasAttr<clang::FinalAttr>()
            && !md->getParent()->hasAttr<clang::FinalAttr>()) {
            return unknown(2, fd, fd, clang::SourceRange());
        }
        return param(fd, idx, 0);
    }

    /// Does \p fd move out of what parameter \p idx (-1: the implicit
    /// object) refers to?
    CxxMoveAnswer param(const clang::FunctionDecl *fd, int idx, unsigned depth = 0) {
        CxxMoveAnswer none;
        if (fd == nullptr) { return none; }
        auto key = ::std::make_pair(fd, idx);
        auto it = C.done.find(key);
        if (it != C.done.end()) { return it->second; }
        // A recursive call says nothing yet; the outer walk finishes it.
        if (!active.insert(key).second) { return none; }
        bool was_capped = capped;
        capped = false;
        CxxMoveAnswer a = compute(fd, idx, depth);
        active.erase(key);
        if (!capped) { C.done[key] = a; }
        capped = capped || was_capped;
        return a;
    }

private:
    static CxxMoveAnswer unknown(unsigned char why, const clang::FunctionDecl *in,
                                 const clang::FunctionDecl *blocker, clang::SourceRange r) {
        CxxMoveAnswer a;
        a.kind = 2;
        a.why = why;
        a.inside = in;
        a.blocker = blocker;
        a.begin = r.getBegin();
        a.end = r.getEnd();
        return a;
    }

    /// The definition of \p fd, instantiating a template instance's body
    /// when it has none yet; null when there is none to read.
    const clang::FunctionDecl *body_of(const clang::FunctionDecl *fd, bool &failed) {
        failed = false;
        const clang::FunctionDecl *def = nullptr;
        if (fd->hasBody(def) && def != nullptr && def->getBody() != nullptr) { return def; }
        auto *mfd = const_cast<clang::FunctionDecl *>(fd);
        if (mfd->getTemplateInstantiationPattern() == nullptr) { return nullptr; }
        auto &diags = S.getDiagnostics();
        bool was = diags.getSuppressAllDiagnostics();
        diags.setSuppressAllDiagnostics(true);
        clang::DiagnosticErrorTrap trap(diags);
        S.InstantiateFunctionDefinition(mfd->getLocation(), mfd, false, false, false);
        diags.setSuppressAllDiagnostics(was);
        C.instantiated += 1;
        if (trap.hasErrorOccurred()) {
            failed = true;
            return nullptr;
        }
        def = nullptr;
        if (fd->hasBody(def) && def != nullptr && def->getBody() != nullptr) { return def; }
        return nullptr;
    }

    CxxMoveAnswer compute(const clang::FunctionDecl *fd, int idx, unsigned depth) {
        C.queries += 1;
        CxxMoveAnswer none;
        // A builtin (`::std::move`, `::std::forward`, `memcpy`) moves nothing of
        // its own: what it returns is judged where it is bound.
        if (fd->getBuiltinID() != 0) { return none; }
        // Defaulted and deleted members move only from their own `T&&`
        // parameter, which is never the one asked about.
        if (fd->isDefaulted() || fd->isDeleted()) { return none; }
        bool failed = false;
        const clang::FunctionDecl *def = body_of(fd, failed);
        if (def == nullptr) {
            return unknown(failed ? 5 : 1, fd, fd, clang::SourceRange());
        }
        Body b;
        b.fn = def;
        b.depth = depth;
        if (idx < 0) {
            b.this_root = true;
        } else {
            if ((unsigned)idx >= def->getNumParams()) { return none; }
            const clang::ParmVarDecl *p = def->getParamDecl((unsigned)idx);
            clang::QualType t = p->getType();
            if (t->isReferenceType()) {
                b.objs.insert(p);
            } else if (t->isPointerType()) {
                b.ptrs.insert(p);
            } else {
                return none;
            }
        }
        if (const auto *ctor = llvm::dyn_cast<clang::CXXConstructorDecl>(def)) {
            for (const clang::CXXCtorInitializer *ci : ctor->inits()) {
                if (ci->getInit() != nullptr) { walk(b, ci->getInit()); }
                if (b.moved.kind == 1) { return b.moved; }
            }
        }
        walk(b, def->getBody());
        if (b.moved.kind == 1) { return b.moved; }
        if (b.unknown.kind == 2) { return b.unknown; }
        return none;
    }

    static const clang::Expr *strip(const clang::Expr *e) {
        while (e != nullptr) {
            e = e->IgnoreParens();
            if (const auto *c = llvm::dyn_cast<clang::CastExpr>(e)) {
                switch (c->getCastKind()) {
                case clang::CK_NoOp:
                case clang::CK_DerivedToBase:
                case clang::CK_UncheckedDerivedToBase:
                case clang::CK_BaseToDerived:
                case clang::CK_LValueToRValue:
                    e = c->getSubExpr();
                    continue;
                default:
                    return e;
                }
            }
            return e;
        }
        return e;
    }

    /// \p e denotes (part of) the object.
    bool obj(Body &b, const clang::Expr *e) {
        e = strip(e);
        if (e == nullptr) { return false; }
        if (const auto *d = llvm::dyn_cast<clang::DeclRefExpr>(e)) { return b.objs.count(d->getDecl()) != 0; }
        if (const auto *u = llvm::dyn_cast<clang::UnaryOperator>(e)) {
            return u->getOpcode() == clang::UO_Deref && ptr(b, u->getSubExpr());
        }
        if (const auto *m = llvm::dyn_cast<clang::MemberExpr>(e)) {
            return m->isArrow() ? ptr(b, m->getBase()) : obj(b, m->getBase());
        }
        if (const auto *s = llvm::dyn_cast<clang::ArraySubscriptExpr>(e)) {
            return s->getBase()->getType()->isPointerType() && ptr(b, s->getBase());
        }
        if (const auto *c = llvm::dyn_cast<clang::AbstractConditionalOperator>(e)) {
            return obj(b, c->getTrueExpr()) || obj(b, c->getFalseExpr());
        }
        if (const auto *call = llvm::dyn_cast<clang::CallExpr>(e)) {
            if (!call->getCallReturnType(S.getASTContext())->isReferenceType()) { return false; }
            const clang::FunctionDecl *fd = call->getDirectCallee();
            if (const auto *mc = llvm::dyn_cast<clang::CXXMemberCallExpr>(call)) {
                const auto *me = llvm::dyn_cast<clang::MemberExpr>(mc->getCallee()->IgnoreParens());
                if (me != nullptr && (me->isArrow() ? ptr(b, me->getBase()) : obj(b, me->getBase()))) {
                    return true;
                }
            }
            unsigned off = 0;
            if (llvm::isa<clang::CXXOperatorCallExpr>(call) && fd != nullptr && llvm::isa<clang::CXXMethodDecl>(fd)) {
                if (call->getNumArgs() > 0 && obj(b, call->getArg(0))) { return true; }
                off = 1;
            }
            for (unsigned i = off; i < call->getNumArgs(); ++i) {
                unsigned j = i - off;
                bool by_ref = fd == nullptr || j >= fd->getNumParams()
                                  ? false
                                  : fd->getParamDecl(j)->getType()->isReferenceType();
                if (by_ref && obj(b, call->getArg(i))) { return true; }
            }
            return false;
        }
        return false;
    }

    /// \p e is a pointer to (part of) the object.
    bool ptr(Body &b, const clang::Expr *e) {
        e = strip(e);
        if (e == nullptr) { return false; }
        if (llvm::isa<clang::CXXThisExpr>(e)) { return b.this_root; }
        if (const auto *d = llvm::dyn_cast<clang::DeclRefExpr>(e)) { return b.ptrs.count(d->getDecl()) != 0; }
        if (const auto *u = llvm::dyn_cast<clang::UnaryOperator>(e)) {
            return u->getOpcode() == clang::UO_AddrOf && obj(b, u->getSubExpr());
        }
        if (const auto *call = llvm::dyn_cast<clang::CallExpr>(e)) {
            // `::std::addressof(x)`.
            if (call->getBuiltinCallee() != 0 && call->getNumArgs() == 1 && call->getType()->isPointerType()) {
                return obj(b, call->getArg(0));
            }
        }
        return false;
    }

    static bool mutable_ref(clang::QualType t) {
        return t->isLValueReferenceType() && !t.getNonReferenceType().isConstQualified();
    }

    static bool mutable_ptr(clang::QualType t) {
        return t->isPointerType() && !t->getPointeeType().isConstQualified();
    }

    void found_move(Body &b, const clang::Expr *at) {
        if (b.moved.kind == 1) { return; }
        b.moved.kind = 1;
        b.moved.inside = b.fn;
        b.moved.begin = at->getBeginLoc();
        b.moved.end = at->getEndLoc();
    }

    void note_unknown(Body &b, const CxxMoveAnswer &a) {
        if (b.unknown.kind != 2) { b.unknown = a; }
    }

    /// The object reaches \p callee's parameter \p j (-1 the implicit
    /// object) at the call \p at: follow it.
    void follow(Body &b, const clang::FunctionDecl *callee, int j, const clang::Expr *at) {
        if (b.depth + 1 > max_depth) {
            capped = true;
            note_unknown(b, unknown(4, b.fn, callee, at->getSourceRange()));
            return;
        }
        CxxMoveAnswer a = param(callee, j, b.depth + 1);
        if (a.kind == 1) {
            b.moved = a;
            return;
        }
        if (a.kind == 2) {
            // The call in this body is where the reader can look.
            CxxMoveAnswer u = a;
            if (!u.begin.isValid()) {
                u.inside = b.fn;
                u.begin = at->getBeginLoc();
                u.end = at->getEndLoc();
            }
            note_unknown(b, u);
        }
    }

    /// The arguments of a call to \p callee (null: not a direct call), the
    /// first \p off of them not bound to a declared parameter.
    void args(Body &b, const clang::FunctionDecl *callee, const clang::Expr *const *as, unsigned n,
              unsigned off, const clang::Expr *at) {
        for (unsigned i = off; i < n; ++i) {
            if (b.moved.kind == 1) { return; }
            const clang::Expr *a = as[i];
            unsigned j = i - off;
            if (callee == nullptr || j >= callee->getNumParams()) {
                // A call through a pointer, or a C `...` argument.
                if (callee == nullptr && (obj(b, a) || ptr(b, a))) {
                    note_unknown(b, unknown(3, b.fn, nullptr, at->getSourceRange()));
                }
                continue;
            }
            clang::QualType pt = callee->getParamDecl(j)->getType();
            if (pt->isRValueReferenceType() && !pt.getNonReferenceType().isConstQualified()) {
                if (obj(b, a)) { found_move(b, a); }
                continue;
            }
            if ((mutable_ref(pt) && obj(b, a)) || (mutable_ptr(pt) && ptr(b, a))) {
                follow(b, callee, (int)j, at);
            }
        }
    }

    bool is_virtual_call(const clang::CXXMethodDecl *md, const clang::Expr *callee) {
        if (md == nullptr || !md->isVirtual()) { return false; }
        if (md->hasAttr<clang::FinalAttr>() || md->getParent()->hasAttr<clang::FinalAttr>()) { return false; }
        const auto *me = llvm::dyn_cast<clang::MemberExpr>(callee->IgnoreParens());
        return me == nullptr || !me->hasQualifier();
    }

    /// The implicit object of a call to \p md is the object: an `&&`
    /// method moves it, a non-const one is followed.
    void object(Body &b, const clang::CXXMethodDecl *md, const clang::Expr *callee, const clang::Expr *at) {
        if (md == nullptr || md->isStatic() || b.moved.kind == 1) { return; }
        if (md->getRefQualifier() == clang::RQ_RValue) {
            found_move(b, at);
            return;
        }
        if (md->isConst()) { return; }
        if (is_virtual_call(md, callee)) {
            note_unknown(b, unknown(2, b.fn, md, at->getSourceRange()));
            return;
        }
        follow(b, md, -1, at);
    }

    void call(Body &b, const clang::CallExpr *c) {
        const clang::FunctionDecl *fd = c->getDirectCallee();
        if (fd != nullptr && fd->getBuiltinID() != 0) { return; }
        const clang::Expr *const *as = c->getArgs();
        unsigned n = c->getNumArgs();
        if (const auto *mc = llvm::dyn_cast<clang::CXXMemberCallExpr>(c)) {
            const clang::CXXMethodDecl *md = mc->getMethodDecl();
            const auto *me = llvm::dyn_cast<clang::MemberExpr>(mc->getCallee()->IgnoreParens());
            if (me != nullptr && (me->isArrow() ? ptr(b, me->getBase()) : obj(b, me->getBase()))) {
                object(b, md, mc->getCallee(), c);
            }
            // A virtual callee's arguments: an override may move them.
            if (is_virtual_call(md, mc->getCallee())) {
                for (unsigned i = 0; i < n; ++i) {
                    if (obj(b, as[i]) || ptr(b, as[i])) {
                        clang::QualType pt = i < md->getNumParams() ? md->getParamDecl(i)->getType() : clang::QualType();
                        if (!pt.isNull() && pt->isRValueReferenceType()) { continue; }
                        note_unknown(b, unknown(2, b.fn, md, c->getSourceRange()));
                    }
                }
            }
            args(b, md, as, n, 0, c);
            return;
        }
        if (llvm::isa<clang::CXXOperatorCallExpr>(c) && fd != nullptr && llvm::isa<clang::CXXMethodDecl>(fd)) {
            const auto *md = llvm::cast<clang::CXXMethodDecl>(fd);
            if (n > 0 && obj(b, as[0])) { object(b, md, c->getCallee(), c); }
            args(b, fd, as, n, 1, c);
            return;
        }
        args(b, fd, as, n, 0, c);
    }

    void walk(Body &b, const clang::Stmt *s) {
        if (s == nullptr || b.moved.kind == 1) { return; }
        // Unevaluated operands (`noexcept(T(::std::move(p)))`, `sizeof`) run nothing.
        if (llvm::isa<clang::CXXNoexceptExpr>(s) || llvm::isa<clang::UnaryExprOrTypeTraitExpr>(s)
            || llvm::isa<clang::RequiresExpr>(s)) {
            return;
        }
        if (const auto *t = llvm::dyn_cast<clang::CXXTypeidExpr>(s)) {
            if (!t->isPotentiallyEvaluated()) { return; }
        }
        if (const auto *ds = llvm::dyn_cast<clang::DeclStmt>(s)) {
            for (const clang::Decl *d : ds->decls()) {
                const auto *v = llvm::dyn_cast<clang::VarDecl>(d);
                if (v == nullptr || v->getInit() == nullptr) { continue; }
                // A local alias of the object: `T& r = p;`, `T* q = p;`.
                clang::QualType t = v->getType();
                if (t->isReferenceType() && obj(b, v->getInit())) { b.objs.insert(v); }
                if (t->isPointerType() && ptr(b, v->getInit())) { b.ptrs.insert(v); }
            }
        }
        if (const auto *c = llvm::dyn_cast<clang::CallExpr>(s)) {
            call(b, c);
        } else if (const auto *ce = llvm::dyn_cast<clang::CXXConstructExpr>(s)) {
            args(b, ce->getConstructor(), ce->getArgs(), ce->getNumArgs(), 0, ce);
        }
        for (const clang::Stmt *child : s->children()) {
            if (b.moved.kind == 1) { return; }
            walk(b, child);
        }
    }
};

}  // namespace kairo
