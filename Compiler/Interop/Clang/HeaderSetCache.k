/// --- The Kairo Project --------------- Interop/Clang/HeaderSetCache.k --- ///
///
///   HeaderSetCache: maps a header-set key to its HeaderSet, one per build.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Path.h"
ffi "c++" import "llvm/ADT/SmallString.h"
ffi "c++" import "cstring"
ffi "c++" import "llvm/ADT/STLExtras.h"
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KShims.hh" // header_set_late_uses
ffi "c++" import "clang/AST/ASTContext.h"
ffi "c++" import "clang/AST/ASTConsumer.h"
ffi "c++" import "clang/Basic/Diagnostic.h"
ffi "c++" import "clang/Basic/DiagnosticOptions.h"
ffi "c++" import "clang/Basic/FileEntry.h"
ffi "c++" import "clang/Basic/SourceManager.h"
ffi "c++" import "clang/Basic/TargetInfo.h"
ffi "c++" import "clang/Frontend/CompilerInstance.h"
ffi "c++" import "clang/Frontend/CompilerInvocation.h"
ffi "c++" import "clang/Frontend/FrontendAction.h"
ffi "c++" import "clang/Frontend/FrontendOptions.h"
ffi "c++" import "clang/Frontend/TextDiagnosticPrinter.h"
ffi "c++" import "clang/Lex/HeaderSearchOptions.h"
ffi "c++" import "clang/Lex/PPCallbacks.h"
ffi "c++" import "clang/Lex/Preprocessor.h"
ffi "c++" import "clang/Sema/Sema.h"
ffi "c++" import "clang/Serialization/ASTWriter.h"
ffi "c++" import "clang/Serialization/PCHContainerOperations.h"
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h"
ffi "c++" import "llvm/Support/Error.h"
ffi "c++" import "llvm/Support/MemoryBuffer.h"
ffi "c++" import "llvm/Support/VirtualFileSystem.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/KTimeReport.hh"
ffi "c++" import "memory"
ffi "c++" import "vector"
ffi "c++" import "string"
ffi "c++" import "set"
ffi "c++" import "utility"
ffi "c++" import "cstdlib"

import Diagnostic::Engine::DiagEngine
import Interop::Clang::ClangBackend::ClangBackend
import Interop::Clang::CodegenPCH::CodegenPCH
import Interop::Clang::HeaderSet::{
    CODEGEN_PCH_GROUP,
    HEADER_BUILD_GROUP,
    HeaderSet,
}
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Threading::ThreadPool::ThreadPool

///
/// \class HeaderSetCache
/// \brief key -> HeaderSet, one per build. Owned by CompilerInstance.
///
pub class HeaderSetCache {
    /// canonical key -> set. StringMap: probed with the key's own bytes.
    /// Minted from the parallel wave, so neither map nor `id` order is
    /// stable; all() sorts by key on the way out.
    priv var _sets: llvm::StringMap<unsafe *HeaderSet>
    /// ordered set ids -> phase B's merged PCH of them (codegen_pch).
    priv var _codegen: llvm::StringMap<unsafe *CodegenPCH>
    priv var _mu:      kairo::std::Mutex
    priv var _be:      unsafe *ClangBackend
    priv var _pool:    *ThreadPool
    /// One clang parse for the build's header lists, not one per list.
    /// request() only records a list (a view); start_shared() parses their
    /// union. -fno-shared-header-set keeps one parse per list.
    priv var _shared_mode: bool                                = true
    priv var _pending:     cxx::std::vector<unsafe *HeaderSet>

    fn HeaderSetCache(self, be: unsafe *ClangBackend, pool: *ThreadPool, shared: bool) {
        self._be          = be
        self._pool        = pool
        self._shared_mode = shared
    }

    fn op finally (self) {
        for var it = self._sets.begin(); it != self._sets.end(); ++it {
            kairo::std::destroy(it->second)
        }

        self._sets.clear()
        for var it = self._codegen.begin(); it != self._codegen.end(); ++it {
            kairo::std::destroy(it->second)
        }

        self._codegen.clear()
    }

    /// The language is part of the key: one header imported as C and as C++
    /// is two parses with two linkages, never one shared set.
    static fn key_of(const headers:   cxx::std::vector<string>,
                     const c_linkage: cxx::std::vector<u8>) -> string {
        var k: string = ""
        for var i: usize = 0; i < headers.size(); ++i {
            if i < c_linkage.size() && c_linkage[i] != 0 {
                k += "c:"
            }

            k += headers[i]
            k += "\n"
        }

        return k
    }

    /// Get-or-mint. Mint enqueues the build. Any thread: PPWalker::_finalize
    /// calls this from the pool (the wave walks files in parallel); `_mu`
    /// covers the map, and the build touches only the set it was given.
    pub fn request(self,
                   headers:          cxx::std::vector<string>,
                   c_linkage:        cxx::std::vector<u8>,
                   locs:             cxx::std::vector<SourceRange>,
                   const import_dir: string) -> unsafe *HeaderSet {
        var key  = HeaderSetCache::key_of(headers, c_linkage)
        var lock = kairo::std::LockGuard(self._mu)
        var it   = self._sets.find(kairo::sref(key))
        if it != self._sets.end() {
            return it->second
        }

        var unsafe *hs = kairo::std::create<HeaderSet>()
        hs->key         = key
        hs->headers     = headers
        hs->c_linkage   = c_linkage
        hs->header_locs = locs
        hs->import_dir  = import_dir
        hs->id          = (self._sets.size())
        self._sets.try_emplace(kairo::sref(key), hs)

        if self._shared_mode {
            self._pending.push_back(hs) // parsed by start_shared, with the others.
            return hs
        }

        self._enqueue_build(hs)
        return hs
    }

    /// Not priv: start_shared's pool task calls it through a captured pointer.
    fn _enqueue_build(self, set: unsafe *HeaderSet) {
        var unsafe *be  = self._be
        var unsafe *rec = kairo::TimeReport::region(r"HeaderSets")
        self._pool->enqueue(
            kairo::SmallFunction<64>(
                fn () |set, be, rec| {
                    var _kt = kairo::TimeReport::Worker(rec)
                    set->build(be)
                },
            ),
            HEADER_BUILD_GROUP,
        )
    }

    /// Where a view's spelled header resolves: its importer's directory first,
    /// as that set's quoted -I entry made it, else the spelling itself, which
    /// every set resolves alike through the shared search path.
    pub static fn resolve_spelling(view: unsafe *HeaderSet, h: string) -> string {
        if view->import_dir.size() > 0 {
            var cand = view->import_dir + "/" + h
            if llvm::sys::fs::exists(llvm::Twine(kairo::sref(cand))) {
                // Lexically normal: `Inputs/../x.h` from one list and `x.h`
                // from another's directory are one file, and must be one
                // union line and one closure key, or the second spelling's
                // lookup finds a path the parse never recorded.
                var norm: llvm::SmallString<256>
                norm.append(kairo::sref(cand))
                llvm::sys::path::remove_dots(&norm, true)
                return string(
                    unsafe ((norm.data() as unsafe *const u8) as *const u8),
                    norm.size(),
                )
            }
        }

        return h
    }

    /// \brief Parse every list request() recorded since the last call
    ///        as ONE set, on the pool; each list's set becomes a view of it.
    ///
    /// \details Driver thread, after a preprocess. The union takes the lists
    ///          by key (a stable order), each header once (by resolved path and
    ///          linkage; include guards make a repeat a no-op anyway), and each
    ///          line's source location from the first list that names it, so a
    ///          header error lands on that import. Per-list parses instead --
    ///          today's behaviour -- when there is one list, when one header is
    ///          imported both as C and as C++, or when the union fails to
    ///          parse (its diagnostics are dropped; the per-list parses report).
    pub fn start_shared(self) {
        var views = cxx::std::vector<unsafe *HeaderSet>()
        {
            var lock = kairo::std::LockGuard(self._mu)
            views = self._pending
            self._pending.clear()
        }

        if views.size() == 0 {
            return
        }

        if views.size() == 1 {
            self._enqueue_build(views[0])
            return
        }

        llvm::sort(
            views.begin(),
            views.end(),
            fn (a: unsafe *const HeaderSet, b: unsafe *const HeaderSet) || -> bool = a->key < b->key,
        )

        var u_headers = cxx::std::vector<string>()
        var u_c       = cxx::std::vector<u8>()
        var u_locs    = cxx::std::vector<SourceRange>()
        var seen      = llvm::StringMap<bool>()         // resolved -> c linkage
        var conflict  = false
        for var v: *HeaderSet in views {
            for var i: usize = 0; i < v->headers.size(); ++i {
                var r  = HeaderSetCache::resolve_spelling(v, v->headers[i])
                var c  = i < v->c_linkage.size() && v->c_linkage[i] != 0
                var it = seen.find(kairo::sref(r))
                if it != seen.end() {
                    if it->second != c {
                        conflict = true
                    }

                    continue
                }

                seen.try_emplace(kairo::sref(r), c)
                u_headers.push_back(r)
                u_c.push_back(c as u8)
                var at = SourceRange::invalid()
                if i < v->header_locs.size() {
                    at = v->header_locs[i]
                }

                u_locs.push_back(at)
            }
        }

        if conflict {
            for var v: unsafe *HeaderSet in views {
                self._enqueue_build(v)
            }

            return
        }

        var unsafe *u = kairo::std::create<HeaderSet>()
        u->key         = "<shared>\n" + HeaderSetCache::key_of(u_headers, u_c)
        u->headers     = u_headers
        u->c_linkage   = u_c
        u->header_locs = u_locs
        u->import_dir  = "" // every quoted header is resolved above.
        {
            var lock = kairo::std::LockGuard(self._mu)
            u->id = (self._sets.size())
            self._sets.try_emplace(kairo::sref(u->key), u)
        }

        var unsafe *job = kairo::std::create<cxx::std::vector<unsafe *HeaderSet>>(
            views,
        )

        var unsafe *be  = self._be
        var        *me  = &self
        var unsafe *rec = kairo::TimeReport::region(r"HeaderSets")
        self._pool->enqueue(
            kairo::SmallFunction<64>(
                fn () |u, job, be, me, rec| {
                    var _kt = kairo::TimeReport::Worker(rec)
                    u->build(be)
                    if u->ok {
                        for var v: unsafe *HeaderSet in *job {
                            v->shared = u
                        }
                    } else {
                        // The views report what is wrong, each as its own parse did.
                        u->discard_diags()
                        for var v: unsafe *HeaderSet in *job {
                            me->_enqueue_build(v)
                        }
                    }

                    kairo::std::destroy(job)
                },
            ),
            HEADER_BUILD_GROUP,
        ) // start_shared: the union parse.
    }

    fn find(self, const key: string) -> unsafe *HeaderSet {
        var lock = kairo::std::LockGuard(self._mu)
        var it   = self._sets.find(kairo::sref(key))
        if it == self._sets.end() {
            return &null
        }

        return it->second
    }

    pub fn wait_all(self) {
        self._pool->wait_group(HEADER_BUILD_GROUP)
    }

    pub fn all(self, @inout out: cxx::std::vector<unsafe *HeaderSet>) {
        var lock  = kairo::std::LockGuard(self._mu)
        var first = out.size()
        for var it = self._sets.begin(); it != self._sets.end(); ++it {
            out.push_back(it->second)
        }

        // By canonical key: the one order independent of which wave thread
        // minted a set first.
        llvm::sort(
            out.begin() + (first as isize),
            out.end(),
            fn (a: unsafe *const HeaderSet, b: unsafe *const HeaderSet) || -> bool = a->key < b->key,
        )
    }

    /// Every set's buffered build diagnostics into `engine`. Sema drains per
    /// importing TU; a run that stops before Sema (a parse error) never
    /// does, and an undrained BufferedDiagSink ICEs when the set dies.
    pub fn drain_all(self, engine: unsafe *DiagEngine, sm: unsafe *SourceManager) {
        self.wait_all()
        var sets: cxx::std::vector<unsafe *HeaderSet>
        self.all(&sets)
        for var i: usize = 0; i < sets.size(); ++i {
            sets[i]->drain_diags(engine, sm)
        }
    }

    /// \brief phase B's one PCH for \p sets, in that order; built on first
    ///        request, then shared by every TU that asks for the same list.
    ///
    /// After wait_all(): it reads every set's includes. Built on the pool
    /// while Sema runs when prebuild_codegen_pch() was given the same list;
    /// the driver joins CODEGEN_PCH_GROUP before asking, so a hit is always
    /// a finished build. The cache owns it because each codegen TU's VFS
    /// mounts its bytes without a copy, so they must outlive every TU.
    pub fn codegen_pch(self,
                       @inout sets: cxx::std::vector<unsafe *HeaderSet>) -> unsafe *CodegenPCH {
        var key = ""
        for var i: usize = 0; i < sets.size(); ++i {
            key += f"{sets[i]->id}-"
        }

        var p: unsafe *CodegenPCH = &null
        {
            var lock = kairo::std::LockGuard(self._mu)
            var it   = self._codegen.find(kairo::sref(key))
            if it != self._codegen.end() {
                return it->second
            }

            p       = kairo::std::create<CodegenPCH>()
            p->path = f"{HeaderSet::vfs_root()}/pch/codegen-{self._codegen.size()}.pch"
            self._codegen.try_emplace(kairo::sref(key), p)
        }

        // Outside the lock: a 50 ms parse must not stall request()/find()
        // from the threads Sema is running on.
        p->build(self._be, &sets)
        return p
    }

    /// \brief starts codegen_pch(\p sets) on the pool, off the critical
    ///        path: it then overlaps Sema and the lowerings instead of
    ///        running on the driver thread at the start of codegen.
    ///
    /// \details Driver thread, after wait_all(). \p rec is the region the
    ///          build is billed under. The caller joins CODEGEN_PCH_GROUP
    ///          before its own codegen_pch() call, which then hits.
    pub fn prebuild_codegen_pch(self,
                                sets: cxx::std::vector<unsafe *HeaderSet>,
                                rec:  unsafe *kairo::KTimeRecord) {
        var unsafe *job = kairo::std::create<cxx::std::vector<unsafe *HeaderSet>>(
            sets,
        )

        var unsafe *me = unsafe &self
        self._pool->enqueue(
            kairo::SmallFunction<64>(
                fn () |me, job, rec| {
                    var _kt = kairo::TimeReport::Worker(rec)
                    me->codegen_pch(&*job)
                    kairo::std::destroy(job)
                },
            ),
            CODEGEN_PCH_GROUP,
        )
    }

    pub fn wait_codegen_pch(self) {
        self._pool->wait_group(CODEGEN_PCH_GROUP)
    }

    pub fn release_all(self) {
        // A build still in flight owns the very clang::CompilerInstance
        // release() destroys. --syntax-only and --preprocess stop before
        // _sema(), which is the only other place phase A is joined, so
        // without this drain the driver tears the instance down underneath
        // the parse thread: a SEGV in ~Preprocessor, or a hang.
        self.wait_all()
        // And the merged PCH a stop before codegen never joined: it reads
        // the sets and parses on the backend's invocation.
        self.wait_codegen_pch()
        var lock = kairo::std::LockGuard(self._mu)
        for var it = self._sets.begin(); it != self._sets.end(); ++it {
            it->second->release() // Final: no revival past here, and any later read is a late use.
        }
    }
}
