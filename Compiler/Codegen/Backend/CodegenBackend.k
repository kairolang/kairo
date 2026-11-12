/// --- The Kairo Project ------------- Codegen/Backend/CodegenBackend.k --- ///
///
///   \brief The codegen DRIVER: entry point, stage schedule, state. Zero
///          emission logic. Mirrors Sema.k's discipline exactly: every time
///          an emit_* helper wants to land here, it is an emitter (own file
///          under Emit/, borrows *CodegenContext, writes to TokenSink)
///          never a method on this class.
///
///   Import rule (the anti-rot law of this layer):
///     - Backend/ is the ONLY directory that imports emitters: this file
///       (an object), EmitCXXHeader.k (a header) and IncludeEmitter.k (the
///       tokens of `#include "foo.k"`), each running a plan into a sink.
///     - Emitters import CodegenContext, never a Backend/ file. They reach
///       the sink through cg->sink.
///     - Emitters write to an EmitSink (Sink/EmitSink.k), never to a
///       concrete sink. The sink files are Sink/EmitSink.k (the interface),
///       Sink/TokenSink.k (clang tokens, the real build) and Sink/TextSink.k
///       (C++ text). This file uses only TokenSink; TextSink's callers are
///       the driver's --print-cxx dump and EmitCXXHeader, both of which run
///       in sema and need no clang.
///     - Only Backend/ and Sink/ may import clang headers. An
///       `ffi "c++" import "clang/..."` appearing in Emit/ is a
///       layer-fusion bug, full stop. Emitters name clang::tok kinds in
///       calls to the sink but import no clang header   they see the enum
///       transitively, which is the one clang detail the emit layer is
///       allowed to know.
///
///   Codegen owns NO intermediate representation. Sema's Lower/ stage
///   produces the codegen-shaped tree; the only structure built here is the
///   EmitPlan (C++-legal decl order + fwd-decl set), which is M3   for a
///   single function it is the identity transform.
///
///   Poisoned nodes reaching this layer are a sema gate failure: assert,
///   never diagnose. "One error, one home"   codegen is not a home.
///
///   Phase: DRIVER
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Frontend/CompilerInstance.h"
ffi "c++" import "clang/Frontend/FrontendActions.h"
ffi "c++" import "clang/Frontend/FrontendOptions.h"
ffi "c++" import "clang/Basic/SourceManager.h"
ffi "c++" import "clang/Lex/PreprocessorOptions.h"
ffi "c++" import "llvm/Support/MemoryBuffer.h"
ffi "c++" import "llvm/Support/VirtualFileSystem.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "Native/KTimeClang.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/KProgress.hh"
ffi "c++" import "vector"
ffi "c++" import "memory"

import AST::Context::ASTContext::ASTContext
import AST::Context::InstantiationRegistry::InstantiationRegistry
import Codegen::Backend::CodegenAction::{
    EmitKind,    KairoEmitAsm, KairoEmitLLVMBC, KairoEmitLLVMIR, KairoEmitObj, KairoInject,
    TokenFiller,
}
import Codegen::Backend::IncludeEmitter::IncludedDecls
import Codegen::Backend::InterfacePCH::InterfacePCH
import Codegen::CodegenContext::{
    CodegenContext,
    CodegenPhase,
}
// Backend/ is the ONLY directory that imports emitters (see header).
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::InterfaceEmitter::InterfaceEmitter
import Codegen::EmitPlan::{
    EmitPlan,
    PlanEntry,
    PlanLease,
    PlanMode,
    PlanTier,
}
import Codegen::Sink::HashSink::HashSink
import Codegen::Sink::TokenSink::TokenSink
import Codegen::Sink::TokenStreamPrinter::TokenStreamPrinter
import Diagnostic::BufferedDiagSink::BufferedDiagSink
import Diagnostic::ClangDiagAdapter::ClangDiagAdapter
import Interop::Clang::ClangBackend::{
    ClangBackend,
    CodegenMounts,
}
import Interop::Clang::ClangLocMap::ClangLocMap
import Interop::Clang::CodegenPCH::CodegenPCH
import Interop::Clang::HeaderSet::HeaderSet
import Location::SourceManager::FileID
import Memory::ArenaAllocator::ArenaAllocator
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Support::TimeReport::{
    TimeRegion,
    time_bill_since,
    time_clock,
}

/// \class CodegenBackend
/// \brief One TU's codegen. Each run() compiles on a CompilerInstance of its
///        own -- a copy of the backend's invocation, the TU's VFS, the TU's
///        ClangDiagAdapter as the client -- so TUs run on several workers at
///        once (CodegenJob) and every clang diagnostic flows into the TU's
///        BufferedDiagSink with Kairo spans.
pub class CodegenBackend derives TokenFiller {
    priv var _be:        unsafe *ClangBackend
    priv var _ctx:       unsafe *ASTContext
    priv var _kfid:      FileID
    priv var _arena:     *ArenaAllocator
    priv var _ksize:     u32                                 = 0
    priv var _print:     u8                                  = 0 ///< bit 0: print-cg, bit 1: print-ir
    priv var _path:      string ///< for the printer header
    priv var _sets:      cxx::std::vector<unsafe *HeaderSet> ///< header sets this TU's graph requested, the implicit PCH's first
    priv var _merged:    unsafe *CodegenPCH                  = &null ///< all of _sets in one PCH; null or !ok -> per-set path
    priv var _iface:     unsafe *InterfacePCH                = &null ///< every TU's interface, chained on _merged; null or !ok -> the whole stream
    priv var _pre:       unsafe *EmitPlan                    = &null ///< this TU's Preamble plan, run ahead (InterfacePCH::plan_all), or null
    priv var _psym:      unsafe *PreprocessorSymbolTable ///< module_base segments -> namespace names
    priv var _instances: unsafe *InstantiationRegistry ///< tier 3 of the plan
    // The TU's own clang plumbing (set_clang): never shared with another TU.
    priv var _vfs:     llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>
    priv var _adapter: unsafe *ClangDiagAdapter
    priv var _locmap:  unsafe *ClangLocMap
    /// The incremental cache's record for this TU's object, as a C++
    /// string literal (ObjectCache::record_asm), or "": written as the
    /// stream's last item, so the object carries the key it was built under.
    priv var _record: string = ""

    fn CodegenBackend(self,
                      be:        unsafe *ClangBackend,
                      ctx:       unsafe *ASTContext,
                      kfid:      FileID,
                      arena:     *ArenaAllocator,
                      ksize:     u32,
                      psym:      unsafe *PreprocessorSymbolTable,
                      instances: unsafe *InstantiationRegistry) {
        self._be        = be
        self._ctx       = ctx
        self._kfid      = kfid
        self._arena     = arena
        self._ksize     = ksize
        self._psym      = psym
        self._instances = instances
    }

    fn set_print_cg(self, on: u8, path: string) {
        self._print = on
        self._path  = path
    }

    /// Header sets whose PCHs this TU's emission loads. Without a merged
    /// PCH the first becomes the implicit PCH and the rest are re-parsed as
    /// text, so the driver puts the biggest first.
    fn set_header_sets(self, sets: cxx::std::vector<unsafe *HeaderSet>) {
        self._sets = sets
    }

    /// The one PCH holding every set (HeaderSetCache::codegen_pch). When it
    /// built, it replaces the per-set path outright.
    fn set_codegen_pch(self, p: unsafe *CodegenPCH) {
        self._merged = p
    }

    /// The build's interface PCH (InterfacePCH). When it built, this TU
    /// loads it instead of the header PCH (it chains on that one) and
    /// writes only what the PCH does not hold.
    fn set_interface_pch(self, p: unsafe *InterfacePCH) {
        self._iface = p
    }

    /// This TU's plan, run ahead of the fan-out, or null to plan in fill().
    fn set_plan(self, p: unsafe *EmitPlan) {
        self._pre = p
    }

    /// The object's cache record (ObjectCache::record_asm), or "".
    fn set_record(self, const r: string) {
        self._record = r
    }

    /// The TU's VFS (ClangBackend::codegen_vfs), diagnostic client and fid
    /// map: its own, never another TU's.
    fn set_clang(self,
                 vfs:     llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>,
                 adapter: unsafe *ClangDiagAdapter,
                 locmap:  unsafe *ClangLocMap) {
        self._vfs     = vfs
        self._adapter = adapter
        self._locmap  = locmap
    }

    /// M2 filler: emitter dispatch over the TU's top-level items.
    ///
    /// For m1_hello.k the output is BYTE-IDENTICAL to the hand-written
    /// stream's: run --print-cg against both and diff.
    override fn fill(self, sink: unsafe *TokenSink) -> bool {
        // Runs inside ExecuteAction (BeginSourceFileAction), so this lands
        // under the driver's Clang region beside what clang itself spends.
        var _t = TimeRegion("IRGeneration")

        var unsafe *tu = self._ctx->tu
        if tu == &null {
            return false
        }

        if tu->program == &null {
            return false
        }

        // The plan the interface PCH's stream ran (InterfacePCH::plan_all),
        // when there is one: bound to this TU's sink for the fill, and left
        // as it was found after, since a TU fills once per kind and again
        // without the PCH when clang had something to say (CodegenJob::run).
        var cg_own = CodegenContext(
            self._ctx,
            sink,
            self._psym,
            self._instances,
        )

        var        plan_own = EmitPlan(unsafe &cg_own, PlanMode::Preamble)
        var unsafe *cg      = unsafe &cg_own
        var unsafe *plan    = unsafe &plan_own
        var        lease    = PlanLease(self._pre, sink, self._ctx)
        if self._pre != &null {
            cg   = self._pre->cg()
            plan = self._pre
        } else {
            plan_own.require_shared()
            plan_own.run()
            cg_own.advance_phase(CodegenPhase::Planned)
        }

        // Under the interface PCH the plan is pruned by its keys, as a kcc
        // include prunes what an earlier one wrote: the PCH's stream ran this
        // very plan, so what is left is tier 3 (this TU's `extern template`s
        // and homes; the PCH writes none) and, should the two ever disagree,
        // a stray entry -- counted for -v, and harmless where it is new to
        // clang.
        var unsafe *pch = if (self._iface != &null
                              && self._iface->ok) => (unsafe &self._iface->seen)
                          else => (&null as unsafe *IncludedDecls)
        var strays: usize = 0
        if pch != &null {
            var kept = cxx::std::vector<PlanEntry>()
            for var i: usize = 0; i < plan->entries.size(); ++i {
                var unsafe *e = unsafe &plan->entries[i]
                if e->tier != PlanTier::Instantiations {
                    if e->eval_item != &null && pch->has_body(e->eval_item) {
                        continue
                    }

                    if pch->has(plan, e) {
                        continue
                    }

                    strays += 1
                }

                kept.push_back(plan->entries[i])
            }

            plan->entries = kept
        }

        // Every declaration, own and foreign, before any body: the item
        // loop below then only ever defines what is already declared. The
        // body emitter is shared: the interface defines the early items
        // through it (EmitPlan::early), and it skips them after.
        var ir = EmitIR(cg)
        var ie = InterfaceEmitter(cg, plan)
        ie.ir = unsafe &ir
        if pch != &null {
            pch->give(unsafe &ie)
            ir.pch_bodies = pch->body_set()
        }

        ie.run()

        // Bodies, driven by the plan: the same order the interface used, so
        // a definition always follows the declaration it matches.
        ir.emit_tu(plan)

        // Home instantiation definitions last: they only instantiate members
        // whose definitions precede them.
        ie.emit_home_instantiations()

        // The cache record, after everything the key hashed (hash_stream
        // writes the same stream without it): one top-level asm whose
        // section the linker drops. Unanchored: it has no Kairo bytes.
        if !self._record.empty() {
            var fid = self._kfid
            var at = if (self._ctx->sm->get_file_size(fid) == 0) => (self._ctx->sm->get_range(
                         fid,
                         0,
                         0,
                     ))
                     else => self._ctx->sm->get_range(fid, 0, 1)
            var lit = self._record
            sink->unanchored(true)
            sink->keyword(at, clang::tok::kw_asm)
            sink->punct(at, clang::tok::l_paren)
            sink->create_str(at, &lit)
            sink->punct(at, clang::tok::r_paren)
            sink->punct(at, clang::tok::semi)
            sink->unanchored(false)
        }

        sink->eof()
        var n_entries = plan->entries.size()
        if self._pre == &null {
            cg->advance_phase(CodegenPhase::Emitted)
        }

        if pch != &null {
            kairo::Logger::info(
                kairo::Logger::Stage::Driver,
                f"codegen tokens: {sink->token_count()} plan entries: {n_entries} in {self._path} (interface PCH; {strays} entries not in it)",
            )
        } else {
            kairo::Logger::info(
                kairo::Logger::Stage::Driver,
                f"codegen tokens: {sink->token_count()} plan entries: {n_entries} in {self._path}",
            )
        }

        if self._print != 0 {
            // we deicide if we prnt cg or ir or both
            if (self._print & 1) != 0 {
                TokenStreamPrinter::print(sink, self._path)
            }

            if (self._print & 2) != 0 {
                TokenStreamPrinter::print_tokens(sink, self._path)
            }
        }

        return true
    }

    /// One ExecuteAction for \p kind on a fresh CompilerInstance. Fresh per
    /// run, not one per worker: under the merged PCH a TU's own setup is
    /// about 0.2 ms (measured), and nothing then carries
    /// from one TU to the next -- no Reset() of the diagnostic counters, no
    /// -W mappings to reinstall, no PCH or Includes to restore.
    fn run(self, out_obj: string, kind: EmitKind = EmitKind::Obj) -> bool {
        if !self._be->ready() {
            kairo::std::ice_fail("CodegenBackend::run before backend ready")
        }

        if self._adapter == &null || self._locmap == &null {
            kairo::std::ice_fail("CodegenBackend::run before set_clang")
        }

        // Up to ExecuteAction this is the TU's setup, after the action its
        // teardown: rows of their own under --time-passes, or the trace shows
        // them as gaps between TUs (time_clock() is 0 with timing off).
        var t_setup = time_clock()

        // A COPY of the backend's invocation, as for every header set and
        // the merged PCH: the PCH reader rejects one whose options differ.
        var inv = cxx::std::make_shared<clang::CompilerInvocation>(
            *self._be->invocation(),
        )

        var *cfe = &inv->getFrontendOpts()
        var empty = llvm::MemoryBuffer::getMemBuffer(
            llvm::StringRef(r"", 0),
            kairo::sref(r"<injected>"),
            false,
        )

        cfe->Inputs.clear()
        cfe->Inputs.push_back(
            clang::FrontendInputFile(
                empty->getMemBufferRef(),
                clang::InputKind(clang::Language::CXX),
            ),
        )

        match kind {
            case EmitKind::Asm {
                cfe->ProgramAction = clang::frontend::EmitAssembly
            } case EmitKind::LLVMIR {
                cfe->ProgramAction = clang::frontend::EmitLLVM
            } case EmitKind::LLVMBC {
                cfe->ProgramAction = clang::frontend::EmitBC
            } default {
                cfe->ProgramAction = clang::frontend::EmitObj
            }
        }

        cfe->OutputFile = kairo::std::to_std_string(out_obj)
        // The instance dies with this run: free its AST rather than leak
        // one per TU into a process that compiles many.
        cfe->DisableFree = (false as u32)
        // Three words clang's own driver puts on every release cc1 line and
        // this invocation never had (perf pass). None
        // changes what an object holds:
        //  - no IR verifier: it re-walks every function before and after
        //    the optimizer, checking clang's codegen, not Kairo's;
        //  - the TU's clang AST is freed once IR generation is done, so the
        //    optimizer and machine code of 24 TUs at once do not run on
        //    top of 24 live ASTs (clang keeps the mangled-name source
        //    locations its backend diagnostics need, CodeGenAction.cpp);
        //  - local IR value names dropped, for an object only: no symbol is
        //    named after one, but .ll text and the `# %bb` comments in .s
        //    are, and the tests read both.
        var *cgo = &inv->getCodeGenOpts()
        cgo->VerifyModule          = (false as u32)
        cgo->ClearASTBeforeBackend = (true as u32)
        if kind == EmitKind::Obj {
            cgo->DiscardValueNames = (true as u32)
        }

        // Phase B: the headers were parsed once already (HeaderSet). Each TU
        // loads them as ONE implicit PCH, clang's limit: the merged PCH of
        // every set when it built (CodegenPCH), so nothing is re-parsed.
        //
        // Fallback, one PCH per set: the FIRST set loads as the implicit
        // PCH; every other set's headers are `#include`d textually through
        // its wrapper, each spelled so it resolves to what phase A found
        // (HeaderSet::replay_include). Correct -- same headers, same order
        // within each set -- just re-parsed.
        //
        // Every byte named here was mounted before the fan-out
        // (CodegenRun::mount); a worker only reads its TU's VFS.
        var *ppo = &inv->getPreprocessorOpts()
        if self._iface != &null && self._iface->ok {
            // The chain names the header PCH below it, mounted beside it.
            if !self._iface->mounted {
                kairo::std::ice_fail(
                    "CodegenBackend::run: the interface PCH was not mounted before the fan-out",
                )
            }

            ppo->Includes.clear()
            ppo->ImplicitPCHInclude = kairo::std::to_std_string(
                self._iface->path,
            )

            // Built by this process from these files and this invocation a
            // moment ago: re-checking each of its ~2,000 input files (and
            // the header PCH's below it) per TU proves nothing.
            ppo->DisablePCHOrModuleValidation = clang::DisableValidationForModuleKind::PCH
        } else if self._merged != &null && self._merged->ok {
            if !self._merged->mounted {
                kairo::std::ice_fail(
                    "CodegenBackend::run: the merged PCH was not mounted before the fan-out",
                )
            }

            ppo->Includes.clear()
            ppo->ImplicitPCHInclude = kairo::std::to_std_string(
                self._merged->path,
            )
        } else if self._sets.size() > 0 {
            ppo->Includes.clear()
            var textual_from: usize = 0
            if self._sets[0]->mounted {
                ppo->ImplicitPCHInclude = kairo::std::to_std_string(
                    self._sets[0]->pch_path(),
                )

                textual_from = 1
            }

            // Every textual set goes through one mounted wrapper: the same
            // direct includes by the same resolved paths, inside the FP
            // pragmas that give headers C++'s semantics rather than Kairo's
            // (ClangBackend::header_fp_pragmas, as phase A's buffer has
            // them), and with the C ones extern "C" as phase A parsed them.
            // Preprocessor `Includes` cannot wrap a path themselves.
            for var i: usize = textual_from; i < self._sets.size(); ++i {
                ppo->Includes.push_back(
                    kairo::std::to_std_string(self._sets[i]->wrap_path()),
                )
            }
        }

        // Destroyed explicitly below, not in a `finally`, so its teardown is
        // timed; always before the adapter: the engine borrows it.
        var unsafe *ci = kairo::std::create<clang::CompilerInstance>(inv)
        ci->setVirtualFileSystem(self._vfs)
        // The member form applies the invocation's -W policy itself
        // (ProcessWarningOptions), with fresh counters: pass/fail is per run.
        ci->createDiagnostics(self._adapter, false)
        if !ci->hasDiagnostics() {
            kairo::std::destroy(ci)
            return false
        }

        // Not clang's "N errors generated." on stderr: the TU's diagnostics
        // are Kairo's to render, from its sink and in TU order, and that
        // line, written from a worker, would interleave with another's.
        ci->setVerboseOutputStream(&llvm::nulls())
        // ExecuteAction builds the target (createTarget) and, finding none,
        // the FileManager and SourceManager.

        // Clang's phases (parse/sema, IRGen, optimizer, machine code) are
        // timed by clang itself; this folds them into --time-passes under the
        // caller's open region. A no-op unless timing is on.
        //
        // One action class per kind: clang picks the backend output by which
        // CodeGenAction subclass runs (CodegenAction.k).
        //
        // The harvest runs in each arm, before the action is destroyed: the
        // action owns the LLVM module and context, whose destruction is the
        // bulk of the teardown billed below.
        var ok              = false
        var t_teardown: u64 = 0
        time_bill_since("TUSetup", t_setup)
        var clang_time = kairo::ktime_clang_begin()
        match kind {
            case EmitKind::Asm {
                var act = KairoEmitAsm()
                self._wire(&act.inj)
                ok = ci->ExecuteAction(&act)
                kairo::ktime_clang_end(clang_time)
                t_teardown = time_clock()
            } case EmitKind::LLVMIR {
                var act = KairoEmitLLVMIR()
                self._wire(&act.inj)
                ok = ci->ExecuteAction(&act)
                kairo::ktime_clang_end(clang_time)
                t_teardown = time_clock()
            } case EmitKind::LLVMBC {
                var act = KairoEmitLLVMBC()
                self._wire(&act.inj)
                ok = ci->ExecuteAction(&act)
                kairo::ktime_clang_end(clang_time)
                t_teardown = time_clock()
            } default {
                var act = KairoEmitObj()
                self._wire(&act.inj)
                ok = ci->ExecuteAction(&act)
                kairo::ktime_clang_end(clang_time)
                t_teardown = time_clock()
            }
        }

        ok = ok && ci->getDiagnostics().getNumErrors() == 0
        kairo::std::destroy(ci)
        time_bill_since("TUTeardown", t_teardown)
        return ok
    }

    priv fn _wire(self, inj: *KairoInject) {
        inj->filler = &self
        inj->locmap = self._locmap
        inj->kfid   = self._kfid
        inj->ksize  = self._ksize
        inj->arena  = self._arena
    }
}

/// ThreadPool group of the codegen fan-out. 10 is HEADER_BUILD_GROUP, 12
/// CODEGEN_PCH_GROUP.
pub
const CODEGEN_GROUP: u8 = 11

/// \class CodegenRun
/// \brief What every TU of one _codegen shares, read-only during the
///        fan-out: the backend, the plan's tables, the merged PCH and the
///        bytes each TU's VFS mounts.
pub class CodegenRun {
    pub var be:        unsafe *ClangBackend
    pub var psym:      unsafe *PreprocessorSymbolTable
    pub var instances: unsafe *InstantiationRegistry
    pub var merged:    unsafe *CodegenPCH              = &null
    pub var mounts:    CodegenMounts

    /// Collects every byte the TUs' VFSs will hold, and marks what it found
    /// mounted (the flags CodegenBackend::run checks). Driver thread, before
    /// the fan-out: after it nothing is mounted or flagged, so the workers
    /// only ever read.
    pub fn mount(self, @inout sets: cxx::std::vector<unsafe *HeaderSet>) {
        if self.merged != &null && self.merged->ok {
            self.mounts.add_pch(
                self.merged->path,
                unsafe &self.merged->pch->Data,
            )

            self.merged->mounted = true
            return
        }

        var fp_open  = cxx::std::vector<string>()
        var fp_close = cxx::std::vector<string>()
        self.be->header_fp_pragmas(unsafe &fp_open, unsafe &fp_close)
        for var i: usize = 0; i < sets.size(); ++i {
            var unsafe *s = sets[i]
            if s->ok && s->pch->Data.size() > 0 { // a set writes no PCH of its own today.
                self.mounts.add_pch(s->pch_path(), unsafe &s->pch->Data)
                s->mounted = true
            }

            var w = ""
            for *l in fp_open {
                w += *l
                w += "\n"
            }

            w += s->replay_lines()
            for *l in fp_close {
                w += *l
                w += "\n"
            }

            self.mounts.add_text(s->wrap_path(), w)
        }
    }
}

/// \class CodegenJob
/// \brief One Kairo TU's codegen: everything the driver decided for it, and
///        what came back. run() is the whole per-TU compile and runs on any
///        thread; the driver reads `ok`, `written` and drains `sink` after the
///        join, in TU order, so output and diagnostics do not depend on which
///        worker finished first.
pub class CodegenJob {
    pub var fid:   FileID
    pub var ctx:   unsafe *ASTContext
    pub var ksize: u32                                 = 0
    pub var print: u8                                  = 0 ///< CodegenBackend::set_print_cg
    pub var path:  string ///< the TU's file name, for the printer
    pub var sets:  cxx::std::vector<unsafe *HeaderSet> ///< the implicit PCH's first (per-set fallback)
    /// The interface PCH of this TU's flavour (CXXSpell::interface_flavour),
    /// or null: the whole stream, as before it.
    pub var iface: unsafe *InterfacePCH = &null
    /// The TU's Preamble plan and its context, run on the pool before the
    /// interface PCH's stream (InterfacePCH::plan_all), which runs it first;
    /// the TU's fill() reuses it. Owned; null when no PCH is built.
    pub var pcg:     unsafe *CodegenContext     = &null
    pub var plan:    unsafe *EmitPlan           = &null
    pub var kinds:   cxx::std::vector<EmitKind>
    pub var outs:    cxx::std::vector<string> ///< one per kind
    pub var written: cxx::std::vector<string> ///< the outs that were written, in kind order
    pub var ok:      bool                       = false
    /// The TU's clang diagnostics, in Kairo terms. Drained by the driver.
    pub var sink: BufferedDiagSink
    /// The incremental cache (Driver/ObjectCache.k): the stream's hash
    /// (hash_stream), the object key, the record the object is to carry
    /// (empty: none), and whether the store already held the object, so
    /// the fan-out skips this TU.
    pub var stream: string = ""
    /// The files the stream's anchored tokens came from (HashSink::files):
    /// the modules and headers the TU draws on, for its key's headers.
    pub var stream_files: cxx::std::vector<u32>
    pub var key:          string                = ""
    pub var record:       string                = ""
    pub var reused:       bool                  = false
    /// Whether this TU compiles under an interface PCH when it compiles:
    /// what clang loads differs, so the key says which.
    pub var iface_on: bool = false
    /// Whether the compile that wrote `written` did load the interface PCH.
    /// iface_on is decided before the PCH is built: when its build fails the
    /// driver leaves `iface` null, and a TU clang had something to say about
    /// compiles again without it (run). Either way the object is not the one
    /// a key made with iface_on describes, and is not stored under it.
    pub var iface_used: bool = false
    /// How many of ctx->diag_sink's diagnostics predate hash_stream: a
    /// TU that compiles drops what the hash's fill reported, since its own
    /// fill reports the same again.
    pub var diag_mark: usize = 0

    pub fn run(self, r: *CodegenRun) {
        // The Kairo side of the TU's setup; CodegenBackend::run bills clang's.
        var        t_setup = time_clock()
        var unsafe *be     = r->be
        // Per TU, as the CompilerInstance is: a ClangLocMap binds the one
        // SourceManager its rebind() saw, and the adapter asks it per
        // diagnostic.
        var unsafe *locmap = kairo::std::create<ClangLocMap>(be->ksm())
        var unsafe *a      = kairo::std::create<ClangDiagAdapter>()
        a->sink   = unsafe &self.sink
        a->ksm    = be->ksm()
        a->kfid   = self.fid
        a->locmap = locmap

        var cg = CodegenBackend(
            be,
            self.ctx,
            self.fid,
            &self.ctx->codegen_alloc,
            self.ksize,
            r->psym,
            r->instances,
        )

        cg.set_print_cg(self.print, self.path)
        cg.set_record(self.record)
        cg.set_header_sets(self.sets)
        cg.set_codegen_pch(r->merged)
        cg.set_interface_pch(self.iface)
        cg.set_plan(self.plan)
        cg.set_clang(be->codegen_vfs(&r->mounts), a, locmap)
        time_bill_since("TUSetup", t_setup)

        self._run_kinds(&cg, a, be)
        self.iface_used = self.iface != &null && self.iface->ok
        // Clang said something about this TU under the interface PCH: it is
        // said again from the whole stream, so a diagnostic names the bytes
        // and the order it always did. The PCH moves where a declaration's
        // tokens came from (the first TU of the build that wrote it) and
        // which TU instantiates a template first; a clean TU is unaffected,
        // and a TU that is not clean is rare enough to pay for twice.
        if self.iface != &null && self.sink.size() > 0 {
            self.sink.discard()
            self.written.clear()
            cg.set_interface_pch(&null)
            self._run_kinds(&cg, a, be)
            self.iface_used = false
        }

        kairo::std::destroy(a)
        kairo::std::destroy(locmap)
    }

    fn op finally(self) {
        if self.plan != &null {
            kairo::std::destroy(self.plan)
        }

        if self.pcg != &null {
            kairo::std::destroy(self.pcg)
        }
    }

    /// \brief the incremental cache's hash of this TU's stream: the fill
    ///        CodegenBackend::fill runs, the whole stream (no interface PCH
    ///        pruning, no record), into a HashSink instead of clang.
    ///
    /// \details Any thread, as the fan-out's fills are: it reads what Sema
    ///          finished and prepare_shared filled, and writes only its own
    ///          context and this TU's diag_sink. What that fill reports is
    ///          the TU's codegen-time diagnostics: kept for a TU the cache
    ///          serves (they are its replay), dropped for one that compiles
    ///          (diag_mark).
    pub fn hash_stream(self, r: *CodegenRun, with_locs: bool) {
        self.diag_mark = self.ctx->diag_sink.size()
        var hs   = HashSink(self.ctx->sm, self.ctx->tcm, with_locs)
        var cg   = CodegenContext(self.ctx, unsafe &hs, r->psym, r->instances)
        var plan = EmitPlan(unsafe &cg, PlanMode::Preamble)
        plan.require_shared()
        plan.run()
        cg.advance_phase(CodegenPhase::Planned)
        var ir = EmitIR(unsafe &cg)
        var ie = InterfaceEmitter(unsafe &cg, unsafe &plan)
        ie.ir = unsafe &ir
        ie.run()
        ir.emit_tu(unsafe &plan)
        ie.emit_home_instantiations()
        cg.advance_phase(CodegenPhase::Emitted)
        self.stream       = hs.digest()
        self.stream_files = hs.files()
    }

    /// The Preamble plan of this TU, on its own context with no sink yet.
    /// Any thread: plans read what Sema finished and prepare_shared filled,
    /// as the fan-out's do.
    pub fn make_plan(self, r: *CodegenRun) {
        self.pcg = kairo::std::create<CodegenContext>(
            self.ctx,
            &null,
            r->psym,
            r->instances,
        )

        self.plan = kairo::std::create<EmitPlan>(self.pcg, PlanMode::Preamble)
        self.plan->require_shared()
        self.plan->run()
        self.pcg->advance_phase(CodegenPhase::Planned)
    }

    /// Every kind in one stream each, `ok` and `written` set from them.
    priv fn _run_kinds(self,
                       cg: *CodegenBackend,
                       a:  unsafe *ClangDiagAdapter,
                       be: unsafe *ClangBackend) {
        a->BeginSourceFile(be->invocation()->getLangOpts(), &null)
        self.ok = true
        for var k: usize = 0; k < self.kinds.size(); ++k {
            // Every run re-fills the same stream; print it once.
            if k > 0 {
                cg->set_print_cg(0, self.path)
            }

            if !cg->run(self.outs[k], self.kinds[k]) {
                self.ok = false
                break
            }

            self.written.push_back(self.outs[k])
        }

        // Flush any builder still open BEFORE the sink is read or drained,
        // or the last diagnostic is silently dropped.
        a->EndSourceFile()
        a->finish()
    }
}

/// \class CodegenQueue
/// \brief The TUs of one fan-out, handed out one at a time to whichever
///        worker asks next (work()). Biggest first: the user's TU is often
///        several times the rest, and started last it would be the whole
///        tail. Which worker ran a TU never shows: each writes only its own
///        CodegenJob, and the driver reads them in TU order after the join.
pub class CodegenQueue {
    pub var  run:    *CodegenRun
    priv var _jobs:  cxx::std::vector<unsafe *CodegenJob>
    priv var _order: cxx::std::vector<usize>
    priv var _next: kairo::std::Atomic<usize> = kairo::std::Atomic<usize>(0)

    pub fn add(self, j: unsafe *CodegenJob) {
        self._jobs.push_back(j)
    }

    /// By Kairo byte size, descending; ties in TU order. A proxy for the
    /// TU's cost that needs no planning: emitted C++ grows with the source.
    pub fn schedule(self) {
        self._order.clear()
        for var i: usize = 0; i < self._jobs.size(); ++i {
            var at = self._order.size()
            while at > 0 && self._jobs[self._order[at - 1]]->ksize < self._jobs[i]->ksize {
                at -= 1
            }

            self._order.insert(self._order.cbegin() + (at as isize), i)
        }
    }

    /// One worker's loop: take the next TU until none is left.
    pub fn work(self) {
        while true {
            var i = self._next.fetch_add(1, kairo::std::MemoryOrder::relaxed)
            if i >= self._order.size() {
                return
            }

            var unsafe *job = self._jobs[self._order[(i)]]
            job->run(self.run)
            // Phase 2 is codegen (ProgressMeter::Phase); Codegen cannot import Driver/.
            kairo::ProgressMeter::tick(2, job->path.c_str())
        }
    }
}
