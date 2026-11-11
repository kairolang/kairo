/// --- The Kairo Project ------------ AST/Context/GlobalDisambigTable.k --- ///
///
///   The build-wide registry: every file's ASTContext and hoisted scope table,
///   plus the one canonical type store, instantiation registry, lang items and
///   tuple records.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/STLExtras.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "algorithm"

import AST::Context::ASTContext::ASTContext
import AST::Context::CanonicalTypes::CanonicalTypeStore
import AST::Context::DeclContext::DeclContext
import AST::Context::DisambigTable::{
    DisambigTable,
    LookupResult,
}
import AST::Context::InstantiationRegistry::InstantiationRegistry
import AST::Context::TupleRecords::TupleRecords
import AST::LangItems::WellKnownDecls // WellKnownDecls: storage only; the fill is Sema's
import AST::Node::Base::Decl
import Config::Invocation::CompilerInvocation
import Diagnostic::Engine::DiagEngine
import Driver::TUStage::TUStage // standalone enum; no cycle
import Location::SourceManager::SourceManager
import Resolution::ImportProbe::ImportResolver
import Resolution::ModulePath::ModulePath
import Token::TokenCacheManager::TokenCacheManager
import std::io

/// Aggregates all file-level DisambigTable instances for cross-file lookup.
/// Owns all ASTContext instances created during the index phase.
/// Read-only after all files are registered.
pub class GlobalDisambigTable {
    /// Entry in the global scope table, one per indexed file.

    struct GlobalScopeEntry {
        pub var fid:      u32
        pub var ctx:      unsafe *ASTContext
        pub var hoisted:  unsafe *DisambigTable // points into ctx
        pub var mod_path: ModulePath
    }

    /// One page of the lock-free fid mirror (_dir): 4096 fids.
    class DirPage {
        pub var ctx: cxx::std::array<kairo::std::Atomic<unsafe *ASTContext>, 4096> = cxx::std::array<kairo::std::Atomic<unsafe *ASTContext>, 4096>()
        pub var hoisted: cxx::std::array<kairo::std::Atomic<unsafe *DisambigTable>, 4096> = cxx::std::array<kairo::std::Atomic<unsafe *DisambigTable>, 4096>()
        pub var builtin: cxx::std::array<kairo::std::Atomic<bool>, 4096> = cxx::std::array<kairo::std::Atomic<bool>, 4096>()
    }

    /// THE canonical type store for the whole build. Deliberately NOT per-fid:
    /// Type::canonical's invariant is that `a->canonical == b->canonical` IS
    /// type identity, and monomorphization keys on it. A per-fid store makes
    /// that false the moment two TUs both name `Foo`, which is the common case.
    /// Owns its own arena so canonicals outlive any one fid's ast_alloc reset.
    priv var _types: CanonicalTypeStore
    /// fid -> entry, the fid WIDENED to u64: lookups take it unguarded and
    /// u32(-1) is DenseMap<u32>'s empty key. Filled under _mu by TU setup,
    /// which may run in parallel, so neither bucket nor insertion order
    /// means anything: everything that walks it (all_fids, dump) sorts by
    /// fid on the way out.
    priv var _by_fid: llvm::DenseMap<u64, Self::GlobalScopeEntry>
    priv var _mu:     kairo::std::SharedMutex
    /// fid -> (ctx, hoisted, is-builtin), read with NO lock (the
    /// same pattern one layer up). get_context / get_scope / is_builtin_fid took
    /// _mu shared on every call, and MemberLookup::index_extensions alone
    /// calls get_context once per fid per MemberLookup (one per Substitution
    /// lookup): libc++'s shared_mutex is a mutex + condvars, so every reader
    /// serialized on its internal mutex, and on musl that contention sleeps
    /// in the kernel (~400k futex calls a whole-tree check). The lock only
    /// ever guarded _by_fid's growth, never a ctx's lifetime (callers use it
    /// after unlocking), so a mirror whose pages never move hands out the
    /// same pointers. Written under _mu exclusively wherever _by_fid's entry
    /// changes (_publish); 1024 pages x 4096 fids, a page allocated on first
    /// use and freed with the table. _by_fid stays the owner (delete, dump,
    /// all_fids).
    priv var _dir: cxx::std::array<kairo::std::Atomic<unsafe *Self::DirPage>, 1024> = cxx::std::array<kairo::std::Atomic<unsafe *Self::DirPage>, 1024>()
    priv var _instances: InstantiationRegistry

    /// The lang items, ONE table for the build. Per-TU storage cannot serve: every TU re-bound them by unqualified name from its own root,
    /// so a file that never mentioned `Vector` had no handle to it and one that
    /// declared its own shadowed the real one.
    ///
    /// STORAGE only. The fill lives in Sema (NameResolution), because it needs
    /// NameLookup and DeclName -- putting it here would make AST depend on
    /// Sema. This layer owns the table, the builtin fid, and the guarantee that
    /// the fill runs once.
    priv var _well_known:  WellKnownDecls
    priv var _builtin_fid: kairo::std::Atomic<u32> = kairo::std::Atomic<u32>(0) ///< 0 = no builtin root this build.
    /// Every fid under the builtin root, the root included. NOT a bool latch:
    /// the lang items are filled by whichever builtin TU DECLARES each one,
    /// because a leaf is type-resolved before the root that re-exports it.
    /// Stored as _dir's per-fid `builtin` flag (lock-free reads).
    /// The tuple patterns, ONE set for the build (TupleRecords): a tuple
    /// written in two TUs must be one record, as a lang item is one decl.
    priv var _tuples: TupleRecords

    fn GlobalDisambigTable(self) {
        self._by_fid.reserve(128)
    }

    fn op finally (self) {
        for var it = self._by_fid.begin(); it != self._by_fid.end(); ++it {
            if it->second.ctx != &null {
                kairo::std::destroy(it->second.ctx)
            }
        }

        for var i: usize = 0; i < 1024; ++i {
            var unsafe *page = self._dir[i].load(kairo::std::MemoryOrder::relaxed)
            if page != &null {
                kairo::std::destroy(page)
            }
        }
    }

    /// \p fid's mirror page, allocated on first use. Caller holds _mu
    /// exclusively (the only writer of _dir).
    priv fn _page_for_write(self, fid: u32) -> unsafe *Self::DirPage {
        var pi = (fid as usize) >> 12
        if pi >= 1024 {
            kairo::std::ice_fail("GlobalDisambigTable: more than 4M file ids")
        }

        var unsafe *page = self._dir[pi].load(kairo::std::MemoryOrder::relaxed)
        if page == &null {
            page = kairo::std::create<Self::DirPage>()
            self._dir[pi].store(page, kairo::std::MemoryOrder::release)
        }

        return page
    }

    /// Mirrors \p fid's entry into _dir. Caller holds _mu exclusively.
    priv fn _publish(self, fid: u32, ctx: unsafe *ASTContext, hoisted: unsafe *DisambigTable) {
        var unsafe *page = self._page_for_write(fid)
        page->ctx[(fid as usize) & 4095].store(ctx, kairo::std::MemoryOrder::release)
        page->hoisted[(fid as usize) & 4095].store(hoisted, kairo::std::MemoryOrder::release)
    }

    /// Lock-free read side of _dir; null for an unknown fid.
    priv fn _page(self, fid: u32) -> unsafe *Self::DirPage {
        var pi = (fid as usize) >> 12
        if pi >= 1024 {
            return &null
        }

        return self._dir[pi].load(kairo::std::MemoryOrder::acquire)
    }

    /// # Registration (index phase)

    /// PP-time: creates the ctx if absent. Does NOT index tokens don't exist yet.
    pub fn get_or_create_context(self,
                                 fid:            u32,
                                 sm:             *SourceManager,
                                 tcm:            unsafe *TokenCacheManager,
                                 diag:           *DiagEngine,
                                 resolver:       *ImportResolver,
                                 ci:             unsafe *CompilerInvocation,
                                 const mod_path: ModulePath) -> unsafe *ASTContext {
        var unsafe *known = self.get_context(fid)
        if known != &null {
            return known
        }

        var unsafe *ctx = kairo::std::create<ASTContext>(fid, sm, tcm, diag, resolver, ci)
        ctx->module_base = mod_path

        var lock = kairo::std::LockGuard(self._mu)
        var it2  = self._by_fid.find(fid as u64)
        if it2 != self._by_fid.end() { // lost the race
            kairo::std::destroy(ctx)
            return it2->second.ctx
        }

        var entry: Self::GlobalScopeEntry
        entry.fid      = fid
        entry.ctx      = ctx
        entry.hoisted  = &null    // set by finish_index
        entry.mod_path = mod_path
        self._by_fid.try_emplace(fid as u64, entry)
        self._publish(fid, ctx, &null)
        return ctx
    }

    /// \brief releases \p fid's artifacts at \p from and every later stage.
    ///
    /// \details Delegates to ASTContext::release_from, which runs registered
    ///          destructors and resets the arenas at or after that stage. The
    ///          context itself survives unless \p from is Preprocessing or
    ///          earlier, in which case it is destroyed and the entry erased
    ///          the PP is what created it.
    ///
    ///          Idempotent: releasing at or above an already-released level is
    ///          a no-op, and an unknown fid returns false rather than faulting.
    pub fn release_from(self, fid: u32, from: TUStage) -> bool {
        var lock = kairo::std::LockGuard(self._mu)
        var it   = self._by_fid.find(fid as u64)
        if it == self._by_fid.end() {
            return false
        }

        if it->second.ctx == &null {
            return false
        }

        it->second.ctx->release_from(from)

        if (from as u8) <= (TUStage::Preprocessing as u8) {
            // Unpublish before the destroy: a lock-free reader that loads
            // after this sees null, never the freed ctx.
            self._publish(fid, &null, &null)
            kairo::std::destroy(it->second.ctx)
            self._by_fid.erase(it)
        } else if (from as u8) <= (TUStage::Parsing as u8) {
            // hoisted lived in the context's index_alloc and release_from
            // cleared the pointer; drop our cached copy so get_scope() cannot
            // hand out a stale table.
            it->second.hoisted = &null
            self._publish(fid, it->second.ctx, &null)
        }

        return true
    }

    /// \brief takes \p fid's context out of the table WITHOUT destroying
    ///        it, and returns it (null for an unknown fid).
    ///
    /// \details A live check that re-checks a file (Tooling/LiveCheck.k)
    ///          cannot free the old context: the build-wide stores are keyed
    ///          by the addresses of its declarations (a canonical record
    ///          type, an instance's arguments), and an arena that is freed is
    ///          handed out again, so a new declaration would land on an old
    ///          one's address and find its entries. A context that stays
    ///          allocated keeps those entries unreachable. The caller owns
    ///          it from here.
    pub fn detach(self, fid: u32) -> unsafe *ASTContext {
        var lock = kairo::std::LockGuard(self._mu)
        var it   = self._by_fid.find(fid as u64)
        if it == self._by_fid.end() || it->second.ctx == &null {
            return &null
        }

        var unsafe *ctx = it->second.ctx
        self._publish(fid, &null, &null)
        self._by_fid.erase(it)
        return ctx
    }

    /// parse-time, step 1 of 2: claims \p fid for indexing.
    ///
    /// \details the Index-mode parser (ASTParse, constructed by the DRIVER
    ///          this module cannot import Parser without a cycle) runs
    ///          between begin_index and finish_index:
    ///
    ///            var ctx = gs->begin_index(fid);
    ///            if ctx != null {
    ///                ASTParse(ctx, null, gs, ParseMode::Index).index();
    ///                gs->finish_index(fid);
    ///            }
    ///
    /// \return the context to index, or null if the fid is unknown (a
    ///         phase-ordering bug PP must have created it) or already
    ///         indexed.
    pub fn begin_index(self, fid: u32) -> unsafe *ASTContext {
        if self.get_scope(fid) != &null { // already indexed
            return &null
        }

        return self.get_context(fid)
    }

    /// parse-time, step 2 of 2: publishes ctx->hoisted (allocated by the
    /// Index-mode parser's constructor) into the global entry.
    pub fn finish_index(self, fid: u32) {
        var lock = kairo::std::LockGuard(self._mu)
        var it   = self._by_fid.find(fid as u64)
        if it != self._by_fid.end() {
            it->second.hoisted = it->second.ctx->hoisted
            self._publish(fid, it->second.ctx, it->second.hoisted)
        }
    }

    /// # Lookup (parse phase, read-only)

    fn get_scope(self, fid: u32) -> unsafe *DisambigTable {
        var unsafe *page = self._page(fid) // lock-free: see _dir
        if page == &null {
            return &null
        }

        return page->hoisted[(fid as usize) & 4095].load(kairo::std::MemoryOrder::acquire)
    }

    /// The ICE path (CompilerInstance::_flush_for_ice): every context's
    /// buffered sink into \p engine, in fid order, so what each TU reported
    /// before the abort is printed. No lock: the process aborts next, and
    /// the thread that ICE'd may be the one holding it.
    pub fn drain_sinks_for_ice(self, engine: unsafe *DiagEngine) {
        var fids = cxx::std::vector<u64>()
        for var it = self._by_fid.begin(); it != self._by_fid.end(); ++it {
            fids.push_back(it->first)
        }

        cxx::std::sort(fids.begin(), fids.end())
        for var i: usize = 0; i < fids.size(); ++i {
            var it = self._by_fid.find(fids[i])
            if it == self._by_fid.end() {
                continue
            }

            var ctx: unsafe *ASTContext = it->second.ctx
            if ctx != &null {
                ctx->diag_sink.drain_into(engine, ctx->sm)
            }
        }
    }

    pub fn get_context(self, fid: u32) -> unsafe *ASTContext {
        var unsafe *page = self._page(fid) // lock-free: see _dir
        if page == &null {
            return &null
        }

        return page->ctx[(fid as usize) & 4095].load(kairo::std::MemoryOrder::acquire)
    }

    /// Looks up an unqualified name in a specific file's scope.
    pub fn lookup_in(self, fid: u32, const name: string) -> LookupResult {
        var unsafe *scope = self.get_scope(fid)
        if scope == &null {
            return LookupResult::not_found()
        }

        return scope->lookup_existing(name)
    }

    /// Cross-file qualified lookup. Caller resolves the fid from ImportProcessor,
    /// then walks remaining segments in that file's DisambigTable.
    ///
    /// Example: parser sees `Foo::Bar::Baz`
    ///   1. Ask ImportProcessor: what fid does `Foo::Bar` resolve to?
    ///   2. Call lookup_in(fid, "Baz")
    ///   OR pass all segments here and we walk them in the scope trie:
    fn lookup_in(self, fid: u32, segments: unsafe *cxx::std::vector<string>) -> LookupResult {
        var unsafe *scope = self.get_scope(fid)
        if scope == &null {
            return LookupResult::not_found()
        }

        return scope->lookup_existing(segments)
    }

    pub fn all_fids(self) -> cxx::std::vector<u32> {
        var result = cxx::std::vector<u32>()
        result.reserve(self._by_fid.size())
        for var it = self._by_fid.begin(); it != self._by_fid.end(); ++it {
            result.push_back(it->first as u32)
        }

        // Fid order: callers index per fid (MemberLookup) and "which file
        // first" must not follow the hash table.
        llvm::sort(result.begin(), result.end())
        return result
    }

    pub fn types(self) -> unsafe *CanonicalTypeStore {
        return unsafe &self._types
    }

    /// # Lang items

    /// The build's lang-item table. Sema reads it through `sc->well_known`.
    pub fn well_known(self) -> unsafe *WellKnownDecls {
        return unsafe &self._well_known
    }

    /// Recorded by the driver from PPResult once the graph is known.
    pub fn set_builtin_fid(self, fid: u32) {
        self._builtin_fid.store(fid, kairo::std::MemoryOrder::release)
    }

    pub fn builtin_fid(self) -> u32 {
        return self._builtin_fid.load(kairo::std::MemoryOrder::acquire)
    }

    /// Every fid in the builtin subtree, recorded by the driver before sema
    /// runs. Sema cannot derive this itself: the test is on the module path,
    /// whose segments are PreprocessorSymbolTable ids, a name domain no Sema
    /// pass can reach.
    pub fn mark_builtin_fid(self, fid: u32) {
        var lock = kairo::std::LockGuard(self._mu)
        self._page_for_write(fid)->builtin[(fid as usize) & 4095].store(
            true,
            kairo::std::MemoryOrder::release,
        )
    }

    pub fn is_builtin_fid(self, fid: u32) -> bool {
        var unsafe *page = self._page(fid) // lock-free: see _dir
        if page == &null {
            return false
        }

        return page->builtin[(fid as usize) & 4095].load(kairo::std::MemoryOrder::acquire)
    }

    fn size(self) -> usize {
        return (self._by_fid.size() as usize)
    }

    fn has_fid(self, fid: u32) -> bool {
        return self._by_fid.count(fid) > 0
    }

    pub fn instances(self) -> unsafe *InstantiationRegistry {
        return unsafe &self._instances
    }

    /// The record a tuple of \p arity is, minted on first use into the
    /// builtin root (TupleRecords). Null without a root or outside
    /// [2, TUPLE_MAX_ARITY]. \p root_dc: the root TU as a DeclContext --
    /// the caller (Sema) casts, since this layer cannot name TranslationUnit.
    pub fn tuple_pattern(self, arity: usize, root_dc: unsafe *DeclContext) -> unsafe *Decl {
        var fid = self.builtin_fid()
        if fid == 0 {
            return &null
        }

        return self._tuples.pattern(arity, self.get_context(fid), root_dc, unsafe &self._types)
    }

    /// # Debug

    pub fn dump(self) {
        io::println("=== GlobalDisambigTable Dump ===")
        io::println(f"Registered files: {self._by_fid.size()}")
        io::println("")

        for var fid: u32 in self.all_fids() {
            var *entry = &self._by_fid.find(fid as u64)->second
            io::println(f"[fid={fid}]")

            if entry->hoisted != &null {
                entry->hoisted->dump()
            }

            io::println("")
        }

        io::println("=== End GlobalDisambigTable ===")
    }
}
