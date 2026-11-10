/// --- The Kairo Project ------------------ Preprocessor/Preprocessor.k --- ///
///
///   The preprocessor driver: one streaming pass per file, expanding macros.
///
///   a streaming lexer, via a TokenSource stack. Imports and macro defs are
///   consumed into the TU (never emitted); invocations expand by pushing
///   splice frames the same walk re-enters. FFI imports are skipped; FFI
///   blocks are copied through for the parser.
///
///   Order-dependent macro visibility (C-preprocessor semantics, but scoped
///   and with pub/priv/prot). Token macros may NOT expand into import/macro
///   declarations (enforced at def time + emission backstop); lift by
///   deleting those two checks and routing the kinds back into the walk.
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
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KTimeReport.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "vector"
ffi "c++" import "map"
ffi "c++" import "set"
ffi "c++" import "string"
ffi "c++" import "algorithm"

import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::Context::TranslationUnit::TranslationUnit
import AST::LangItems::builtin_root_name
import AST::Node::Declarations::MacroDecl
import Config::Invocation::CompilerInvocation
import Config::Preprocessor::PreprocessorOptions
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Interop::Clang::HeaderSetCache::HeaderSetCache
import Lexer::Lexer::Lexer
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Preprocessor::DepScanner::{
    DepGraph,
    DepScanner,
}
import Preprocessor::MacroTable::{
    MacroEntry,
    MacroTable,
}
import Preprocessor::PPWalker::PPWalker
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Preprocessor::TokenSource::TokenSource
import Preprocessor::WaveExecutor::WaveExecutor
import Resolution::ImportProbe::ImportResolver
import Resolution::ModulePath::ModulePath
import Support::FileIO::Path::Path
import Support::TimeReport::{
    TimeRegion,
    TimeWorker,
}
import Threading::ThreadPool::ThreadPool
import Token::Token::Token
import Token::TokenBuffer::TokenBuffer
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenKind::TokenKind
import std::c_char

pub struct PPResult {
    pub var ok:   bool                  = false
    pub var fids: cxx::std::vector<u32>         ///< entry's transitive graph, sorted ascending.
    /// The builtin module's fid (`builtin/module.k`), or 0 when there is no
    /// builtin root or the prelude is off. Handed out rather than rediscovered:
    /// the prelude fold already resolved it, and sema cannot find it on its own
    /// -- ModulePath segments are PreprocessorSymbolTable SymbolIDs, a name
    /// domain nothing in Sema can reach.
    pub var builtin_fid: u32 = 0
}

/// A file on an import cycle, lexed and its macros collected ahead of the
/// waves (PreProcessor::_prelex_cycles): the open stream and every token it
/// produced, for _walk_one to replay.
pub struct PrelexedFile {
    var lexer:  unsafe *Lexer
    var tokens: unsafe *cxx::std::vector<Token>
}

//  Batch driver replaces the old PreProcessor::preprocess phases

pub class PreProcessor {
    priv var _sym:      unsafe *PreprocessorSymbolTable
    priv var _macros:   unsafe *MacroTable
    priv var _sm:       *SourceManager
    priv var _tcm:      unsafe *TokenCacheManager
    priv var _diag:     *DiagEngine
    priv var _pool:     *ThreadPool
    priv var _resolver: *ImportResolver
    priv var _gscope:   *GlobalDisambigTable ///< owns per-fid ASTContext/TU now
    priv var _inv:      unsafe *CompilerInvocation
    priv var _headers:  unsafe *HeaderSetCache          = &null ///< borrowed from CompilerInstance; handed to every walker.
    priv var _opts:     PreprocessorOptions
    /// Fid sets/maps here are keyed `fid as u64`: a u32 key would reserve
    /// u32(-1)/(-2) as DenseMap's empty/tombstone keys. None is iterated
    /// where the order shows (_prelexed only to free it).
    priv var _walked: llvm::DenseSet<u64>
    /// Every fid a preprocess() of this batch scanned, with its edges and
    /// module path (DepScanner::set_known). Driver thread only: written after
    /// each walk, read by the next scan.
    priv var _scanned: DepGraph
    /// What reach() has scanned this batch, followed by its later calls.
    priv var _reach_known: DepGraph
    priv var _walked_mu:   kairo::std::SharedMutex // wave tasks are parallel
    /// The builtin module's scope and fid, and every fid in its own import
    /// closure (the builtin files): the macro prelude. Set by preprocess()
    /// when the real builtin root is folded in; read by _walk_one.
    priv var _prelude_scope: ModulePath
    priv var _prelude_fid:   u32                 = 0
    priv var _prelude_files: llvm::DenseSet<u64>
    /// Per file that names `f256` / `f512`: the class files it imports
    /// implicitly (_add_wide_floats). Written before the waves start and
    /// only read while they run (_walk_one).
    priv var _wide_imports: cxx::std::map<u32, cxx::std::vector<u32>>
    /// Files on an import cycle, lexed ahead of the waves. Written before
    /// the waves start and only read while they run (_walk_one).
    priv var _prelexed:       llvm::DenseMap<u64, PrelexedFile>
    priv var _define_storage: cxx::std::vector<cxx::std::string> ///< -D value bytes; load_virtual
    ///  needs them stable for the
    ///  whole compile. reserved
    ///  up front so it never
    ///  reallocates after that.
    priv var _late_define_value: cxx::std::string         ///< define_late's one value
    priv var _late_define_used:  bool             = false

    fn PreProcessor(self,
                    sm:         *SourceManager,
                    tcm:        unsafe *TokenCacheManager,
                    resolver:   *ImportResolver,
                    pool:       *ThreadPool,
                    diag:       *DiagEngine,
                    gscope:     *GlobalDisambigTable,
                    inv:        unsafe *CompilerInvocation,
                    const opts: PreprocessorOptions = PreprocessorOptions(),
                    headers:    unsafe *HeaderSetCache = &null) {
        self._headers  = headers
        self._sym      = kairo::std::create<PreprocessorSymbolTable>()
        self._macros   = kairo::std::create<MacroTable>()
        self._sm       = sm
        self._tcm      = tcm
        self._resolver = resolver
        self._pool     = pool
        self._diag     = diag
        self._gscope   = gscope
        self._opts     = opts
        self._inv      = inv
        self._register_defines()
    }

    /// \brief pre-registers `-D NAME[=VALUE]` as parameterless, pub, global-scope
    ///        macros before any file is walked. Runs once, from the constructor
    ///        not from preprocess(), since preprocess() runs once per input file
    ///        and a second registration attempt would just be silently dropped by
    ///        MacroTable::register's duplicate check while still reallocating
    ///        _define_storage (dangling every buffer load_virtual already handed
    ///        out for the first pass).
    ///
    ///        Each value gets its own virtual file (SourceManager::load_virtual)
    ///        so it goes through the SAME lex path a real macro body would,
    ///        rather than hand-building tokens; that's also what gives the
    ///        macro's tokens a real fid/ImmediateTable pair for later diagnostics.
    ///        Bare `-D FOO` (no `=value`) expands to `1`, matching gcc/clang.
    priv fn _register_defines(self) {
        if self._opts.defines.size() == 0 {
            return
        }

        self._define_storage.reserve(self._opts.defines.size())

        for var i: usize = 0; i < self._opts.defines.size(); ++i {
            var raw = self._opts.defines[i]

            var name:  string
            var value: string
            var eq            = kairo::std::to_std_string(raw).find(('=' as u8) as c_char)
            if eq != cxx::std::string::npos {
                name  = raw.subslice(0, eq)
                value = raw.subslice(eq + 1, raw.size())
            } else {
                name  = raw
                value = "1"
            }

            if name.empty() {
                // "=VALUE" and "" used to be skipped silently, so a typo'd -D
                // looked accepted and the macro just never existed.
                self._diag->report(
                    DiagID::U006E,
                    f"invalid -D argument '{raw}': expected NAME or NAME=VALUE with a non-empty NAME",
                ).emit()
                continue
            }

            self._define_storage.push_back(kairo::std::to_std_string(value))
            self._register_define(name, self._define_storage[self._define_storage.size() - 1])
        }
    }

    /// \brief `NAME` as `-D NAME` would define it (to `1`), after
    ///        construction: the driver's macros it decides on only once the
    ///        inputs are loaded (__KAIRO_GLOBAL_ALLOCATOR_SET). Must run before
    ///        any file is walked, as _register_defines does, or the files
    ///        already walked never saw it. The value is a member of its own,
    ///        never _define_storage, whose growth would dangle the buffers
    ///        already handed to load_virtual; so this holds ONE such macro.
    pub fn define_late(self, const name: string) {
        if self._late_define_used {
            return
        }

        self._late_define_used = true
        var one: string = "1"
        self._late_define_value = kairo::std::to_std_string(one)
        self._register_define(name, self._late_define_value)
    }

    /// One `-D NAME` whose value bytes are \p stored (kept alive by the
    /// caller for the run): its own virtual file, lexed as a macro body.
    priv fn _register_define(self, const name: string, const stored: cxx::std::string) {
        {
            var fid = self._sm->load_virtual(
                Path(f"<command-line>:{name}"),
                unsafe (stored.data() as kairo::std::ConstPtr<u8>),
                stored.size(),
            )

            var unsafe *lexer = self._tcm->open_stream(fid)
            if lexer == &null {
                return
            }

            var unsafe *imm = lexer->get_imm_tbl()

            var unsafe *tcm_tokens    = kairo::std::create<TokenBuffer<512>>()
            var unsafe *macro_storage = kairo::std::create<TokenBuffer<512>>()
            var        src            = TokenSource(lexer)
            while !src.at_eof() {
                var t = src.next()
                if t.kind == TokenKind::TkEof {
                    break
                }

                tcm_tokens->append(t)
                macro_storage->append(t)
            }

            self._tcm->close_stream(fid, tcm_tokens)

            var unsafe *ctx = self._gscope->get_or_create_context(
                fid,
                self._sm,
                self._tcm,
                self._diag,
                self._resolver,
                self._inv,
                ModulePath(),
            )

            var unsafe *tu = ctx->tu
            if tu == &null {
                tu = ctx->alloc_init_pp_cleanup<TranslationUnit>(
                    ctx,
                    fid,
                    ctx->hoisted,
                    self._gscope,
                )

                ctx->tu = tu
            }

            var name_tok = Token()
            name_tok.kind  = TokenKind::LitIdentifier
            name_tok.range = SourceRange::invalid()
            name_tok.imm   = imm->intern_ident_copy(name)

            var unsafe *decl = MacroDecl::create(ctx, SourceRange::invalid(), name_tok)
            decl->accepts_params = false

            var unsafe *entry = kairo::std::create<MacroEntry>()
            entry->decl       = decl
            entry->storage    = macro_storage
            entry->body_len   = (macro_storage->size() as u32)
            entry->name_sym   = self._sym->intern(name)
            entry->scope      = ModulePath() // global: visible from every TU
            entry->source_fid = fid
            entry->visibility = 3 // pub: MacroTable::find's cross-file check needs it

            self._macros->register_macro(entry)
        }
    }

    fn op finally (self) {
        kairo::std::destroy(self._macros)
        kairo::std::destroy(self._sym)
    }

    pub fn get_macro_table(self) -> unsafe *MacroTable {
        return self._macros
    }

    pub fn get_symbol_table(self) -> unsafe *PreprocessorSymbolTable {
        return self._sym
    }

    /// \brief drops \p fid from the walked set so a later preprocess() will
    ///        walk it again.
    ///
    /// \details _walked is the DAG dedup: within one batch a fid shared by two
    ///          inputs is preprocessed once. That is correct for a batch, where
    ///          nothing is ever released, and WRONG the moment a fid's
    ///          artifacts are torn down   the walk is what creates the
    ///          ASTContext and the TranslationUnit, so a released-then-reparsed
    ///          fid that is still marked walked comes back with no context at
    ///          all and only the diagnostics its importers happened to raise.
    ///
    ///          This has been load-bearing in reverse: because release(Loading)
    ///          also dropped the SourceManager entry, every reparse minted a
    ///          BRAND NEW fid, which never matched _walked and so always
    ///          re-walked. The fid leak was what made reparse appear to work.
    ///          Keeping a fid stable across a release is only correct once the
    ///          walked set is invalidated with it.
    ///
    /// \note ALSO drops this fid's macros. MacroEntry::decl is an obs<MacroDecl>
    ///       into the fid's ASTContext, so entries must not outlive it. Leaving
    ///       them is worse than a dangling read: register()'s duplicate check
    ///       keeps the FIRST entry for a (scope, name) and destroys the later
    ///       one, so the next walk's freshly-built macro is discarded in favour
    ///       of the stale one and the table converges on all-dangling decls.
    ///
    /// \return false if \p fid was neither walked nor had macros.
    pub fn forget(self, fid: u32) -> bool {
        var dropped = self._macros->forget_fid(fid)

        var wlock = kairo::std::UniqueLock(self._walked_mu)
        if !self._walked.erase(fid as u64) {
            return dropped > 0
        }

        return true
    }

    /// Live macro entries across all fids. See MacroTable::size.
    fn macro_count(self) -> usize {
        return self._macros->size()
    }

    /// \brief clears the whole walked set. For a full batch reset.
    fn forget_all(self) {
        var wlock = kairo::std::UniqueLock(self._walked_mu)
        self._walked.clear()
    }

    /// \brief every fid \p entry_fid's own imports reach, itself included:
    ///        the scan preprocess() starts with, without the prelude or
    ///        --force-include, and without walking anything. For ordering
    ///        the batch's inputs before the first walk (CompilerInstance).
    pub fn reach(self, entry_fid: u32) -> cxx::std::set<u32> {
        self._resolver->wait_for_index()
        var scanner = DepScanner(
            self._sm,
            self._tcm,
            self._resolver,
            self._sym,
            self._opts.max_import_depth,
        )

        // Every earlier reach's edges are followed, not rescanned. The
        // driver asks this of every input (_kairo_order, and the global
        // allocator check): a fresh scan each time lexed the whole closure
        // once PER INPUT, and 305 inputs sharing one closure spent ~150 s
        // in 1.2 million lexer runs before the first file was compiled.
        // Kept apart from _scanned: an entry here has no module
        // path of its own, and preprocess() must still walk what only this
        // has seen.
        scanner.set_known(unsafe &self._reach_known)
        var graph = scanner.build_graph(entry_fid, ModulePath())
        for fid in graph.all_fids {
            if self._reach_known.all_fids.contains(fid) {
                continue
            }

            self._reach_known.add_node(fid, graph.mod_paths[fid])
            self._reach_known.deps[fid] = graph.deps[fid]
        }

        return graph.all_fids
    }

    /// \brief true if \p fid has already been walked in this batch.
    fn has_walked(self, fid: u32) -> bool {
        var rlock = kairo::std::SharedLock(self._walked_mu)
        return self._walked.contains(fid as u64)
    }

    /// \brief preprocesses exactly one fid: lex it, walk it, build its
    ///        ASTContext and TranslationUnit.
    ///
    /// \details The unit of work the wave executor dispatches, factored out so
    ///          a single file can be re-walked without re-walking the graph
    ///          around it (see preprocess_one).
    ///
    /// \return false if the fid was already walked, too large, or would not lex.
    priv fn _walk_one(self, fid: u32, mod_path: ModulePath) -> bool {
        {
            // claim-on-entry is safe ONLY because execute() runs input files
            // sequentially. if FrontendActions ever parallelize, this needs a
            // per-fid completion latch, not a claimed-set.
            var wlock = kairo::std::UniqueLock(self._walked_mu)
            if !self._walked.insert(fid as u64).second {
                return false
            }
        }

        if self._opts.max_file_size_mb > 0 {
            // compare exact bytes, not truncated MB: a 1.9MB file under a
            // 1MB cap would otherwise round down to size_mb=1, and 1 > 1
            // is false so the cap silently wouldn't fire until 2x over.
            var size_bytes = self._sm->get_file_size(fid)
            var max_bytes  = (self._opts.max_file_size_mb as usize) * 1024 * 1024
            if size_bytes > max_bytes {
                var size_mb = size_bytes / (1024 * 1024) // display only
                self._diag->report(
                    DiagID::S066E,
                    f"'{self._sm->get_filename(fid)}' is {size_mb}MB, over the {self._opts.max_file_size_mb}MB cap; raise it with --cmax-file-size-mb=N",
                ).emit()
                return false
            }
        }

        // Slot setup plus contention on TokenCacheManager::_lex_mu, which
        // every file in the wave serializes through. If this is anything but
        // noise, the wave is queueing on that one mutex and widening the pool
        // will not help. NOT lex time   see Lexer::next, which bills "Lex".
        var lexer:  unsafe *Lexer                   = &null
        var replay: unsafe *cxx::std::vector<Token> = &null
        var pit                                     = self._prelexed.find(fid as u64)
        if pit != self._prelexed.end() {
            // Opened, lexed and its macros registered by _prelex_cycles.
            lexer  = pit->second.lexer
            replay = pit->second.tokens
        } else {
            var _tl = TimeRegion("Open")
            lexer = self._tcm->open_stream(fid)
        }

        if lexer == &null {
            kairo::Logger::error(
                kairo::Logger::Stage::Preprocessor,
                f"PP: stream open failed fid={fid}",
            )

            return false
        }

        var unsafe *ctx = self._gscope->get_or_create_context(
            fid,
            self._sm,
            self._tcm,
            self._diag,
            self._resolver,
            self._inv,
            mod_path,
        )

        // Re-intern the module path's leaf into this file's imm space. The
        // path is spelled in the PP symbol table; the parser's synthesized
        // ModuleDecl name token needs an imm, and the two are different name
        // domains (see ASTContext::module_leaf_imm).
        if ctx->module_leaf_imm == u32::MAX && ctx->module_base.segments.size() > 0 {
            var        *segs = &ctx->module_base.segments
            var unsafe *leaf = self._sym->resolve((*segs)[segs->size() - 1].name)
            var unsafe *imms = ctx->get_imm_table()
            if leaf != &null && imms != &null {
                ctx->module_leaf_imm = imms->intern_ident_copy(*leaf)
            }
        }

        var unsafe *tu = ctx->tu
        if tu == &null {
            tu = ctx->alloc_init_pp_cleanup<TranslationUnit>(ctx, fid, ctx->hoisted, self._gscope)
            ctx->tu = tu
        }

        var unsafe *walker = kairo::std::create<PPWalker>(
            fid,
            lexer,
            ctx,
            tu,
            self._macros,
            self._resolver,
            self._sym,
            self._sm,
            self._tcm,
            self._diag,
            self._opts,
            mod_path,
            self._headers,
        )

        finally {
            kairo::std::destroy(walker)
        }

        if self._prelude_fid != 0 && !self._prelude_files.contains(fid as u64) {
            walker->set_prelude_scope(self._prelude_scope)
        }

        if replay != &null {
            walker->set_replay(replay)
            walker->assume_macros_known()
        }

        walker->run()
        var wit = self._wide_imports.find(fid)
        if wit != self._wide_imports.end() {
            for var i: usize = 0; i < wit->second.size(); ++i {
                walker->add_implicit_import(wit->second[i])
            }
        }

        return true
    }

    /// Folds builtin::num::<\p leaf> (an f256 / f512 class file) into the
    /// graph for \p users, the files the scan saw name its type. The graph
    /// edge orders the walk; _walk_one then gives each user a prelude-shaped
    /// wildcard import of the file (PPWalker::add_implicit_import), whose
    /// edge orders Sema: the class's N binds its lang item and the
    /// builtin's lang_decl before the user is typed. A builtin file gets
    /// neither: it imports what it uses, and the engine files' edge to the
    /// class would close a cycle (the class imports them).
    priv fn _add_wide_floats(self,
                             scanner:     *DepScanner,
                             graph:       *DepGraph,
                             const leaf:  string,
                             const users: cxx::std::set<u32>) {
        if users.size() == 0 {
            return
        }

        var bsym  = self._sym->intern(builtin_root_name())
        var takes = cxx::std::vector<u32>()
        for f in users {
            if graph->mod_paths.contains(f) {
                var *segs = &graph->mod_paths[f].segments
                if segs->size() > 0 && (*segs)[0].name == bsym {
                    continue
                }
            }

            takes.push_back(f)
        }

        if takes.size() == 0 {
            return
        }

        var segs = cxx::std::vector<string>()
        segs.push_back(builtin_root_name())
        segs.push_back("num")
        segs.push_back(leaf)
        var w_fid = scanner->add_module_dependency(segs, graph)
        if w_fid == 0 || w_fid == u32::MAX {
            return
        }

        for var i: usize = 0; i < takes.size(); ++i {
            if takes[i] == w_fid {
                continue
            }

            graph->add_edge(takes[i], w_fid)
            self._wide_imports[takes[i]].push_back(w_fid)
        }
    }

    /// Every file on an import cycle, opened, lexed in full and its macro
    /// definitions registered BEFORE any file is walked (PPWalker::
    /// collect_macros). The waves walk an importee before its importer, and
    /// on a cycle one import always points the other way: without this, the
    /// file walked first expanded none of the macros of a file it imports.
    /// With it every file on the cycle sees every macro the cycle defines,
    /// in either direction and whatever the walk order. Files off every
    /// cycle are untouched -- lexed once, walked once, as before.
    priv fn _prelex_cycles(self, graph: *DepGraph) {
        for var c: usize = 0; c < graph->cycles.size(); ++c {
            var *cyc = &graph->cycles[c]
            for var i: usize = 0; i < cyc->size(); ++i {
                var fid = (*cyc)[i]
                if self._prelexed.contains(fid as u64) {
                    continue
                }

                {
                    var rlock = kairo::std::SharedLock(self._walked_mu)
                    if self._walked.contains(fid as u64) {
                        continue
                    }
                }

                // Over the size cap: the walk reports it and stops there.
                if self._opts.max_file_size_mb > 0
                    && self._sm->get_file_size(
                        fid,
                    ) > (self._opts.max_file_size_mb as usize) * 1024 * 1024 {
                    continue
                }

                var unsafe *lexer = self._tcm->open_stream(fid)
                if lexer == &null {
                    continue
                }

                var unsafe *toks = kairo::std::create<cxx::std::vector<Token>>()
                var        t     = Token()
                while lexer->next(&t) {
                    toks->push_back(t)
                }

                var mp = graph->mod_paths[fid]
                var unsafe *ctx = self._gscope->get_or_create_context(
                    fid,
                    self._sm,
                    self._tcm,
                    self._diag,
                    self._resolver,
                    self._inv,
                    mp,
                )

                var unsafe *tu = ctx->tu
                if tu == &null {
                    tu = ctx->alloc_init_pp_cleanup<TranslationUnit>(
                        ctx,
                        fid,
                        ctx->hoisted,
                        self._gscope,
                    )

                    ctx->tu = tu
                }

                var unsafe *walker = kairo::std::create<PPWalker>(
                    fid,
                    lexer,
                    ctx,
                    tu,
                    self._macros,
                    self._resolver,
                    self._sym,
                    self._sm,
                    self._tcm,
                    self._diag,
                    self._opts,
                    mp,
                    self._headers,
                )

                walker->set_replay(toks)
                walker->collect_macros()
                kairo::std::destroy(walker)
                var pf = PrelexedFile{}
                pf.lexer                   = lexer
                pf.tokens                  = toks
                self._prelexed[fid as u64] = pf
            }
        }
    }

    /// \brief re-walks ONE fid, leaving the rest of the import graph alone.
    ///
    /// \details The single-file reparse path. No DepScanner, no wave executor,
    ///          no graph: just this file's own lex + walk, against the macro
    ///          and symbol tables the rest of the graph already populated.
    ///
    ///          DELIBERATELY PARTIAL. The imports of \p fid are NOT re-resolved
    ///          or re-walked. If the edit added an import, the target is not
    ///          pulled in and names from it will not resolve   report it rather
    ///          than assume a full preprocess happened. Callers that need the
    ///          graph re-examined must run preprocess() instead.
    ///
    /// \pre \p fid must have been forgotten first (CompilerInstance::invalidate
    ///      does this), otherwise the walked-set check refuses and this is a
    ///      no-op returning false.
    pub fn preprocess_one(self, fid: u32, const mod_path: ModulePath) -> bool {
        self._resolver->wait_for_index()
        return self._walk_one(fid, mod_path)
    }

    /// The `import` in \p from that names \p to, as the walk recorded it,
    /// or an invalid range when there is none.
    priv fn _import_range(self, from: u32, to: u32) -> SourceRange {
        var unsafe *ctx = self._gscope->get_context(from)
        if ctx == &null || ctx->tu == &null {
            return SourceRange::invalid()
        }

        var unsafe *tu = ctx->tu
        for var i: usize = 0; i < tu->import_edges.size(); ++i {
            var unsafe *e = tu->import_edges.get(i)
            if e == &null || e->target_fid != to || e->decl == &null {
                continue
            }

            return e->decl->range
        }

        return SourceRange::invalid()
    }

    /// An import cycle (modules.mdx, Circular Dependencies). \p cyc is its
    /// files in import order, the last importing the first (DepGraph::
    /// cycles). A cycle compiles, but is warned about (R058W): no module on
    /// it can be read, built or tested without the others. -fno-import-
    /// cycles makes it an error (R058E), which stops the build after parse.
    /// The diagnostic is at the import that closes it -- the one the scan
    /// met with its target still open -- and each edge of the cycle gets a
    /// note at its own import, so the whole loop reads off it. No fix-it
    /// for a real cycle: which import to drop, or what to move into a third
    /// module, is a design call. A self-import is the exception: it only
    /// closes the cycle, and the fix-it removes it.
    priv fn _report_cycle(self, @inout cyc: cxx::std::vector<u32>) {
        var n = cyc.size()
        if n == 0 {
            return
        }

        // A cycle through the builtin root is the builtin's own, and allowed:
        // a builtin file that names a lang item module.k declares (alloc.k's
        // `T?` needs Nullable) imports the root back. Once a container in the
        // prelude imports such a file, every compile would carry the warning
        // about a library the user cannot change. No user file closes one: the
        // root imports none.
        for var i: usize = 0; i < n; ++i {
            if (cyc)[i] != 0 && (cyc)[i] == self._prelude_fid {
                return
            }
        }

        var path = ""
        for var i: usize = 0; i < n; ++i {
            path += Path::filename_of(self._sm->get_filename((cyc)[i]))
            path += " -> "
        }

        path += Path::filename_of(self._sm->get_filename((cyc)[0]))
        var last   = (cyc)[n - 1]
        var first  = (cyc)[0]
        var at     = self._import_range(last, first)
        var forbid = self._opts.import_cycles == 0
        var head   = f"import cycle: {path}"
        if n == 1 {
            head = f"'{Path::filename_of(self._sm->get_filename(first))}' imports itself"
        }

        var msg = f"{head}; import cycles are disabled (-fno-import-cycles)"
        if !forbid {
            msg = f"{head}; a cycle hinders maintainability: no module on it can be read, built or tested without the others"
        }

        var b = self._diag->report(
            if (forbid) => (DiagID::R058E) else => DiagID::R058W,
            at.start,
            msg,
        )

        b.first(at, "this import closes the cycle")
        if n > 1 {
            for var i: usize = 0; i < n; ++i {
                var a = (cyc)[i]
                var t = (cyc)[(i + 1) % n]
                var r = self._import_range(a, t)
                b.note(
                    r.start,
                    f"'{Path::filename_of(self._sm->get_filename(a))}' imports '{Path::filename_of(self._sm->get_filename(t))}' here",
                )
            }
        }

        if n == 1 {
            // A file sees its own declarations without importing itself, so
            // the import does nothing but close the cycle: drop it.
            b.remove(at, "remove the import; a file sees its own declarations without one")
        } else {
            b.note(
                "move the declarations the modules share into a third module that each of them imports",
            )
        }

        b.emit()
    }

    /// \brief no ffi header is handed to clang from here on: a walk records
    ///        the header list and builds no HeaderSet. For --syntax-only,
    ///        which never reaches the Sema that reads one; the cache
    ///        stays the CompilerInstance's.
    pub fn drop_headers(self) {
        self._headers = &null
    }

    pub fn preprocess(self, entry_fid: u32, const entry_path: ModulePath) -> PPResult {
        var out = PPResult()

        // Separate region: the resolver index is built on the pool at
        // initialize() to overlap with this. Time spent here is time the
        // overlap failed to hide.
        {
            var _tw = TimeRegion("ResolverIndexWait")
            self._resolver->wait_for_index()
        }

        // Timed inside DepScanner::build_graph, not wrapped here: hoisting the
        // graph out of a timing block would cost a default-construct plus a
        // copy-assign of five maps on every TU, and pessimizing the compiler
        // to measure the compiler is a bad trade.
        var scanner = DepScanner(
            self._sm,
            self._tcm,
            self._resolver,
            self._sym,
            self._opts.max_import_depth,
        )

        // What an earlier input of the batch scanned (every input reaches
        // builtin) is followed through the edges recorded then, not rescanned.
        scanner.set_known(unsafe &self._scanned)
        var graph = scanner.build_graph(entry_fid, entry_path)

        if !graph.depth_exceeded_path.empty() {
            self._diag->report(
                DiagID::R019E,
                f"import depth limit ({self._opts.max_import_depth}) exceeded at '{graph.depth_exceeded_path}'; raise it with --cmax-import-depth=N",
            ).emit()
        }

        // The PRELUDE: every TU behaves as though it wrote `import builtin::*`
        // before its first token. Folded HERE, beside --force-include, for the
        // same reason: the graph has to reach it before the walk, or sema asks
        // for a lang item that was never parsed.
        //
        // Resolved as a MODULE, not a path -- the resolver answers with the
        // canonical `builtin` segments, which is what the lang-item fill keys
        // on. A custom --prelude REPLACES it (a plain file, folded like a
        // force-include); --no-prelude and --freestanding turn it off; and a
        // builtin file reached as the entry is its own prelude, so the
        // self-edge is skipped.
        if !self._opts.no_prelude {
            var p_fid: u32 = 0
            if self._opts.prelude_path.size() > 0 {
                p_fid = self._sm->load_file(Path(self._opts.prelude_path))
                if p_fid != u32::MAX && p_fid != 0 && p_fid != entry_fid {
                    scanner.add_root_dependency(p_fid, &graph)
                }
            } else {
                var segs = cxx::std::vector<string>()
                segs.push_back(builtin_root_name())
                p_fid = scanner.add_module_dependency(segs, &graph)
                // Only the real builtin module is reported: a custom --prelude
                // is a file, not the lang-item root, and sema must not read
                // lang items out of it.
                if p_fid != 0 && p_fid != u32::MAX {
                    out.builtin_fid     = p_fid
                    self._prelude_fid   = p_fid
                    self._prelude_scope = graph.mod_paths[p_fid]
                }
            }

            if p_fid != 0 && p_fid != u32::MAX && p_fid != entry_fid {
                graph.add_edge(entry_fid, p_fid)
            }
        }

        // --force-include: fold each file (and its own transitive imports) into
        // the graph at global scope, as if this TU implicitly wrote
        // `import <file>::*;` before its own first token. load_file() already
        // reports U001F (fatal) on a missing/unreadable path, so a u32(-1)
        // return needs no diagnostic of its own here just skip it.
        for *path_str in self._opts.force_includes {
            var fi_fid = self._sm->load_file(Path(*path_str))
            if fi_fid == u32::MAX || fi_fid == entry_fid { // self-include: a no-op, not a self-edge
                continue
            }

            scanner.add_root_dependency(fi_fid, &graph)
            graph.add_edge(entry_fid, fi_fid)
        }

        // `@create` / `@destroy`: alloc.k's create / destroy, with no
        // import written. The graph must reach alloc.k for sema to type it
        // (and fill its lang items) before the file using the sugar; the
        // edge binds no name -- the driver's matching ImportEdge is
        // nameless too (AllocSugarDesugar). Before the macro-prelude block
        // below, so alloc.k gets its own edge to the builtin root there.
        if !self._opts.no_prelude
            && self._opts.prelude_path.size() == 0
            && graph.alloc_sugar.size() > 0 {
            var asegs = cxx::std::vector<string>()
            asegs.push_back(builtin_root_name())
            asegs.push_back("base")
            asegs.push_back("alloc")
            var users = cxx::std::vector<u32>()
            for f in graph.alloc_sugar {
                users.push_back(f)
            }

            var a_fid = scanner.add_module_dependency(asegs, &graph)
            if a_fid != 0 && a_fid != u32::MAX {
                for var ui: usize = 0; ui < users.size(); ++ui {
                    if users[ui] != a_fid {
                        graph.add_edge(users[ui], a_fid)
                    }
                }
            }
        }

        // `f256` / `f512` (P723): num/f256_t.k and num/f512_t.k, which the
        // builtin root does not re-export, for the files that name one.
        self._wide_imports.clear()
        if !self._opts.no_prelude && self._opts.prelude_path.size() == 0 {
            self._add_wide_floats(&scanner, &graph, "f256_t", graph.f256_users)
            self._add_wide_floats(&scanner, &graph, "f512_t", graph.f512_users)
        }

        // The macro prelude needs the builtin root WALKED before any file
        // that may expand one of its macros, and the graph above only has
        // the entry's edge to it. Every other file outside the builtin
        // root's own closure gets one too; a builtin file never does, or a
        // builtin import of it would close a cycle.
        if self._prelude_fid != 0 && graph.all_fids.contains(self._prelude_fid) {
            self._prelude_files.clear()
            var work = cxx::std::vector<u32>()
            work.push_back(self._prelude_fid)
            while !work.empty() {
                var f = work.back()
                work.pop_back()
                if !self._prelude_files.insert(f as u64).second {
                    continue
                }

                if graph.deps.contains(f) {
                    for d in graph.deps[f] {
                        work.push_back(d)
                    }
                }
            }

            for fid in graph.all_fids {
                if self._prelude_files.contains(fid as u64) {
                    continue
                }

                graph.add_edge(fid, self._prelude_fid)
            }
        }

        self._prelex_cycles(&graph)

        var executor          = WaveExecutor(self._pool)
        var dispatched: usize = 0
        {
            // One region, not a Wave/walk pair. The driver's time here is the
            // wave's LATENCY (dispatch + dependency stalls); each worker bills
            // its file's walk as WORK to the same record. par is then exactly
            // the parallelism the import DAG allowed   which is the only thing
            // anyone wants to know about a wave scheduler.
            var        _te   = TimeRegion("Walk")
            var unsafe *wrec = _te.record()

            dispatched = executor.run(
                &graph,
                fn(fid: u32, mod_path: ModulePath) {
                    var _tw = TimeWorker(wrec)
                    _tw.units(self._sm->get_file_size(fid) as u64, "B".c_str())
                    self._walk_one(fid, mod_path)
                },
            )
        }

        for var c: usize = 0; c < graph.cycles.size(); ++c {
            self._report_cycle(&graph.cycles[c])
        }

        // The replayed tokens were copied into each walk's output; the lexers
        // went with their streams (close_stream).
        for var it = self._prelexed.begin(); it != self._prelexed.end(); ++it {
            kairo::std::destroy(it->second.tokens)
        }

        self._prelexed.clear()

        // A file the waves never reached was never walked, so it is never
        // parsed or compiled. The scan drops (and reports) every edge that
        // would close a cycle, so this is a scanner bug if it fires -- but it
        // is reported, not ignored: dropping a file and exiting 0 is how an
        // import cycle used to lose both of its files without a word.
        if dispatched < graph.all_fids.size() {
            var lost = ""
            for fid in graph.all_fids {
                if graph.in_degree[fid] == 0 {
                    continue
                }

                lost = self._sm->get_filename(fid)
                break
            }

            self._diag->report(
                DiagID::I003E,
                f"{graph.all_fids.size() - dispatched} file(s) of the import graph were never preprocessed (first: '{lost}'); the graph has a cycle the dependency scan did not break",
            ).emit()
        }

        // Recorded for the next input's scan. A fid already known keeps its
        // first entry: this graph followed it from there.
        for fid in graph.all_fids {
            if self._scanned.all_fids.contains(fid) {
                continue
            }

            self._scanned.add_node(fid, graph.mod_paths[fid])
            self._scanned.deps[fid] = graph.deps[fid]
        }

        out.ok = !self._diag->has_fatal()
        out.fids.reserve(graph.all_fids.size())
        for fid in graph.all_fids {
            out.fids.push_back(fid)
        }

        cxx::std::sort(out.fids.begin(), out.fids.end())
        return out
    }
}
