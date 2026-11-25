/// --- The Kairo Project ------------------------ Native/ClangMoveWalk.k --- ///
///
///   Whether a C++ function moves out of what one of its reference or
///   pointer parameters refers to, read off its body: MoveCheck asks it of
///   each C++ call that passes a MOVE value by `T&` / `T*`
///   (Compiler/Spec/Ownership.md, "C++ bodies").
///
///   The question is "does an expression that refers to the parameter's
///   object reach a `T&&` parameter of some call or constructor call", not
///   a flow analysis: any path counts, and a move followed by a reassignment
///   still counts (`std::swap` moves both of its arguments by this rule).
///
///   What refers to the object (granularity: the whole object):
///     - the parameter itself (a `T&`), or `*p` / `p->m` / `p[i]` for a `T*`,
///       and `*this` / `this->m` for the implicit object;
///     - a member of any of those (`p.m`, `p.*pd`), so moving a field moves
///       the object;
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
///   or a call through a pointer, given the object by `U&` / `U*` to
///   non-const, or a C `...` argument given a pointer to non-const to it,
///   makes the answer Unknown unless some other path moves:
///   Moves over Unknown over None. Every override of a virtual method and
///   every function a pointer can hold has the parameter types the call
///   names, so the object bound to one of them by value or by reference or
///   pointer to const is not moved, and bound to a `T&&` it is.
///
///   A callee with no visible body that the toolchain's own library
///   declares (CxxLibRoots) is Assumed instead: it is taken not to move,
///   and the call is listed. It ranks below Unknown, so a body that hands
///   the object to both an opaque library function and an opaque function
///   of any other header is Unknown: Moves over Unknown over Assumed over
///   None.
///
///   A lambda's body is read where the lambda is written, since the calls
///   of the closure are not followed: a capture by reference is the object,
///   a capture by copy is not. A recursive call answers None for the pair
///   being answered; the pairs between the two are not cached, as their
///   answers wait on it.
///
///   Instantiation: a template instance's body is instantiated on demand
///   with diagnostics suppressed; an error during it makes that callee
///   Unknown. The caller holds ForeignInstantiate's lock and then the
///   owning HeaderSet's sema_lock() (clang::Sema is single-threaded).
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
ffi "c++" import "clang/AST/DeclCXX.h"
ffi "c++" import "clang/AST/DeclTemplate.h"
ffi "c++" import "clang/AST/Expr.h"
ffi "c++" import "clang/AST/ExprCXX.h"
ffi "c++" import "clang/AST/ExprConcepts.h"
ffi "c++" import "clang/AST/Stmt.h"
ffi "c++" import "clang/Basic/Diagnostic.h"
ffi "c++" import "clang/Basic/SourceManager.h"
ffi "c++" import "clang/Sema/Sema.h"
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/ADT/SmallPtrSet.h"
ffi "c++" import "llvm/ADT/SmallString.h"
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Path.h"
ffi "c++" import "string"
ffi "c++" import "utility"

/// The root list's element. CxxLibRoots names it through this alias: its
/// field `cxx` hides the `cxx` namespace inside the class.
type RootPath = cxx::std::string

/// One answer. `kind`: 0 the body does not move it, 1 it moves it, 2 not
/// known (a body or a call that cannot be inspected; `why` says which), 3
/// assumed not to move it (what could not be read is library functions
/// with no visible body, CxxLibRoots).
pub class CxxMoveAnswer {
    pub var kind: u8 = 0
    /// Unknown: 1 no visible body, 2 virtual call, 3 call through a pointer,
    /// 4 depth limit, 5 the body does not instantiate for these arguments,
    /// 7 a pointer to non-const passed through a C `...` argument.
    /// Assumed: 1 a C++ standard library function, 2 a C library one.
    pub var why: u8 = 0
    /// Moves: the expression that moves. Unknown: the call that cannot be
    /// inspected (invalid when it is the function asked about).
    pub var begin:   clang::SourceLocation
    pub var end:     clang::SourceLocation
    pub var inside:  unsafe *const clang::FunctionDecl = &null ///< the function whose body holds `begin`.
    pub var blocker: unsafe *const clang::FunctionDecl = &null ///< Unknown 1/2/5/7, Assumed: the callee that cannot be read.

    pub fn in_is(const self, f: unsafe *const clang::FunctionDecl) -> bool {
        return self.inside != &null
            && f != &null
            && self.inside->getCanonicalDecl() == f->getCanonicalDecl()
    }

    pub fn blocker_is(const self, f: unsafe *const clang::FunctionDecl) -> bool {
        return self.blocker != &null
            && f != &null
            && self.blocker->getCanonicalDecl() == f->getCanonicalDecl()
    }

    pub fn in_name(const self) -> cxx::std::string {
        if self.inside != &null {
            return self.inside->getQualifiedNameAsString()
        }

        return cxx::std::string()
    }

    pub fn blocker_name(const self) -> cxx::std::string {
        if self.blocker != &null {
            return self.blocker->getQualifiedNameAsString()
        }

        return cxx::std::string()
    }
}

/// The toolchain's own library roots (ClangBackend::library_roots), as real
/// paths. A function is the library's when its first declaration is in a
/// file under a C++ root (libc++), or has C language linkage and is in a
/// file under a C root (the sysroot's libc, the clang builtins). The test
/// is the file, not clang's system-header bit (every root and anything
/// under `#pragma GCC system_header` is a system header) nor namespace
/// `std` (a user header can declare into it, and an explicit
/// specialization of a std template for a user type is the user's). An
/// implicit instance of a std template is declared where its pattern is,
/// so a std member instantiated with a user type is the library's.
pub class CxxLibRoots {
    pub var cxx:   llvm::SmallVector<RootPath, 4>
    pub var c:     llvm::SmallVector<RootPath, 4>
    pub var ready: bool                           = false

    /// A root `dir`, of the C++ library when `is_cxx`; one that does not
    /// exist is left out.
    pub fn add(self, is_cxx: bool, dir: llvm::StringRef) {
        var r = llvm::SmallString<256>()
        if llvm::sys::fs::real_path(llvm::Twine(dir), &r, false).value() != 0 {
            return
        }

        if is_cxx {
            self.cxx.push_back(r.str().str())
        } else {
            self.c.push_back(r.str().str())
        }
    }

    /// 1 when `fd` is the C++ standard library's, 2 the C library's, 0
    /// neither.
    pub fn library_of(const self,
                      const sm: clang::SourceManager,
                      fd:       unsafe *const clang::FunctionDecl) -> u8 {
        if fd == &null || (self.cxx.empty() && self.c.empty()) {
            return 0
        }

        var unsafe *first = fd->getFirstDecl()
        var        loc    = sm.getExpansionLoc(first->getLocation())
        if !loc.isValid() {
            return 0
        }

        var fe = sm.getFileEntryRefForID(sm.getFileID(loc))
        if !fe.has_value() {
            return 0
        }

        var path = fe->getFileEntry().tryGetRealPathName().str()
        if path.empty() {
            var r = llvm::SmallString<256>()
            if llvm::sys::fs::real_path(llvm::Twine(fe->getName()), &r, false).value() != 0 {
                return 0
            }

            path = r.str().str()
        }

        if Self::under(self.cxx, llvm::StringRef(path)) {
            return 1
        }

        if first->isExternC() && Self::under(self.c, llvm::StringRef(path)) {
            return 2
        }

        return 0
    }

    priv static fn under(const roots: llvm::SmallVector<RootPath, 4>,
                         path:        llvm::StringRef) -> bool {
        for r in roots {
            // A real path uses the host's separator: `\` on Windows.
            if path.size() > r.size()
                && path.starts_with(llvm::StringRef(r))
                && llvm::sys::path::is_separator(path[r.size()]) {
                return true
            }
        }

        return false
    }
}

/// The cache: (function, parameter) -> answer, for one build. Keys are
/// clang decls of sets that stay pinned for the build (HeaderSet::ast()
/// pins a set it is asked of), so a key never outlives its decl.
pub class CxxMoveCache {
    pub var done: llvm::DenseMap<cxx::std::pair<unsafe *const clang::FunctionDecl, i32>, CxxMoveAnswer>
    pub var queries:      u32 = 0
    pub var instantiated: u32 = 0
}

pub class CxxMoveWalk {
    priv var S:         unsafe *clang::Sema
    priv var C:         unsafe *CxxMoveCache
    priv var max_depth: u32
    priv var roots:     unsafe *const CxxLibRoots = &null ///< null: no function is the library's.
    /// The (function, parameter) pairs being answered, outermost first, each
    /// with its place on that stack.
    priv var active: llvm::DenseMap<cxx::std::pair<unsafe *const clang::FunctionDecl, i32>, u32>
    priv var capped: bool = false ///< some answer below hit the depth limit: not cached.
    /// The outermost stack place a recursive call below re-entered: an
    /// answer computed above it is partial until that pair is answered.
    priv var low: u32 = ~(0 as u32)

    /// The walk of one body for one root.
    class Body {
        pub var objs:      llvm::SmallPtrSet<unsafe *const clang::ValueDecl, 4> ///< refer to the object.
        pub var ptrs:      llvm::SmallPtrSet<unsafe *const clang::ValueDecl, 4> ///< point at it.
        pub var this_root: bool                                                 = false
        pub var fn_:       unsafe *const clang::FunctionDecl                    = &null
        pub var depth:     u32                                                  = 0
        pub var moved:     CxxMoveAnswer ///< kind 1 once found.
        pub var unknown:   CxxMoveAnswer ///< the first Unknown met.
        pub var assumed:   CxxMoveAnswer ///< the first Assumed met.
    }

    pub fn CxxMoveWalk(self,
                       s:     unsafe *clang::Sema,
                       c:     unsafe *CxxMoveCache,
                       depth: u32,
                       lib:   unsafe *const CxxLibRoots = &null) {
        self.S         = s
        self.C         = c
        self.max_depth = depth
        self.roots     = lib
    }

    /// The question for a call from Kairo: parameter `idx` of `fd` (-1 the
    /// implicit object). One a body cannot move out of -- by value, `T&&`
    /// (the call itself moves), a reference or pointer to const, a const
    /// method -- is None without reading anything; a virtual method is
    /// Unknown, since an override is what runs.
    pub fn top(self, fd: unsafe *const clang::FunctionDecl, idx: i32) -> CxxMoveAnswer {
        var none = CxxMoveAnswer()
        if fd == &null {
            return none
        }

        var unsafe *md = llvm::dyn_cast<clang::CXXMethodDecl>(fd)
        if idx < 0 {
            if md == &null || md->isStatic() || md->isConst() {
                return none
            }

            if md->getRefQualifier() == clang::RQ_RValue {
                return none
            }
        } else {
            if (idx as u32) >= fd->getNumParams() {
                return none
            }

            var pt = fd->getParamDecl(idx as u32)->getType()
            if !Self::mutable_ref(pt) && !Self::mutable_ptr(pt) && !Self::ptr_ref(pt) {
                return none
            }
        }

        if md != &null
            && md->isVirtual()
            && !md->hasAttr<clang::FinalAttr>()
            && !md->getParent()->hasAttr<clang::FinalAttr>() {
            return Self::unknown(2, fd, fd, clang::SourceRange())
        }

        return self.param(fd, idx, 0)
    }

    /// Does `fd` move out of what parameter `idx` (-1: the implicit
    /// object) refers to?
    pub fn param(self,
                 fd:    unsafe *const clang::FunctionDecl,
                 idx:   i32,
                 depth: u32 = 0) -> CxxMoveAnswer {
        var none = CxxMoveAnswer()
        if fd == &null {
            return none
        }

        var key = cxx::std::pair<unsafe *const clang::FunctionDecl, i32>(
            fd,
            idx,
        )

        var it = self.C->done.find(key)
        if it != self.C->done.end() {
            return it->second
        }

        // A recursive call says nothing yet; the outer walk finishes it. What
        // the pairs in between answer depends on it, so they are not cached.
        var at = self.active.find(key)
        if at != self.active.end() {
            if at->second < self.low {
                self.low = at->second
            }

            return none
        }

        const place: u32 = self.active.size() as u32
        self.active[key] = place
        const was_capped = self.capped
        const was_low    = self.low
        self.capped = false
        self.low    = ~(0 as u32)
        var a = self.compute(fd, idx, depth)
        self.active.erase(key)
        if !self.capped && self.low >= place {
            self.C->done[key] = a
        }

        self.capped = self.capped || was_capped
        if self.low >= place {
            self.low = ~(0 as u32)
        }

        if was_low < self.low {
            self.low = was_low
        }

        return a
    }

    priv static fn unknown(why:     u8,
                           in_:     unsafe *const clang::FunctionDecl,
                           blocker: unsafe *const clang::FunctionDecl,
                           r:       clang::SourceRange) -> CxxMoveAnswer {
        var a = CxxMoveAnswer()
        a.kind    = 2
        a.why     = why
        a.inside  = in_
        a.blocker = blocker
        a.begin   = r.getBegin()
        a.end     = r.getEnd()
        return a
    }

    /// The definition of `fd`, instantiating a template instance's body
    /// when it has none yet; null when there is none to read.
    priv fn body_of(self,
                    fd:            unsafe *const clang::FunctionDecl,
                    @inout failed: bool) -> unsafe *const clang::FunctionDecl {
        failed = false
        var def: unsafe *const clang::FunctionDecl = &null
        if fd->hasBody(&def) && def != &null && def->getBody() != &null {
            return def
        }

        var unsafe *mfd = unsafe (fd as unsafe *clang::FunctionDecl)
        if mfd->getTemplateInstantiationPattern() == &null {
            return &null
        }

        const was = self.S->getDiagnostics().getSuppressAllDiagnostics()
        self.S->getDiagnostics().setSuppressAllDiagnostics(true)
        var trap = clang::DiagnosticErrorTrap(&self.S->getDiagnostics())
        self.S->InstantiateFunctionDefinition(
            mfd->getLocation(),
            mfd,
            false,
            false,
            false,
        )

        self.S->getDiagnostics().setSuppressAllDiagnostics(was)
        self.C->instantiated += 1
        if trap.hasErrorOccurred() {
            failed = true
            return &null
        }

        def = &null
        if fd->hasBody(&def) && def != &null && def->getBody() != &null {
            return def
        }

        return &null
    }

    priv fn compute(self,
                    fd:    unsafe *const clang::FunctionDecl,
                    idx:   i32,
                    depth: u32) -> CxxMoveAnswer {
        self.C->queries += 1
        var none = CxxMoveAnswer()
        // A builtin (`std::move`, `std::forward`, `memcpy`) moves nothing of
        // its own: what it returns is judged where it is bound.
        if fd->getBuiltinID() != 0 {
            return none
        }

        // Defaulted and deleted members move only from their own `T&&`
        // parameter, which is never the one asked about.
        if fd->isDefaulted() || fd->isDeleted() {
            return none
        }

        var        failed = false
        var unsafe *def   = self.body_of(fd, &failed)
        if def == &null {
            const lib: u8 = if failed || self.roots == &null => 0
                            else => self.roots->library_of(
                                self.S->getSourceManager(),
                                fd,
                            )

            if lib != 0 {
                var a = Self::unknown(lib, fd, fd, clang::SourceRange())
                a.kind = 3
                return a
            }

            return Self::unknown(
                if failed => 5 as u8 else => 1 as u8,
                fd,
                fd,
                clang::SourceRange(),
            )
        }

        var b = CxxMoveWalk::Body()
        b.fn_   = def
        b.depth = depth
        if idx < 0 {
            b.this_root = true
        } else {
            if (idx as u32) >= def->getNumParams() {
                return none
            }

            var unsafe *p = def->getParamDecl(idx as u32)
            var        t  = p->getType()
            if Self::ptr_ref(t) {
                b.ptrs.insert(p) // `T*&`: the reference names the pointer.
            } else if t->isReferenceType() {
                b.objs.insert(p)
            } else if t->isPointerType() {
                b.ptrs.insert(p)
            } else {
                return none
            }
        }

        var unsafe *ctor = llvm::dyn_cast<clang::CXXConstructorDecl>(def)
        if ctor != &null {
            for ci in ctor->inits() {
                if ci->getInit() != &null {
                    self.walk(&b, ci->getInit())
                }

                if b.moved.kind == 1 {
                    return b.moved
                }
            }
        }

        self.walk(&b, def->getBody())
        if b.moved.kind == 1 {
            return b.moved
        }

        if b.unknown.kind == 2 {
            return b.unknown
        }

        if b.assumed.kind == 3 {
            return b.assumed
        }

        return none
    }

    priv static fn strip(e_in: unsafe *const clang::Expr) -> unsafe *const clang::Expr {
        var unsafe *e = e_in
        while e != &null {
            e = e->IgnoreParens()
            var unsafe *c = llvm::dyn_cast<clang::CastExpr>(e)
            if c != &null {
                const k = c->getCastKind()
                if k == clang::CK_NoOp
                    || k == clang::CK_DerivedToBase
                    || k == clang::CK_UncheckedDerivedToBase
                    || k == clang::CK_BaseToDerived
                    || k == clang::CK_LValueToRValue {
                    e = c->getSubExpr()
                    continue
                }

                return e
            }

            return e
        }

        return e
    }

    /// `e_in` denotes (part of) the object.
    priv fn obj(self, @inout b: CxxMoveWalk::Body, e_in: unsafe *const clang::Expr) -> bool {
        var unsafe *e = Self::strip(e_in)
        if e == &null {
            return false
        }

        var unsafe *d = llvm::dyn_cast<clang::DeclRefExpr>(e)
        if d != &null {
            return b.objs.count(d->getDecl()) != 0
        }

        var unsafe *u = llvm::dyn_cast<clang::UnaryOperator>(e)
        if u != &null {
            return u->getOpcode() == clang::UO_Deref && self.ptr(&b, u->getSubExpr())
        }

        var unsafe *m = llvm::dyn_cast<clang::MemberExpr>(e)
        if m != &null {
            return if m->isArrow() => self.ptr(&b, m->getBase()) else => self.obj(&b, m->getBase())
        }

        var unsafe *s = llvm::dyn_cast<clang::ArraySubscriptExpr>(e)
        if s != &null {
            return s->getBase()->getType()->isPointerType() && self.ptr(&b, s->getBase())
        }

        var unsafe *pm = llvm::dyn_cast<clang::BinaryOperator>(e)
        if pm != &null {
            // `o.*pd`, `p->*pd`: a member of the object.
            if pm->getOpcode() == clang::BO_PtrMemD {
                return self.obj(&b, pm->getLHS())
            }

            if pm->getOpcode() == clang::BO_PtrMemI {
                return self.ptr(&b, pm->getLHS())
            }

            return false
        }

        var unsafe *c = llvm::dyn_cast<clang::AbstractConditionalOperator>(e)
        if c != &null {
            return self.obj(&b, c->getTrueExpr()) || self.obj(&b, c->getFalseExpr())
        }

        var unsafe *call = llvm::dyn_cast<clang::CallExpr>(e)
        if call != &null {
            if !call->getCallReturnType(self.S->getASTContext())->isReferenceType() {
                return false
            }

            var unsafe *fd = call->getDirectCallee()
            var unsafe *mc = llvm::dyn_cast<clang::CXXMemberCallExpr>(call)
            if mc != &null {
                var unsafe *me = llvm::dyn_cast<clang::MemberExpr>(
                    mc->getCallee()->IgnoreParens(),
                )

                if me != &null
                    && (if me->isArrow() => self.ptr(&b, me->getBase())
                        else => self.obj(&b, me->getBase())) {
                    return true
                }
            }

            var off: u32 = 0
            if llvm::isa<clang::CXXOperatorCallExpr>(call)
                && fd != &null
                && llvm::isa<clang::CXXMethodDecl>(fd) {
                if call->getNumArgs() > 0 && self.obj(&b, call->getArg(0)) {
                    return true
                }

                off = 1
            }

            for var i: u32 = off; i < call->getNumArgs(); ++i {
                const j: u32 = i - off
                const by_ref = if fd == &null || j >= fd->getNumParams() => false
                               else => fd->getParamDecl(j)->getType()->isReferenceType()
                if by_ref && self.obj(&b, call->getArg(i)) {
                    return true
                }
            }

            return false
        }

        return false
    }

    /// `e_in` is a pointer to (part of) the object.
    priv fn ptr(self, @inout b: CxxMoveWalk::Body, e_in: unsafe *const clang::Expr) -> bool {
        var unsafe *e = Self::strip(e_in)
        if e == &null {
            return false
        }

        if llvm::isa<clang::CXXThisExpr>(e) {
            return b.this_root
        }

        var unsafe *d = llvm::dyn_cast<clang::DeclRefExpr>(e)
        if d != &null {
            return b.ptrs.count(d->getDecl()) != 0
        }

        var unsafe *u = llvm::dyn_cast<clang::UnaryOperator>(e)
        if u != &null {
            return u->getOpcode() == clang::UO_AddrOf && self.obj(&b, u->getSubExpr())
        }

        var unsafe *call = llvm::dyn_cast<clang::CallExpr>(e)
        if call != &null {
            // `std::addressof(x)`.
            if call->getBuiltinCallee() != 0
                && call->getNumArgs() == 1
                && call->getType()->isPointerType() {
                return self.obj(&b, call->getArg(0))
            }
        }

        return false
    }

    priv static fn mutable_ref(t: clang::QualType) -> bool {
        return t->isLValueReferenceType() && !t.getNonReferenceType().isConstQualified()
    }

    priv static fn mutable_ptr(t: clang::QualType) -> bool {
        return t->isPointerType() && !t->getPointeeType().isConstQualified()
    }

    /// A reference to a pointer to non-const (`T*&`, `T* const&`): it
    /// reaches the object the pointer points at.
    priv static fn ptr_ref(t: clang::QualType) -> bool {
        return t->isReferenceType() && Self::mutable_ptr(t.getNonReferenceType())
    }

    /// `a`, bound to a parameter of type `pt`, reaches the object through
    /// something a body can move it out of.
    priv fn reaches(self,
                    @inout b: CxxMoveWalk::Body,
                    pt:       clang::QualType,
                    a:        unsafe *const clang::Expr) -> bool {
        if Self::ptr_ref(pt) || Self::mutable_ptr(pt) {
            return self.ptr(&b, a)
        }

        return Self::mutable_ref(pt) && self.obj(&b, a)
    }

    priv fn found_move(self, @inout b: CxxMoveWalk::Body, at: unsafe *const clang::Expr) {
        if b.moved.kind == 1 {
            return
        }

        b.moved.kind   = 1
        b.moved.inside = b.fn_
        b.moved.begin  = at->getBeginLoc()
        b.moved.end    = at->getEndLoc()
    }

    /// `a` is Unknown or Assumed: kept when it is the first of its kind.
    priv fn note_unknown(self, @inout b: CxxMoveWalk::Body, const a: CxxMoveAnswer) {
        if a.kind == 3 {
            if b.assumed.kind != 3 {
                b.assumed = a
            }

            return
        }

        if b.unknown.kind != 2 {
            b.unknown = a
        }
    }

    /// The object reaches `callee`'s parameter `j` (-1 the implicit
    /// object) at the call `at`: follow it.
    priv fn follow(self,
                   @inout b: CxxMoveWalk::Body,
                   callee:   unsafe *const clang::FunctionDecl,
                   j:        i32,
                   at:       unsafe *const clang::Expr) {
        if b.depth + 1 > self.max_depth {
            self.capped = true
            self.note_unknown(
                &b,
                Self::unknown(4, b.fn_, callee, at->getSourceRange()),
            )

            return
        }

        var a = self.param(callee, j, b.depth + 1)
        if a.kind == 1 {
            b.moved = a
            return
        }

        if a.kind == 2 || a.kind == 3 {
            // The call in this body is where the reader can look.
            var u = a
            if !u.begin.isValid() {
                u.inside = b.fn_
                u.begin  = at->getBeginLoc()
                u.end    = at->getEndLoc()
            }

            self.note_unknown(&b, u)
        }
    }

    /// The arguments of a call to `callee`, the first `off` of them not
    /// bound to a declared parameter. A call through a pointer has no callee
    /// (null) and the pointer's prototype `proto` (null: none): what it
    /// binds to a reference or pointer to non-const cannot be followed.
    priv fn args(self,
                 @inout b: CxxMoveWalk::Body,
                 callee:   unsafe *const clang::FunctionDecl,
                 as_:      unsafe *const (unsafe *const clang::Expr),
                 n:        u32,
                 off:      u32,
                 at:       unsafe *const clang::Expr,
                 proto:    unsafe *const clang::FunctionProtoType = &null) {
        for var i: u32 = off; i < n; ++i {
            if b.moved.kind == 1 {
                return
            }

            var unsafe *a     = unsafe as_[i]
            const      j: u32 = i - off
            if callee == &null {
                if !self.obj(&b, a) && !self.ptr(&b, a) {
                    continue
                }

                if proto != &null && j < proto->getNumParams() {
                    var pt = proto->getParamType(j)
                    if pt->isRValueReferenceType() && !pt.getNonReferenceType().isConstQualified() {
                        if self.obj(&b, a) {
                            self.found_move(&b, a)
                        }

                        continue
                    }

                    // By value (a copy), or a reference or pointer to const.
                    if !self.reaches(&b, pt, a) {
                        continue
                    }
                }

                self.note_unknown(
                    &b,
                    Self::unknown(3, b.fn_, &null, at->getSourceRange()),
                )

                continue
            }

            if j >= callee->getNumParams() {
                // A C `...` argument has no declared type: the body reads it
                // back with `va_arg` as any type it names, so a pointer to
                // non-const that reaches the object cannot be followed.
                if Self::mutable_ptr(a->getType()) && self.ptr(&b, a) {
                    var u = Self::unknown(
                        7,
                        b.fn_,
                        callee,
                        at->getSourceRange(),
                    )

                    // The toolchain's own library with no visible body is
                    // Assumed, as compute() answers for a declared parameter.
                    var def: unsafe *const clang::FunctionDecl = &null
                    if self.roots != &null && !callee->hasBody(&def) {
                        const lib = self.roots->library_of(
                            self.S->getSourceManager(),
                            callee,
                        )

                        if lib != 0 {
                            u.kind = 3
                            u.why  = lib
                        }
                    }

                    self.note_unknown(&b, u)
                }

                continue
            }

            var pt = callee->getParamDecl(j)->getType()
            if pt->isRValueReferenceType() && !pt.getNonReferenceType().isConstQualified() {
                if self.obj(&b, a) {
                    self.found_move(&b, a)
                }

                continue
            }

            if self.reaches(&b, pt, a) {
                self.follow(&b, callee, j as i32, at)
            }
        }
    }

    priv fn is_virtual_call(self,
                            md:     unsafe *const clang::CXXMethodDecl,
                            callee: unsafe *const clang::Expr) -> bool {
        if md == &null || !md->isVirtual() {
            return false
        }

        if md->hasAttr<clang::FinalAttr>() || md->getParent()->hasAttr<clang::FinalAttr>() {
            return false
        }

        var unsafe *me = llvm::dyn_cast<clang::MemberExpr>(
            callee->IgnoreParens(),
        )

        return me == &null || !me->hasQualifier()
    }

    /// The implicit object of a call to `md` is the object: an `&&`
    /// method moves it, a non-const one is followed.
    priv fn object(self,
                   @inout b: CxxMoveWalk::Body,
                   md:       unsafe *const clang::CXXMethodDecl,
                   callee:   unsafe *const clang::Expr,
                   at:       unsafe *const clang::Expr) {
        if md == &null || md->isStatic() || b.moved.kind == 1 {
            return
        }

        if md->getRefQualifier() == clang::RQ_RValue {
            self.found_move(&b, at)
            return
        }

        if md->isConst() {
            return
        }

        if self.is_virtual_call(md, callee) {
            self.note_unknown(
                &b,
                Self::unknown(2, b.fn_, md, at->getSourceRange()),
            )

            return
        }

        self.follow(&b, md, -1, at)
    }

    priv fn call(self, @inout b: CxxMoveWalk::Body, c: unsafe *const clang::CallExpr) {
        var unsafe *fd = c->getDirectCallee()
        if fd != &null && fd->getBuiltinID() != 0 {
            return
        }

        var unsafe **as_     = c->getArgs()
        const      n:    u32 = c->getNumArgs()
        var unsafe *mc       = llvm::dyn_cast<clang::CXXMemberCallExpr>(c)
        if mc != &null {
            // `(o.*pm)(...)`: the member it calls is not known.
            var unsafe *pm = llvm::dyn_cast<clang::BinaryOperator>(
                mc->getCallee()->IgnoreParens(),
            )

            if pm != &null {
                if pm->isPtrMemOp() {
                    const on = if pm->getOpcode() == clang::BO_PtrMemI => self.ptr(
                                   &b,
                                   pm->getLHS(),
                               )
                               else => self.obj(&b, pm->getLHS())
                    if on {
                        self.note_unknown(
                            &b,
                            Self::unknown(3, b.fn_, &null, c->getSourceRange()),
                        )
                    }

                    self.args(
                        &b,
                        &null,
                        as_,
                        n,
                        0,
                        c,
                        Self::proto_of(pm->getRHS()->getType()),
                    )

                    return
                }
            }

            var unsafe *md = mc->getMethodDecl()
            var unsafe *me = llvm::dyn_cast<clang::MemberExpr>(
                mc->getCallee()->IgnoreParens(),
            )

            if me != &null
                && (if me->isArrow() => self.ptr(&b, me->getBase())
                    else => self.obj(&b, me->getBase())) {
                self.object(&b, md, mc->getCallee(), c)
            }

            // A virtual callee's arguments: an override, which has the same
            // parameter types, may move what a `U&` / `U*` to non-const
            // reaches. A copy, a reference or pointer to const, and a `T&&`
            // (a move whatever runs: args() below) need no body.
            if self.is_virtual_call(md, mc->getCallee()) {
                for var i: u32 = 0; i < n && i < md->getNumParams(); ++i {
                    var pt = md->getParamDecl(i)->getType()
                    if self.reaches(&b, pt, unsafe as_[i]) {
                        self.note_unknown(
                            &b,
                            Self::unknown(2, b.fn_, md, c->getSourceRange()),
                        )
                    }
                }
            }

            self.args(&b, md, as_, n, 0, c)
            return
        }

        if llvm::isa<clang::CXXOperatorCallExpr>(c)
            && fd != &null
            && llvm::isa<clang::CXXMethodDecl>(fd) {
            var unsafe *md = llvm::cast<clang::CXXMethodDecl>(fd)
            if n > 0 && self.obj(&b, unsafe as_[0]) {
                self.object(&b, md, c->getCallee(), c)
            }

            self.args(&b, fd, as_, n, 1, c)
            return
        }

        self.args(
            &b,
            fd,
            as_,
            n,
            0,
            c,
            if fd == &null => Self::proto_of(c->getCallee()->getType()) else => &null,
        )
    }

    /// The prototype a callee expression of type `t_in` calls through: a
    /// function, a pointer or reference to one, a pointer to member function.
    priv static fn proto_of(t_in: clang::QualType) -> unsafe *const clang::FunctionProtoType {
        if t_in.isNull() {
            return &null
        }

        var        t   = t_in
        var unsafe *pt = t->getAs<clang::PointerType>()
        if pt != &null {
            t = pt->getPointeeType()
        } else {
            var unsafe *rt = t->getAs<clang::ReferenceType>()
            if rt != &null {
                t = rt->getPointeeType()
            } else {
                var unsafe *mp = t->getAs<clang::MemberPointerType>()
                if mp != &null {
                    t = mp->getPointeeType()
                }
            }
        }

        return t->getAs<clang::FunctionProtoType>()
    }

    /// A lambda's body runs where the closure is called, which the walk does
    /// not follow, so it is read where the lambda is written: what it
    /// captures by reference is the object itself. A capture by copy is the
    /// closure's own (moving it moves nothing of the object), but a copied
    /// pointer still points at it. Capture initialisers are walked by the
    /// caller as any expression.
    priv fn lambda(self, @inout b: CxxMoveWalk::Body, l: unsafe *const clang::LambdaExpr) {
        var in_ = b
        for cap in l->captures() {
            if cap.getCaptureKind() == clang::LCK_StarThis {
                in_.this_root = false
            }

            // A copied pointer still points at the object; only a copied
            // reference's object is the closure's own.
            if cap.capturesVariable() && cap.getCaptureKind() == clang::LCK_ByCopy {
                in_.objs.erase(cap.getCapturedVar())
            }
        }

        in_.moved   = CxxMoveAnswer()
        in_.unknown = CxxMoveAnswer()
        in_.assumed = CxxMoveAnswer()
        self.walk(&in_, l->getBody())
        if in_.moved.kind == 1 {
            b.moved = in_.moved
            return
        }

        if in_.unknown.kind == 2 {
            self.note_unknown(&b, in_.unknown)
        }

        if in_.assumed.kind == 3 {
            self.note_unknown(&b, in_.assumed)
        }
    }

    priv fn walk(self, @inout b: CxxMoveWalk::Body, s: unsafe *const clang::Stmt) {
        if s == &null || b.moved.kind == 1 {
            return
        }

        // Unevaluated operands (`noexcept(T(std::move(p)))`, `sizeof`) run nothing.
        if llvm::isa<clang::CXXNoexceptExpr>(s)
            || llvm::isa<clang::UnaryExprOrTypeTraitExpr>(s)
            || llvm::isa<clang::RequiresExpr>(s) {
            return
        }

        var unsafe *t = llvm::dyn_cast<clang::CXXTypeidExpr>(s)
        if t != &null {
            if !t->isPotentiallyEvaluated() {
                return
            }
        }

        var unsafe *ds = llvm::dyn_cast<clang::DeclStmt>(s)
        if ds != &null {
            for d in ds->decls() {
                var unsafe *v = llvm::dyn_cast<clang::VarDecl>(d)
                if v == &null || v->getInit() == &null {
                    continue
                }

                // A local alias of the object: `T& r = p;`, `T* q = p;`.
                var vt = v->getType()
                if vt->isReferenceType() && self.obj(&b, v->getInit()) {
                    b.objs.insert(v)
                }

                if vt->isPointerType() && self.ptr(&b, v->getInit()) {
                    b.ptrs.insert(v)
                }
            }
        }

        var unsafe *l = llvm::dyn_cast<clang::LambdaExpr>(s)
        if l != &null {
            // Its children are the capture initialisers and the body; the
            // body is read by lambda(), with the captures it copies left out.
            for ci in l->capture_inits() {
                if ci != &null {
                    self.walk(&b, ci)
                }
            }

            self.lambda(&b, l)
            return
        }

        var unsafe *c = llvm::dyn_cast<clang::CallExpr>(s)
        if c != &null {
            self.call(&b, c)
        } else {
            var unsafe *ce = llvm::dyn_cast<clang::CXXConstructExpr>(s)
            if ce != &null {
                self.args(
                    &b,
                    ce->getConstructor(),
                    ce->getArgs(),
                    ce->getNumArgs(),
                    0,
                    ce,
                )
            }
        }

        for child in s->children() {
            if b.moved.kind == 1 {
                return
            }

            self.walk(&b, child)
        }
    }
}
