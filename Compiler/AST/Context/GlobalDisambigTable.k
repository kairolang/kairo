/// --- The Kairo Project ------------- AST/Context/GlobalDisambigTable.k --- ///
///
///   Global symbol table aggregating DisambigTable instances from all indexed
///   files. Used for cross-file symbol resolution before parsing.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::ASTContext::*;
import Driver::TUStage::*;   // standalone enum; no cycle
import Resolution::ModulePath::*;
import AST::Node::CanonicalTypes::*;

/// Aggregates all file-level DisambigTable instances for cross-file lookup.
/// Owns all ASTContext instances created during the index phase.
/// Read-only after all files are registered.
class GlobalDisambigTable {
    /// Entry in the global scope table, one per indexed file.
    
    struct GlobalScopeEntry {
        pub var fid:      u32;
        pub var ctx:      own::<ASTContext>;
        pub var hoisted:  obs::<DisambigTable>;  // points into ctx
        pub var mod_path: ModulePath;
    }

    /// THE canonical type store for the whole build. Deliberately NOT per-fid:
    /// Type::canonical's invariant is that `a->canonical == b->canonical` IS
    /// type identity, and monomorphization keys on it. A per-fid store makes
    /// that false the moment two TUs both name `Foo`, which is the common case.
    /// Owns its own arena so canonicals outlive any one fid's ast_alloc reset.
    priv var _types:  CanonicalTypeStore;
    priv var _by_fid: libcxx::unordered_map::<u32, GlobalScopeEntry>;
    priv var _mu:     std::SharedMutex;

    fn GlobalDisambigTable(self) {
        self._by_fid.reserve(128);
    }

    fn op delete (self) {
        for var it = self._by_fid.begin(); it != self._by_fid.end(); ++it {
            if it->second.ctx != &null {
                std::destroy(it->second.ctx);
            }
        }
    }

    // --- Registration (index phase) ------------------------------------------
    
    /// PP-time: creates the ctx if absent. Does NOT index tokens don't exist yet.
    fn get_or_create_context(
        self,
        fid:       u32,
        sm:       *SourceManager,
        tcm:      *TokenCacheManager,
        diag:     *DiagEngine,
        resolver: *ImportResolver,
        ci:       *CompilerInvocation,
        mod_path:  ModulePath
    ) -> *ASTContext {
        {
            var rlock = std::SharedLock(self._mu);
            var it = self._by_fid.find(fid);
            if it != self._by_fid.end() { return it->second.ctx; }
        }

        var ctx = std::create::<ASTContext>(fid, sm, tcm, diag, resolver, ci);
        ctx->module_base = mod_path;

        var lock = std::LockGuard(self._mu);
        var it2 = self._by_fid.find(fid);
        if it2 != self._by_fid.end() {   // lost the race
            std::destroy(ctx);
            return it2->second.ctx;
        }

        var entry: GlobalScopeEntry;
        entry.fid      = fid;
        entry.ctx      = ctx;
        entry.hoisted  = &null;          // set by finish_index
        entry.mod_path = mod_path;
        self._by_fid.insert(libcxx::make_pair(fid, entry));
        return ctx;
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
    fn release_from(self, fid: u32, from: TUStage) -> bool {
        var lock = std::LockGuard(self._mu);
        var it = self._by_fid.find(fid);
        if it == self._by_fid.end() { return false; }
        if it->second.ctx == &null  { return false; }

        it->second.ctx->release_from(from);

        if from <= TUStage::Preprocessing {
            std::destroy(it->second.ctx);
            self._by_fid.erase(it);
        } else if from <= TUStage::Parsing {
            // hoisted lived in the context's index_alloc and release_from
            // cleared the pointer; drop our cached copy so get_scope() cannot
            // hand out a stale table.
            it->second.hoisted = &null;
        }

        return true;
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
    fn begin_index(self, fid: u32) -> *ASTContext {
        var rlock = std::SharedLock(self._mu);
        var it = self._by_fid.find(fid);
        if it == self._by_fid.end() { return &null; }
        if it->second.hoisted != &null { return &null; } // already indexed
        return it->second.ctx;
    }

    /// parse-time, step 2 of 2: publishes ctx->hoisted (allocated by the
    /// Index-mode parser's constructor) into the global entry.
    fn finish_index(self, fid: u32) {
        var lock = std::LockGuard(self._mu);
        var it = self._by_fid.find(fid);
        if it != self._by_fid.end() { it->second.hoisted = it->second.ctx->hoisted; }
    }

    // --- Lookup (parse phase, read-only) -------------------------------------

    fn get_scope(self, fid: u32) -> *DisambigTable {
        var rlock = std::SharedLock(self._mu);
        var it = self._by_fid.find(fid);
        if it == self._by_fid.end() { return &null; }
        return it->second.hoisted;
    }

    fn get_context(self, fid: u32) -> *ASTContext {
        var rlock = std::SharedLock(self._mu);
        var it = self._by_fid.find(fid);
        if it == self._by_fid.end() { return &null; }
        return it->second.ctx;
    }

    /// Looks up an unqualified name in a specific file's scope.
    fn lookup_in(self, fid: u32, name: string) -> LookupResult {
        var scope = self.get_scope(fid);
        if scope == &null { return LookupResult::not_found(); }
        return scope->lookup(name);
    }

    /// Cross-file qualified lookup. Caller resolves the fid from ImportProcessor,
    /// then walks remaining segments in that file's DisambigTable.
    ///
    /// Example: parser sees `Foo::Bar::Baz`
    ///   1. Ask ImportProcessor: what fid does `Foo::Bar` resolve to?
    ///   2. Call lookup_in(fid, "Baz")
    ///   OR pass all segments here and we walk them in the scope trie:
    fn lookup_in(self, fid: u32, segments: *vec::<string>) -> LookupResult {
        var scope = self.get_scope(fid);
        if scope == &null { return LookupResult::not_found(); }
        return scope->lookup(segments);
    }

    fn all_fids(self) -> vec::<u32> {
        var result = vec::<u32>();
        result.reserve(self._by_fid.size());
        for var it = self._by_fid.begin(); it != self._by_fid.end(); ++it {
            result.push_back(it->first);
        }
        return result;
    }

    fn types(self) -> *CanonicalTypeStore { return &self._types; }

    fn size(self) -> usize {
        return self._by_fid.size();
    }

    fn has_fid(self, fid: u32) -> bool {
        return self._by_fid.count(fid) > 0;
    }

    // --- Debug ---------------------------------------------------------------

    fn dump(self) {
        std::print("=== GlobalDisambigTable Dump ===");
        std::print(f"Registered files: {self._by_fid.size()}");
        std::print("");

        for var it = self._by_fid.begin(); it != self._by_fid.end(); ++it {
            var fid   = it->first;
            var entry = &it->second;
            std::print(f"[fid={fid}]");

            if entry->hoisted != &null {
                entry->hoisted->dump();
            }

            std::print("");
        }

        std::print("=== End GlobalDisambigTable ===");
    }
}