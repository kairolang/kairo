/// --- The Kairo Project ---------------------- Driver/FrontendAction.k --- ///
///
///   Driver Layer 3: FrontendAction, the per-file pipeline executor
///   (load, preprocess, parse, sema, codegen and the post-stage dumps), with
///   the helpers only it uses (PublishOnExit, SemaSlot, ImportGroups). The
///   shared resources it borrows are CompilerInstance's (Layer 2).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/Object/ObjectFile.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Path.h"
ffi "c++" import "llvm/TargetParser/Host.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "llvm/Support/Threading.h"
ffi "c++" import "llvm/Support/xxhash.h"
ffi "c++" import "llvm/Support/Process.h"
ffi "c++" import "llvm/ADT/StringExtras.h"
ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "llvm/MC/TargetRegistry.h"
ffi "c++" import "llvm/MC/MCSubtargetInfo.h"
ffi "c++" import "llvm/Support/TargetSelect.h"
ffi "c++" import "llvm/Target/TargetMachine.h"
ffi "c++" import "llvm/Target/TargetOptions.h"
ffi "c++" import "llvm/Support/CodeGen.h"
ffi "c++" import "llvm/ADT/APFloat.h"
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h"
ffi "c++" import "clang/Basic/Diagnostic.h"
ffi "c++" import "clang/Basic/DiagnosticIDs.h"
ffi "c++" import "clang/Basic/DiagnosticOptions.h"
ffi "c++" import "clang/Basic/TargetInfo.h"
ffi "c++" import "clang/Basic/TargetOptions.h"
ffi "c++" import "clang/Frontend/FrontendActions.h"
ffi "c++" import "Native/KTimeReport.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KShims.hh"
ffi "c++" import "Native/KObjCache.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/GlobalRecycler.hh"
ffi "c++" import "vector"
ffi "c++" import "memory"
ffi "c++" import "string"
ffi "c++" import "utility"
ffi "c++" import "algorithm"
ffi "c++" import "cstring"
ffi "c++" import "optional"
ffi "c++" import "chrono"
ffi "c++" import "system_error"
ffi "c++" import "set"
ffi "c++" import "atomic"
ffi "c++" import "thread"
ffi "c++" import "cstdlib"

import AST::ASTSupport::FrozenList
import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContext
import AST::Context::DepLog::DepLogScope
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::Context::ImportOverlay::{
    ImportOverlay,
    OverlayTargetKind,
    OverlayVisibility,
}
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::Context::SymbolTable::SymbolTable
import AST::Context::TranslationUnit::{
    ImportEdge,
    TranslationUnit,
}
import AST::DeclFacts::decl_spec_kind
import AST::LangItems::{
    LowerTargets,
    builtin_root_name,
    hex32,
}
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Printer::PrintCore::{
    Color,
    Painter,
    PrintOptions,
}
import AST::Printer::Printers::{
    ASTPrinter,
    DeclPrinter,
    TypePrinter,
}
import AST::Serialize::RoundTrip::{
    ASTRoundTrip,
    RoundTripStats,
}
import AST::Serialize::Serializer::{
    ASTBinWriter,
    write_ast_file,
}
import AST::VisibilityFacts::stamp_tu_visibility
import Codegen::Backend::CodegenAction::EmitKind
import Codegen::Backend::CodegenBackend::{
    CODEGEN_GROUP,
    CodegenJob,
    CodegenQueue,
    CodegenRun,
}
import Codegen::Backend::EmitCXXHeader::EmitCXXHeader
import Codegen::Backend::InterfacePCH::InterfacePCH
import Codegen::CodegenContext::{
    CodegenContext,
    CodegenPhase,
}
import Codegen::Emit::CXXSpell::CXXSpell
import Codegen::Emit::InterfaceEmitter::InterfaceEmitter
import Codegen::EmitPlan::{
    EmitPlan,
    PlanMode,
}
import Codegen::Sink::TextSink::TextSink
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Driver::CompilerInstance::CompilerInstance
import Driver::CompilerLink
import Driver::CompilerNative
import Driver::CompilerRecovery
import Driver::ObjectCache::ObjectCache
import Driver::Progress::{
    PROGRESS_CODEGEN, PROGRESS_PARSE, PROGRESS_SEMA, progress_begin, progress_end, progress_finish,
    progress_on,      progress_reuse, progress_tick,
}
import Driver::TUResult::TUResult
import Driver::TUStage::TUStage
import Interop::Clang::ClangBackend::CLANG_STARTUP_GROUP
import Interop::Clang::CodegenPCH::CodegenPCH
import Interop::Clang::HeaderSet::HeaderSet
import Interop::Clang::HeaderSetCache::HeaderSetCache
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Parser::ASTParse::ASTParse
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Resolution::ImportProbe::ImportResolver
import Resolution::ModulePath::ModulePath
import Sema::Check::EffectPropagation::EffectTable
import Sema::Incremental::Plan::PlanModule
import AST::DeclFacts::decl_is_imported
import AST::Node::CanonicalNodes::{
    QualifiedType,
    RecordType,
}
import Sema::Incremental::Retract::{
    RetractStats,
    retract_instances,
    verify_retired,
}
import Diagnostic::FileDiagnostics::FileDiagConsumer
import Sema::Incremental::Facts::{
    FileDeps,
    FileFacts,
    IncrFacts,
    incr_decl_id,
    incr_json,
    incr_resolve_deps,
}
import Sema::Resolve::ImportResolution::ImportResolution
import Sema::Resolve::NameLookup::NameLookup
import Sema::Resolve::TypeResolve::TypeResolution
import Sema::Sema::Sema
import Sema::SemaContext::{
    OnceMention,
    SemaPhase,
}
import Sema::SemaDump::SemaDump
import Tooling::SemaObserver::SemaObserver
import Support::FileIO::Path::Path
import Support::Ascii::is_control
import Support::TimeReport::{
    TimeRegion,
    time_mark_idle,
    time_region,
}
import Token::TokenKind::TokenKind
import Token::TokenPrinter::TokenPrinter
import Token::TokenText::TokenText
import std::io

/// Per-file pipeline executor.
///
/// Owned by \c CompilerInstance::execute() for the lifetime of one input file.
/// Advances through \c TUStage in order, honouring \c FrontendOptions stop-at
/// points and post-stage dump flags at each boundary.
///
/// Stages are strictly sequential on the calling thread. Load and lex must run
/// on the driver thread (shared SM/TCM writes). Preprocess through codegen are
/// per-file and will be async-dispatchable to the \c ThreadPool in a future
/// phase once SM/TCM are read-only.
///
/// \c _ci and \c _resolver are non-owning borrows valid for the lifetime of
/// \c execute(). \c _pp is owned and destroyed with the action.
pub class FrontendAction {
    pub var  path:          Path
    pub var  module_base:   ModulePath
    priv var _ci:           unsafe *CompilerInstance ///< non-owning borrow from execute()
    priv var _resolver:     *ImportResolver ///< non-owning borrow from execute()
    priv var _global_scope: unsafe *GlobalDisambigTable ///< non-owning borrow from CompilerInstance
    priv var _file_id:      u32
    priv var _fids:         cxx::std::vector<u32> ///< the graph's fids this action claimed (claim_fid)
    /// Each Kairo TU's interface facts, taken at Checked under
    /// --dump-interface / --dump-deps and written at the end of _sema. Only
    /// the driver thread appends (_sema_finish runs there).
    priv var _incr: cxx::std::vector<FileFacts>
    /// Registry entries the last retract() re-armed (refresh() checks that
    /// its Sema made each live again).
    priv var _rearmed:     cxx::std::vector<unsafe *InstanceEntry>
    priv var _rearmed_was: cxx::std::vector<string> ///< parallel: what each was, for the reason
    /// More about the last refresh()'s refusal (which instance), for a log.
    pub var refresh_detail: string = ""

    /// A live check that re-checks an edit's files in SLICES
    /// (LiveCheck::two_tier): retract() is called once for the whole
    /// refresh set and refresh() once per slice, with other edits'
    /// retractions and slices in between. What one refresh() of the whole
    /// set decides at its end is then decided across the calls:
    ///  - an entry a retraction re-armed must be used again by a file of
    ///    THAT retraction's set (\c _rearm_set, \c _rearm_ok), judged when
    ///    every slice is done (tier_finish);
    ///  - an adopted stand-in's record is compared with the layout it had
    ///    before the first retraction since the last tier_finish
    ///    (\c _tt_old_i), whichever slice re-reads it.
    pub var tiered: bool = false
    priv var _tt_sets:   cxx::std::vector<cxx::std::vector<u32>>
    priv var _rearm_set: cxx::std::vector<u64> ///< parallel to _rearmed: its retraction's set
    priv var _rearm_ok:  cxx::std::vector<u8>  ///< parallel: used again by that set, or dropped
    priv var _tt_old_i:  llvm::StringMap<u32>
    priv var _tt_old_v:  cxx::std::vector<string>
    priv var _tt_old_f:  llvm::DenseSet<u64>   ///< files whose old hashes are in _tt_old_i
    /// RetractStats::first_* of every retraction since the last tier_finish.
    priv var _tt_first_prim:  cxx::std::vector<u64>
    priv var _tt_first_fid:   cxx::std::vector<u32>
    priv var _tt_first_entry: cxx::std::vector<unsafe *InstanceEntry>
    priv var _graph:        cxx::std::vector<u32> ///< every fid of the graph, an earlier input's too
    pub var  result:        TUResult
    priv var _stage:        TUStage
    /// The shared engine's counts this input is judged against (see run()):
    /// what the previous input left, 0 for the first. Set by execute().
    pub var errors_at_start: u32 = 0
    pub var fatals_at_start: u32 = 0
    /// Found through an include, not named on the command line
    /// (InputKind::discovered): its object never goes to -o.
    pub var discovered: bool = false

    fn FrontendAction(
        self,
        const path:        Path,
        const module_base: ModulePath,
        g_scope:    unsafe *GlobalDisambigTable,
        resolver:   *ImportResolver, // one single import resolver for the full
                                     // batch; shared among all actions and threads,
                                     // fully indexed before the first action runs
        ci:         unsafe *CompilerInstance
    ) {
        self.path          = path
        self.module_base   = module_base
        self._ci           = ci
        self._resolver     = resolver
        self._global_scope = g_scope
        self._stage        = TUStage::Pending
        self._file_id      = u32::MAX
        self.result.path   = path.full_path()
    }

    fn op finally (self) = default

    /// Executes the full pipeline on the calling thread.
    ///
    /// Stages are gated by \c FrontendOptions. A stage returning false halts the
    /// pipeline and leaves \c _stage at \c Failed. An early-exit stop-at flag
    /// advances \c _stage to \c Done and returns without running further stages.
    ///
    /// Load and lex run on the driver thread (shared SM/TCM writes). Preprocess
    /// through codegen are per-file and will be async-dispatchable in a future
    /// phase.
    pub fn run(self) {
        var t0 = cxx::std::chrono::steady_clock::now()
        // Every way out of the action, a fatal included: a pinned line left
        // on screen would be overwritten by whatever prints next.
        finally {
            progress_finish()
        }

        finally {
            var t1 = cxx::std::chrono::steady_clock::now()
            self.result.elapsed_ms = (cxx::std::chrono::duration_cast<cxx::std::chrono::microseconds>(
                t1 - t0,
            ).count() as f64) / 1000.0
            self.result.stage   = self._stage
            self.result.file_id = self._file_id

            // Snapshot AFTER every stage this TU reached, whichever one halted
            // it. `_preprocess()` used to be the only writer here, which meant
            // errors from parse/sema/codegen never made it into `result` and a
            // TU that failed there was silently reported as clean.
            self.result.error_count = self._ci->diag()->error_count()
            self.result.warn_count  = self._ci->diag()->warn_count()
        }

        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"FrontendAction: begin '{self.path.full_path()}'",
        )

        // The engine is shared by every input of the batch and never reset, so
        // the gates below compare against what the PREVIOUS input left
        // (errors_at_start, set by execute(); 0 for the first). Testing the
        // batch total stopped every input after the first one that had an
        // error, right after its parse: `kairo --type-check-only a.k b.k` never
        // checked b.k when a.k failed, where clang (and a whole-tree check)
        // reports every input's errors. Not the count when run() starts: the
        // batch's dependency scan reports an input's own lexing errors (S072E)
        // before any run(), and they must still stop the first input's Sema.

        // Phase 1: shared-state stages driver thread only.
        if !self._load() {
            return
        }

        // Phase 2: per-file stages async-dispatchable in a future phase.
        if !self._preprocess() {
            return
        }

        var fe = self._ci->invocation()->frontend
        // Past the action's own stop when a C++ input may include this file:
        // the include needs it analysed (CompilerInstance::kairo_feeds_includes).
        var feed = self._ci->kairo_feeds_includes()
        if fe.stops_at_preprocess() && !feed {
            self._stage = TUStage::Done
            return
        }

        if self._fids.empty() {
            self._stage = TUStage::Done
            return
        }

        if !self._parse() {
            return
        }

        // --check-past-syntax-errors (kals): the files the errors leave sound
        // go on to Sema, and the check after it fails the action as this one
        // would have. Never for an action that stops at the parse anyway.
        if self._ci->diag()->error_count() > self.errors_at_start
            && (fe.stops_at_parse() || !self._ci->admit_past_syntax_errors(self._global_scope, self._fids, self.errors_at_start)) {
            self._stage = TUStage::Failed
            return
        }

        if fe.stops_at_parse() && !feed {
            self._stage = TUStage::Done
            return
        }

        if !self._sema() {
            return
        }

        if self._ci->diag()->error_count() > self.errors_at_start {
            self._stage = TUStage::Failed
            return
        }

        self._dump_purity_stats() // --print-stats; before the stop, so --type-check-only has it
        if fe.stops_at_sema() {
            self._stage = TUStage::Done
            return
        }

        self._dump_mem_stats() // --print-stats: after Sema, before the header release.
        // Phase A's clang instances are Sema's (HeaderIndex, M2 fills, defined!):
        // codegen reads only the merged PCH and the sets' text. With one Kairo
        // input and no C++ input including a .k, no later action needs them, so
        // they are freed before the fan-out instead of at exit -- ~200 MB each,
        // the bulk of the peak. Any later read is counted, not silent.
        if self._ci->kairo_only_input_count() == 1
            && !self._ci->kairo_feeds_includes()
            && self._ci->headers() != &null {
            var _tr = TimeRegion("HeaderRelease")
            self._ci->headers()->drain_all(self._ci->diag(), self._ci->sm())
            self._ci->headers()->release_all()
        }

        if !self._codegen() {
            return
        }

        self._dump_mem_stats()
        {
            var late = kairo::header_set_late_uses().load()
            kairo::Logger::info(
                kairo::Logger::Stage::Driver,
                f"header sets revived after release_unused: {kairo::header_set_revivals().load()}",
            )

            if late > 0 {
                kairo::Logger::warn(
                    kairo::Logger::Stage::Driver,
                    f"{late} use(s) of a header set's clang AST after its early release",
                )

                io::eprintln(f"kairo: warning: {late} use(s) of a released header set")
            }
        }

        self._stage = TUStage::Done
        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"FrontendAction: done '{self.path.full_path()}' ({self.result.elapsed_ms:.2}ms)",
        )
    }

    pub fn stage(self) -> TUStage {
        return self._stage
    }

    pub fn file_id(self) -> u32 {
        return self._file_id
    }

    pub fn fids(self) -> cxx::std::vector<u32> {
        return self._fids
    }

    fn ok(self) -> bool {
        return self._stage == TUStage::Done
    }

    fn failed(self) -> bool {
        return self._stage == TUStage::Failed
    }

    priv static fn _ensure_parent_dir(const path: string) {
        Path::make_parent_dirs(path)
    }

    /// --print-panic-sets: every Panic<T, E...> instance the build formed
    /// (Compiler/Spec/Panic.md#canonical-sets, §1.1a), by its C++ spelling: the canonical set in
    /// order with each type id, then the layout Sema predicted (size 0:
    /// not known before C++ lays it out). Sorted, for golden tests: the
    /// registry's own order is mint order, which moves when an unrelated TU
    /// mints first.
    priv fn _dump_panic_sets(self) {
        var unsafe *ids = self._ci->panic_type_ids()
        if ids == &null {
            return
        }

        var all = cxx::std::vector<unsafe *InstanceEntry>()
        self._global_scope->instances()->collect(&all)
        var rows = cxx::std::vector<string>()
        for var i: usize = 0; i < all.size(); ++i {
            var unsafe *e = all[i]
            if !ids->is_panic(e->primary) || e->type_ids.size() == 0 {
                continue
            }

            var p = e->args.size() - e->type_ids.size()
            var t = ids->spelling(e->args[0])
            var r = f"Panic<{t}"
            for var k: usize = p; k < e->args.size(); ++k {
                r += ", " + ids->spelling(e->args[k])
            }

            r += f">: size {e->adt_size}, payload offset {e->payload_offset}"
            for var k: usize = 0; k < e->type_ids.size(); ++k {
                r += "\n  " + ids->spelling(e->args[p + k]) + " = 0x" + hex32(e->type_ids[k])
            }

            var at = rows.size()
            rows.push_back(r)
            while at > 0 && r < rows[at - 1] {
                rows[at] = rows[at - 1]
                at -= 1
            }

            rows[at] = r
        }

        io::println("-- panic sets --")
        for var i: usize = 0; i < rows.size(); ++i {
            io::println(f"{rows[i]}")
        }
    }

    // Pipeline stages: each returns true to continue, false to halt.

    /// Emits a fatal diagnostic, marks the TU as failed, and returns false.
    priv fn _fatal(self, id: DiagID, const msg: string) -> bool {
        self._ci->diag()->report(id, msg).emit()
        self.result.had_fatal = true
        self._stage           = TUStage::Failed
        return false
    }

    /// --syntax-only, unless a C++ input includes Kairo (the include needs
    /// the whole program analysed, kairo_feeds_includes).
    priv fn _syntax_only(self) -> bool {
        var fe = self._ci->invocation()->frontend
        return fe.is_syntax_only() && !self._ci->kairo_feeds_includes()
    }

    /// Registers the source file with \c SourceManager and obtains a file ID.
    priv fn _load(self) -> bool {
        var _t = TimeRegion("Load")

        self._stage   = TUStage::Loading
        self._file_id = self._ci->sm()->load_file(self.path)
        if self._file_id == u32::MAX {
            return self._fatal(DiagID::I005F, f"cannot open '{self.path.full_path()}'")
        }

        return true
    }

    /// Runs the preprocessor walk for this file's dependency graph.
    /// The PreProcessor is batch-scoped (owned by CompilerInstance): it walks
    /// each fid exactly once across all input files, so a fid shared by two
    /// inputs is preprocessed once. Its DAG visited-set does the dedup.
    priv fn _preprocess(self) -> bool {
        var _t = TimeRegion("Preprocess")

        self._stage = TUStage::Preprocessing

        // --syntax-only is per file: it parses its inputs and nothing they
        // import, and a C++ header is not syntax, so no clang parse either. The
        // import closure is still preprocessed -- an imported macro is expanded
        // in the input's own tokens, and that needs its definition.
        var syntax_only = self._syntax_only()
        if syntax_only {
            self._ci->pp()->drop_headers()
        }

        var pp_res = self._ci->pp()->preprocess(self._file_id, self.module_base)
        // The header lists this preprocess recorded are parsed as one set,
        // on the pool, overlapping the parse.
        if self._ci->headers() != &null {
            self._ci->headers()->start_shared()
        }

        // Only what no earlier input took: the rest is done (claim_fid). An
        // input another one imports is left with nothing -- except under
        // --syntax-only, where the importer parsed only itself.
        self._graph = pp_res.fids
        self._fids.clear()
        for var f: u32 in pp_res.fids {
            var mine = self._ci->claim_fid(f)
            if mine || syntax_only && f == self._file_id {
                self._fids.push_back(f)
            }
        }

        // Which fid is the builtin module, recorded once for the build. Sema fills
        // the lang-item table from it (NameResolution); it cannot identify the fid
        // itself, because ModulePath segments are PP SymbolIDs and Sema has no
        // symbol table. 0 means no builtin root -- the lang items stay unbound and
        // whichever pass needs one diagnoses it at the use.
        if pp_res.builtin_fid != 0 {
            self._global_scope->set_builtin_fid(pp_res.builtin_fid)
        }

        // error_count/warn_count are snapshotted once in run()'s finally block,
        // after every stage this TU reaches - not here.

        if self._ci->diag()->fatal_count() > self.fatals_at_start {
            self.result.had_fatal = true
            self._stage           = TUStage::Failed
            return false
        }

        if !pp_res.ok {
            self._stage = TUStage::Failed
            return false
        }

        // NOTE: no clang preload here. Kairo fids are mirrored into the clang SM
        // by ClangLocMap::rebind(), inside the codegen action window   the only
        // place a FileID survives FrontendAction::BeginSourceFile's
        // clearIDTables(). Registering off-thread after preprocess produced a map
        // that was stale from the first ExecuteAction onward.

        var fe = self._ci->invocation()->frontend
        if fe.dump_preprocessed {
            self._dump_preprocessed_source()
        }

        if fe.print_tokens {
            self._dump_tokens()
        }

        if fe.print_macros {
            self._dump_macros()
        }

        if fe.print_imports {
            self._dump_imports()
        }

        return true
    }

    priv fn _parse(self) -> bool {
        var _t = TimeRegion("Parse")

        self._stage = TUStage::Parsing

        // tree order, fids[0] == main. A C++ header is never in _fids (the PP
        // never walks one), but a fid is only a number: filter anyway, because a
        // header TU reaching ASTParse would lex C++ as Kairo and overwrite the TU
        // Sema/Foreign filled.
        var fids = cxx::std::vector<u32>()
        for var f: u32 in self._fids {
            if self._ci->is_foreign_fid(f) {
                continue
            }

            fids.push_back(f)
        }

        // --syntax-only: the closure is indexed (the parser's disambiguation
        // reads imported names), but only the input is parsed in full, so only
        // its errors are reported.
        var parse_fids  = cxx::std::vector<u32>()
        var syntax_only = self._syntax_only()
        for var f: u32 in fids {
            if syntax_only && f != self._file_id {
                continue
            }

            parse_fids.push_back(f)
        }

        // index phase: Index-mode ASTParse over each fid (same grammar as the
        // full parse, shallow materialization). Replaces the old ASTIndex
        // token-level pre-pass.

        {
            var _ti = TimeRegion("Index")

            for var fid: u32 in fids {
                var unsafe *captured_rec = kairo::TimeReport::current()
                self._ci->pool()->enqueue(
                    kairo::SmallFunction<64>(
                        fn () |fid, self, captured_rec| {
                            var        _kt  = kairo::TimeReport::Worker(captured_rec)
                            var unsafe *gs  = self._global_scope
                            var unsafe *ctx = gs->begin_index(fid)
                            if ctx != &null {
                                var indexer = ASTParse(ctx, &null, gs, ASTParse::ParseMode::Index)
                                indexer.index()
                                gs->finish_index(fid)
                            }
                        },
                    ),
                    5,
                )
            }

            self._ci->pool()->wait_group(5)
        }

        // parallel parse + low-water-mark flush
        {
            var _tp = TimeRegion("Full")
            var N   = parse_fids.size()
            progress_begin(PROGRESS_PARSE, N)
            var unsafe *time_rec = kairo::TimeReport::current()
            var unsafe *time_sm  = self._ci->sm()
            var unsafe *time_flush = kairo::TimeReport::region_under(
                time_rec,
                kairo::std::to_std_string(r"DiagFlush"),
            )

            kairo::TimeReport::mark_idle(time_flush)

            // done[i] published (release) by the parse task for fids[i];
            // read (acquire) by the flusher. Outlives both: the flusher is
            // joined and the parse group drained before this scope ends.
            var        done       = cxx::std::vector<kairo::std::Atomic<bool>>(N)
            var unsafe *done_data = done.data()

            var unsafe *engine    = self._ci->diag()
            var unsafe *fids_data = parse_fids.data()
            var unsafe *gs        = self._global_scope

            // flusher: drains contiguous done-prefix in fid order, single-threaded.
            var flusher = cxx::std::#thread(
                fn () |time_rec, time_flush, N, done_data, fids_data, gs, engine| {
                    var _kr           = kairo::TimeReport::ThreadRoot(time_rec)
                    var _kf           = kairo::TimeReport::Scope(time_flush)
                    var cursor: usize = 0
                    while cursor < N {
                        if done_data[cursor].load(cxx::std::memory_order_acquire) {
                            var        fid: u32 = fids_data[cursor]
                            var unsafe *ctx     = gs->get_context(fid)
                            if ctx != &null {
                                ctx->diag_sink.drain_into(engine, ctx->sm)
                            }

                            ++cursor
                        } else {
                            // Parks until PublishOnExit's notify.
                            done_data[cursor].wait(false, cxx::std::memory_order_acquire)
                        }
                    }
                },
            )

            for var i: usize = 0; i < N; ++i {
                var fid: u32 = parse_fids[i]
                self._ci->pool()->enqueue(
                    kairo::SmallFunction<64>(
                        fn () |gs, fid, done_data, i, time_rec, time_sm| {
                            var _kt     = kairo::TimeReport::Worker(time_rec)
                            var publish = PublishOnExit(unsafe &done_data[i])

                            var unsafe *ctx = gs->get_context(fid)
                            if ctx != &null {
                                var        parser = ASTParse(ctx, &null, gs, ASTParse::ParseMode::Full)
                                var unsafe *tu    = parser.parse()
                                ctx->tu = tu
                                if time_sm != &null {
                                    _kt.units(time_sm->get_file_size(fid), "B".c_str())
                                }
                            }

                            if time_sm != &null && progress_on() {
                                progress_tick(PROGRESS_PARSE, time_sm->get_filename(fid))
                            }
                        },
                    ),
                    6,
                )
            }

            self._ci->pool()->wait_group(6) // all parses done => all done[i] set
            flusher.join()                  // flusher drains tail, exits
            progress_end(PROGRESS_PARSE)
        }

        // Before any dump: under --ast-roundtrip the tree the dumps and Sema
        // see is the reloaded one.
        if !self._ast_serialize(&parse_fids) {
            return false
        }

        /// # print-ast / mem stats: unchanged

        var ast_mode = self._ci->invocation()->frontend.print_ast
        if !ast_mode.empty() {
            var use_color              = !self._ci->invocation()->diag.no_color
            var opts:     PrintOptions
            if ast_mode == "tree" {
                opts = PrintOptions::dump()
            } else if ast_mode == "flat" {
                opts = PrintOptions::diag()
            } else if ast_mode == "canonical" {
                opts = PrintOptions::canonical()
            } else {
                return self._fatal(
                    DiagID::I010F,
                    f"invalid --print-ast value '{ast_mode}'; expected one of: tree, flat, canonical",
                )
            }

            opts.color = use_color
            for var fid: u32 in parse_fids {
                io::println(f"============== AST ({ast_mode}) for fid {fid} ==============")
                var unsafe *ctx = self._global_scope->get_context(fid)
                if ctx == &null {
                    return self._fatal(DiagID::I006F, f"failed to get context for fid {fid}")
                }

                var unsafe *tu = ctx->tu
                if tu == &null {
                    return self._fatal(DiagID::I006F, f"parse failed for fid {fid}")
                }

                ASTPrinter::print(tu, opts)
            }
        }

        /// # print-symbols: frozen per-DeclContext symbol tables
        /// Styled by the same --print-ast value (default 'tree' -> dump()); when
        /// --print-ast is unset we still honor --print-symbols with diag() (flat)
        /// rows, since the symbol dump renders decls one-line regardless.
        if self._ci->invocation()->frontend.print_symbols {
            var use_color              = !self._ci->invocation()->diag.no_color
            var sym_opts: PrintOptions = PrintOptions::diag()
            if ast_mode == "tree" {
                sym_opts = PrintOptions::dump()
            } else if ast_mode == "canonical" {
                sym_opts = PrintOptions::canonical()
            }

            sym_opts.color = use_color

            for var fid: u32 in parse_fids {
                var unsafe *ctx = self._global_scope->get_context(fid)
                if ctx == &null {
                    continue
                }

                var unsafe *tu = ctx->tu
                if tu == &null {
                    continue
                }

                io::println(f"============== SYMBOLS for fid {fid} ==============")
                self._dump_symbols(tu, ctx, sym_opts)
            }
        }

        // dump the hoisted scope as well
        if !ast_mode.empty() {
            io::println(f"-- hoisted scope: {self.path.full_path()} --")
            self._global_scope->dump()
        }

        self._dump_mem_stats()
        return true
    }

    /// The serialized-AST test flags (Compiler/Spec/Serialization.md), run
    /// once every file is parsed and before anything reads a tree:
    /// --emit-ast-bin writes the entry file's AST, --verify-ast-roundtrip
    /// reloads each file's AST beside the parsed one and compares them, and
    /// --ast-roundtrip (or KAIRO_AST_ROUNDTRIP=1) replaces each parsed tree
    /// with its reloaded one, so the rest of the pipeline runs on what the
    /// reader built.
    ///
    /// On this thread, one file at a time: a reader appends to its file's
    /// immediate table and, for a macro another file defines, to that
    /// file's, and nothing else is running to race it here.
    priv fn _ast_serialize(self, @inout fids: cxx::std::vector<u32>) -> bool {
        var fe = self._ci->invocation()->frontend
        if fe.emit_ast_bin.empty() && (!fe.ast_roundtrip) && (!fe.verify_ast_roundtrip) {
            return true
        }

        // Created only here, so a run without these flags reports the same
        // --time-passes rows it always did.
        var _t = TimeRegion("ASTSerialize")

        var psym: unsafe *PreprocessorSymbolTable = &null
        if self._ci->pp() != &null {
            psym = self._ci->pp()->get_symbol_table()
        }

        var unsafe *gs = self._global_scope
        var stats      = RoundTripStats{}

        for var fid: u32 in fids {
            var unsafe *ctx = gs->get_context(fid)
            if ctx == &null || ctx->tu == &null {
                continue
            }

            var name = self._ci->sm()->get_filename(fid)

            if (!fe.emit_ast_bin.empty()) && fid == self._file_id {
                var w = ASTBinWriter()
                if !w.write(ctx->tu, psym, gs) {
                    var why = w.error()
                    return self._fatal(DiagID::I002F, f"cannot serialize the AST of {name}: {why}")
                }

                if !write_ast_file(fe.emit_ast_bin, w.out) {
                    return self._fatal(DiagID::I002F, f"cannot write {fe.emit_ast_bin}")
                }
            }

            var err: string
            if fe.verify_ast_roundtrip {
                if !ASTRoundTrip::verify(ctx->tu, psym, gs, &stats, &err) {
                    return self._fatal(DiagID::I002F, f"AST round trip of {name} failed: {err}")
                }
            }

            if fe.ast_roundtrip {
                if !ASTRoundTrip::replace(ctx, psym, gs, &stats, &err) {
                    return self._fatal(DiagID::I002F, f"AST round trip of {name} failed: {err}")
                }
            }
        }

        if fe.print_stats && stats.files > 0 {
            io::println(
                f"[stats] ast-serialize: {stats.files} files, {stats.bytes} bytes for {stats.source} source bytes, {stats.nodes} nodes, {stats.tokens} tokens, {stats.payloads} payloads, {stats.strings} strings",
            )
        }

        return true
    }

    priv fn _sema(self) -> bool {
        // Timed per piece, not as one region: this function also runs the FFI
        // header join, the lowerings and mono, none of which is semantic
        // analysis, and a "Sema" row that contained them misreported all three.
        self._stage = TUStage::Sema
        var fe = self._ci->invocation()->frontend
        // --dump-type-info has no consumer: SemaDump's expression-types section is
        // private to its whole-TU walk, so there is no cheap per-expression hook
        // here. It is marked unimplemented centrally rather than faking a header.

        // --print-sema styling follows --print-ast, exactly like --print-symbols:
        // 'tree' -> dump(), 'canonical' -> canonical(), otherwise flat diag rows.
        var sema_opts: PrintOptions = PrintOptions::diag()
        if fe.print_sema || fe.print_lowered {
            var ast_mode = fe.print_ast
            if ast_mode == "tree" {
                sema_opts = PrintOptions::dump()
            } else if ast_mode == "canonical" {
                sema_opts = PrintOptions::canonical()
            }

            sema_opts.color = !self._ci->invocation()->diag.no_color
        }

        if fe.print_sema {
            io::println(f"-- sema: {self.path.full_path()} --")
        }

        // Phase A of header import joins here. Every set requested during
        // preprocess must be PARSED before it can be indexed, and INDEXED before
        // phase I of any importer folds its headers. Indexing mints the header
        // fids, so it runs on this (driver) thread; _attach_ffi_edges then stamps
        // each ffi ImportDecl with the closure it imports.
        // The runtime's C objects need nothing from Kairo: compile them on the
        // pool now, while the serial Sema below leaves it idle.
        self._ci->prestart_runtime()

        var unsafe *hc = self._ci->headers()
        if hc != &null {
            var _th = TimeRegion("Headers")
            {
                var _tw = TimeRegion("HeaderSetWait")
                hc->wait_all()
            }

            for var fid: u32 in self._fids {
                var unsafe *hctx = self._global_scope->get_context(fid)
                if hctx == &null {
                    continue
                }

                var unsafe *htu = hctx->tu
                if htu == &null || htu->header_set == &null {
                    continue
                }

                var unsafe *view = unsafe (htu->header_set as unsafe *HeaderSet)
                // A view's headers were parsed in the build's one shared
                // set; from here on the TU's set IS that set, and only the ffi
                // closures below still read which file the view's spelling meant.
                var unsafe *hs = view
                if view->shared != &null {
                    hs = view->shared
                }

                self._ci->header_index()->index(hs)
                // The set's build-time clang diagnostics, buffered on the pool
                // thread (HeaderSet::diag_buf): into the engine now the build
                // has joined. A set shared by several TUs drains once.
                hs->drain_diags(self._ci->diag(), self._ci->sm())
                self._attach_ffi_edges(htu, hctx, hs, view)
                htu->header_set = unsafe (hs as unsafe *void)
            }

            // Phase B's merged PCH needs nothing but the sets that just joined:
            // build it on the pool now, overlapping Sema and the lowerings,
            // rather than on the driver thread when codegen starts (about 45 ms
            // there on a hello-sized program). _codegen joins it.
            if !fe.stops_before_codegen() {
                var gsets = self._graph_header_sets()
                if gsets.size() > 0 {
                    hc->prebuild_codegen_pch(gsets, kairo::TimeReport::current())
                }
            }
        }

        // Each module's top C++ namespace, decided once for the build
        // (CXXSpell::decide_tops) from the graph's header sets, now that they
        // are joined and before any stand-in (TypeExport) or TU is spelled. Not
        // only under `hc`: a build with no C++ headers still renames `main`.
        {
            var tsets = self._graph_header_sets()
            var tops  = cxx::std::vector<string>()
            for var tf: u32 in self._graph {
                var unsafe *tctx = self._global_scope->get_context(tf)
                if tctx == &null || tctx->tu == &null {
                    continue
                }

                var tcg = CodegenContext(
                    tctx,
                    &null,
                    self._ci->pp()->get_symbol_table(),
                    self._global_scope->instances(),
                )

                var tsp = CXXSpell(unsafe &tcg)
                tops.push_back(tsp.top_segment(tctx->tu))
            }

            CXXSpell::decide_tops(
                &tops,
                fn (c: string) -> bool {
                    for var k: usize = 0; k < tsets.size(); ++k {
                        if tsets[k]->declares_global(c) {
                            return true
                        }
                    }

                    return false
                },
            )
        }

        // Clang builtins, the fourth source of unqualified names. Here because
        // init mints a foreign TU (HeaderIndex writes the SM and the global
        // table: driver thread only) and must finish before the first
        // SemaContext. Outside the header block on purpose: a TU that imports
        // no C++ can still call `__builtin_expect`.
        //
        // startup() is idempotent and joins the pool task through the backend's
        // mutex; it is normally long done by now. Timed apart from init so a
        // stall reads as what it is.
        {
            var unsafe *be = self._ci->backend()
            var unsafe *bi = self._ci->builtins()
            if be != &null && bi != &null {
                {
                    var _tj = TimeRegion("BuiltinStartupJoin")
                    be->startup()
                }

                // A startup that failed (a word --mllvm rejects, a target
                // clang cannot make, as --march=bogus) leaves no clang at
                // all: no builtin, no header, so every builtin file's use of
                // `__builtin_*` was an R020E flood under the real error
                // (P896). A missing sysroot or resource dir does NOT fail
                // the startup (it is a P008W / header errors, and the
                // backend runs), so those keep type-checking.
                if !be->ready() {
                    return self._fatal(
                        DiagID::I006F,
                        "the clang backend failed to start (the error above says why); nothing can be type-checked without it",
                    )
                }

                bi->init(
                    be->oracle(),
                    self._ci->sm(),
                    self._ci->header_index(),
                    self._global_scope,
                    self._ci->foreign_registry(),
                )
            }
        }

        // The PRELUDE, as a real ImportDecl. The PP folded the builtin root into
        // the import GRAPH, so it is parsed, ordered and admitted -- but a graph
        // edge binds no NAMES: phase I builds a TU's overlay from tu->imports and
        // nothing else, so without this every user TU sees an empty builtin
        // surface and `string` fails to resolve.
        //
        // Injected HERE because this is the one point where both halves exist:
        // ctx->tu is set by the parse above, and phase I runs just below.
        //
        // resolved_fid is stamped rather than resolved. FileImportIndex resolves a
        // path by SPELLING path_segments, and a synthesized node has none to
        // spell; a wildcard fold reads resolved_fid and never looks at the path.
        //
        // MARKING is not gated on --no-builtins, only injection is: that flag
        // suppresses the implicit import, not the builtin root's own compilation.
        // The builtin files are still parsed and type-resolved either way, and an
        // unmarked one resolves `[T;]` against an empty lang-item table and
        // reports the item missing from inside Lib/builtin itself.
        var bfid = self._global_scope->builtin_fid()
        if bfid != 0 {
            var bsym   = self._ci->pp()->get_symbol_table()->intern(builtin_root_name())
            var inject = !self._ci->invocation()->pp.no_builtins
            self._global_scope->mark_builtin_fid(bfid) // the loop skips the root below.

            // alloc.k (`builtin::base::alloc`), when the PP put it in the graph
            // for a file that writes `@create` / `@destroy`.
            var afid = u32::MAX
            {
                var s_base  = self._ci->pp()->get_symbol_table()->intern("base")
                var s_alloc = self._ci->pp()->get_symbol_table()->intern("alloc")
                for var i: usize = 0; i < self._fids.size(); ++i {
                    var unsafe *actx = self._global_scope->get_context(self._fids[i])
                    if actx == &null {
                        continue
                    }

                    var *asg = &actx->module_base.segments
                    if asg->size() != 3 {
                        continue
                    }

                    if (*asg)[0].name == bsym
                        && (*asg)[1].name == s_base
                        && (*asg)[2].name == s_alloc {
                        afid = self._fids[i]
                        break
                    }
                }
            }

            {
                for var i: usize = 0; i < self._fids.size(); ++i {
                    var fid = self._fids[i]
                    if fid == bfid { // the builtin root is its own prelude
                        continue
                    }

                    var unsafe *pctx = self._global_scope->get_context(fid)
                    if pctx == &null {
                        continue
                    }

                    var unsafe *ptu = pctx->tu
                    if ptu == &null {
                        continue
                    }

                    if ptu->is_foreign { // clang-owned; it has no Kairo overlay.
                        continue
                    }

                    // Every file UNDER the builtin root is part of the prelude
                    // rather than a consumer of it. Injecting there would make
                    // builtin reach itself by a second path, and the re-export
                    // fold would then depend on its own overlay being complete.
                    var *psegs = &pctx->module_base.segments
                    if psegs->size() > 0 {
                        var phead = (*psegs)[0]
                        if phead.name == bsym {
                            self._global_scope->mark_builtin_fid(fid)
                            continue
                        }
                    }

                    if !inject {
                        continue
                    }

                    // The file's start, as the std alias below takes it (see there
                    // for why not SourceLocation::from_base(fid, 0)).
                    var prng = SourceRange::invalid()
                    if pctx->sm != &null {
                        var ploc = pctx->sm->get_loc(fid, 0)
                        prng = SourceRange(ploc, ploc)
                    }

                    var unsafe *pid = Declarations::ImportDecl::create(
                        pctx,
                        prng,
                        Declarations::ImportKind::Native,
                    )

                    pid->is_wildcard    = true
                    pid->is_prelude     = true
                    pid->resolved_fid   = bfid
                    pid->file_seg_count = 1
                    ptu->imports.push(pid)

                    var pedge = ImportEdge{}
                    pedge.target_fid = bfid
                    pedge.decl       = pid
                    ptu->import_edges.push(pedge)

                    // `@create` / `@destroy` lower to alloc.k's create / destroy
                    // pre-bound (AllocSugarDesugar), so this TU must be typed
                    // AFTER alloc.k, whose N fills the lang item: an edge orders
                    // that (_import_order reads import_edges). The ImportDecl
                    // binds NO name -- plain, with no path segments, so phase I's
                    // _fold_plain has no handle to bind -- and a hand-written
                    // `create<T>()` with no import is still undeclared.
                    if afid != u32::MAX && afid != fid && ptu->has_alloc_sugar {
                        var unsafe *aid = Declarations::ImportDecl::create(
                            pctx,
                            prng,
                            Declarations::ImportKind::Native,
                        )

                        aid->is_prelude     = true
                        aid->resolved_fid   = afid
                        aid->file_seg_count = 1
                        ptu->imports.push(aid)
                        var aedge = ImportEdge{}
                        aedge.target_fid = afid
                        aedge.decl       = aid
                        ptu->import_edges.push(aedge)
                    }
                }
            }
        }

        // --prelude <file> / --force-include <file>: the PP folded each file into
        // the import GRAPH, which orders and parses it but binds no names (see the
        // builtin note above), so without a real wildcard ImportDecl the entry TU
        // reports every one of their declarations as undeclared (R020E).
        //
        // The ENTRY TU only, not every fid: a force-included file may itself import
        // helper modules, and injecting its wildcard into those would close a cycle
        // in the overlay fold. Flags apply per input file, so each input's own
        // action gets its own injection. load_file is a cache hit here (the PP
        // loaded the same paths), so this re-derives the fids without PP state.
        {
            var xfids = cxx::std::vector<u32>()
            if !self._ci->invocation()->pp.no_prelude
                && self._ci->invocation()->pp.prelude_path.size() > 0 {
                xfids.push_back(
                    self._ci->sm()->load_file(Path(self._ci->invocation()->pp.prelude_path)),
                )
            }

            for *xpath in self._ci->invocation()->pp.force_includes {
                xfids.push_back(self._ci->sm()->load_file(Path(*xpath)))
            }

            var unsafe *xctx = self._global_scope->get_context(self._file_id)
            if xfids.size() > 0 && xctx != &null {
                var unsafe *xtu = xctx->tu
                if xtu != &null && !xtu->is_foreign {
                    var xrng = SourceRange::invalid()
                    if xctx->sm != &null {
                        var xloc = xctx->sm->get_loc(self._file_id, 0)
                        xrng = SourceRange(xloc, xloc)
                    }

                    for var xi: usize = 0; xi < xfids.size(); ++xi {
                        var xf = xfids[xi]
                        // u32(-1): load_file already reported the missing path.
                        // A self-include is a no-op, not a self-edge.
                        if xf == u32::MAX || xf == 0 || xf == self._file_id {
                            continue
                        }

                        var unsafe *xid = Declarations::ImportDecl::create(
                            xctx,
                            xrng,
                            Declarations::ImportKind::Native,
                        )

                        xid->is_wildcard    = true
                        xid->is_prelude     = true
                        xid->resolved_fid   = xf
                        xid->file_seg_count = 1
                        xtu->imports.push(xid)

                        var xedge = ImportEdge{}
                        xedge.target_fid = xf
                        xedge.decl       = xid
                        xtu->import_edges.push(xedge)
                    }
                }
            }
        }

        // Phases I -> E -> V -> N -> T -> checks (ImportResolution, Expand,
        // Verify, NameResolution, TypeResolution/ChainBinding, then the
        // signature/layout checks) across every fid of this TU's graph. Run in
        // REVERSE tree order so leaf modules build their overlays before
        // importers fold re-exports (DAG order guarantees source-overlay
        // completeness, Compiler/Spec/Pipeline.md #2). Each TU runs to Typed, then (past
        // the panic-set barrier) through the late checks, the lowerings and
        // M1 / M2 (_sema_group).
        var n     = self._fids.size()
        var order = self._import_order()

        // The panic-set barrier (Compiler/Spec/Panic.md#declared-sets, Compiler/Spec/Pipeline.md "The Typed
        // barrier"). A set is the union of its callees' sets, and a callee is
        // only ever in the caller's import closure, so a TU's sets are final
        // once every TU it reaches through imports is typed. In import order
        // that holds for free -- except inside an import CYCLE (a.k and b.k
        // importing each other type-check today), which has no order in which
        // every callee is finished first. So the graph runs in groups, one per
        // strongly connected component of the import graph: every TU of a group
        // goes to SemaPhase::Typed, the group's sets are solved at once, and
        // then each goes on. A group is one TU everywhere there is no cycle, and
        // that is exactly the loop as it was.
        // Every TU's module and default visibility, here, before any Sema
        // runs: parallel Sema reads another TU's from any worker
        // (AST/VisibilityFacts.k), so they are written while one thread runs.
        for var vfid: u32 in self._fids {
            var unsafe *vctx = self._global_scope->get_context(vfid)
            if vctx != &null && vctx->tu != &null {
                stamp_tu_visibility(vctx->tu)
            }
        }

        var groups = ImportGroups()
        groups.build(order, self._global_scope)
        // A header set nothing imported points into (HeaderSet::contributed is
        // false: 85 of the self-host graph's 115) is still each owning TU's
        // fallback for a fill or a deduction its first set cannot spell, and only during that TU's Sema. So it is freed once the last
        // TU owning it has run its group, instead of at exit (~200 MB each).
        // One action only: a later input's graph may own it too.
        var early_release = self._ci->kairo_only_input_count() == 1
            && !self._ci->kairo_feeds_includes()
            && self._ci->headers() != &null
            && !fe.live_check
        var set_owners = llvm::DenseMap<u64, u64>()
        if early_release {
            for var fid: u32 in self._fids {
                var unsafe *octx = self._global_scope->get_context(fid)
                if octx == &null {
                    continue
                }

                var unsafe *otu = octx->tu
                if otu == &null || otu->header_set == &null {
                    continue
                }

                set_owners[otu->header_set as usize as u64] += 1
            }
        }

        var effects:  EffectTable
        var ngroups               = ((groups.starts.size() - 1) as u64)
        var rank_base             = self._global_scope->instances()->reserve_ranks(ngroups)
        var workers               = self._sema_workers()
        progress_begin(PROGRESS_SEMA, groups.fids.size())
        if workers > 1 {
            self._sema_parallel(
                unsafe &groups,
                unsafe &effects,
                rank_base,
                fe.print_sema,
                fe.print_lowered,
                sema_opts,
                early_release,
                unsafe &set_owners,
            )
        } else {
            for var g: usize = 0; g + 1 < groups.starts.size(); ++g {
                var members = cxx::std::vector<u32>()
                for var k: usize = (groups.starts[g]); k < (groups.starts[g + 1]); ++k {
                    members.push_back(groups.fids[k])
                }

                // The same mint ranks as the parallel driver, so the registry
                // keys its worklist the same way under either.
                var slot = SemaSlot()
                slot.rank = group_rank(rank_base, g as u64)
                slot.enter()
                self._sema_group(
                    unsafe &members,
                    unsafe &effects,
                    fe.print_sema,
                    fe.print_lowered,
                    sema_opts,
                )

                SemaSlot::leave()
                if members.size() > 0 && progress_on() {
                    progress_tick(
                        PROGRESS_SEMA,
                        self._ci->sm()->get_filename(members[0]),
                        members.size(),
                    )
                }

                if early_release {
                    self._release_group_sets(members, unsafe &set_owners)
                }
            }
        }

        progress_end(PROGRESS_SEMA)
        // Past every group: a mint from here on (codegen, the next input's
        // header indexing) goes after all of this action's Sema in the
        // worklist, as one appended then always did.
        self._global_scope->instances()->set_floor_rank(group_rank(rank_base, ngroups))

        if fe.print_imports {
            self._dump_overlays()
        }

        if !fe.dump_import_uses.empty() {
            self._dump_import_uses(fe.dump_import_uses)
        }

        if (!fe.dump_interface.empty()) || (!fe.dump_deps.empty()) || self._ci->incr.on {
            self._dump_incremental(fe.dump_interface, fe.dump_deps)
        }

        // Incremental Sema's input list: every file of every header set, so
        // a header edit is a miss though no Kairo file changed. From the
        // sets, not the SourceManager: a header clang read but no Kairo
        // declaration names has no fid there (kfid 0).
        if self._ci->incr.on {
            for var hs: unsafe *HeaderSet in self._graph_header_sets() {
                for var i: usize = 0; i < hs->files.size(); ++i {
                    self._ci->incr.hdr_files.push_back(hs->files[i].path)
                }
            }
        }

        if fe.print_panic_sets {
            self._dump_panic_sets()
        }

        // The EmitPlan is codegen's, but it reads only sema's resolved links, so
        // it can be built and dumped here without a backend. That is what makes
        // it testable at all today: EmitIR cannot yet emit a record, so a full
        // codegen run over a file with a class never reaches the plan.
        if fe.print_emit_plan {
            for var i: usize = 0; i < n; ++i {
                var        fid  = self._fids[n - 1 - i]
                var unsafe *ctx = self._global_scope->get_context(fid)
                if ctx == &null {
                    continue
                }

                var unsafe *tu = ctx->tu
                if tu == &null {
                    continue
                }

                var unsafe *psym = self._ci->pp()->get_symbol_table()
                var        cg    = CodegenContext(ctx, &null, psym, self._global_scope->instances())
                var        plan  = EmitPlan(unsafe &cg, PlanMode::Preamble)
                plan.run()
                plan.dump(self._ci->sm()->get_filename(fid))

                // The header root set too (own pub decls, no uses), so both
                // are golden-testable from one flag. A pathless TU has no
                // header (EmitCXXHeader skips it), so its dump would be noise.
                if CXXSpell::is_entry_tu(tu) {
                    continue
                }

                var hcg   = CodegenContext(ctx, &null, psym, self._global_scope->instances())
                var hplan = EmitPlan(unsafe &hcg, PlanMode::Header)
                hplan.run()
                hplan.dump(self._ci->sm()->get_filename(fid))
            }
        }

        // The interface text needs no clang either, so it is produced here and
        // works under --type-check-only. A header now carries the module's
        // inline and template bodies (EmitCXXHeader), so --emit-headers runs
        // EmitIR over them and ICEs on any such body EmitIR cannot emit yet, as a
        // full codegen run would.
        // A sibling loop, not the plan loop: that one skips a pathless TU before
        // its header dump, and a pathless TU still has a preamble.
        //
        // First, which hidden decls another file's header names (P900,
        // EmitPlan::note_borrowed): their home headers declare them, so every
        // header plan has to see the whole set. Serial, before any header.
        if !fe.emit_headers.empty() && !self._ci->diag()->has_errors() {
            EmitPlan::clear_borrowed()
            var grew   = true
            var rounds = 0
            while grew && rounds < 8 {
                grew   = false
                rounds = rounds + 1
                for var i: usize = 0; i < n; ++i {
                    var unsafe *bctx = self._global_scope->get_context(self._fids[i])
                    if bctx == &null || bctx->tu == &null || CXXSpell::is_entry_tu(bctx->tu) {
                        continue
                    }

                    var bcg = CodegenContext(
                        bctx,
                        &null,
                        self._ci->pp()->get_symbol_table(),
                        self._global_scope->instances(),
                    )

                    var bplan = EmitPlan(unsafe &bcg, PlanMode::Header)
                    bplan.run()
                    if bplan.note_borrowed() {
                        grew = true
                    }
                }
            }
        }

        if fe.print_cxx || !fe.emit_headers.empty() {
            for var i: usize = 0; i < n; ++i {
                var        fid  = self._fids[n - 1 - i]
                var unsafe *ctx = self._global_scope->get_context(fid)
                if ctx == &null {
                    continue
                }

                var unsafe *tu = ctx->tu
                if tu == &null {
                    continue
                }

                // An empty TU prints nothing, not even its banner: a module that
                // only re-exports must not change a golden.
                if fe.print_cxx && !self._tu_is_empty(fid) {
                    var ts = TextSink(self._ci->sm(), self._ci->tcm())
                    var tcg = CodegenContext(
                        ctx,
                        unsafe &ts,
                        self._ci->pp()->get_symbol_table(),
                        self._global_scope->instances(),
                    )

                    var tplan = EmitPlan(unsafe &tcg, PlanMode::Preamble)
                    tplan.run()
                    tcg.advance_phase(CodegenPhase::Planned)
                    InterfaceEmitter(unsafe &tcg, unsafe &tplan).run()
                    io::println(
                        f"============== CXX PREAMBLE fid {fid}: {self._ci->sm()->get_filename(fid)} ==============",
                    )

                    io::println(f"{ts.out}")
                }

                // EmitCXXHeader skips the entry TU and writes nothing for it.
                // Nor after an error: the bodies it emits need a lowered tree,
                // and sema stops short of lowering once anything fails.
                if !fe.emit_headers.empty() && !self._ci->diag()->has_errors() {
                    var h = EmitCXXHeader(
                        ctx,
                        self._ci->pp()->get_symbol_table(),
                        self._global_scope->instances(),
                    )

                    h.line_directives = fe.emit_header_lines || fe.emit_header_layout
                    h.layout          = fe.emit_header_layout
                    if h.write(fe.emit_headers) {
                        var docs: string = ""
                        if h.layout {
                            docs = f" (doc comments: {h.docs_placed} in place, {h.docs_prelude} on a forward declaration, {h.docs_dropped} dropped; out-of-line bodies: {h.bodies_dropped} left out, {h.bodies_needed} kept as needed)"
                        }

                        kairo::Logger::info(
                            kairo::Logger::Stage::Driver,
                            f"emitted header {h.path_under(fe.emit_headers)}" + docs,
                        )
                    } else if h.render().size() > 0 {
                        // write() is false both for a TU with no header (the entry
                        // TU) and for a failed write; only the second has text. An
                        // unwritable --emit-headers dir used to exit 0 silently.
                        self._ci->diag()->report(
                            DiagID::U022E,
                            f"cannot write C++ header '{h.path_under(fe.emit_headers)}'",
                        ).emit()
                    }
                }
            }
        }

        // The set names this compile's decls by address: a later compile in
        // the same process must not read it.
        EmitPlan::clear_borrowed()

        // TODO(sema): full pipeline once N/T/checks land: Sema(ctx, gs).run().
        return true
    }

    /// \brief Sema again for \p fids alone, in an instance whose first
    ///        check is done (Tooling/LiveCheck.k): each of them has been
    ///        re-read, re-preprocessed and re-parsed, and every other file
    ///        of the graph is as its own Sema left it.
    ///
    /// \details What _sema does, for a part of the graph: the header set
    ///          of each file joined and indexed and its ffi imports stamped,
    ///          the prelude import, the visibility stamp, then the files'
    ///          import groups in import order on this thread, each to the
    ///          end of its Sema (its own effect table and mint ranks, after
    ///          every rank of the first check). The files' old interface
    ///          facts are replaced.
    ///
    /// \pre \p fids is closed under "imports one of them": no file left out
    ///      points into one that is in.
    pub fn refresh(self, const fids: cxx::std::vector<u32>) -> string {
        self.refresh_detail = ""
        var fe        = self._ci->invocation()->frontend
        var sema_opts = PrintOptions::diag()
        var unsafe *hc = self._ci->headers()
        if hc != &null {
            hc->wait_all()
            for var fid: u32 in fids {
                var unsafe *hctx = self._global_scope->get_context(fid)
                if hctx == &null {
                    continue
                }

                var unsafe *htu = hctx->tu
                if htu == &null || htu->header_set == &null {
                    continue
                }

                var unsafe *view = unsafe (htu->header_set as unsafe *HeaderSet)
                var unsafe *hs   = view
                if view->shared != &null {
                    hs = view->shared
                }

                self._ci->header_index()->index(hs)
                hs->drain_diags(self._ci->diag(), self._ci->sm())
                self._attach_ffi_edges(htu, hctx, hs, view)
                htu->header_set = unsafe (hs as unsafe *void)
            }
        }

        for var fid: u32 in fids {
            self._inject_prelude_one(fid)
            var unsafe *vctx = self._global_scope->get_context(fid)
            if vctx != &null && vctx->tu != &null {
                stamp_tu_visibility(vctx->tu)
            }
        }

        // The files' old facts go; _sema_finish appends the new ones. Their
        // declarations' interface hashes are kept by DeclId: a record whose
        // C++ stand-in is adopted must still have the layout it was
        // declared with.
        var old_i = llvm::StringMap<u32>()
        var old_v = cxx::std::vector<string>()
        for var i: usize = 0; i < self._incr.size(); ++i {
            var mine = false
            for var fid: u32 in fids {
                if self._incr[i].fid == fid {
                    mine = true
                }
            }

            if mine {
                _facts_hashes(unsafe &self._incr[i], unsafe &old_i, unsafe &old_v)
            }
        }

        var kept = cxx::std::vector<FileFacts>()
        for var i: usize = 0; i < self._incr.size(); ++i {
            var drop = false
            for var fid: u32 in fids {
                if self._incr[i].fid == fid {
                    drop = true
                }
            }

            if !drop {
                kept.push_back(self._incr[i])
            }
        }

        self._incr = kept

        // Import order over the whole graph, cut down to the files asked for.
        var order = cxx::std::vector<u32>()
        for var f: u32 in self._import_order() {
            for var fid: u32 in fids {
                if f == fid {
                    order.push_back(f)
                }
            }
        }

        var groups = ImportGroups()
        groups.build(order, self._global_scope)
        var effects:  EffectTable
        var ngroups   = ((groups.starts.size() - 1) as u64)
        var unsafe *reg = self._global_scope->instances()
        var rank_base   = reg->reserve_ranks(ngroups)
        var relive      = cxx::std::vector<unsafe *InstanceEntry>()
        var relive_at   = cxx::std::vector<SourceRange>()
        reg->relive_log = unsafe &relive
        reg->relive_at  = unsafe &relive_at
        for var g: usize = 0; g + 1 < groups.starts.size(); ++g {
            var members = cxx::std::vector<u32>()
            for var k: usize = (groups.starts[g]); k < (groups.starts[g + 1]); ++k {
                members.push_back(groups.fids[k])
            }

            var slot = SemaSlot()
            slot.rank = group_rank(rank_base, g as u64)
            slot.enter()
            self._sema_group(unsafe &members, unsafe &effects, false, false, sema_opts)
            SemaSlot::leave()
        }

        reg->relive_log = &null
        reg->relive_at  = &null
        reg->set_floor_rank(group_rank(rank_base, ngroups))

        // An instance's once-only reports belong to its FIRST use in the
        // order files are checked. Two ways a re-check of some files can
        // have moved that, each a result a fresh run would not print:
        //  - an entry the set had made live was re-armed and nothing of the
        //    re-check made it live again: its first use is now a kept
        //    file's, which was not re-checked;
        //  - a file of the set used an entry a kept file made live, from a
        //    place earlier in the order than that file.
        if self.tiered {
            // Judged at tier_finish: a later slice may be the one that
            // uses it. Noted here, while this slice's uses are known: made
            // live from a file of its retraction's set, or used (already
            // live) from one.
            for var i: usize = 0; i < self._rearmed.size(); ++i {
                if self._rearm_ok[i] != 0 {
                    continue
                }

                var unsafe *re = self._rearmed[i]
                var *rset      = &self._tt_sets[self._rearm_set[i] as usize]
                if re->depth != 0 && re->use_at.is_valid() && _fid_in(rset, self._ci->sm()->resolve(re->use_at.start).fid as u32) {
                    self._rearm_ok[i] = (1 as u8)
                    continue
                }

                for var k: usize = 0; k < relive.size(); ++k {
                    if relive[k] == re && relive_at[k].is_valid() && _fid_in(rset, self._ci->sm()->resolve(relive_at[k].start).fid as u32) {
                        self._rearm_ok[i] = (1 as u8)
                        break
                    }
                }
            }
        } else {
            for var i: usize = 0; i < self._rearmed.size(); ++i {
                if self._rearmed[i]->depth == 0 {
                    var unsafe *re = self._rearmed[i]
                    var what = if (re->primary != &null) => (incr_decl_id(re->primary, self._ci->pp()->get_symbol_table())) else => "?"
                    self.refresh_detail = what + f" ({self._rearmed_was[i]})"
                    return "an instance the edited files used first is now used first by a kept file"
                }
            }
        }

        for var i: usize = 0; i < relive.size(); ++i {
            if relive[i]->primary != &null && decl_is_imported(relive[i]->primary) {
                continue
            }

            var mine = self._drain_place(relive_at[i])
            var its  = self._drain_place(relive[i]->use_at)
            if mine != usize::MAX && its != usize::MAX && mine < its {
                return "the edited files now use an instance before the kept file that used it first"
            }
        }

        // A C++ stand-in a re-read record adopted keeps the layout clang
        // was given the first time: the record's interface hash, which is
        // its layout, has to be the one it had.
        var unsafe *freg = self._ci->foreign_registry()
        if freg != &null && freg->adopted.size() > 0 {
            var new_i = llvm::StringMap<u32>()
            var new_v = cxx::std::vector<string>()
            for var i: usize = 0; i < self._incr.size(); ++i {
                // In slices, the record may have been re-read by an earlier
                // one: every file a retraction named, as it stands.
                if self.tiered {
                    if self._tt_old_f.contains(self._incr[i].fid as u64) {
                        _facts_hashes(unsafe &self._incr[i], unsafe &new_i, unsafe &new_v)
                    }

                    continue
                }

                for var fid: u32 in fids {
                    if self._incr[i].fid == fid {
                        _facts_hashes(unsafe &self._incr[i], unsafe &new_i, unsafe &new_v)
                    }
                }
            }

            for var i: usize = 0; i < freg->adopted.size(); ++i {
                var id = incr_decl_id(freg->adopted[i], self._ci->pp()->get_symbol_table())
                var b  = new_i.find(kairo::sref(id))
                if self.tiered {
                    var ta = self._tt_old_i.find(kairo::sref(id))
                    if ta == self._tt_old_i.end() || b == new_i.end() || self._tt_old_v[ta->second as usize] != new_v[b->second as usize] {
                        return "a record handed to a C++ template changed its layout: " + id
                    }

                    continue
                }

                var a = old_i.find(kairo::sref(id))
                if a == old_i.end() || b == new_i.end() || old_v[a->second as usize] != new_v[b->second as usize] {
                    return "a record handed to a C++ template changed its layout: " + id
                }
            }
        }

        if (!self.tiered) && ((!fe.dump_interface.empty()) || (!fe.dump_deps.empty())) {
            self._dump_incremental(fe.dump_interface, fe.dump_deps)
        }

        return ""
    }

    /// \brief every slice of a tiered re-check is done: what refresh()
    ///        decides at its end when it is handed the whole set. "" when
    ///        the result stands; otherwise why it takes a full check.
    pub fn tier_finish(self) -> string {
        var why = ""
        for var i: usize = 0; i < self._rearmed.size() && why.empty(); ++i {
            if self._rearm_ok[i] == 0 {
                var unsafe *re = self._rearmed[i]
                var what = if (re->primary != &null) => (incr_decl_id(re->primary, self._ci->pp()->get_symbol_table())) else => "?"
                self.refresh_detail = what + f" ({self._rearmed_was[i]})"
                why = "an instance the edited files used first is now used first by a kept file"
            }
        }

        self._rearmed.clear()
        self._rearmed_was.clear()
        self._rearm_set.clear()
        self._rearm_ok.clear()
        self._tt_sets.clear()
        self._tt_old_i.clear()
        self._tt_old_v.clear()
        self._tt_old_f.clear()
        self._tt_first_prim.clear()
        self._tt_first_fid.clear()
        self._tt_first_entry.clear()
        if !why.empty() {
            return why
        }

        var fe = self._ci->invocation()->frontend
        if (!fe.dump_interface.empty()) || (!fe.dump_deps.empty()) {
            self._dump_incremental(fe.dump_interface, fe.dump_deps)
        }

        return ""
    }

    /// The primaries whose instances \p fid's Sema asked for, from its
    /// dependency log (DepLog::bodies), into \p out.
    priv fn _bodies_of(self, fid: u32, out: unsafe *llvm::DenseSet<u64>) {
        var unsafe *c = self._global_scope->get_context(fid)
        if c == &null || c->tu == &null || c->tu->dep_log == &null {
            return
        }

        for var i: usize = 0; i < c->tu->dep_log->bodies.size(); ++i {
            out->insert(c->tu->dep_log->bodies[i])
        }
    }

    /// \brief may the queued files \p ahead be re-checked before the files
    ///        that precede them in Sema's order (a tool's open buffer and
    ///        what it imports)? An instance's once-only reports belong to
    ///        its first use in that order, so a file that was the first
    ///        user of an instance \p ahead also names must go before it:
    ///        those still queued are appended to \p first (the caller adds
    ///        them and asks again). False when the order cannot be kept:
    ///        such an instance has no first user any more (an edited file
    ///        stopped naming it), and which file is next is not known
    ///        before the files between are re-checked.
    ///
    /// \details Read from what the retractions recorded (the instance's
    ///          primary and the file of its first use) and from the
    ///          dependency logs of \p ahead's OLD trees, which name the
    ///          primaries they instantiate; their text has not changed, so
    ///          they will ask for the same. By primary, not by instance:
    ///          too many files go first, never too few, except that an
    ///          edited file is taken to name an instance still when it
    ///          names another of the same primary. refresh() / tier_finish
    ///          still judge every first use afterwards; a miss here is a
    ///          full check there, not a wrong result.
    pub fn prefer_first_users(self,
                              ahead:  cxx::std::vector<u32>,
                              queued: cxx::std::vector<u32>,
                              edited: cxx::std::vector<u32>,
                              first:  *cxx::std::vector<u32>) -> bool {
        var bodies = llvm::DenseSet<u64>()
        for var f: u32 in ahead {
            self._bodies_of(f, unsafe &bodies)
        }

        for var i: usize = 0; i < self._tt_first_prim.size(); ++i {
            if !bodies.contains(self._tt_first_prim[i]) {
                continue
            }

            var fid = self._tt_first_fid[i]
            if _fid_in(&ahead, fid) {
                continue
            }

            if _fid_in(&queued, fid) {
                if !_fid_in(first, fid) {
                    first->push_back(fid)
                }

                continue
            }

            // Its first user is re-checked. Re-armed: it is live again, or
            // nobody has named it since.
            var unsafe *e = self._tt_first_entry[i]
            if e != &null {
                if e->depth == 0 {
                    return false
                }

                continue
            }

            // Dropped: an importer re-read with its text unchanged names it
            // again; an edited file does when its new tree still asks for
            // the primary.
            if _fid_in(&edited, fid) {
                var now = llvm::DenseSet<u64>()
                self._bodies_of(fid, unsafe &now)
                if !now.contains(self._tt_first_prim[i]) {
                    return false
                }
            }
        }

        return true
    }

    /// \p fids group by group, as the sema loop runs them: each import
    /// cycle's members together, each group after every group it imports
    /// (ImportGroups over order_of). order_of alone breaks a cycle at one
    /// file, which then stands BEFORE files outside the cycle that it
    /// imports; in this order the first file's group imports nothing else
    /// of the list.
    pub fn group_order_of(self, const fids: cxx::std::vector<u32>) -> cxx::std::vector<u32> {
        var groups = ImportGroups()
        groups.build(self.order_of(fids), self._global_scope)
        return groups.fids
    }

    /// KAIRO_LIVE_DEBUG: the stores retract() purges hold nothing of a
    /// replaced tree (Sema/Incremental/Retract.k, verify_retired). How
    /// many they do hold.
    pub fn verify_retired(self) -> usize {
        return verify_retired(self._global_scope, self._ci->foreign_registry(), self._ci->retired)
    }

    /// \brief every address of the replaced trees (\p dead: their arena
    ///        blocks) leaves the build-wide stores that are keyed by one or
    ///        hold one: the canonical type table, the conformance rows,
    ///        the dropped instances. After it CompilerInstance::
    ///        release_retired may free them. Says what went, for a log.
    ///
    /// \pre every file of every retraction has been re-checked (no queued
    ///      file holds an old tree) and tier_finish / refresh accepted the
    ///      result.
    pub fn sweep_retired(self, dead: unsafe *kairo::AddrRanges) -> string {
        var shells = llvm::DenseSet<u64>()
        var types  = llvm::DenseSet<u64>()
        var unsafe *reg = self._global_scope->instances()
        reg->dead_shells(unsafe &shells)
        var nt = self._global_scope->types()->sweep(dead, unsafe &shells, unsafe &types, false)
        var nr = reg->sweep_dead(dead, unsafe &types, false)
        return f"{nt} canonical types, {nr} conformance rows, {shells.size()} instance nodes"
    }

    /// \brief a retraction's part of the same: the conformance rows that
    ///        name a declaration of \p set (a witness, the declaring
    ///        `impl`, a conformer that is one of its records) leave the
    ///        tables NOW, while the files are still to be re-read.
    ///
    /// \details A row is found by (conformer, interface), and `extend i32
    ///          impl I` in a file of the set is found by every later
    ///          question about i32: left in, the re-check is answered from
    ///          the old text (a witness that was renamed away still
    ///          conforms), and the file's own re-check adds nothing, the
    ///          row being there.
    priv fn _retract_rows(self, const set: cxx::std::vector<u32>) {
        var dead = kairo::AddrRanges()
        dead.label(kairo::std::to_std_string("a file being re-read"))
        for var f: u32 in set {
            var unsafe *c = self._global_scope->get_context(f)
            if c != &null {
                c->ranges_into(unsafe &dead, 0)
            }
        }

        dead.seal()
        var shells = llvm::DenseSet<u64>()
        var types  = llvm::DenseSet<u64>()
        var unsafe *reg = self._global_scope->instances()
        reg->dead_shells(unsafe &shells)
        self._global_scope->types()->sweep(unsafe &dead, unsafe &shells, unsafe &types, true)
        reg->sweep_dead(unsafe &dead, unsafe &types, true)
    }

    /// \p fids in the order their Sema runs (import order over the graph).
    pub fn order_of(self, const fids: cxx::std::vector<u32>) -> cxx::std::vector<u32> {
        var want = llvm::DenseSet<u64>()
        for var f: u32 in fids {
            want.insert(f as u64)
        }

        var out = cxx::std::vector<u32>()
        for var f: u32 in self._import_order() {
            if want.contains(f as u64) {
                out.push_back(f)
            }
        }

        return out
    }

    /// \brief why \p set cannot be re-checked by refresh(), "" when it
    ///        can. Asked on the files' CHECKED trees, before they are
    ///        re-read.
    ///
    /// \details Each reason is something a file of the set wrote into
    ///          state that outlives its tree and that nothing takes back
    ///          out: such an edit is a full check.
    pub fn refresh_blocker(self, const set: cxx::std::vector<u32>) -> string {
        for var fid: u32 in set {
            var unsafe *ctx = self._global_scope->get_context(fid)
            if ctx == &null || ctx->tu == &null {
                return "a file of the refresh set was never checked"
            }

            var unsafe *tu = ctx->tu
            // The registry's specialization tables match every use in the
            // build, and hold the declaration.
            var exts = cxx::std::vector<unsafe *Decl>()
            if _refresh_specs(unsafe (tu as unsafe *DeclContext), unsafe &exts) {
                return "a file that declares a specialization: " + Path(ctx->sm->get_filename(fid)).filename()
            }

            // An out-of-line definition is spliced into the redeclaration
            // ring of a class another file declares.
            for var i: usize = 0; i < tu->out_of_line.size(); ++i {
                var unsafe *d = *tu->out_of_line.get(i)
                if d == &null || d->semantic_dc == &null {
                    continue
                }

                var unsafe *home  = NameLookup::tu_of(d->semantic_dc)
                var        inside = false
                for var f: u32 in set {
                    var unsafe *c = self._global_scope->get_context(f)
                    if c != &null && c->tu == home {
                        inside = true
                    }
                }

                if !inside {
                    return "a file that defines another file's member out of line: " + Path(ctx->sm->get_filename(fid)).filename()
                }
            }
        }

        return ""
    }

    /// The header set \p fid's ffi imports are checked against (the
    /// build's shared one when its list was merged into it), or null.
    pub fn header_set_of(self, fid: u32) -> unsafe *void {
        var unsafe *ctx = self._global_scope->get_context(fid)
        if ctx == &null || ctx->tu == &null || ctx->tu->header_set == &null {
            return &null
        }

        var unsafe *view = unsafe (ctx->tu->header_set as unsafe *HeaderSet)
        if view->shared != &null {
            return unsafe (view->shared as unsafe *void)
        }

        return unsafe (view as unsafe *void)
    }

    /// \brief before \p set is re-read: its files are taken out of the
    ///        build-wide stores that outlive a tree.
    pub fn retract(self, const set: cxx::std::vector<u32>) -> RetractStats {
        // The layouts the set's records have, while its facts are the old
        // ones: a slice compares against them whenever it runs.
        if self.tiered {
            for var i: usize = 0; i < self._incr.size(); ++i {
                var mine = false
                for var f: u32 in set {
                    if self._incr[i].fid == f {
                        mine = true
                    }
                }

                if mine && !self._tt_old_f.contains(self._incr[i].fid as u64) {
                    self._tt_old_f.insert(self._incr[i].fid as u64)
                    _facts_hashes(unsafe &self._incr[i], unsafe &self._tt_old_i, unsafe &self._tt_old_v)
                }
            }
        }

        var st = retract_instances(self._global_scope, self._ci->sm(), self._ci->foreign_registry(), set)
        self._retract_rows(set)
        if !self.tiered {
            self._rearmed = st.rearmed_list
            self._rearmed_was.clear()
            for var i: usize = 0; i < st.rearmed_was.size(); ++i {
                self._rearmed_was.push_back(st.rearmed_was[i])
            }

            return st
        }

        // An entry an earlier retraction re-armed and this one dropped has
        // nothing left to report.
        var gone = llvm::DenseSet<u64>()
        for var i: usize = 0; i < st.dropped_list.size(); ++i {
            gone.insert(st.dropped_list[i] as usize as u64)
        }

        for var i: usize = 0; i < self._rearmed.size(); ++i {
            if gone.contains(self._rearmed[i] as usize as u64) {
                self._rearm_ok[i] = (1 as u8)
            }
        }

        for var i: usize = 0; i < st.first_prim.size(); ++i {
            self._tt_first_prim.push_back(st.first_prim[i])
            self._tt_first_fid.push_back(st.first_fid[i])
            self._tt_first_entry.push_back(st.first_entry[i])
        }

        self._tt_sets.push_back(set)
        for var i: usize = 0; i < st.rearmed_list.size(); ++i {
            self._rearmed.push_back(st.rearmed_list[i])
            self._rearmed_was.push_back(st.rearmed_was[i])
            self._rearm_set.push_back((self._tt_sets.size() - 1) as u64)
            self._rearm_ok.push_back(0 as u8)
        }

        return st
    }

    /// The place of the file of \p at in the order files are drained (a
    /// first check's order, kept by the per-file diagnostics); usize::MAX
    /// when unknown.
    priv fn _drain_place(self, at: SourceRange) -> usize {
        var unsafe *fdc = unsafe (self._ci->invocation()->frontend.file_diags as unsafe *FileDiagConsumer)
        if fdc == &null || !at.is_valid() {
            return usize::MAX
        }

        var name = self._ci->sm()->get_filename(at.start)
        for var i: usize = 0; i < fdc->order.size(); ++i {
            if fdc->order[i] == name {
                return i
            }
        }

        return usize::MAX
    }

    /// \brief the files that must join \p set because a file of it
    ///        extends a record they declare: an extension is visible in the
    ///        extended record's own file whether that file imports it or
    ///        not (MemberLookup's visibility rule), so that file reads the
    ///        set and is re-checked with it. Appended to \p out, each once;
    ///        the caller adds their importers and asks again.
    pub fn refresh_extends(self, const set: cxx::std::vector<u32>, out: *cxx::std::vector<u32>) {
        for var fid: u32 in set {
            var unsafe *ctx = self._global_scope->get_context(fid)
            if ctx == &null || ctx->tu == &null {
                continue
            }

            var exts = cxx::std::vector<unsafe *Decl>()
            _refresh_specs(unsafe (ctx->tu as unsafe *DeclContext), unsafe &exts)
            for var i: usize = 0; i < exts.size(); ++i {
                var unsafe *e = cast<Declarations::ExtensionDecl>(exts[i])
                var unsafe *c = e->target
                if c != &null && c->canonical != &null {
                    c = c->canonical
                }

                if c != &null && isa<QualifiedType>(c) {
                    c = cast<QualifiedType>(c)->inner
                    if c != &null && c->canonical != &null {
                        c = c->canonical
                    }
                }

                if c == &null || !isa<RecordType>(c) || cast<RecordType>(c)->decl == &null {
                    continue
                }

                var unsafe *home = NameLookup::ctx_of(cast<RecordType>(c)->decl)
                if home == &null || home->tu == &null || home->tu->is_foreign {
                    continue
                }

                var have = false
                for var f: u32 in set {
                    if f == home->fid {
                        have = true
                    }
                }

                for var k: usize = 0; k < out->size(); ++k {
                    if (*out)[k] == home->fid {
                        have = true
                    }
                }

                if !have {
                    out->push_back(home->fid)
                }
            }
        }
    }

    /// The prelude import of one non-builtin file, as _sema injects it for
    /// every file of a first check (see there for why it is a real
    /// ImportDecl and why it is stamped rather than resolved).
    priv fn _inject_prelude_one(self, fid: u32) {
        var bfid = self._global_scope->builtin_fid()
        if bfid == 0 || fid == bfid || self._ci->invocation()->pp.no_builtins {
            return
        }

        var unsafe *pctx = self._global_scope->get_context(fid)
        if pctx == &null || pctx->tu == &null || pctx->tu->is_foreign {
            return
        }

        var unsafe *ptu = pctx->tu
        var afid        = u32::MAX
        var bsym        = self._ci->pp()->get_symbol_table()->intern(builtin_root_name())
        var s_base      = self._ci->pp()->get_symbol_table()->intern("base")
        var s_alloc     = self._ci->pp()->get_symbol_table()->intern("alloc")
        for var i: usize = 0; i < self._fids.size(); ++i {
            var unsafe *actx = self._global_scope->get_context(self._fids[i])
            if actx == &null {
                continue
            }

            var *asg = &actx->module_base.segments
            if asg->size() != 3 {
                continue
            }

            if (*asg)[0].name == bsym && (*asg)[1].name == s_base && (*asg)[2].name == s_alloc {
                afid = self._fids[i]
                break
            }
        }

        var prng = SourceRange::invalid()
        if pctx->sm != &null {
            var ploc = pctx->sm->get_loc(fid, 0)
            prng = SourceRange(ploc, ploc)
        }

        var unsafe *pid = Declarations::ImportDecl::create(pctx, prng, Declarations::ImportKind::Native)
        pid->is_wildcard    = true
        pid->is_prelude     = true
        pid->resolved_fid   = bfid
        pid->file_seg_count = 1
        ptu->imports.push(pid)
        var pedge = ImportEdge{}
        pedge.target_fid = bfid
        pedge.decl       = pid
        ptu->import_edges.push(pedge)
        if afid != u32::MAX && afid != fid && ptu->has_alloc_sugar {
            var unsafe *aid = Declarations::ImportDecl::create(pctx, prng, Declarations::ImportKind::Native)
            aid->is_prelude     = true
            aid->resolved_fid   = afid
            aid->file_seg_count = 1
            ptu->imports.push(aid)
            var aedge = ImportEdge{}
            aedge.target_fid = afid
            aedge.decl       = aid
            ptu->import_edges.push(aedge)
        }
    }

    /// Stamp every ffi ImportDecl of \p tu with what its header resolved to in
    /// \p hs: resolved_fid (the header's own fid), the closure fids phase I folds,
    /// and one ImportEdge per closure header, so the import graph (importers_of,
    /// release's inbound-edge guard) sees a header the way it sees a Kairo file.
    /// A spelling clang never resolved leaves resolved_fid 0 and no edges.
    /// \p hs is the set the TU's headers were parsed in; \p view the TU's own
    /// list, which is \p hs unless the build parsed every list as one:
    /// then a spelling is first resolved as the view's own parse resolved it.
    priv fn _attach_ffi_edges(self,
                              tu:   unsafe *TranslationUnit,
                              ctx:  unsafe *ASTContext,
                              hs:   unsafe *HeaderSet,
                              view: unsafe *HeaderSet) {
        for var i: usize = 0; i < tu->imports.size(); ++i {
            var unsafe **slot = tu->imports.at(i)
            if slot == &null {
                continue
            }

            var unsafe *id = dyn_cast<Declarations::ImportDecl>(*slot)
            if id == &null || !id->has_ffi_linkage() {
                continue
            }

            // Before the stamp-once skip: each action reports it for its link.
            var hdr = HeaderSet::unquote(ctx->get_spelling(id->header))
            if hdr == "pthread.h" {
                self.result.ffi_pthread = true
            }

            // A fid shared by two inputs' graphs reaches here twice; stamp once.
            if id->ffi_closure_fids.size() > 0 {
                continue
            }

            var key = hdr
            if view != hs {
                key = HeaderSetCache::resolve_spelling(view, hdr)
            }

            var unsafe *ks = hs->closure_kfids(key)
            for var p: usize = 0; p < ks->size(); ++p {
                var k = (*ks)[p]
                if id->ffi_closure_fids.size() == 0 {
                    id->resolved_fid = k
                }

                id->ffi_closure_fids.push_back(k)
                var e = ImportEdge{}
                e.target_fid = k
                e.decl       = id
                tu->import_edges.push(e)
            }

            id->file_seg_count = 0
        }
    }

    /// Every fid of the graph, each after everything it imports.
    ///
    /// Reversing `_fids` is not that order: it is a tree walk, so reversed it
    /// puts a later SIBLING first. `module.k` imports `string` before `fmt`
    /// (now fmt/fmt_buf.k), and reversed, `fmt` was typed before `string` had
    /// resolved -- every `s.len` on a `string` came out unknown, without an
    /// error, and reached codegen untyped. A fid is placed once each fid it imports (in this graph)
    /// is placed; imports are acyclic, but should a pass place nothing the rest
    /// go in the old reverse order rather than be dropped.
    priv fn _import_order(self) -> cxx::std::vector<u32> {
        var n     = self._fids.size()
        var order = cxx::std::vector<u32>()
        // Membership only (order comes from the _fids walk). Keyed by the fid
        // WIDENED: an import edge's target_fid can be u32(-1), DenseSet<u32>'s
        // empty key, and even a find with it asserts.
        var placed = llvm::DenseSet<u64>()
        var in_set = llvm::DenseSet<u64>()
        for var i: usize = 0; i < n; ++i {
            in_set.insert(self._fids[i] as u64)
        }

        while order.size() < n {
            var progressed = false
            for var i: usize = 0; i < n; ++i {
                var fid = self._fids[n - 1 - i]
                if placed.contains(fid) {
                    continue
                }

                var        ready                         = true
                var unsafe *ctx                          = self._global_scope->get_context(fid)
                var        tu:   unsafe *TranslationUnit = &null
                if ctx != &null {
                    tu = ctx->tu
                }

                if tu != &null {
                    for var j: usize = 0; j < tu->import_edges.size(); ++j {
                        var unsafe *e = tu->import_edges.get(j)
                        if e == &null {
                            continue
                        }

                        var t = e->target_fid
                        if t == fid || !in_set.contains(t) {
                            continue
                        }

                        if !placed.contains(t) {
                            ready = false
                            break
                        }
                    }
                }

                if !ready {
                    continue
                }

                order.push_back(fid)
                placed.insert(fid as u64)
                progressed = true
            }

            // Stuck on an import cycle: break it at ONE file and keep sorting.
            // Placing every remaining file at once in list order would drop the
            // dependency order for the whole rest of the program -- and the
            // builtin prelude has a cycle (module.k -> containers -> alloc.k ->
            // module.k for Nullable), so every program would hit it.
            // ImportGroups keeps each cycle's members together either way.
            if !progressed {
                for var i: usize = 0; i < n; ++i {
                    var fid = self._fids[n - 1 - i]
                    if placed.find(fid) == placed.end() {
                        order.push_back(fid)
                        placed.insert(fid)
                        break
                    }
                }
            }
        }

        return order
    }

    /// Semantic analysis stage: runs the pipeline to its current end (N) over
    /// every fid of this TU's graph, then honors the sema dump flags.
    /// One group of the sema loop (FrontendAction::_sema): every Kairo TU of
    /// \p fids to SemaPhase::Typed, the group's panic sets solved, then each
    /// on to Checked, the lowerings and mono, in \p fids's order.
    ///
    /// The group's Semas live until the second pass is done, at addresses that
    /// never move: Sema keeps `&self.sc` (and the context `&self.lifecycle`)
    /// from its constructor on, so a growing vector of them by value would
    /// break both. The arena runs their destructors when the group ends, which
    /// for a group of one is where the loop's `sem` used to die.
    priv fn _sema_group(self,
                        fids:          unsafe *cxx::std::vector<u32>,
                        effects:       unsafe *EffectTable,
                        print_sema:    bool,
                        print_lowered: bool,
                        sema_opts:     PrintOptions) {
        var sems = self._sema_make(*fids)
        self._sema_finish(sems, effects, print_sema, print_lowered, sema_opts)
        for var i: usize = 0; i < sems.size(); ++i {
            kairo::std::destroy(sems[i])
        }
    }

    /// One Sema per Kairo TU of a group, in member order. On the heap, one
    /// object each, so its address never moves (Sema keeps `&self.sc`, and the
    /// context keeps `&self.lifecycle`, from its constructor on) and the
    /// parallel driver can hold a group's Semas from its typed checks on a
    /// worker until its late checks on this thread. The caller destroys them.
    priv fn _sema_make(self, const fids: cxx::std::vector<u32>) -> cxx::std::vector<unsafe *Sema> {
        var sems = cxx::std::vector<unsafe *Sema>()
        for var i: usize = 0; i < fids.size(); ++i {
            var        fid  = (fids)[i]
            var unsafe *ctx = self._global_scope->get_context(fid)
            if ctx == &null {
                continue
            }

            var unsafe *tu = ctx->tu
            if tu == &null {
                continue
            }

            if tu->is_foreign { // decls came from clang, already resolved; nothing to run.
                continue
            }

            var unsafe *sem = kairo::std::create<Sema>(ctx, self._global_scope)
            sem->sc.foreign  = self._ci->foreign_instantiate() // before any pass captures &sem->sc.
            sem->sc.builtins = self._ci->builtins()
            // The file this action was asked to compile is a root, and may be a
            // script (Compiler/Spec/ScriptMode.md#which-file-is-a-script); a fid reached through its imports, or a
            // `.k` a C++ input includes (discovered), is a module, whose
            // top-level statement nothing would run. The same answer for kcc and
            // every --emit mode: it depends on the command line, not the output.
            sem->sc.script_root = fid == self._file_id && !self.discovered
            sems.push_back(sem)
        }

        return sems
    }

    /// A group's Sema from wherever its Semas are (a fresh group, or one whose
    /// typed checks before Conformance already ran on a worker) to the
    /// end: the rest of the typed checks, the panic-set barrier, the late
    /// checks, the lowerings, mono, and the diagnostics drained into the
    /// driver's sink. Driver thread, groups in import order.
    priv fn _sema_finish(self,
                         const sems_in: cxx::std::vector<unsafe *Sema>,
                         effects:       unsafe *EffectTable,
                         print_sema:    bool,
                         print_lowered: bool,
                         sema_opts:     PrintOptions) {
        var sems = sems_in
        for var i: usize = 0; i < sems.size(); ++i {
            sems[i]->sc.effects = unsafe (effects as unsafe *void)
        }

        // One TU goes to Typed in one run, as it always did. The TUs of an
        // import cycle go there in LOCKSTEP, one phase at a time across the
        // group: each phase of one reads what the same phase of the other
        // produced (I folds the other's surface, X calls functions whose
        // parameter types the other's T resolved), and with no order in which
        // every import is finished first, run one TU to Typed ahead of the
        // other and its calls into the other see unresolved types. A TU that
        // stops in a phase (a hard stop in I/N/T) goes no further; the others
        // carry on, as an acyclic importer of it would.
        {
            var _ts = TimeRegion("Sema")
            if sems.size() == 1 {
                // A split run whose front stopped short of the typed
                // checks hit a hard stop there, and a continuation would carry
                // it past the stop; one that finished them continues into
                // Conformance. An unsplit run goes to Typed as it always did.
                // One _settle_once stopped after T goes no further.
                if !sems[0]->stopped()
                    && (!sems[0]->split_conformance || sems[0]->checks_front_done()) {
                    sems[0]->run_to(SemaPhase::Typed)
                }
            } else {
                // A group whose front ran on a worker continues where it
                // stopped; phases it finished are skipped. Its Conformance,
                // split off the typed checks there, runs here.
                for var i: usize = 0; i < sems.size(); ++i {
                    sems[i]->split_conformance = false
                }

                sema_lockstep(unsafe &sems, false)
            }
        }

        // The barrier. A TU that stopped short of Typed (a hard stop in I/N/T)
        // is not registered: its bodies were never typed, and a call into it
        // says nothing about panics (EffectPropagation, "a set that cannot be
        // known"). A TU that reached Typed with errors is: its poisoned nodes
        // are skipped like everywhere else.
        {
            var _te = TimeRegion("PanicSets")
            sema_sub(9, 0)
            effects->reset()
            for var i: usize = 0; i < sems.size(); ++i {
                if (sems[i]->sc.phase as u8) >= (SemaPhase::Typed as u8) {
                    effects->add_tu(unsafe &sems[i]->sc)
                }
            }

            effects->solve()
        }

        // The TU that declares the Nullable lang item lowers first: every `T?`
        // in another TU is lowered through its layout, which that TU's
        // EnumLayoutLowering builds. Import order already puts the builtin root
        // ahead of what imports it, except around a cycle: a builtin file the
        // root imports that itself imports alloc.k (which names `T?`) put
        // alloc.k first, and NullTestLowering ICEd on the missing layout.
        var order = cxx::std::vector<usize>()
        for var i: usize = 0; i < sems.size(); ++i {
            var unsafe *en = sems[i]->sc.nullable_enum()
            var unsafe *home = if (en != &null) => (NameLookup::tu_of(en->semantic_dc))
                               else => &null
            if home != &null && home == sems[i]->sc.tu {
                order.push_back(i)
                break
            }
        }

        for var i: usize = 0; i < sems.size(); ++i {
            if order.size() > 0 && order[0] == i {
                continue
            }

            order.push_back(i)
        }

        for var oi: usize = 0; oi < order.size(); ++oi {
            var unsafe *sem                    = sems[order[oi]]
            var        ctx: unsafe *ASTContext = sem->sc.ctx
            sema_sub(10, oi)
            // Through L, not just the checks: OperatorLowering rewrites every user
            // operator into the call it is, and codegen ICEs on any operator node
            // that reaches it. --type-check-only stops here too, so the lowering
            // schedule runs under it and is exercised by the sema tests.
            // The dump is PINNED at Checked: X's output is what --print-sema is
            // about, and a lowering replaces the very nodes it names (a list
            // literal becomes a ctor call, a cast becomes a construction). Run
            // the rest afterwards; --print-lowered is the same dump on the far
            // side, for asserting what a lowering produced.
            // Splitting the run must not lose the hard stop: a stage that
            // returned false has already halted the pipeline, and re-entering
            // would carry on past it -- running the checks and the lowerings over
            // a tree whose names or types never resolved, which is cascade noise
            // by the schedule's own policy (Sema.k::_hard_stop). A TU that
            // stopped before Typed is not continued at all; one that reached it
            // runs the late checks whatever errors it had, as one run did.
            var reached = false
            if (sem->sc.phase as u8) >= (SemaPhase::Typed as u8) {
                var _ts = TimeRegion("Sema")
                reached = sem->run_to(SemaPhase::Checked)
            }

            if print_sema {
                SemaDump(unsafe &sem->sc, sema_opts).run()
            }

            // The same pin, for incremental Sema's facts: an interface is
            // what the CHECKED tree says, and the lowerings below rewrite it
            // (Compiler/Spec/IncrementalSema.md).
            var has_facts = false
            if sem->sc.opts.log_deps && sem->sc.tu != &null {
                var _ti   = TimeRegion("IncrFacts")
                var facts = FileFacts{}
                IncrFacts(unsafe &sem->sc, self._ci->pp()->get_symbol_table()).run(unsafe &facts)
                self._incr.push_back(facts)
                has_facts = true
            }

            // The same pin, for a tool: kals indexes the tree here, before a
            // lowering replaces the operator and literal nodes a user wrote.
            // Whatever the TU reached, including one that stopped early: an
            // editor wants the half-resolved tree of a broken file too.
            var unsafe *observer = self._ci->invocation()->frontend.sema_observer
            if observer != &null {
                unsafe { (observer as unsafe *SemaObserver)->on_checked(unsafe &sem->sc) }
            }

            // Two continuations instead of one run(), only so the timing tree can
            // tell lowering from mono. run_to is re-entrant and _done() is pure,
            // so stopping at Lowered and resuming is the same schedule.
            if reached {
                {
                    var _tl = TimeRegion("Lower")
                    sem->run_to(SemaPhase::Lowered)
                }

                {
                    var _tm = TimeRegion("Mono")
                    sem->run()
                }
            }

            // The tool's second look, once the lowerings have written what
            // a layout query reads (kals: an ADT's size on hover). Always,
            // so a tool that held something back at on_checked gets it back.
            if observer != &null {
                unsafe { (observer as unsafe *SemaObserver)->on_lowered(unsafe &sem->sc) }
            }

            // Test hook (Tests/CLI/Driver/ice_flushes_diagnostics.k): an ICE at
            // the worst point for the diagnostics -- Sema done on a TU that
            // reported errors, its sink not yet drained -- so the test proves
            // the ICE path flushes them.
            if cxx::std::getenv(r"KAIRO_DEBUG_FORCE_ICE") != &null
                && ctx->diag_sink.error_count() > 0 {
                kairo::std::ice_fail("forced by KAIRO_DEBUG_FORCE_ICE (a test hook)")
            }

            if ctx->diag_sink.error_count() > 0 {
                ctx->sema_errored = true
            }

            // Incremental Sema keeps a TU's diagnostics with its record
            // (Compiler/Spec/IncrementalSema.md, change 4 as far as a record
            // needs it): the text this drain delivers, and the other files
            // it names a position in. Only for a recording run; the lowerings
            // and mono above have reported what they will by now.
            var rec_diag = has_facts && self._ci->incr.on
            var d0: usize = 0
            if rec_diag {
                var named = cxx::std::vector<u32>()
                ctx->diag_sink.named_fids(ctx->sm, unsafe &named)
                var *ff = &self._incr[self._incr.size() - 1]
                for var ni: usize = 0; ni < named.size(); ++ni {
                    if named[ni] != ctx->fid {
                        ff->diag_files.push_back(ctx->sm->get_filename(named[ni]))
                    }
                }

                llvm::sort(ff->diag_files.begin(), ff->diag_files.end())
                d0 = self._ci->incr_diag_count()
            }

            // A tool keeping diagnostics per file is told whose these are.
            var unsafe *fdc = unsafe (self._ci->invocation()->frontend.file_diags as unsafe *FileDiagConsumer)
            if fdc != &null {
                fdc->enter(ctx->sm->get_filename(ctx->fid))
            }

            ctx->diag_sink.drain_into(self._ci->diag(), ctx->sm)
            if fdc != &null {
                fdc->current = ""
            }

            if rec_diag {
                self._incr[self._incr.size() - 1].diag = self._ci->incr_diag_text(d0, self._ci->incr_diag_count())
            }

            // Kept past `sem`: the batch rejects two scripts in one link.
            if sem->sc.script_at.is_valid() {
                self.result.script_at = sem->sc.script_at
            }

            // Likewise two global allocators. One action compiles every module
            // its input imports, so the second may be in this same loop: that
            // one is reported here, the batch compares actions.
            if sem->sc.tu != &null && sem->sc.tu->global_alloc_at.is_valid() {
                var here  = sem->sc.tu->global_alloc_at
                var hfile = ctx->sm->get_filename(here.start)
                // Its forwarders would be strong kairo_global_* definitions in an
                // object that inlined System for its own allocations: refused
                // here rather than at the link. Only a split build gets here
                // (_settle_global_allocator found it otherwise).
                if !self._ci->invocation()->pp.global_allocator_set
                    && !self._ci->invocation()->frontend.stops_before_codegen() {
                    var hname = Path(hfile).filename()
                    var mac   = LowerTargets::global_alloc_set_macro()
                    var d = self._ci->diag()->report(
                        DiagID::SC140E,
                        here.start,
                        f"'{hname}' sets the global allocator, but this build does not define {mac}; pass --global-allocator-set when compiling the program's files separately",
                    )

                    d.first(here)
                    d.emit()
                }

                if !self.result.global_alloc_at.is_valid() {
                    self.result.global_alloc_at   = here
                    self.result.global_alloc_file = hfile
                } else if self.result.global_alloc_file != hfile {
                    var first = self.result.global_alloc_at
                    var a     = Path(self.result.global_alloc_file).filename()
                    var b     = Path(hfile).filename()
                    var d = self._ci->diag()->report(
                        DiagID::SC138E,
                        here.start,
                        f"two files set the global allocator: '{b}' and '{a}'; a program has one",
                    )

                    d.first(here)
                    d.note(DiagCode(DiagID::SC138N), first.start, f"'{a}' sets it here")->child_first(
                        first,
                    )

                    d.emit()
                }
            }

            // Dump INSIDE the loop: SemaDump reads sc.phase / sc.well_known, which
            // live on this fid's SemaContext and die with the arena.
            if print_lowered {
                io::println(f"-- lowered: {self.path.full_path()} --")
                SemaDump(unsafe &sem->sc, sema_opts).run()
            }
        }
    }

    /// How many threads run Sema: the pool, unless --sema-threads
    /// names a count (1 is the one-thread loop, the A/B baseline for the
    /// byte-identical gate). The dumps that print as each TU finishes keep one
    /// thread, as --print-cg does for codegen; so does a one-thread pool.
    priv fn _sema_workers(self) -> usize {
        var unsafe *pool = self._ci->pool()
        if pool == &null {
            return 1
        }

        var workers = pool->get_thread_count()
        var fe      = self._ci->invocation()->frontend
        if fe.sema_threads > 0 {
            workers = (fe.sema_threads as usize)
        }

        if fe.print_sema || fe.print_lowered {
            workers = 1
        }

        return workers
    }

    /// Sema over the import groups with each group's front (I, E, V, N, T and
    /// the typed checks before ConformanceChecking, about 85% of Sema's time;
    /// an import cycle's members in lockstep) on the pool, and the rest on
    /// this thread, one group at a time in import order, exactly as the
    /// one-thread loop runs it.
    ///
    /// A front may start once every group it imports has finished all of its
    /// Sema (its importers read its lowered, mono'd tree). It runs beside other
    /// fronts and beside the driver's late part of an earlier group, neither of
    /// which it imports. What keeps every observable order that of the
    /// one-thread loop (Compiler/Spec/Performance.md#parallel-sema):
    ///  - diagnostics go into each TU's own sink and are drained here, in
    ///    group order (_sema_finish);
    ///  - InstantiationRegistry keys its worklist and its homes by the step of
    ///    the one-thread schedule that asked (sema_mint_rank, sema_sub), not by
    ///    the thread that got there first; NullableTypeLowering, the panic-set
    ///    anchor and re-filled foreign shells follow the same keys;
    ///  - Conformance, which decides where an instance diagnostic lands, the
    ///    panic-set barrier, the late checks, the lowerings and mono stay on
    ///    this thread, in order;
    ///  - a once-per-build report T meets in a front (SC157E / SC158E) is
    ///    recorded, not claimed, and the front stops after T; this thread
    ///    claims it at the group's turn (_settle_once), so the first file in
    ///    the one-thread order reports it and stops, as with one thread;
    ///  - a group whose Sema writes facts that TUs not importing it read runs
    ///    alone (a barrier, no front): a builtin TU (lang items,
    ///    WellKnownDecls), a TU declaring a specialization (the registry's
    ///    tables match every use) or an extension (every TU's member lookup
    ///    indexes it). A front that meets such a fact mid-way (an `eval if`
    ///    deferred to layouts, an out-of-line definition of another file's
    ///    member) stops there, and the driver finishes that group alone.
    priv fn _sema_parallel(self,
                           groups:        unsafe *ImportGroups,
                           effects:       unsafe *EffectTable,
                           rank_base:     u64,
                           print_sema:    bool,
                           print_lowered: bool,
                           sema_opts:     PrintOptions,
                           early_release: bool,
                           set_owners:    unsafe *llvm::DenseMap<u64, u64>) {
        var m = groups->starts.size() - 1
        // fid -> group, for the edges.
        var group_of = llvm::DenseMap<u64, u64>()
        for var g: usize = 0; g < m; ++g {
            for var k: usize = (groups->starts[g]); k < (groups->starts[g + 1]); ++k {
                group_of[groups->fids[k] as u64] = (g as u64)
            }
        }

        var slots   = cxx::std::vector<unsafe *SemaSlot>()
        var maxdep  = cxx::std::vector<usize>() ///< 1 + the last group it imports; 0 for none.
        var barrier = cxx::std::vector<u8>()
        for var g: usize = 0; g < m; ++g {
            var unsafe *slot = kairo::std::create<SemaSlot>()
            slot->rank = group_rank(rank_base, g as u64)
            for var k: usize = (groups->starts[g]); k < (groups->starts[g + 1]); ++k {
                slot->members.push_back(groups->fids[k])
            }

            var dep:       usize = 0
            var kairo_tus: usize = 0
            var serial           = false
            for var fid: u32 in slot->members {
                var unsafe *ctx = self._global_scope->get_context(fid)
                if ctx == &null {
                    continue
                }

                var unsafe *tu = ctx->tu
                if tu == &null || tu->is_foreign {
                    continue
                }

                kairo_tus += 1
                if self._global_scope->is_builtin_fid(fid)
                    || _declares_specs(unsafe (tu as unsafe *DeclContext)) {
                    serial = true
                } else {
                    tu->no_extensions = true
                } // _declares_specs is false on any extension.

                for var j: usize = 0; j < tu->import_edges.size(); ++j {
                    var unsafe *e = tu->import_edges.get(j)
                    if e == &null {
                        continue
                    }

                    var it = group_of.find(e->target_fid as u64)
                    if it == group_of.end() {
                        continue
                    }

                    var h = (it->second as usize)
                    if h != g && h + 1 > dep {
                        dep = h + 1
                    }
                }
            }

            slot->front = kairo_tus >= 1 && !serial
            slots.push_back(slot)
            maxdep.push_back(dep)
            barrier.push_back(if (kairo_tus > 0 && serial) => (1 as u8) else => (0 as u8))
        }

        var unsafe *rec                = kairo::TimeReport::current()
        var        next_barrier: usize = 0
        for var r: usize = 0; r < m; ++r {
            // Groups r.. whose imports are all finished, up to the next barrier.
            while next_barrier < m && (next_barrier < r || barrier[next_barrier] == 0) {
                next_barrier += 1
            }

            for var h: usize = r; h < m && h < next_barrier; ++h {
                var unsafe *sh = slots[h]
                if sh->queued || !sh->front || maxdep[h] > r {
                    continue
                }

                // Constructing a Sema can mint (lang records), so it counts as
                // the group's own requests, as it does in the one-thread loop.
                sh->enter()
                sh->sems = self._sema_make(sh->members)
                SemaSlot::leave()
                sh->queued = true
                if sh->sems.size() == 0 {
                    sh->front = false
                    continue
                }

                if h == r { // the driver runs it just below.
                    continue
                }

                self._ci->pool()->enqueue(
                    kairo::SmallFunction<64>(
                        fn () |sh, rec| {
                            var _kt = kairo::TimeReport::Worker(rec)
                            sh->run_front()
                        },
                    ),
                    SEMA_GROUP,
                )
            }

            var unsafe *slot = slots[r]
            if !slot->queued {
                slot->enter()
                slot->sems = self._sema_make(slot->members)
                SemaSlot::leave()
                slot->queued = true
            }

            if slot->front {
                slot->run_front() // a no-op when a worker has it
                while !slot->done.load(cxx::std::memory_order_acquire) { // park, not yield
                    slot->done.wait(false, cxx::std::memory_order_acquire)
                }
            }

            // A barrier group, and a TU whose front stopped early, run the
            // stages that write what other TUs' fronts read (the registry's
            // specializations, the extension index, lang items, another file's
            // redeclaration rings): alone, once every front in flight is done.
            // Any other group's late part runs beside the fronts of later
            // groups, which never import it and read none of what it writes
            // (Compiler/Spec/Performance.md#parallel-sema).
            var alone = barrier[r] != 0 || slot->partial
            for var h: usize = r + 1; alone && h < m; ++h {
                var unsafe *sh = slots[h]
                if !(sh->queued && sh->front) {
                    continue
                }

                while !sh->done.load(cxx::std::memory_order_acquire) {
                    sh->done.wait(false, cxx::std::memory_order_acquire)
                }
            }

            slot->enter()
            self._settle_once(slot)
            self._sema_finish(slot->sems, effects, print_sema, print_lowered, sema_opts)
            SemaSlot::leave()
            if slot->members.size() > 0 && progress_on() {
                progress_tick(
                    PROGRESS_SEMA,
                    self._ci->sm()->get_filename(slot->members[0]),
                    slot->members.size(),
                )
            }

            for var i: usize = 0; i < slot->sems.size(); ++i {
                kairo::std::destroy(slot->sems[i])
            }

            slot->sems.clear()
            if early_release {
                self._release_group_sets(slot->members, set_owners)
            }
        }

        self._ci->pool()->wait_group(SEMA_GROUP)
        for var g: usize = 0; g < m; ++g {
            kairo::std::destroy(slots[g])
        }
    }

    /// The group's turn for the once-per-build reports its front deferred
    /// (SemaContext::once_log): each is claimed now, in the order the front
    /// met them, as T claims on this thread, so the file that reports it is
    /// the first in the one-thread order whatever the fronts' timing. Every
    /// earlier group has finished, and with it every claim a one-thread run
    /// makes before this group's. A claimed report is a T error, and stops
    /// its TU after T as T's own gate would have (Sema::stop_if_types_errored).
    priv fn _settle_once(self, slot: unsafe *SemaSlot) {
        for var i: usize = 0; i < slot->sems.size(); ++i {
            slot->sems[i]->sc.once_log = &null
        }

        for var i: usize = 0; i < slot->once.size(); ++i {
            var *m = &slot->once[i]
            TypeResolution(m->sc).report_selection(m->entry, m->at)
        }

        if slot->once.size() == 0 {
            return
        }

        slot->once.clear()
        for var i: usize = 0; i < slot->sems.size(); ++i {
            slot->sems[i]->stop_if_types_errored()
        }
    }

    /// Give back a finished group's hold on its TUs' header sets; the last
    /// owner's release frees a set that contributed nothing (see _sema).
    priv fn _release_group_sets(self,
                                const members: cxx::std::vector<u32>,
                                set_owners:    unsafe *llvm::DenseMap<u64, u64>) {
        for var fid: u32 in members {
            var unsafe *mctx = self._global_scope->get_context(fid)
            if mctx == &null {
                continue
            }

            var unsafe *mtu = mctx->tu
            if mtu == &null || mtu->header_set == &null {
                continue
            }

            var key = (mtu->header_set as usize as u64)
            var it  = set_owners->find(key)
            if it == set_owners->end() || it->second == 0 {
                continue
            }

            it->second -= 1
            if it->second == 0 {
                (unsafe (mtu->header_set as unsafe *HeaderSet))->release_unused()
            }
        }
    }

    priv fn _codegen(self) -> bool {
        var _t = TimeRegion("Codegen")

        self._stage = TUStage::Codegen

        {
            var _tw = TimeRegion("ClangStartupWait")
            self._ci->pool()->wait_group(CLANG_STARTUP_GROUP)
        }

        // A TU Sema reported errors against is emitted by nobody, and neither is
        // anything that imports it: its decls are poisoned or were never lowered
        // (a field initializer FieldInitLowering skipped), and the emitters'
        // guards would ICE and abort the batch, hiding every other diagnostic.
        // Its errors are already in the engine, so the batch fails on those.
        // Walked through the import edges, not _fids: that holds only the fids
        // THIS action claimed, and a TU an earlier input already analysed (and
        // reported) is one this graph imports but does not own.
        {
            var seen  = llvm::DenseSet<u64>()
            var stack = cxx::std::vector<u32>()
            for var fid: u32 in self._fids {
                stack.push_back(fid)
                seen.insert(fid as u64)
            }

            while stack.size() > 0 {
                var fid = stack.back()
                stack.pop_back()
                var unsafe *ectx = self._global_scope->get_context(fid)
                if ectx == &null {
                    continue
                }

                if ectx->sema_errored {
                    kairo::Logger::info(
                        kairo::Logger::Stage::Driver,
                        f"codegen: skipped, {self._ci->sm()->get_filename(fid)} had errors",
                    )

                    self._stage = TUStage::Failed
                    return false
                }

                var unsafe *etu = ectx->tu
                if etu == &null {
                    continue
                }

                for var j: usize = 0; j < etu->import_edges.size(); ++j {
                    var unsafe *e = etu->import_edges.get(j)
                    if e == &null {
                        continue
                    }

                    var t = e->target_fid
                    if t == u32::MAX {
                        continue
                    }

                    if seen.contains(t) {
                        continue
                    }

                    seen.insert(t as u64)
                    stack.push_back(t)
                }
            }
        }

        var unsafe *be = self._ci->backend()
        if be == &null || !be->ready() {
            return self._fatal(DiagID::I006F, "clang backend not ready")
        }

        var        fe     = self._ci->invocation()->frontend
        var unsafe *psym  = self._ci->pp()->get_symbol_table()
        var unsafe *insts = self._global_scope->instances()

        // One object per Kairo TU with something to define. Foreign fids are C++
        // headers: clang parsed them, nothing is emitted for them.
        var own       = cxx::std::vector<u32>()
        var n         = self._fids.size()
        var any_kairo = false
        // --emit-scope=inputs: this action's own file only, and nothing for a
        // discovered one (a header to this run). The rest is analysed for it.
        var inputs_only = self._ci->invocation()->linker.inputs_only()
        var cand        = cxx::std::vector<u32>()
        for var i: usize = 0; i < n; ++i {
            var f = self._fids[n - 1 - i] // reverse tree order: imports before importers.
            if self._ci->is_foreign_fid(f) {
                continue
            }

            any_kairo = true
            if inputs_only && (f != self._file_id || self.discovered) {
                continue
            }

            cand.push_back(f)
        }

        // An empty TU -- zero bytes, comments, only `pub import`s -- has done
        // all it can (it resolved as an import, it passed sema). Decided on
        // the PLAN, before any backend or anchor exists for it, so it gets no
        // CodegenBackend, no clang run and no object.
        //
        // A plan's one in-place write that other plans read is the entry TU's
        // cxx_escaping (prepare_shared); made first, serially and in this order,
        // the plans are then read-only and run side by side, as the codegen
        // workers run them. They were one serial plan per TU on this thread,
        // seconds on a large graph. Verdicts are read back in order.
        {
            var unsafe *psym0 = self._ci->pp()->get_symbol_table()
            var unsafe *inst0 = self._global_scope->instances()
            for var f: u32 in cand {
                var unsafe *sctx = self._global_scope->get_context(f)
                if sctx == &null || sctx->tu == &null {
                    continue
                }

                var scg   = CodegenContext(sctx, &null, psym0, inst0)
                var sprep = EmitPlan(unsafe &scg, PlanMode::Header)
                sprep.prepare_shared()
            }
        }

        var empty = cxx::std::vector<u8>()
        for var i: usize = 0; i < cand.size(); ++i {
            empty.push_back(0 as u8)
        }

        {
            var unsafe *e_p = empty.data()
            var unsafe *c_p = cand.data()
            var        *me  = &self
            for var i: usize = 0; i < cand.size(); ++i {
                self._ci->pool()->enqueue(
                    kairo::SmallFunction<64>(
                        fn () |e_p, c_p, me, i| {
                            if me->_tu_is_empty(c_p[i]) {
                                e_p[i] = (1)
                            }
                        },
                    ),
                    14,
                ) // the emptiness plans.
            }

            self._ci->pool()->wait_group(14)
        }

        for var i: usize = 0; i < cand.size(); ++i {
            var f = cand[i]
            if empty[i] != (0 as u8) {
                kairo::Logger::info(
                    kairo::Logger::Stage::Driver,
                    f"nothing to define in {self._ci->sm()->get_filename(f)}; no object",
                )

                continue
            }

            own.push_back(f)
        }

        if !any_kairo {
            return self._fatal(DiagID::I006F, "codegen: no Kairo translation unit to emit")
        }

        // -o under -c names the one object; a graph emits several, and they go
        // to --cache-dir. A linking run never has a single object here: -o is
        // the executable then.
        // What each TU writes (--emit), all under the object dir, one
        // ExecuteAction each. The extension is the kind's.
        var kinds = cxx::std::vector<EmitKind>()
        var exts  = cxx::std::vector<string>()
        if fe.emit_obj {
            kinds.push_back(EmitKind::Obj)
            exts.push_back(".o")
        }

        if fe.emit_asm {
            kinds.push_back(EmitKind::Asm)
            exts.push_back(".s")
        }

        if fe.emit_llvm_ir {
            kinds.push_back(EmitKind::LLVMIR)
            exts.push_back(".ll")
        }

        if fe.emit_llvm_bc {
            kinds.push_back(EmitKind::LLVMBC)
            exts.push_back(".bc")
        }

        if kinds.size() == 0 {
            return self._fatal(DiagID::I004F, "--emit names no output to write")
        }

        // -o names the one USER translation unit's output. The prelude (builtin,
        // std) and any imported module are separate TUs in `own` too, but they are
        // not what -o is about: they go under the object dir. So the I004F count
        // is user inputs and kinds, never `own`, which always holds the prelude.
        var single_obj = self._ci->single_object()
        if !single_obj.empty() {
            var n_out = self._ci->kairo_input_count() * kinds.size()
            if n_out > 1 {
                return self._fatal(
                    DiagID::I004F,
                    f"-o {single_obj} names one output, but this build emits {n_out}; use --cache-dir <dir> for them",
                )
            }
        }

        var obj_dir = self._ci->object_dir()

        // Every TU loads the same headers: the whole graph's sets, in graph
        // order, as one PCH (CodegenPCH). Normally already built on the pool
        // during Sema (prebuild_codegen_pch); else built here, before the first
        // TU.
        var graph_sets                    = self._graph_header_sets()
        var merged:    unsafe *CodegenPCH = &null
        // Also for ONE set: the sets write no PCH of their own now.
        if graph_sets.size() > 0 && self._ci->headers() != &null {
            self._ci->headers()->wait_all()
            {
                var _tw = TimeRegion("CodegenPCHWait")
                self._ci->headers()->wait_codegen_pch()
            }

            merged = self._ci->headers()->codegen_pch(&graph_sets)
        }

        // Pre-pass, driver thread: every decision about a TU (its output paths,
        // its header sets), so the per-TU compile below reads nothing it shares
        // with another TU except what is read-only from here on.
        var crun = CodegenRun()
        crun.be        = be
        crun.psym      = psym
        crun.instances = insts
        crun.merged    = merged
        var jobs       = cxx::std::vector<unsafe *CodegenJob>()
        var all_sets   = cxx::std::vector<unsafe *HeaderSet>()
        var used_stems = cxx::std::vector<string>()
        for var fid: u32 in own {
            var unsafe *ctx = self._global_scope->get_context(fid)
            if ctx == &null {
                for var j: unsafe *CodegenJob in jobs {
                    kairo::std::destroy(j)
                }

                return self._fatal(DiagID::I006F, "codegen: no ASTContext for a Kairo fid")
            }

            var ksize = (self._ci->sm()->get_file_size(fid) as u32)

            // The output path mirrors the module path, so two modules of the
            // same leaf name do not collide. A pathless TU (outside every search
            // dir) is named by its file stem instead.
            var stem      = ""
            var obj_stem  = "" // the object dir's name for it, whatever `stem` became
            var to_single = !single_obj.empty() && fid == self._file_id && !self.discovered
            if !to_single {
                var ocg  = CodegenContext(ctx, &null, psym, insts)
                var sp   = CXXSpell(unsafe &ocg)
                var segs = sp.module_segments(ctx->tu)
                var rel  = ""
                for var i: usize = 0; i < segs.size(); ++i {
                    if i > 0 {
                        rel += "/"
                    }

                    rel += segs[i]
                }

                // A one-segment path sits beside a C/C++ input's <stem>.o, and
                // `foo.cc` including `foo.k` is the common case: kairo_object_stem
                // moves the Kairo object aside, as it did when foo.k was an entry.
                if rel.size() == 0 {
                    rel = self._ci->kairo_object_stem(self.path.stem())
                } else if segs.size() == 1 {
                    rel = self._ci->kairo_object_stem(rel)
                }

                stem     = obj_dir + "/" + rel
                obj_stem = stem
                // Two TUs can map to one object name: a pathless `builtin.k`
                // outside every search dir is named by its stem, as the builtin
                // root is. Serially the later TU overwrote the earlier and the
                // link happened to keep the right one; side by side, which write
                // lands last is a race. The later TU in graph order (the
                // importer, the one that used to win) takes a fid-suffixed name.
                var taken = false
                for *p in used_stems {
                    if *p == obj_stem {
                        taken = true
                        break
                    }
                }

                if taken {
                    obj_stem = obj_stem + f"-{fid}"
                    stem     = obj_stem
                }

                used_stems.push_back(obj_stem)
                var beside = if (self.discovered || fid != self._file_id) => ("")
                             else => self._ci->emit_beside(self.path.stem())
                if !beside.empty() {
                    stem = beside
                }
            }

            var unsafe *job = kairo::std::create<CodegenJob>()
            job->fid   = fid
            job->ctx   = ctx
            job->ksize = ksize
            job->path  = self._ci->sm()->get_filename(fid)
            if fe.print_cg {
                job->print |= 2
            }

            if fe.print_ir {
                job->print |= 1
            }

            for var k: usize = 0; k < kinds.size(); ++k {
                var out = if (to_single) => (single_obj) else => stem + exts[k]
                // An object nobody listed is a link input only.
                if !to_single && kinds[k] == EmitKind::Obj && !self._ci->obj_listed() {
                    out = obj_stem + exts[k]
                }

                self._ensure_parent_dir(out)
                job->kinds.push_back(kinds[k])
                job->outs.push_back(out)
            }

            // Phase B loads phase A's PCHs instead of re-parsing the headers:
            // the merged one when it built, else one per set (CodegenBackend::
            // run), where only the first loads as a PCH and the rest are text.
            var        sets    = cxx::std::vector<unsafe *HeaderSet>()
            var unsafe *own_tu = ctx->tu
            if own_tu != &null && own_tu->header_set != &null {
                sets.push_back(unsafe (own_tu->header_set as unsafe *HeaderSet))
            }

            // The whole graph's: an inline body this TU emits may name a header
            // of a module an earlier input claimed (builtin's rt/fmt.h).
            for var hs: unsafe *HeaderSet in graph_sets {
                var dup = false
                for var j: usize = 0; j < sets.size(); ++j {
                    if sets[j] == hs {
                        dup = true
                        break
                    }
                }

                if !dup {
                    sets.push_back(hs)
                }
            }

            // Per-set fallback: the set that is costliest to re-parse goes first,
            // as the PCH. Headers are include-guarded and each set stands alone,
            // so only which one loads as the PCH changes, not what is declared.
            // Without this a builtin TU loaded its small rt/fmt.h set and parsed
            // libc++'s <coroutine> as text, every TU (4.7x on a small program).
            var big: usize = 0
            for var j: usize = 1; j < sets.size(); ++j {
                if !sets[j]->ok {
                    continue
                }

                if !sets[big]->ok || sets[j]->files.size() > sets[big]->files.size() {
                    big = j
                }
            }

            if big > 0 {
                var unsafe *b = sets[big]
                sets.erase(sets.cbegin() + (big as isize))
                sets.insert(sets.cbegin(), b)
            }

            for var hs: unsafe *HeaderSet in sets {
                var dup = false
                for var j: usize = 0; j < all_sets.size(); ++j {
                    if all_sets[j] == hs {
                        dup = true
                        break
                    }
                }

                if !dup {
                    all_sets.push_back(hs)
                }
            }

            job->sets = sets
            jobs.push_back(job)

            // The one cache a plan fills in place that other TUs' plans read
            // (EmitPlan::prepare_shared): filled here, one TU at a time, so the
            // fills below only read what they share.
            var pcg  = CodegenContext(ctx, &null, psym, insts)
            var prep = EmitPlan(unsafe &pcg, PlanMode::Header)
            prep.prepare_shared()
        }

        // Everything any TU's VFS will hold, mounted (well, listed) before the
        // first TU starts: nothing is added once workers read.
        crun.mount(&all_sets)

        // The graph-independent facts every plan below reads (EmitPlan::
        // set_file_ranks, assign_homes; Compiler/Spec/Incremental.md#shared-across-graphs):
        // a TU's stream, and so its object, must be the same in every graph
        // that holds it, or kairo, kcc and kfmt could not share one cache.
        // Always, cache or not: a reused object is what a clean compile writes.
        var jkeys  = cxx::std::vector<string>()
        var gmods  = cxx::std::vector<u32>()
        var gedges = cxx::std::vector<cxx::std::vector<u32>>()
        finally {
            EmitPlan::reset_graph_facts()
        }

        {
            var _tg   = TimeRegion("GraphFacts")
            var rkeys = cxx::std::vector<string>()
            var rfids = cxx::std::vector<u32>()
            for var gf: u32 in self._graph {
                var unsafe *gctx = self._global_scope->get_context(gf)
                if gctx == &null || gctx->tu == &null {
                    continue
                }

                var gcg = CodegenContext(gctx, &null, psym, insts)
                var gsp = CXXSpell(unsafe &gcg)
                rkeys.push_back(
                    "0" + self._module_key(&gsp, gctx->tu, self._ci->sm()->get_filename(gf)),
                )

                rfids.push_back(gf)
            }

            // Headers (a foreign declaration's file) after every module, by path.
            for var hs: unsafe *HeaderSet in graph_sets {
                for var i: usize = 0; i < hs->files.size(); ++i {
                    if hs->files[i].kfid == 0 {
                        continue
                    }

                    rkeys.push_back("1" + hs->files[i].path)
                    rfids.push_back(hs->files[i].kfid)
                }
            }

            EmitPlan::set_file_ranks(rkeys, rfids)
            // The import graph: each TU's own file order walks it, and the
            // homes rule reads which user imports which.
            for var gf: u32 in self._graph {
                var unsafe *gctx = self._global_scope->get_context(gf)
                if gctx == &null || gctx->tu == &null || gctx->tu->is_foreign {
                    continue
                }

                var ts = cxx::std::vector<u32>()
                for var k: usize = 0; k < gctx->tu->import_edges.size(); ++k {
                    var unsafe *e = gctx->tu->import_edges.get(k)
                    if e != &null && e->target_fid != 0 {
                        ts.push_back(e->target_fid)
                    }
                }

                gmods.push_back(gf)
                gedges.push_back(ts)
            }

            var prelude: u32 = 0
            if !self._ci->invocation()->pp.no_prelude
                && self._ci->invocation()->pp.prelude_path.size() > 0 {
                prelude = self._ci->sm()->load_file(Path(self._ci->invocation()->pp.prelude_path))
            }

            EmitPlan::set_graph(gmods, gedges, prelude)

            var plans = cxx::std::vector<unsafe *EmitPlan>()
            for var j: *CodegenJob in jobs {
                var kcg = CodegenContext(j->ctx, &null, psym, insts)
                var ksp = CXXSpell(unsafe &kcg)
                jkeys.push_back(self._module_key(&ksp, j->ctx->tu, Path(j->path).filename()))
            }

            // Each TU's plan, side by side, for the instances it admits; the
            // plans are thrown away (their tier 3 was ordered by the old homes).
            {
                var *cr = &crun
                for var j: *CodegenJob in jobs {
                    self._ci->pool()->enqueue(
                        kairo::SmallFunction<64>(fn () |j, cr| { j->make_plan(cr) }),
                        CODEGEN_GROUP,
                    )
                }

                self._ci->pool()->wait_group(CODEGEN_GROUP)
            }

            for var j: *CodegenJob in jobs {
                plans.push_back(j->plan)
            }

            EmitPlan::assign_homes(plans, jkeys)
            for var j: *CodegenJob in jobs {
                kairo::std::destroy(j->plan)
                kairo::std::destroy(j->pcg)
                j->plan = &null
                j->pcg  = &null
            }
        }

        // Which TUs compile under an interface PCH (Compiler/Spec/Codegen.md#the-interface-pch):
        // one per flavour (CXXSpell::interface_flavour), since TUs that spell a
        // declaration differently never share one. Not under --print-cg /
        // --print-ir, which print each TU's whole stream, nor -Wshift-count-
        // unproven, which reports on the own bodies a TU no longer writes.
        // Decided over EVERY TU, the ones the cache serves included, so an
        // incremental run builds the PCH a clean run would and its objects
        // are the clean run's.
        var iface_mode = self._iface_pch_mode()
        var warn_shift = false
        if jobs.size() > 0 {
            var wcg = CodegenContext(jobs[0]->ctx, &null, psym, insts)
            warn_shift = wcg.opts.warn_unproven_shift
        }

        var flavours = cxx::std::vector<u8>()
        // u8, not bool: vector<bool> hands back bit references.
        var flavour_on = cxx::std::vector<u8>()
        flavour_on.push_back(0 as u8)
        flavour_on.push_back(0 as u8)
        for var j: *CodegenJob in jobs {
            var fcg = CodegenContext(j->ctx, &null, psym, insts)
            var fsp = CXXSpell(unsafe &fcg)
            flavours.push_back(fsp.interface_flavour(j->ctx->tu))
        }

        if iface_mode != 0 && !fe.print_cg && !fe.print_ir && !warn_shift {
            for var flavour: u8 = 0; flavour < 2; ++flavour {
                var count: usize = 0
                var bytes: usize = 0
                for var i: usize = 0; i < jobs.size(); ++i {
                    if flavours[i] != flavour {
                        continue
                    }

                    count += 1
                    bytes += jobs[i]->ksize as usize
                }

                // Auto: only where it pays. The PCH is one serial parse ahead
                // of the fan-out, and what it saves is each TU re-parsing its
                // imports' interfaces in parallel; on a hello-sized graph (28
                // TUs, 180 KB of Kairo) that parallel re-parse is cheaper than
                // the serial union (0.17 s -> 0.24 s), on the compiler's own
                // (316 TUs, 10 MB) it is most of codegen.
                var on = !(count < 2 || iface_mode == 3 && bytes < IFACE_PCH_MIN_BYTES)
                if on {
                    flavour_on[flavour as usize] = (1 as u8)
                }
            }
        }

        for var i: usize = 0; i < jobs.size(); ++i {
            jobs[i]->iface_on = flavour_on[flavours[i] as usize] != (0 as u8)
        }

        // Each flavour's PCH takes its TUs in module-path order (iface_order),
        // and the first one writes the stream helpers every TU shares
        // (InterfaceEmitter's __kairo_fn / __kairo_raw_fn, anchored at that
        // TU's first byte): with -g, every object compiled under the PCH
        // names that TU's file in its debug info, so its key says which
        // (ObjectCache::key's writer). By module path, not graph order, so
        // kairo and kfmt agree on it.
        var iface_order = cxx::std::vector<usize>()
        for var i: usize = 0; i < jobs.size(); ++i {
            iface_order.push_back(i)
        }

        {
            var *kp = &jkeys
            llvm::sort(
                iface_order.begin(),
                iface_order.end(),
                fn (a: usize, b: usize) |kp| -> bool {
                    if (*kp)[a] != (*kp)[b] {
                        return (*kp)[a] < (*kp)[b]
                    }

                    return a < b
                },
            )
        }

        var iface_first = cxx::std::vector<string>()
        iface_first.push_back("")
        iface_first.push_back("")
        for var oi: usize in iface_order {
            var fl = flavours[oi] as usize
            if iface_first[fl].empty() {
                iface_first[fl] = jkeys[oi]
            }
        }

        // The incremental object cache, phase 1 (Driver/ObjectCache.k,
        // Compiler/Spec/Incremental.md): each TU's key from the stream its
        // fill would write, then the TUs whose object the cache holds skip
        // codegen and clang. Objects only, one kind: a .s/.ll/.bc is an
        // output the user asked for, and --print-cg / --print-ir print the
        // stream a reused TU would never write.
        progress_begin(PROGRESS_CODEGEN, jobs.size())
        var ocache = ObjectCache()
        var caching = kinds.size() == 1
            && kinds[0] == EmitKind::Obj
            && !fe.print_cg
            && !fe.print_ir
            && ocache.setup(be, self._ci->invocation()->linker.cache_dir)
        if caching {
            var _tk = TimeRegion("CacheKeys")
            // Which header files each TU can reach (ObjectCache::tu_headers):
            // the graph's modules and their import edges.
            ocache.begin_run(&graph_sets, merged != &null && merged->ok, gmods, gedges)
            {
                var *cr  = &crun
                var locs = ocache.with_locs
                for var j: *CodegenJob in jobs {
                    self._ci->pool()->enqueue(
                        kairo::SmallFunction<64>(fn () |j, cr, locs| { j->hash_stream(cr, locs) }),
                        CODEGEN_GROUP,
                    )
                }

                self._ci->pool()->wait_group(CODEGEN_GROUP)
            }

            for var ji: usize = 0; ji < jobs.size(); ++ji {
                var unsafe *j = jobs[ji]
                var writer = if (j->iface_on) => (iface_first[flavours[ji] as usize]) else => ""
                j->key = ocache.key(
                    j->stream,
                    j->iface_on,
                    ocache.tu_headers(j->fid, j->stream_files),
                    writer,
                )

                var modname = jkeys[ji]
                var why     = ""
                if self._ci->incr.on {
                    self._ci->incr.keys.push_back(modname + "\t" + j->key)
                }

                // --force-recompile: no lookup, every TU compiles, and the
                // store is refreshed with what it writes.
                if !fe.force_recompile && ocache.fetch(j->key, j->outs[0], &why) {
                    j->reused = true
                    j->ok     = true
                    j->written.push_back(j->outs[0])
                    ocache.reused += 1
                    kairo::Logger::info(
                        kairo::Logger::Stage::Driver,
                        f"incremental: reused {modname} ({j->key})",
                    )

                    continue
                }

                // It compiles: its own fill reports what the hash's did.
                j->ctx->diag_sink.truncate(j->diag_mark)
                var src  = ""
                var buf? = self._ci->sm()->get_buffer(j->fid)
                if buf != null && buf.is_valid() {
                    src = kairo::std::from_std_string<string>(
                        kairo::objcache_hash128_bytes(buf.data(), buf.size()),
                    )
                }

                j->record = ocache.record_asm(
                    ocache.record(j->key, ObjectCache::clean(modname), src, j->stream),
                )

                ocache.compiled += 1
                if fe.force_recompile {
                    kairo::Logger::info(
                        kairo::Logger::Stage::Driver,
                        f"incremental: compiling {modname} (--force-recompile)",
                    )
                } else if why.empty() {
                    kairo::Logger::info(
                        kairo::Logger::Stage::Driver,
                        f"incremental: compiling {modname} (not cached)",
                    )
                } else {
                    kairo::Logger::info(
                        kairo::Logger::Stage::Driver,
                        f"incremental: compiling {modname} (changed:{why})",
                    )
                }
            }
        }

        var todo = cxx::std::vector<unsafe *CodegenJob>()
        for var j: *CodegenJob in jobs {
            if !j->reused {
                todo.push_back(j)
            }
        }

        progress_reuse(PROGRESS_CODEGEN, jobs.size() - todo.size())

        // The interface PCHs: every TU's declarations and template / inline
        // bodies parsed once, chained on the header PCH, so each TU parses
        // only what its object defines. A flavour none of whose TUs compiles
        // this run builds none.
        var ifaces = cxx::std::vector<unsafe *InterfacePCH>()
        finally {
            for var p: unsafe *InterfacePCH in ifaces {
                kairo::std::destroy(p)
            }
        }

        for var flavour: u8 = 0; flavour < 2; ++flavour {
            if flavour_on[flavour as usize] == (0 as u8) {
                continue
            }

            var mine   = cxx::std::vector<unsafe *CodegenJob>()
            var needed = false
            for var i: usize in iface_order {
                if flavours[i] != flavour {
                    continue
                }

                mine.push_back(jobs[i])
                if !jobs[i]->reused {
                    needed = true
                }
            }

            if !needed {
                continue
            }

            // The plans first, side by side: the stream runs each, and so
            // does each TU's compile (CodegenJob::make_plan).
            {
                var _tp = TimeRegion("InterfacePlans")
                var *cr = &crun
                for var j: *CodegenJob in mine {
                    self._ci->pool()->enqueue(
                        kairo::SmallFunction<64>(fn () |j, cr| { j->make_plan(cr) }),
                        CODEGEN_GROUP,
                    )
                }

                self._ci->pool()->wait_group(CODEGEN_GROUP)
            }

            var unsafe *iface = kairo::std::create<InterfacePCH>()
            ifaces.push_back(iface)
            iface->path = HeaderSet::vfs_root() + f"/pch/interface-{flavour}.pch"
            for var j: *CodegenJob in mine {
                iface->add(j->ctx, j->fid, j->ksize, j->plan)
            }

            iface->build(be, merged, &crun.mounts, psym, insts)
            if fe.verbose && !iface->ok {
                iface->diag.drain_into(self._ci->diag(), self._ci->sm())
            } else {
                iface->diag.discard()
            }

            if !iface->ok {
                continue
            }

            crun.mounts.add_pch(iface->path, unsafe &iface->pch->Data)
            iface->mounted = true
            for var j: unsafe *CodegenJob in mine {
                j->iface = iface
            }
        }

        // The fan-out. Each TU compiles on a CompilerInstance of its own
        // (CodegenJob::run), so TUs run side by side up to the pool's size
        // (--threads; every logical CPU by default) and the TU count. An early
        // spike capped it at the physical cores (SMT doubled a small program's
        // per-TU time); on the self-host graph (316 TUs) all 24 threads beat 12
        // by 12% of the whole build, so the cap is gone. One worker when
        // something prints per TU (--print-cg / --print-ir): their output is
        // written as each TU fills, so it must come one TU at a time.
        var workers = self._ci->pool()->get_thread_count()
        if workers > todo.size() {
            workers = todo.size()
        }

        // --codegen-threads: an explicit worker count, for measuring.
        if fe.codegen_threads > 0 {
            workers = (fe.codegen_threads as usize)
            if workers > todo.size() {
                workers = todo.size()
            }
        }

        if fe.print_cg || fe.print_ir {
            workers = 1
        }

        // Every mount is in (the interface PCHs above added theirs): build the
        // one in-memory layer all TUs' VFSs share, and drop it after the join,
        // before the PCH buffers its views point into are freed.
        crun.mounts.freeze()
        finally {
            crun.mounts.release()
        }

        {
            var _tr = TimeRegion("Backend")
            if workers <= 1 {
                for var j: *CodegenJob in todo {
                    j->run(&crun)
                    progress_tick(PROGRESS_CODEGEN, j->path)
                }
            } else {
                var q = CodegenQueue()
                q.run = &crun
                for var j: *CodegenJob in todo {
                    q.add(j)
                }

                q.schedule()
                kairo::Logger::info(
                    kairo::Logger::Stage::Driver,
                    f"codegen: {todo.size()} TU(s) on {workers} worker(s)",
                )

                var        *qp  = &q
                var unsafe *rec = _tr.record()
                for var w: usize = 0; w < workers; ++w {
                    self._ci->pool()->enqueue(
                        kairo::SmallFunction<64>(
                            fn () |qp, rec| {
                                var _kt = kairo::TimeReport::Worker(rec)
                                qp->work()
                            },
                        ),
                        CODEGEN_GROUP,
                    )
                }

                var unsafe *wrec = time_region("Join")
                time_mark_idle(wrec)
                var _tj = TimeRegion(wrec)
                self._ci->pool()->wait_group(CODEGEN_GROUP)
            }
        }

        progress_end(PROGRESS_CODEGEN)
        // The post-pass prints (`kairo: wrote`, [stats]); the line must be gone.
        progress_finish()

        // Post-pass, driver thread, in TU order: what each TU said and wrote,
        // independent of which worker finished first. Every TU ran, a failed
        // one included, so every sink is drained before the verdict.
        var all_ok = true
        for var job: *CodegenJob in jobs {
            // Stored only when clang said nothing: a stored object's record
            // holds no diagnostics to replay (Incremental.md#diagnostics), so
            // a TU clang warned about compiles again, and says it again,
            // every run. Kairo's own codegen-time reports need no such rule:
            // the key's fill (hash_stream) reports them on every run.
            if caching
                && job->ok
                && !job->reused
                && job->sink.size() == 0
                && job->written.size() == 1
                // The key says whether the TU compiled under the interface
                // PCH (iface_on); an object compiled without it, after a
                // failed PCH build or clang's retry, is not that key's (P888).
                && job->iface_used == job->iface_on {
                ocache.store(job->key, job->written[0])
            }

            job->sink.drain_into(self._ci->diag(), self._ci->sm())
            // Codegen's OWN reports (EmitIR's I011W, Compiler/Spec/Codegen.md#diagnostics) go to
            // the TU's diag_sink, whose last drain was after sema. Undrained, they
            // were never shown and the sink ICEd in its destructor at exit.
            job->ctx->diag_sink.drain_into(self._ci->diag(), job->ctx->sm)
            if !job->ok {
                all_ok = false
                continue
            }

            if !all_ok {
                continue
            }

            // Only objects are link inputs; the rest are outputs in their own right.
            for var k: usize = 0; k < job->written.size(); ++k {
                kairo::Logger::info(kairo::Logger::Stage::Driver, f"emitted {job->written[k]}")
                if job->kinds[k] == EmitKind::Obj {
                    self.result.objects.push_back(job->written[k])
                }
            }

            // A linking run's extra outputs are named, as the executable is not:
            // the user asked for them and could not have known where they went.
            if self._ci->emits_beside_link() && !self.discovered && job->fid == self._file_id {
                for var k: usize = 0; k < job->written.size(); ++k {
                    if job->kinds[k] == EmitKind::Obj && !self._ci->obj_listed() {
                        continue
                    }

                    io::eprintln(f"kairo: wrote {job->written[k]}")
                }
            }
        }

        for var j: unsafe *CodegenJob in jobs {
            kairo::std::destroy(j)
        }

        if caching {
            ocache.gc()
            if fe.print_stats {
                io::eprintln(
                    f"[stats] incremental: {ocache.reused} reused, {ocache.compiled} compiled, {ocache.stored} stored",
                )
            }
        }

        if !all_ok {
            self._stage = TUStage::Failed
            return false
        }

        self._stage = TUStage::Done
        return true
    }

    /// \p fid has nothing to define (EmitPlan::is_empty, on the preamble plan).
    /// A fid with no context or TU is not empty -- it is not a Kairo TU at all,
    /// and the callers already skip those -- so this answers only for real ones.
    /// The header sets of every TU in the graph, in graph order, each once:
    /// what phase B's merged PCH holds. One helper for the early build in
    /// _sema and the lookup in _codegen, so both name the same list.
    /// \p tu's module path, `::`-joined; for a pathless TU, \p fallback (its
    /// file's name, never its directory: a key or record must not depend on
    /// where the checkout is).
    priv fn _module_key(self,
                        sp:             *CXXSpell,
                        tu:             unsafe *TranslationUnit,
                        const fallback: string) -> string {
        var segs = sp->module_segments(tu)
        var out  = ""
        for var i: usize = 0; i < segs.size(); ++i {
            if i > 0 {
                out += "::"
            }

            out += segs[i]
        }

        if out.empty() {
            out = Path(fallback).filename()
        }

        return out
    }

    priv fn _graph_header_sets(self) -> cxx::std::vector<unsafe *HeaderSet> {
        var out = cxx::std::vector<unsafe *HeaderSet>()
        for var other: u32 in self._graph {
            var unsafe *sctx = self._global_scope->get_context(other)
            if sctx == &null {
                continue
            }

            var unsafe *stu = sctx->tu
            if stu == &null || stu->header_set == &null {
                continue
            }

            var unsafe *hs = unsafe (stu->header_set as unsafe *HeaderSet)
            var        dup = false
            for var j: usize = 0; j < out.size(); ++j {
                if out[j] == hs {
                    dup = true
                    break
                }
            }

            if !dup {
                out.push_back(hs)
            }
        }

        return out
    }

    /// --interface-pch: auto = 3 (IFACE_PCH_MIN_BYTES); off = 0; on = 1
    /// whatever the size. Under --verbose a failed build's clang diagnostics are
    /// reported in every mode that builds one (the TUs report the same ones from
    /// their whole streams otherwise).
    priv fn _iface_pch_mode(self) -> u8 {
        var fe = self._ci->invocation()->frontend
        if fe.interface_pch == "off" {
            return 0
        }

        if fe.interface_pch == "on" {
            return 1
        }

        return 3
    }

    // not priv: _codegen's pool tasks call it.
    fn _tu_is_empty(self, fid: u32) -> bool {
        var unsafe *ctx = self._global_scope->get_context(fid)
        if ctx == &null || ctx->tu == &null {
            return false
        }

        var cg = CodegenContext(
            ctx,
            &null,
            self._ci->pp()->get_symbol_table(),
            self._global_scope->instances(),
        )

        var plan = EmitPlan(unsafe &cg, PlanMode::Preamble)
        plan.run()
        return plan.is_empty()
    }

    // Post-stage dump helpers

    priv fn _dump_tokens(self) {
        var unsafe *tokens = self._ci->tcm()->get_tokens(self._file_id)
        if tokens == &null {
            io::println(f"-- token stream: {self.path.full_path()} (none) --")
            return
        }

        var printer = TokenPrinter(self._ci->tcm(), self._ci->invocation()->diag.no_color)

        printer.print_stream(tokens, self.path.full_path())
    }

    /// \brief --dump-preprocessed: reconstruct macro-expanded source text from the
    ///        finalized token buffer and print it to stdout. This is the ONLY
    ///        stdout-emitting form of the preprocessor's output --preprocess alone
    ///        stops the pipeline after preprocessing with no extra output, matching
    ///        every other stops_at_* flag.
    ///
    ///        Spelling comes from TokenText::resolve() (the sole sanctioned text
    ///        accessor  see Token/TokenText.k), which already unwraps macro
    ///        expansion chains to their substituted identity. TkNewLine is
    ///        special-cased to a real byte instead of resolve()'s escaped debug
    ///        rendering (`"\\n"`), since this is meant to read back as source,
    ///        not as a token dump.
    ///
    ///        The lexer doesn't emit TkWhitespace for ordinary inter-token gaps
    ///        on a line (only newlines are real tokens - verified against
    ///        --print-tokens output), so original spacing isn't recoverable from
    ///        the buffer. A single space is inserted before every content token
    ///        that isn't the first on its line instead; this over-spaces
    ///        one-character punctuation ("( )" instead of "()") but stays
    ///        readable, matching the eyeball-aid framing for this flag.
    priv fn _dump_preprocessed_source(self) {
        var unsafe *tokens = self._ci->tcm()->get_tokens(self._file_id)
        if tokens == &null {
            io::println(f"-- preprocessed source: {self.path.full_path()} (none) --")
            return
        }

        var unsafe *tcm                 = self._ci->tcm()
        var        out:          string = ""
        var        at_line_start        = true
        for var i: usize = 0; i < tokens->size(); ++i {
            var unsafe *tok = tokens->get(i)
            if tok->kind == TokenKind::TkNewLine {
                out += "\n"
                at_line_start = true
                continue
            }

            if tok->kind == TokenKind::TkWhitespace {
                continue
            }

            if tok->kind == TokenKind::TkEof {
                continue
            }

            if tok->kind == TokenKind::TkFileStart {
                continue
            }

            if tok->kind == TokenKind::TkFileEnd {
                continue
            }

            if !at_line_start {
                out += " "
            }

            at_line_start = false
            out += *TokenText::resolve(*tok, tcm).get_text()
        }

        io::println(f"{out}")
    }

    priv fn _dump_macros(self) {
        var unsafe *pp = self._ci->pp()
        if pp == &null {
            return
        }

        var unsafe *mt = pp->get_macro_table()
        var unsafe *st = pp->get_symbol_table()
        if mt == &null || st == &null {
            return
        }

        io::println(f"-- macro table: {self.path.full_path()} --")
        // One row per macro this graph defines, builtin/std included: they share
        // the table, and hiding them would make the count disagree with
        // PreProcessor::macro_count(). Keyed by fid because that is the table's
        // ownership index; `_fids` is the set this action preprocessed.
        for var fid: u32 in self._fids {
            var entries = mt->entries_of_fid(fid)
            for var i: usize = 0; i < entries.size(); ++i {
                var unsafe *e = entries[i]
                if e->decl == &null {
                    continue
                }

                var unsafe *name = st->resolve(e->name_sym)
                var        nm    = "?"
                if name != &null {
                    nm = *name
                }

                var nparams: usize = e->decl->params_spec.size()
                var shape          = f"{nparams} param(s)"
                if e->decl->is_variadic {
                    shape = f"{nparams} param(s) + variadic"
                }

                var full = self._ci->sm()->get_line_col(e->decl->range.start)
                io::println(
                    f"macro {nm}: {shape}, defined at {full.path.full_path()}:{full.line}:{full.column}",
                )
            }
        }
    }

    priv fn _dump_imports(self) {
        io::println(f"-- imports: {self.path.full_path()} --")
        for var fid: u32 in self._fids {
            var unsafe *ctx = self._global_scope->get_context(fid)
            if ctx == &null {
                continue
            }

            var unsafe *tu = ctx->tu
            if tu == &null {
                continue
            }

            io::println(f"fid {fid}: {tu->import_edges.size()} edge(s)")
            for var i: usize = 0; i < tu->import_edges.size(); ++i {
                var unsafe *edge = tu->import_edges.at(i) // *ImportEdge
                var unsafe *id   = dyn_cast<Declarations::ImportDecl>(edge->decl)
                if id == &null {
                    continue
                }

                // path spelling: a::b::c
                var path: string = ""
                for var s: usize = 0; s < id->path_segments.size(); ++s {
                    if s > 0 {
                        path += "::"
                    }

                    path += ctx->get_spelling(id->path_segments[s])
                }

                // edge shape label
                var kind: string = "plain"
                if id->is_wildcard {
                    kind = "wildcard"
                } else if id->has_items {
                    kind = "selective"
                } else if id->last_seg_is_macro {
                    kind = "macro"
                }

                var alias: string = ""
                if id->has_alias {
                    alias = f" as {ctx->get_spelling(id->alias)}"
                }

                io::println(f"  [{kind}] {path}{alias} -> fid {edge->target_fid}")
            }
        }
    }

    /// Dump the built import overlays (phase I output): per fid, each folded name
    /// key and its targets (kind, source fid, visibility, origin import shape).
    /// Runs AFTER ImportResolution in _sema, so the overlay is populated. Pairs
    /// with _dump_imports (edges) the way --print-symbols pairs with the parse.
    priv fn _dump_overlays(self) {
        io::println(f"-- overlays: {self.path.full_path()} --")
        for var fid: u32 in self._fids {
            var unsafe *ctx = self._global_scope->get_context(fid)
            if ctx == &null {
                continue
            }

            var unsafe *tu = ctx->tu
            if tu == &null {
                continue
            }

            var unsafe *ov = tu->import_overlay
            if ov == &null {
                io::println(f"fid {fid}: (no overlay)")
                continue
            }

            io::println(f"fid {fid}: {ov->size()} overlay key(s)")

            // The injected prelude is not in the source, so naming it here is the
            // only place a reader can see WHY builtin's names are in this overlay.
            for var pi: usize = 0; pi < tu->imports.size(); ++pi {
                var unsafe **pslot = tu->imports.at(pi)
                if pslot == &null {
                    continue
                }

                var unsafe *pimp = dyn_cast<Declarations::ImportDecl>(*pslot)
                if pimp == &null {
                    continue
                }

                if !pimp->is_prelude {
                    continue
                }

                // One prelude: builtin's wildcard. std has none; it is imported
                // by name (`import std::io`) like any other module. A plain one
                // is the nameless edge to alloc.k for `@create`.
                if !pimp->is_wildcard {
                    io::println(
                        f"  <prelude> alloc edge for @create / @destroy (src=fid {pimp->resolved_fid})",
                    )

                    continue
                }

                io::println(f"  <prelude> import builtin::* (src=fid {pimp->resolved_fid})")
            }

            var unsafe *imms = ctx->get_imm_table()
            var        rows  = cxx::std::vector<ImportOverlay::Row>()
            ov->collect_rows(&rows)
            for var i: usize = 0; i < rows.size(); ++i {
                var row  = rows[i]
                var name = if (imms == &null) => ("<?>") else => imms->get_ident(row.key)
                var amb  = if (row.entry->is_ambiguous()) => (" [AMBIGUOUS]") else => ""
                if row.entry->is_ambiguous() && row.entry->lazy {
                    amb += " (reported at use)"
                }

                io::println(f"  {name}: {row.entry->targets.size()} target(s){amb}")
                for var t: usize = 0; t < row.entry->targets.size(); ++t {
                    var tg  = row.entry->targets[t]
                    var hid = if (tg.hidden) => (" hidden") else => ""
                    io::println(
                        f"    - {_overlay_kind_str(tg.kind)} src=fid {tg.src_fid} vis={_overlay_vis_str(tg.vis)}{hid}",
                    )
                }
            }
        }
    }

    /// --dump-import-uses: per TU, its written imports and every name the overlay
    /// answered, attributed to the import(s) that folded it, with the spelled
    /// use sites NameLookup logged (ImportUseLog). The input of
    /// Scripts/import_lint.py, which turns wildcard imports into selective or
    /// qualified ones and drops dead ones; it trusts this dump to be complete,
    /// so a name looked up with no spelled site is still listed (`implicit`).
    ///
    /// Format (one object): {"version": 1, "tus": [{"fid", "path", "imports":
    /// [{"idx", "path", "line", "wildcard", "selective", "module_only", "ffi",
    /// "pub", "resolved_fid", "resolved_path"}], "names": [{"name", "origins":
    /// [import idx], "src_fids", "sites": [[offset, line, col]], "implicit",
    /// "foreign"}]}]}. `foreign` counts sites outside the TU's own file (a macro
    /// body, an imported node T read through this overlay).
    priv fn _dump_import_uses(self, const out_path: string) {
        var unsafe *sm             = self._ci->sm()
        var        o:       string = "{\"version\": 1, \"tus\": ["
        var        first_tu        = true
        for var fid: u32 in self._fids {
            var unsafe *ctx = self._global_scope->get_context(fid)
            if ctx == &null {
                continue
            }

            var unsafe *tu = ctx->tu
            if tu == &null || tu->is_foreign {
                continue
            }

            var unsafe *ov = tu->import_overlay
            if ov == &null || ov->uses == &null {
                continue
            }

            var unsafe *imms = ctx->get_imm_table()
            if imms == &null {
                continue
            }

            if !first_tu {
                o += ",\n"
            }

            first_tu = false
            o += "{" + f"\"fid\": {fid}, \"path\": {_json_str(sm->get_filename(fid))}, \"imports\": ["

            // The written imports, in source order; an origin is named by its
            // index here. The prelude is listed (so indices match tu->imports)
            // but flagged: the lint never touches it.
            var decls = cxx::std::vector<unsafe *Declarations::ImportDecl>()
            for var pi: usize = 0; pi < tu->imports.size(); ++pi {
                var unsafe **pslot                                  = tu->imports.at(pi)
                var        imp:    unsafe *Declarations::ImportDecl = &null
                if pslot != &null {
                    imp = dyn_cast<Declarations::ImportDecl>(*pslot)
                }

                decls.push_back(imp)
                if pi > 0 {
                    o += ", "
                }

                if imp == &null {
                    o += "null"
                    continue
                }

                var path: string = ""
                for var si: usize = 0; si < imp->path_segments.size(); ++si {
                    if si > 0 {
                        path += "::"
                    }

                    path += ctx->get_spelling(imp->path_segments[si])
                }

                var line: usize = 0
                if imp->range.start.id != 0 && !imp->is_prelude {
                    var lc = sm->get_line_col(imp->range.start)
                    line = lc.line
                }

                var rpath: string = ""
                if imp->resolved_fid != 0 {
                    rpath = sm->get_filename(imp->resolved_fid)
                }

                var is_ffi = imp->path_segments.size() == 0 && !imp->is_prelude
                o += "{" + f"\"idx\": {pi}, \"path\": {_json_str(path)}, \"line\": {line}, " + f"\"wildcard\": {_json_bool(imp->is_wildcard)}, \"selective\": {_json_bool(imp->has_items)}, " + f"\"anchor\": {_json_str(_import_anchor(imp))}, \"ffi\": {_json_bool(is_ffi)}, " + f"\"prelude\": {_json_bool(imp->is_prelude)}, \"pub\": {_json_bool(imp->is_public() || imp->is_protected())}, " + f"\"resolved_fid\": {imp->resolved_fid}, \"resolved_path\": {_json_str(rpath)}" + "}"
            }

            o += "], \"names\": ["

            // Group the log by key, first-hit order.
            var        order = cxx::std::vector<u32>()
            var        slot  = llvm::DenseMap<u64, u64>()
            var        sites = cxx::std::vector<cxx::std::vector<u32>>()
            var unsafe *log  = ov->uses
            for var k: usize = 0; k < log->keys.size(); ++k {
                var key       = log->keys[k] as u64
                var it        = slot.find(key)
                var at: usize = 0
                if it == slot.end() {
                    at        = order.size()
                    slot[key] = at as u64
                    order.push_back(log->keys[k])
                    sites.push_back(cxx::std::vector<u32>())
                } else {
                    at = it->second as usize
                }

                sites[at].push_back(log->ats[k])
            }

            var first_name = true
            for var n: usize = 0; n < order.size(); ++n {
                var unsafe *entry = ov->entry(order[n])
                if entry == &null {
                    continue
                }

                var origins: string = ""
                var fids:    string = ""
                var any             = false
                for var t: usize = 0; t < entry->targets.size(); ++t {
                    var tg = entry->targets[t]
                    if tg.hidden {
                        continue
                    }

                    var unsafe *od = dyn_cast<Declarations::ImportDecl>(tg.origin)
                    if od == &null || od->is_prelude {
                        continue
                    }

                    var idx: usize = usize::MAX
                    for var d: usize = 0; d < decls.size(); ++d {
                        if decls[d] == od {
                            idx = d
                            break
                        }
                    }

                    if idx == usize::MAX {
                        continue
                    }

                    if any {
                        origins += ", "
                        fids += ", "
                    }

                    any = true
                    origins += f"{idx}"
                    fids += f"{tg.src_fid}"
                }

                // Answered by the builtin prelude alone: no written import to lint.
                if !any {
                    continue
                }

                var implicit: usize  = 0
                var foreign:  usize  = 0
                var seen             = llvm::DenseSet<u32>()
                var sl:       string = ""
                for var s: usize = 0; s < sites[n].size(); ++s {
                    var raw = sites[n][s]
                    if raw == 0 {
                        implicit += 1
                        continue
                    }

                    var res = sm->resolve(SourceLocation::from_raw(raw))
                    if (res.fid as u32) != fid {
                        foreign += 1
                        continue
                    }

                    if !seen.insert(raw).second {
                        continue
                    }

                    var lc = sm->get_line_col(SourceLocation::from_raw(raw))
                    if sl.size() > 0 {
                        sl += ", "
                    }

                    sl += f"[{res.offset}, {lc.line}, {lc.column}]"
                }

                if !first_name {
                    o += ", "
                }

                first_name = false
                o += "\n  {" + f"\"name\": {_json_str(imms->get_ident(order[n]))}, \"origins\": [{origins}], " + f"\"src_fids\": [{fids}], \"implicit\": {implicit}, \"foreign\": {foreign}, \"sites\": [{sl}]" + "}"
            }

            o += "]}"
        }

        o += "]}\n"
        if !Path::write_file(out_path, o) {
            self._ci->diag()->report(
                DiagID::U023E,
                f"cannot write import-use dump '{out_path}'",
            ).emit()
        }
    }

    /// --dump-interface / --dump-deps (Compiler/Spec/IncrementalSema.md has
    /// both formats and Scripts/incr_oracle.py reads them). Files are sorted
    /// by module path and every list inside one is sorted, so two runs, two
    /// checkouts and two import orders write the same bytes; the only
    /// absolute path is the top-level `root` (the working directory), and a
    /// file's `path` is relative to it, or empty for a file outside it (the
    /// bundled library), which its module path still names.
    priv fn _dump_incremental(self, const iface_path: string, const deps_path: string) {
        var _t          = TimeRegion("IncrDump")
        var unsafe *psym = self._ci->pp()->get_symbol_table()
        var root         = Path::cwd().path_data
        var prefix       = root + "/"

        // Sorted by (module, path): the order of every file list below.
        var order = cxx::std::vector<string>()
        for var i: usize = 0; i < self._incr.size(); ++i {
            order.push_back(self._incr[i].mod_path + "\t" + self._incr[i].path + "\t" + f"{i}")
        }

        llvm::sort(order.begin(), order.end())
        var idx = cxx::std::vector<usize>()
        for var i: usize = 0; i < order.size(); ++i {
            var s        = order[i]
            var n: usize = 0
            var at       = s.size()
            while at > 0 && s[at - 1] != ('\t' as u8) {
                at -= 1
            }

            for var k: usize = at; k < s.size(); ++k {
                n = n * 10 + ((s[k] - ('0' as u8)) as usize)
            }

            idx.push_back(n)
        }

        var overlays = llvm::DenseMap<u64, unsafe *TranslationUnit>()
        for var fid: u32 in self._fids {
            var unsafe *c = self._global_scope->get_context(fid)
            if c != &null && c->tu != &null && c->tu->import_overlay != &null {
                overlays[c->tu->import_overlay as usize as u64] = c->tu
            }
        }

        var rec  = self._ci->incr.on
        var head = "{\"version\": 1, \"root\": " + incr_json(root) + ", \"files\": ["
        var io_: string = head
        var do_: string = head
        for var i: usize = 0; i < idx.size(); ++i {
            var *f  = &self._incr[idx[i]]
            var rel: string = ""
            if f->path.size() > prefix.size() && f->path.subslice(0, prefix.size()) == prefix {
                rel = f->path.subslice(prefix.size(), f->path.size() - prefix.size())
            }

            var who = "\n{\"module\": " + incr_json(f->mod_path) + ", \"path\": " + incr_json(rel)
            if i > 0 {
                io_ += ","
                do_ += ","
            }

            var io_at = io_.size()
            var do_at = do_.size()

            io_ += who + ", \"phase\": " + incr_json(f->phase) + ", \"hash\": " + incr_json(f->hash) + ", \"macros\": " + incr_json(f->macros) + ", \"decls\": ["
            for var k: usize = 0; k < f->decls.size(); ++k {
                io_ += (if (k > 0) => (",\n  ") else => "\n  ") + f->decls[k]
            }

            io_ += "], \"scopes\": ["
            for var k: usize = 0; k < f->scopes.size(); ++k {
                io_ += (if (k > 0) => (",\n  ") else => "\n  ") + f->scopes[k]
            }

            io_ += "]}"

            if deps_path.empty() && !rec {
                continue
            }

            var        deps = FileDeps{}
            var unsafe *c   = self._global_scope->get_context(f->fid)
            if c != &null {
                incr_resolve_deps(c->tu, self._global_scope, psym, unsafe &overlays, unsafe &deps)
            }

            do_ += who + ", \"surface\": ["
            for var k: usize = 0; k < deps.surface.size(); ++k {
                do_ += (if (k > 0) => (", ") else => "") + incr_json(deps.surface[k])
            }

            do_ += "], \"names\": ["
            for var k: usize = 0; k < deps.names.size(); ++k {
                do_ += (if (k > 0) => (",\n  ") else => "\n  ") + deps.names[k]
            }

            // Overlay rows are `<module>\t<name>`, sorted: one object per
            // module, its names in order.
            do_ += "], \"overlay\": ["
            var cur:  string = ""
            var open_        = false
            for var k: usize = 0; k < deps.overlay.size(); ++k {
                var row      = deps.overlay[k]
                var cut: usize = 0
                while cut < row.size() && row[cut] != ('\t' as u8) {
                    cut += 1
                }

                var of_  = row.subslice(0, cut)
                var name = if (cut < row.size()) => (row.subslice(cut + 1, row.size() - cut - 1)) else => ""
                if (!open_) || of_ != cur {
                    if open_ {
                        do_ += "]},"
                    }

                    do_ += "\n  {\"of\": " + incr_json(of_) + ", \"names\": ["
                    cur   = of_
                    open_ = true
                } else {
                    do_ += ", "
                }

                do_ += incr_json(name)
            }

            if open_ {
                do_ += "]}"
            }

            // Declaration rows: the checked tree's, then the hooks'.
            var rows = f->rows
            for var k: usize = 0; k < deps.rows.size(); ++k {
                rows.push_back(deps.rows[k])
            }

            llvm::sort(rows.begin(), rows.end())
            do_ += "], \"decls\": ["
            var prev:  string = ""
            var first_        = true
            for var k: usize = 0; k < rows.size(); ++k {
                if rows[k] == prev {
                    continue
                }

                prev = rows[k]
                var cut: usize = 0
                while cut < prev.size() && prev[cut] != ('\t' as u8) {
                    cut += 1
                }

                var part = prev.subslice(0, cut)
                var id   = if (cut < prev.size()) => (prev.subslice(cut + 1, prev.size() - cut - 1)) else => ""
                do_ += (if (first_) => ("\n  ") else => ",\n  ") + "{\"id\": " + incr_json(id) + ", \"part\": " + incr_json(
                    part,
                ) + "}"
                first_ = false
            }

            do_ += "]}"
            // Incremental Sema's per-module record (Driver/ModuleRecords.k):
            // the same two entries the dumps print, plus the files it imports.
            if rec {
                var imps = ""
                if c != &null && c->tu != &null {
                    for var k: usize = 0; k < c->tu->import_edges.size(); ++k {
                        var unsafe *e = c->tu->import_edges.get(k)
                        // Kairo modules only: a header's ffi closure is
                        // thousands of files per TU, and the manifest
                        // already hashes every header of the run.
                        if e == &null || e->target_fid == u32::MAX || self._ci->is_foreign_fid(e->target_fid) {
                            continue
                        }

                        imps += (if (imps.empty()) => ("") else => ", ") + incr_json(self._ci->sm()->get_filename(e->target_fid))
                    }
                }

                var name = if (f->mod_path.empty()) => (f->path) else => f->mod_path
                // The same facts as lines the invalidation rules read
                // (Sema/Incremental/Plan.k), with the TU's diagnostics.
                var pm = PlanModule()
                pm.name       = name
                pm.path       = f->path
                pm.hash       = f->hash
                pm.macros     = f->macros
                pm.decls      = f->plain_decls
                pm.scopes     = f->plain_scopes
                pm.surface    = deps.surface
                pm.names      = deps.plain_names
                pm.overlay    = deps.overlay
                pm.diag       = f->diag
                pm.diag_files = f->diag_files
                var plast: string = ""
                for var k: usize = 0; k < rows.size(); ++k {
                    if rows[k] != plast {
                        plast = rows[k]
                        pm.rows.push_back(plast)
                    }
                }

                self._ci->incr.mod_plan.push_back(pm)
                self._ci->incr.mod_names.push_back(name)
                self._ci->incr.mod_hash.push_back(f->hash)
                self._ci->incr.mod_json.push_back(
                    "\"imports\": [" + imps + "],\n\"interface\": " + io_.subslice(io_at + 1, io_.size() - io_at - 1) + ",\n\"deps\": " + do_.subslice(do_at + 1, do_.size() - do_at - 1) + "\n",
                )
            }
        }

        io_ += "\n]}\n"
        do_ += "\n]}\n"
        if (!iface_path.empty()) && !Path::write_file(iface_path, io_) {
            self._ci->diag()->report(DiagID::U023E, f"cannot write interface dump '{iface_path}'").emit()
        }

        if (!deps_path.empty()) && !Path::write_file(deps_path, do_) {
            self._ci->diag()->report(DiagID::U023E, f"cannot write dependency dump '{deps_path}'").emit()
        }
    }

    priv fn _dump_symbols(self,
                          tu:   unsafe *TranslationUnit,
                          ctx:  unsafe *ASTContext,
                          opts: PrintOptions) {
        var unsafe *tu_dc = unsafe (tu as unsafe *DeclContext)
        self._dump_symbols_dc(tu_dc, ctx, opts, "<tu>")
    }

    priv fn _dump_symbols_dc(self,
                             dc:         unsafe *DeclContext,
                             ctx:        unsafe *ASTContext,
                             opts:       PrintOptions,
                             const qual: string) {
        if dc == &null {
            return
        }

        var p = Painter(opts)
        p.paint(Color::NodeKind, f"scope {qual}")
        if dc->dc_symbols == &null {
            p.paint(Color::Dim, "  (no table)")
            p.newline()
        } else {
            var unsafe *tbl = dc->dc_symbols
            if tbl->is_frozen() {
                p.paint(Color::Dim, f"  ({tbl->size()} names, frozen)")
            } else {
                p.paint(Color::Error, f"  ({tbl->size()} names, NOT FROZEN)")
            }

            p.newline()

            var entries: cxx::std::vector<SymbolTable::Entry>
            tbl->collect_entries(&entries)
            for var ei: usize = 0; ei < entries.size(); ++ei {
                var unsafe *cell = entries[ei].cell
                if cell == &null {
                    continue
                }

                // Name header: idents/ctor/dtor decode from the key; operators
                // cannot (the key packs TokenKind hashes lossily), so render them
                // from the first decl's op_token via get_spelling   the exact
                // source bytes the user wrote.
                var name = entries[ei].name.describe(ctx)
                if entries[ei].name.is_op() {
                    var unsafe *od = cell->get(0)
                    if od != &null && isa<Declarations::FunctionDecl>(od) {
                        var unsafe *f          = cast<Declarations::FunctionDecl>(od)
                        var        opr: string = "op "
                        for var ti: usize = 0; ti < f->op_token.size(); ++ti {
                            opr += ctx->get_spelling(f->op_token[ti])
                        }

                        name = opr
                    }
                }

                var n = cell->size()
                p.paint(Color::Ident, name)
                if n > 1 {
                    p.paint(Color::Dim, f"  [overloaded x{n}]")
                }

                p.newline()
                for var di: usize = 0; di < n; ++di {
                    var unsafe *d = cell->get(di)
                    if d == &null {
                        continue
                    }

                    p.paint(Color::Tree, "    ")
                    p.put(DeclPrinter::print(d, ctx, opts))
                    p.newline()
                }
            }
        }

        io::println(f"{p.out}")

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *d = *dc->dc_decls.get(i)
            if d == &null {
                continue
            }

            var child: unsafe *DeclContext = &null
            var name:  string              = ""

            if isa<Declarations::ClassDecl>(d) {
                var unsafe *n = cast<Declarations::ClassDecl>(d)
                child = n
                name = ctx->get_spelling(n->name) + _sym_spec_suffix(
                    ctx,
                    opts,
                    n->spec_kind,
                    &n->spec_args,
                    &n->generic_params,
                )
            } else if isa<Declarations::StructDecl>(d) {
                var unsafe *n = cast<Declarations::StructDecl>(d)
                child = n
                name = ctx->get_spelling(n->name) + _sym_spec_suffix(
                    ctx,
                    opts,
                    n->spec_kind,
                    &n->spec_args,
                    &n->generic_params,
                )
            } else if isa<Declarations::UnionDecl>(d) {
                var unsafe *n = cast<Declarations::UnionDecl>(d)
                child = n
                name = ctx->get_spelling(n->name) + _sym_spec_suffix(
                    ctx,
                    opts,
                    n->spec_kind,
                    &n->spec_args,
                    &n->generic_params,
                )
            } else if isa<Declarations::InterfaceDecl>(d) {
                var unsafe *n = cast<Declarations::InterfaceDecl>(d)
                child = n
                name = ctx->get_spelling(n->name) + _sym_spec_suffix(
                    ctx,
                    opts,
                    n->spec_kind,
                    &n->spec_args,
                    &n->generic_params,
                )
            } else if isa<Declarations::EnumDecl>(d) {
                var unsafe *n = cast<Declarations::EnumDecl>(d)
                child = n
                name = ctx->get_spelling(n->name) + _sym_spec_suffix(
                    ctx,
                    opts,
                    n->spec_kind,
                    &n->spec_args,
                    &n->generic_params,
                )
            } else if isa<Declarations::ModuleDecl>(d) {
                var unsafe *n = cast<Declarations::ModuleDecl>(d)
                child = n
                name  = ctx->get_spelling(n->name)
            } else if isa<Declarations::ExtensionDecl>(d) {
                var unsafe *n = cast<Declarations::ExtensionDecl>(d)
                child = n
                name  = "<extension>"
            }

            if child == &null {
                continue
            }

            self._dump_symbols_dc(child, ctx, opts, f"{qual}::{name}")
        }
    }

    priv fn _dump_mem_stats(self) {
        if !self._ci->invocation()->frontend.print_stats {
            return
        }

        var total_bytes:  usize = 0
        var total_slabs:  usize = 0
        var total_allocs: usize = 0
        var tu_count:     usize = 0

        for var fid: u32 in self._fids {
            var unsafe *ctx = self._global_scope->get_context(fid)
            if ctx == &null {
                continue
            }

            var p = ctx->mem_profile()
            total_bytes += p.0
            total_slabs += p.1
            total_allocs += p.2
            tu_count += 1
        }

        var retained_blocks: usize = 0
        var retained_bytes:  usize = 0
        kairo::GlobalRecycler::instance().stats(&retained_blocks, &retained_bytes)

        io::eprintln(f"[stats] mem: TU contexts:        {tu_count}")
        io::eprintln(
            f"[stats] mem: arena live bytes:   {total_bytes / (1024*1024)} MB ({total_bytes} B)",
        )

        io::eprintln(f"[stats] mem: arena slabs:        {total_slabs}")
        io::eprintln(f"[stats] mem: alloc calls:        {total_allocs}")
        io::eprintln(
            f"[stats] mem: bytes / alloc:      {if (total_allocs > 0) => (total_bytes / total_allocs) else => 0}",
        )

        io::eprintln(
            f"[stats] mem: recycler retained:  {retained_bytes / (1024*1024)} MB ({retained_blocks} blocks)",
        )

        {
            var b_pp:    usize = 0
            var b_ix:    usize = 0
            var b_ast:   usize = 0
            var b_sem:   usize = 0
            var b_scr:   usize = 0
            var b_str:   usize = 0
            var top_fid: u32   = 0
            var top_b:   usize = 0
            for var fid: u32 in self._fids {
                var unsafe *c = self._global_scope->get_context(fid)
                if c == &null {
                    continue
                }

                b_pp += c->pp_alloc.profile().bytes_allocated
                b_ix += c->index_alloc.profile().bytes_allocated
                b_ast += c->ast_alloc.profile().bytes_allocated
                b_sem += c->sema_alloc.profile().bytes_allocated
                b_scr += c->scratch_alloc.profile().bytes_allocated
                b_str += c->string_alloc.profile().bytes_allocated
                var one = c->mem_profile().0
                if one > top_b {
                    top_b   = one
                    top_fid = fid
                }
            }

            var mb: usize = 1024 * 1024
            io::eprintln(
                f"[stats] mem: by arena MB: pp {b_pp / mb} index {b_ix / mb} ast {b_ast / mb} sema {b_sem / mb} scratch {b_scr / mb} string {b_str / mb}",
            )

            io::eprintln(
                f"[stats] mem: largest TU: {self._ci->sm()->get_filename(top_fid)} {top_b / mb} MB",
            )
        }

        if self._ci->headers() != &null {
            var hsets: cxx::std::vector<unsafe *HeaderSet>
            self._ci->headers()->all(&hsets)
            var live:   usize = 0
            var hbytes: usize = 0
            for var hs: *HeaderSet in hsets {
                var b = hs->ast_bytes()
                if b > 0 {
                    live += 1
                    hbytes += b
                }
            }

            io::eprintln(
                f"[stats] mem: header sets:        {live} of {hsets.size()} live, clang AST {hbytes / (1024*1024)} MB",
            )

            var m_buf: usize = 0
            var m_map: usize = 0
            var m_sm:  usize = 0
            var m_pp:  usize = 0
            for var hs: *HeaderSet in hsets {
                hs->other_bytes(unsafe &m_buf, unsafe &m_map, unsafe &m_sm, unsafe &m_pp)
            }

            var mb: usize = 1024 * 1024
            io::eprintln(
                f"[stats] mem: header sets other:  file buffers heap {m_buf / mb} MB mmap {m_map / mb} MB, SM tables {m_sm / mb} MB, PP {m_pp / mb} MB",
            )
        }
    }

    /// --print-stats: what -finfer-purity found over the whole build.
    priv fn _dump_purity_stats(self) {
        if !self._ci->invocation()->frontend.print_stats {
            return
        }

        if self._ci->invocation()->lang.infer_purity == 0 {
            return
        }

        io::eprintln(
            f"[stats] purity inferred: const {kairo::purity_inferred_const().load()}, pure {kairo::purity_inferred_pure().load()}",
        )
    }
}

/// Marks one parse task's fid as done when the task ends, however it ends,
/// so the flusher never waits on a task that threw.
pub class PublishOnExit {
    priv var _d: unsafe *kairo::std::Atomic<bool>

    fn PublishOnExit(self, d: unsafe *kairo::std::Atomic<bool>) {
        self._d = d
    }

    @copy fn PublishOnExit(self, const other: Self) = delete

    /// notify_all after the store: the waiters (the flusher, the driver in
    /// _sema_parallel) park on the flag with atomic wait instead of spinning
    /// on sched_yield (~42k yields per whole-tree check). Without a
    /// waiter the notify is one atomic load on libc++'s waiter count.
    fn op finally (self) {
        self._d->store(true, cxx::std::memory_order_release)
        self._d->notify_all()
    }
}

/// Group \p g's instantiation rank: reserve_ranks gave the run \p base
/// and one counter value per group above it, and the value sits in the
/// high word. Spelled once because `base + g + 1 << 32` shifts the sum
/// only by C's precedence. g == the group count is the run's floor.
fn group_rank(base: u64, g: u64) -> u64 {
    return (base + g + 1) << 32
}

/// The registry's ordering key for the calling thread, narrowed to
/// one step of its group's schedule: \p code the step (1 I, 2 the re-export
/// refold, 3 E, 4 V, 5 N, 6 T's pre-pass, 7 T, 8 the typed checks and
/// Conformance, 9 the panic-set barrier, 10 the late part), \p member the
/// TU's place in the group. A one-thread run does the steps in this order,
/// so requests key as it makes them even when an import cycle's typed
/// checks run on a worker and their Conformance later on the driver.
fn sema_sub(code: u64, member: usize) {
    var unsafe *rp = kairo::sema_mint_rank()
    if *rp == u64::MAX {
        return
    }

    var base = *rp & 0xFFFFFFFF00000000
    *rp = base | code << 16 | (member as u64)
}

/// An import cycle's TUs, to Typed in LOCKSTEP, one phase at a time across
/// the group: each phase of one reads what the same phase of the other
/// produced (I folds the other's surface, X calls functions whose parameter
/// types the other's T resolved), and with no order in which every import
/// is finished first, run one TU to Typed ahead of the other and its calls
/// into the other see unresolved types. A TU that stops in a phase (a hard
/// stop in I/N/T) goes no further; the others carry on, as an acyclic
/// importer of it would. Re-entrant: phases a TU finished are skipped.
///
/// \p front: the parallel driver's worker part. The TUs were split
/// at Conformance, and the run stops, returning false, before a phase that
/// would read another group's late Sema (see SemaSlot::run_front); the
/// driver then continues the group in order.
fn sema_lockstep(sems: unsafe *cxx::std::vector<unsafe *Sema>, front: bool) -> bool {
    var n      = sems->size()
    var phases = cxx::std::vector<SemaPhase>()
    phases.push_back(SemaPhase::ImportsResolved)
    phases.push_back(SemaPhase::Expanded)
    phases.push_back(SemaPhase::Verified)
    phases.push_back(SemaPhase::NamesResolved)
    phases.push_back(SemaPhase::TypesResolved)
    phases.push_back(SemaPhase::Typed)
    var codes = cxx::std::vector<u64>()
    codes.push_back(1)
    codes.push_back(3)
    codes.push_back(4)
    codes.push_back(5)
    codes.push_back(7)
    codes.push_back(8)
    for var p: usize = 0; p < phases.size(); ++p {
        if front && phases[p] == SemaPhase::Verified {
            for var i: usize = 0; i < n; ++i {
                var unsafe *si = (*sems)[i]
                if !si->stopped() && si->sc.eval_branches.pending() > 0 {
                    return false
                }
            }
        }

        if front && phases[p] == SemaPhase::TypesResolved {
            for var i: usize = 0; i < n; ++i {
                var unsafe *si = (*sems)[i]
                if !si->stopped() && _defines_foreign_members(si->sc.tu, *sems) {
                    return false
                }
            }
        }

        // T before any ChainBinding of the group: binding walks the
        // other TUs' records through edges their T resolves.
        if phases[p] == SemaPhase::TypesResolved {
            for var i: usize = 0; i < n; ++i {
                var unsafe *si = (*sems)[i]
                if si->stopped() {
                    continue
                }

                sema_sub(6, i)
                if si->sc.phase == SemaPhase::NamesResolved {
                    si->resolve_types_pre()
                }
            }
        }

        for var i: usize = 0; i < n; ++i {
            var unsafe *si = (*sems)[i]
            // A hard stop is final (run_to refuses a stopped TU, whose
            // phase still names the stage that stopped). A TU that merely has
            // errors goes on, as it would outside a cycle: run_to's result is
            // false for both, so it is not what this asks. Asking it stopped
            // a TU with an error in N before T, and its importers' calls into
            // it failed on unresolved parameter types (P883).
            if si->stopped() {
                continue
            }

            if (si->sc.phase as u8) >= (phases[p] as u8) {
                continue
            }

            sema_sub(codes[p], i)
            si->run_to(phases[p])
        }

        // A front that met a once-per-build report in T stops after T: the
        // driver claims it, and whichever TU it lands in may then stop
        // there (FrontendAction::_settle_once).
        if front && phases[p] == SemaPhase::TypesResolved && n > 0 {
            var unsafe *log = (*sems)[0]->sc.once_log
            if log != &null && log->size() > 0 {
                return false
            }
        }

        // Re-exports across the cycle, to a fixpoint: the TU that
        // ran I first folded its sources' re-exports from overlays
        // the others had not built yet (ImportResolution::
        // refold_reexports). Bounded: each round that continues
        // added a target, and the targets are finite.
        if phases[p] == SemaPhase::ImportsResolved {
            sema_sub(2, 0)
            var grew = true
            while grew {
                grew = false
                for var i: usize = 0; i < n; ++i {
                    if (*sems)[i]->stopped() {
                        continue
                    }

                    // The one stage the driver runs on a TU's behalf outside
                    // Sema::run_to, so the one place it names the reader.
                    var _deps = DepLogScope((*sems)[i]->sc.tu->dep_log)
                    if ImportResolution(&(*sems)[i]->sc).refold_reexports() {
                        grew = true
                    }
                }
            }
        }
    }

    return true
}

/// The pool group of the parallel Sema fronts; 15 is free (parse
/// uses 5 and 6, the Clang groups 9 to 13, the emptiness checks 14).
pub
const SEMA_GROUP: u8 = 15

/// One import group's Semas while the parallel Sema driver holds them
/// (`FrontendAction::_sema_parallel`). A group runs its "front"
/// (every stage up to the typed checks before ConformanceChecking, in
/// lockstep for an import cycle) on whichever thread claims it first, a
/// pool worker or the driver, and the rest of its Sema on the driver
/// thread in import order.
pub class SemaSlot {
    pub var sems:    cxx::std::vector<unsafe *Sema>
    pub var members: cxx::std::vector<u32>
    /// The group's place in the order a one-thread run uses, and its
    /// InstantiationRegistry request counter (sema_mint_rank /
    /// sema_mint_counter): what keeps the registry's worklist and homes
    /// the one-thread run's whichever thread mints first.
    pub var rank:    u64  = 0
    pub var counter: u64  = 0
    pub var front:   bool = false ///< its front may run on a worker.
    /// The front stopped early on purpose (see run_front); the driver runs
    /// the rest of the TU's Sema, in order, like a barrier group's.
    pub var partial: bool                     = false
    pub var queued:  bool                     = false ///< handed to the pool (or run by the driver).
    pub var claim:   kairo::std::Atomic<u32>  = kairo::std::Atomic<u32>(0)
    pub var done:    kairo::std::Atomic<bool> = kairo::std::Atomic<bool>(false)
    /// The once-per-build reports the front met, in the order it met them
    /// (SemaContext::once_log; one thread runs a front, so this is the
    /// one-thread order within the group). The driver claims them at the
    /// group's turn (FrontendAction::_settle_once).
    pub var once: cxx::std::vector<OnceMention>

    fn SemaSlot(self) { }

    /// Run the front unless another thread already took it. Both the pool
    /// task and the driver call this; the claim makes it run once.
    fn run_front(self) {
        var expected: u32 = 0
        if !self.claim.compare_exchange_strong(&expected, 1) {
            return
        }

        var publish = PublishOnExit(unsafe &self.done)
        self.enter()
        {
            var        _ts  = TimeRegion("Sema")
            var unsafe *sem = self.sems[0]
            sem->split_conformance = true
            for var i: usize = 0; i < self.sems.size(); ++i {
                self.sems[i]->sc.once_log = unsafe &self.once
            }

            sema_sub(0, 0)
            // Two facts only show after a stage, and each makes what follows
            // read another TU's late Sema, so the rest waits for the driver,
            // where every earlier group has finished as in a one-thread run:
            //  - an `eval if` on a type fact, deferred by E, is decided in
            //    T from layouts (EnumLayoutQuery) that other TUs' lowerings
            //    fill (a `T?`'s);
            //  - an out-of-line definition of another file's member, which
            //    RedeclMerge (T) splices into that file's redeclaration ring.
            // A hard stop leaves split_conformance set and the typed checks
            // not run, which is how _sema_finish knows not to continue it.
            if self.sems.size() > 1 {
                // An import cycle: the same stops, phase by phase across
                // the group (sema_lockstep).
                for var i: usize = 0; i < self.sems.size(); ++i {
                    self.sems[i]->split_conformance = true
                }

                if !sema_lockstep(unsafe &self.sems, true) {
                    self.partial = true
                }
            } else {
                sem->run_to(SemaPhase::Expanded)
                if !sem->stopped() && sem->sc.eval_branches.pending() > 0 {
                    self.partial = true
                }

                if !sem->stopped() && !self.partial {
                    sem->run_to(SemaPhase::NamesResolved)
                    if !sem->stopped() && _defines_foreign_members(sem->sc.tu, self.sems) {
                        self.partial = true
                    }
                }

                // A once-per-build report T met waits for the driver, and
                // a claimed one stops the TU after T (_settle_once): the
                // typed checks wait with it.
                if !sem->stopped() && !self.partial {
                    sem->run_to(SemaPhase::TypesResolved)
                    if !sem->stopped() && self.once.size() > 0 {
                        self.partial = true
                    }
                }

                if !sem->stopped() && !self.partial {
                    sem->run_to(SemaPhase::Typed)
                }

                if self.partial {
                    sem->split_conformance = false
                }
            }
        }

        Self::leave()
    }

    /// Mint as this group on the calling thread (InstantiationRegistry).
    fn enter(self) {
        *kairo::sema_mint_rank()    = self.rank
        *kairo::sema_mint_counter() = unsafe &self.counter
    }

    static fn leave() {
        *kairo::sema_mint_rank()    = u64::MAX
        *kairo::sema_mint_counter() = &null
    }
}

/// The import graph of one action cut into the groups the sema loop runs
/// together: its strongly connected components, each placed after every
/// component it imports, in the order the loop already used (`order`,
/// _import_order) wherever that order holds. With no import cycle every
/// component is one fid and the groups are `order` itself.
pub class ImportGroups {
    pub var  fids:    cxx::std::vector<u32> ///< every fid, group by group.
    pub var  starts:  cxx::std::vector<usize> ///< group g is fids[starts[g] .. starts[g + 1]).
    priv var _order:  cxx::std::vector<u32>
    priv var _adj:    cxx::std::vector<usize> ///< the imports of order[i], as indices: _adj[_adj_at[i] .. _adj_at[i + 1]).
    priv var _adj_at: cxx::std::vector<usize>
    priv var _reach:  cxx::std::vector<u8> ///< n*n: order[i] reaches order[j] through imports.
    priv var _done:   cxx::std::vector<u8>

    fn ImportGroups(self) { }

    fn build(self, const order: cxx::std::vector<u32>, gs: unsafe *GlobalDisambigTable) {
        var n = order.size()
        self._order = order
        // Index by fid, WIDENED: an edge's target can be u32(-1), DenseMap's
        // empty key (_import_order has the same note).
        var at = llvm::DenseMap<u64, u64>()
        for var i: usize = 0; i < n; ++i {
            at[(order)[i] as u64] = (i as u64)
        }

        for var i: usize = 0; i < n; ++i {
            self._adj_at.push_back(self._adj.size())
            var unsafe *ctx                         = gs->get_context((order)[i])
            var        tu:  unsafe *TranslationUnit = &null
            if ctx != &null {
                tu = ctx->tu
            }

            if tu == &null {
                continue
            }

            for var j: usize = 0; j < tu->import_edges.size(); ++j {
                var unsafe *e = tu->import_edges.get(j)
                if e == &null {
                    continue
                }

                var it = at.find(e->target_fid as u64)
                if it == at.end() {
                    continue
                }

                var k = (it->second as usize)
                if k != i {
                    self._adj.push_back(k)
                }
            }
        }

        self._adj_at.push_back(self._adj.size())

        // Reachability by one walk from each fid: graphs are small, and a
        // component is then "reaches and is reached by".
        for var i: usize = 0; i < n * n; ++i {
            self._reach.push_back(0)
        }

        for var i: usize = 0; i < n; ++i {
            var stack = cxx::std::vector<usize>()
            stack.push_back(i)
            while stack.size() > 0 {
                var v = stack[stack.size() - 1]
                stack.pop_back()
                for var a: usize = (self._adj_at[(v)]); a < (self._adj_at[v + 1]); ++a {
                    var w = self._adj[a]
                    if self._reach[i * n + (w)] != 0 {
                        continue
                    }

                    self._reach[i * n + (w)] = 1
                    stack.push_back(w)
                }
            }
        }

        for var i: usize = 0; i < n; ++i {
            self._done.push_back(0)
        }

        for var i: usize = 0; i < n; ++i {
            self._place(i)
        }

        self.starts.push_back(self.fids.size())
    }

    priv fn _same(self, i: usize, j: usize) -> bool {
        if i == j {
            return true
        }

        var n = self._order.size()
        return self._reach[i * n + j] != 0 && self._reach[j * n + i] != 0
    }

    /// Place \p i's component after every component it imports. Its members
    /// are marked first: no import of another component can lead back into
    /// this one (it would be in it), so the recursion ends.
    priv fn _place(self, i: usize) {
        if self._done[i] != 0 {
            return
        }

        var n       = self._order.size()
        var members = cxx::std::vector<usize>()
        for var j: usize = 0; j < n; ++j {
            if self._same(i, j) {
                members.push_back(j)
                self._done[j] = 1
            }
        }

        for var m: usize = 0; m < members.size(); ++m {
            var v = members[m]
            for var a: usize = (self._adj_at[(v)]); a < (self._adj_at[v + 1]); ++a {
                var w = self._adj[a]
                if !self._same(i, (w)) {
                    self._place((w))
                }
            }
        }

        self.starts.push_back(self.fids.size())
        for var m: usize = 0; m < members.size(); ++m {
            self.fids.push_back(self._order[members[m]])
        }
    }
}

/// \p tu defines, out of line, a member of a type declared in a file
/// outside its import group (N attached it there: `semantic_dc`).
fn _defines_foreign_members(tu:          unsafe *TranslationUnit,
                            const group: cxx::std::vector<unsafe *Sema>) -> bool {
    if tu == &null {
        return false
    }

    for var i: usize = 0; i < tu->out_of_line.size(); ++i {
        var unsafe *d = *tu->out_of_line.get(i)
        if d == &null || d->semantic_dc == &null {
            continue
        }

        var unsafe *home  = NameLookup::tu_of(d->semantic_dc)
        var        inside = false
        for var k: usize = 0; k < group.size(); ++k {
            if (group)[k]->sc.tu == home {
                inside = true
            }
        }

        if !inside {
            return true
        }
    }

    return false
}

/// \p dc or a type or module scope under it declares an explicit or partial
/// specialization, which the registry matches against every use whether
/// the user imports it or not (TypeResolution::_register_specs_in walks the
/// same scopes), or an extension, which every TU's member lookup indexes
/// the same way: such a TU's Sema must not overlap any other's.
/// _declares_specs for a live check's refresh set: true for an explicit or
/// partial specialization (the registry's tables match every use in the
/// build and hold the declaration), while an extension is not a reason to
/// refuse: it is collected into \p exts, and the file of the record it
/// extends joins the set (FrontendAction::refresh_extends).
fn _refresh_specs(dc: unsafe *DeclContext, exts: unsafe *cxx::std::vector<unsafe *Decl>) -> bool {
    if dc == &null {
        return false
    }

    var found = false
    for var i: usize = 0; i < dc->dc_decls.size(); ++i {
        var unsafe *d = *dc->dc_decls.get(i)
        if d != &null && _decl_refresh_specs(d, exts) {
            found = true
        }
    }

    return found
}

fn _decl_refresh_specs(d: unsafe *Decl, exts: unsafe *cxx::std::vector<unsafe *Decl>) -> bool {
    if isa<Declarations::VisibilityGroupDecl>(d) {
        var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
        var found     = false
        for var i: usize = 0; i < g->members.size(); ++i {
            if g->members[i] != &null && _decl_refresh_specs(g->members[i], exts) {
                found = true
            }
        }

        return found
    }

    if isa<Declarations::EvalBlockDecl>(d) {
        var unsafe *b = cast<Declarations::EvalBlockDecl>(d)
        var found     = false
        for var i: usize = 0; i < b->body.size(); ++i {
            if b->body[i] != &null && _decl_refresh_specs(b->body[i], exts) {
                found = true
            }
        }

        return found
    }

    if isa<Declarations::ModuleDecl>(d) {
        return _refresh_specs(NameLookup::context_of(d), exts)
    }

    if isa<Declarations::ExtensionDecl>(d) {
        exts->push_back(d)
        return false
    }

    var k = decl_spec_kind(d)
    if k == Declarations::SpecKind::Explicit || k == Declarations::SpecKind::Partial {
        return true
    }

    var unsafe *child = NameLookup::context_of(d)
    if child != &null && child->is_type_scope() {
        return _refresh_specs(child, exts)
    }

    return false
}

/// DeclId -> the interface hashes under it (joined), from \p f's plan
/// lines (`id, scope, name, I, ...`), added to \p at / \p vals.
fn _fid_in(set: *cxx::std::vector<u32>, fid: u32) -> bool {
    for var i: usize = 0; i < set->size(); ++i {
        if (*set)[i] == fid {
            return true
        }
    }

    return false
}

fn _facts_hashes(f: unsafe *FileFacts, at: unsafe *llvm::StringMap<u32>, vals: unsafe *cxx::std::vector<string>) {
    for var k: usize = 0; k < f->plain_decls.size(); ++k {
        var l          = f->plain_decls[k]
        var cut        = cxx::std::vector<usize>()
        for var c: usize = 0; c < l.size() && cut.size() < 4; ++c {
            if l[c] == ('\t' as u8) {
                cut.push_back(c)
            }
        }

        if cut.size() < 4 {
            continue
        }

        var id = l.subslice(0, cut[0])
        var ih = l.subslice(cut[2] + 1, cut[3] - cut[2] - 1)
        var it = at->find(kairo::sref(id))
        if it == at->end() {
            at->try_emplace(kairo::sref(id), vals->size() as u32)
            vals->push_back(ih)
        } else {
            (*vals)[it->second as usize] = (*vals)[it->second as usize] + "," + ih
        }
    }
}

fn _declares_specs(dc: unsafe *DeclContext) -> bool {
    if dc == &null {
        return false
    }

    var type_body = dc->is_type_scope()
    for var i: usize = 0; i < dc->dc_decls.size(); ++i {
        var unsafe *d = *dc->dc_decls.get(i)
        if d == &null {
            continue
        }

        if type_body && isa<Declarations::VisibilityGroupDecl>(d) {
            continue
        }

        if _decl_declares_specs(d) {
            return true
        }
    }

    return false
}

fn _decl_declares_specs(d: unsafe *Decl) -> bool {
    if isa<Declarations::VisibilityGroupDecl>(d) {
        var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
        for var i: usize = 0; i < g->members.size(); ++i {
            if _decl_declares_specs(g->members[i]) {
                return true
            }
        }

        return false
    }

    if isa<Declarations::EvalBlockDecl>(d) {
        var unsafe *b = cast<Declarations::EvalBlockDecl>(d)
        for var i: usize = 0; i < b->body.size(); ++i {
            if _decl_declares_specs(b->body[i]) {
                return true
            }
        }

        return false
    }

    if isa<Declarations::ModuleDecl>(d) {
        return _declares_specs(NameLookup::context_of(d))
    }

    // An extension is in every TU's index whether the TU imports it or not
    // (MemberLookup::index_extensions), from the moment its own T resolves
    // its target: one Sema running beside it would see it or not by timing.
    if isa<Declarations::ExtensionDecl>(d) {
        return true
    }

    var k = decl_spec_kind(d)
    if k == Declarations::SpecKind::Explicit || k == Declarations::SpecKind::Partial {
        return true
    }

    var unsafe *child = NameLookup::context_of(d)
    if child != &null && child->is_type_scope() {
        return _declares_specs(child)
    }

    return false
}

/// The interface PCH's threshold in auto mode: the Kairo bytes of one
/// flavour's TUs below which the whole streams are cheaper (_codegen).
pub
const IFACE_PCH_MIN_BYTES: usize = 1048576

pub fn _overlay_kind_str(k: OverlayTargetKind) -> string {
    if k == OverlayTargetKind::FunctionSet {
        return "fn-set"
    }

    if k == OverlayTargetKind::Type {
        return "type"
    }

    if k == OverlayTargetKind::ModuleHandle {
        return "module"
    }

    return "?"
}

pub fn _overlay_vis_str(v: OverlayVisibility) -> string {
    if v == OverlayVisibility::Public {
        return "pub"
    }

    if v == OverlayVisibility::Protected {
        return "prot"
    }

    if v == OverlayVisibility::Private {
        return "priv"
    }

    return "?"
}

/// A JSON string literal. Paths and identifiers only, so quote, backslash
/// and control bytes are all that can need escaping.
fn _json_str(const s: string) -> string {
    var o: string = "\""
    for var i: usize = 0; i < s.size(); ++i {
        var c = s[i]
        if c == ('"' as u8) || c == ('\\' as u8) {
            o += "\\"
            o.push_back(c)
        } else if is_control(c) {
            o += " "
        } else {
            o.push_back(c)
        }
    }

    o += "\""
    return o
}

fn _json_bool(b: bool) -> string {
    return if (b) => ("true") else => "false"
}

/// The anchor an import path was written with: "" (the search roots),
/// "self" or "module". The JSON's `path` never carries it, so a tool that
/// rewrites imports has to put it back.
fn _import_anchor(imp: unsafe *Declarations::ImportDecl) -> string {
    if imp->import_kind == Declarations::ImportKind::SelfRelative {
        return "self"
    }

    if imp->import_kind == Declarations::ImportKind::ModuleRelative {
        return "module"
    }

    return ""
}

/// Disambiguating suffix for a type-decl scope header. Overloaded/specialized
/// types (e.g. `class <T> Box`, `class <> Box<i32>`, `class <> Box<[T]>`) all
/// share the bare name `Box`, so three `scope <tu>::Box` headers are
/// indistinguishable in the dump. Append the specialization args (`<i32>`) or,
/// for a generic primary, the parameter list (`<T>`), rendered through the
/// same type/token printers the AST dump uses. Non-generic decls get "".
pub fn _sym_spec_suffix(ctx:                   unsafe *ASTContext,
                        opts:                  PrintOptions,
                        spec_kind:             Declarations::SpecKind,
                        @inout spec_args:      FrozenList<unsafe *Type>,
                        @inout generic_params: FrozenList<unsafe *Declarations::GenericParamDecl>) -> string {
    // Specialization: render the post-name `<...>` argument pattern.
    if spec_kind == Declarations::SpecKind::Explicit
        || spec_kind == Declarations::SpecKind::Partial {
        var s: string = "<"
        for var i: usize = 0; i < spec_args.size(); ++i {
            if i > 0 {
                s += ", "
            }

            if spec_args[i] != &null {
                s += TypePrinter::print(spec_args[i], ctx, opts)
            }
        }

        s += ">"
        return s
    }

    // Generic primary: render the parameter names.
    if !generic_params.is_empty() {
        var s: string = "<"
        for var i: usize = 0; i < generic_params.size(); ++i {
            if i > 0 {
                s += ", "
            }

            if generic_params[i] != &null {
                s += ctx->get_spelling(generic_params[i]->name)
            }
        }

        s += ">"
        return s
    }

    return ""
}
