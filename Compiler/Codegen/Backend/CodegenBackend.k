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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Frontend/CompilerInstance.h";
ffi "c++" import "clang/Frontend/FrontendActions.h";
ffi "c++" import "clang/Frontend/FrontendOptions.h";
ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "clang/Lex/PreprocessorOptions.h";
ffi "c++" import "llvm/Support/MemoryBuffer.h";
ffi "c++" import "llvm/Support/VirtualFileSystem.h";
ffi "c++" import "llvm/Support/raw_ostream.h";
ffi "c++" import "Native/KTimeClang.hh";

import Interop::Clang::ClangBackend::*;
import Interop::Clang::HeaderSet::*;
import Interop::Clang::ClangLocMap::*;
import Diagnostic::BufferedDiagSink::*;
import Diagnostic::ClangDiagAdapter::*;
import Location::SourceLocation::*;
import Codegen::Sink::EmitSink::*;
import Codegen::Sink::TokenSink::*;
import Codegen::EmitPlan::*;
import Codegen::Backend::CodegenAction::*;
import Codegen::CodegenContext::*;
import Codegen::Sink::TokenStreamPrinter::*;

// Backend/ is the ONLY directory that imports emitters (see header).
import Codegen::Emit::EmitIR::*;
import Codegen::Emit::InterfaceEmitter::*;

import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::InstantiationRegistry::*;
import AST::Node::Program::*;
import Preprocessor::PreprocessorSymbolTable::*;
import Support::TimeReport::*;

/// \class CodegenBackend
/// \brief One TU's codegen. Each run() compiles on a CompilerInstance of its
///        own -- a copy of the backend's invocation, the TU's VFS, the TU's
///        ClangDiagAdapter as the client -- so TUs run on several workers at
///        once (CodegenJob) and every clang diagnostic flows into the TU's
///        BufferedDiagSink with Kairo spans.
class CodegenBackend derives TokenFiller {
    priv var _be:    obs::<ClangBackend>;
    priv var _ctx:   obs::<ASTContext>;
    priv var _kfid:  FileID;
    priv var _arena: obs::<ArenaAllocator>;
    priv var _ksize: u32 = 0;
    priv var _print: u8 = 0;   ///< bit 0: print-cg, bit 1: print-ir
    priv var _path:  string;         ///< for the printer header
    priv var _sets:  vec::<*HeaderSet>;  ///< header sets this TU's graph requested, the implicit PCH's first
    priv var _merged: *CodegenPCH = &null; ///< all of _sets in one PCH; null or !ok -> per-set path
    priv var _psym:      obs::<PreprocessorSymbolTable>;  ///< module_base segments -> namespace names
    priv var _instances: obs::<InstantiationRegistry>;    ///< tier 3 of the plan
    // The TU's own clang plumbing (set_clang): never shared with another TU.
    priv var _vfs:     llvm::IntrusiveRefCntPtr::<llvm::vfs::FileSystem>;
    priv var _adapter: obs::<ClangDiagAdapter>;
    priv var _locmap:  obs::<ClangLocMap>;

    fn CodegenBackend(self, be: *ClangBackend, ctx: *ASTContext, kfid: FileID,
                      arena: *ArenaAllocator, ksize: u32,
                      psym: *PreprocessorSymbolTable, instances: *InstantiationRegistry) {
        self._be        = be;
        self._ctx       = ctx;
        self._kfid      = kfid;
        self._arena     = arena;
        self._ksize     = ksize;
        self._psym      = psym;
        self._instances = instances;
    }

    fn set_print_cg(self, on: u8, path: string) {
        self._print = on;
        self._path  = path;
    }

    /// Header sets whose PCHs this TU's emission loads. Without a merged
    /// PCH the first becomes the implicit PCH and the rest are re-parsed as
    /// text, so the driver puts the biggest first.
    fn set_header_sets(self, sets: vec::<*HeaderSet>) { self._sets = sets; }

    /// The one PCH holding every set (HeaderSetCache::codegen_pch). When it
    /// built, it replaces the per-set path outright.
    fn set_codegen_pch(self, p: *CodegenPCH) { self._merged = p; }

    /// The TU's VFS (ClangBackend::codegen_vfs), diagnostic client and fid
    /// map: its own, never another TU's.
    fn set_clang(self, vfs: llvm::IntrusiveRefCntPtr::<llvm::vfs::FileSystem>,
                 adapter: *ClangDiagAdapter, locmap: *ClangLocMap) {
        self._vfs     = vfs;
        self._adapter = adapter;
        self._locmap  = locmap;
    }

    /// M2 filler: emitter dispatch over the TU's top-level items.
    ///
    /// This replaces M1's hand-written stream. The regression test is that
    /// for m1_hello.k the two are BYTE-IDENTICAL   run --print-cg against
    /// both and diff.
    override fn fill(self, sink: *TokenSink) -> bool {
        // Runs inside ExecuteAction (BeginSourceFileAction), so this lands
        // under the driver's Clang region beside what clang itself spends.
        var _t = TimeRegion("IRGeneration");

        var tu = reinterpret_cast::<*TranslationUnit>(self._ctx->tu);
        if tu == &null { return false; }
        if tu->program == &null { return false; }

        var cg = CodegenContext(self._ctx, sink, self._psym, self._instances);
        var plan = EmitPlan(&cg, PlanMode::Preamble);
        plan.run();
        cg.advance_phase(CodegenPhase::Planned);

        // Every declaration, own and foreign, before any body: the item
        // loop below then only ever defines what is already declared. The
        // body emitter is shared: the interface defines the early items
        // through it (EmitPlan::early), and it skips them after.
        var ir = EmitIR(&cg);
        var ie = InterfaceEmitter(&cg, &plan);
        ie.ir = &ir;
        ie.run();

        // Bodies, driven by the plan: the same order the interface used, so
        // a definition always follows the declaration it matches.
        ir.emit_tu(&plan);

        // Home instantiation definitions last: they only instantiate members
        // whose definitions precede them.
        ie.emit_home_instantiations();

        sink->eof();
        cg.advance_phase(CodegenPhase::Emitted);
        Logger::info(Logger::Stage::Driver, f"codegen tokens: {sink->token_count()} plan entries: {plan.entries.size()} in {self._path}");

        if self._print != 0 {
            // we deicide if we prnt cg or ir or both
            if (self._print & 1) != 0 {
                TokenStreamPrinter::print(sink, self._path);
            }
            if (self._print & 2) != 0 {
                TokenStreamPrinter::print_tokens(sink, self._path);
            }
        }

        return true;
    }

    /// One ExecuteAction for \p kind on a fresh CompilerInstance. Fresh per
    /// run, not one per worker: under the merged PCH a TU's own setup is
    /// about 0.2 ms (private/spikes/codegen-par), and nothing then carries
    /// from one TU to the next -- no Reset() of the diagnostic counters, no
    /// -W mappings to reinstall, no PCH or Includes to restore.
    fn run(self, out_obj: string, kind: EmitKind = EmitKind::Obj) -> bool {
        ICE_IF(!self._be->ready(), "CodegenBackend::run before backend ready");
        ICE_IF((self._adapter == &null) || (self._locmap == &null), "CodegenBackend::run before set_clang");

        // A COPY of the backend's invocation, as for every header set and
        // the merged PCH: the PCH reader rejects one whose options differ.
        var inv = libcxx::make_shared::<clang::CompilerInvocation>(*(self._be->invocation()));
        var cfe = &(inv->getFrontendOpts());
        var empty = llvm::MemoryBuffer::getMemBuffer(
            llvm::StringRef(r"", 0), r"<injected>", false);
        cfe->Inputs.clear();
        cfe->Inputs.push_back(clang::FrontendInputFile(
            empty->getMemBufferRef(), clang::InputKind(clang::Language::CXX)));
        switch kind {
            case EmitKind::Asm    { cfe->ProgramAction = clang::frontend::EmitAssembly; }
            case EmitKind::LLVMIR { cfe->ProgramAction = clang::frontend::EmitLLVM;     }
            case EmitKind::LLVMBC { cfe->ProgramAction = clang::frontend::EmitBC;       }
            default               { cfe->ProgramAction = clang::frontend::EmitObj;      }
        }
        cfe->OutputFile  = out_obj.std_string();
        // The instance dies with this run: free its AST rather than leak
        // one per TU into a process that compiles many.
        cfe->DisableFree = false;

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
        var ppo = &(inv->getPreprocessorOpts());
        if (self._merged != &null) && self._merged->ok {
            ICE_IF(!self._merged->mounted, "CodegenBackend::run: the merged PCH was not mounted before the fan-out");
            ppo->Includes.clear();
            ppo->ImplicitPCHInclude = self._merged->path.std_string();
        } else if self._sets.size() > 0 {
            ppo->Includes.clear();
            var textual_from: usize = 0;
            if self._sets[0]->mounted {
                ppo->ImplicitPCHInclude = self._sets[0]->pch_path().std_string();
                textual_from = 1;
            }
            // Every textual set goes through one mounted wrapper: the same
            // direct includes by the same resolved paths, inside the FP
            // pragmas that give headers C++'s semantics rather than Kairo's
            // (ClangBackend::header_fp_pragmas, as phase A's buffer has
            // them), and with the C ones extern "C" as phase A parsed them.
            // Preprocessor `Includes` cannot wrap a path themselves.
            for var i: usize = textual_from; i < self._sets.size(); ++i {
                ppo->Includes.push_back(self._sets[i]->wrap_path().std_string());
            }
        }

        var ci = std::create::<clang::CompilerInstance>(inv);
        finally { std::destroy(ci); }   // before the adapter: the engine borrows it.
        ci->setVirtualFileSystem(self._vfs);
        // The member form applies the invocation's -W policy itself
        // (ProcessWarningOptions), with fresh counters: pass/fail is per run.
        ci->createDiagnostics(self._adapter, false);
        if !ci->hasDiagnostics() { return false; }
        // Not clang's "N errors generated." on stderr: the TU's diagnostics
        // are Kairo's to render, from its sink and in TU order, and that
        // line, written from a worker, would interleave with another's.
        ci->setVerboseOutputStream(llvm::nulls());
        // ExecuteAction builds the target (createTarget) and, finding none,
        // the FileManager and SourceManager.

        // Clang's phases (parse/sema, IRGen, optimizer, machine code) are
        // timed by clang itself; this folds them into --time-passes under the
        // caller's open region. A no-op unless timing is on.
        //
        // One action class per kind: clang picks the backend output by which
        // CodeGenAction subclass runs (CodegenAction.k).
        var ok = false;
        var clang_time = kairo::ktime_clang_begin();
        switch kind {
            case EmitKind::Asm {
                var act = KairoEmitAsm();
                self._wire(&(act.inj));
                ok = ci->ExecuteAction(act);
            }
            case EmitKind::LLVMIR {
                var act = KairoEmitLLVMIR();
                self._wire(&(act.inj));
                ok = ci->ExecuteAction(act);
            }
            case EmitKind::LLVMBC {
                var act = KairoEmitLLVMBC();
                self._wire(&(act.inj));
                ok = ci->ExecuteAction(act);
            }
            default {
                var act = KairoEmitObj();
                self._wire(&(act.inj));
                ok = ci->ExecuteAction(act);
            }
        }
        kairo::ktime_clang_end(clang_time);
        return ok && (ci->getDiagnostics().getNumErrors() == 0);
    }

    priv fn _wire(self, inj: *KairoInject) {
        inj->filler  = &self;
        inj->locmap  = self._locmap;
        inj->kfid    = self._kfid;
        inj->ksize   = self._ksize;
        inj->arena   = self._arena;
    }
}

/// ThreadPool group of the codegen fan-out. 10 is HEADER_BUILD_GROUP, 12
/// CODEGEN_PCH_GROUP.
eval fn CODEGEN_GROUP() -> u8 { return 11; }

/// \class CodegenRun
/// \brief What every TU of one _codegen shares, read-only during the
///        fan-out: the backend, the plan's tables, the merged PCH and the
///        bytes each TU's VFS mounts.
class CodegenRun {
    pub var be:        obs::<ClangBackend>;
    pub var psym:      obs::<PreprocessorSymbolTable>;
    pub var instances: obs::<InstantiationRegistry>;
    pub var merged:    *CodegenPCH = &null;
    pub var mounts:    CodegenMounts;

    /// Collects every byte the TUs' VFSs will hold, and marks what it found
    /// mounted (the flags CodegenBackend::run checks). Driver thread, before
    /// the fan-out: after it nothing is mounted or flagged, so the workers
    /// only ever read.
    fn mount(self, sets: ref!(vec::<*HeaderSet>)) {
        if (self.merged != &null) && self.merged->ok {
            self.mounts.add_pch(self.merged->path, &(self.merged->pch->Data));
            self.merged->mounted = true;
            return;
        }
        var fp_open  = vec::<string>();
        var fp_close = vec::<string>();
        self.be->header_fp_pragmas(&fp_open, &fp_close);
        for var i: usize = 0; i < sets.size(); ++i {
            var s = sets[i];
            if s->ok {
                self.mounts.add_pch(s->pch_path(), &(s->pch->Data));
                s->mounted = true;
            }
            var w = "";
            for l: string in fp_open { w += l; w += "\n"; }
            w += s->replay_lines();
            for l: string in fp_close { w += l; w += "\n"; }
            self.mounts.add_text(s->wrap_path(), w);
        }
    }
}

/// \class CodegenJob
/// \brief One Kairo TU's codegen: everything the driver decided for it, and
///        what came back. run() is the whole per-TU compile and runs on any
///        thread; the driver reads `ok`, `written` and drains `sink` after the
///        join, in TU order, so output and diagnostics do not depend on which
///        worker finished first.
class CodegenJob {
    pub var fid:     FileID;
    pub var ctx:     obs::<ASTContext>;
    pub var ksize:   u32 = 0;
    pub var print:   u8 = 0;            ///< CodegenBackend::set_print_cg
    pub var path:    string;            ///< the TU's file name, for the printer
    pub var sets:    vec::<*HeaderSet>; ///< the implicit PCH's first (per-set fallback)
    pub var kinds:   vec::<EmitKind>;
    pub var outs:    vec::<string>;     ///< one per kind
    pub var written: vec::<string>;     ///< the outs that were written, in kind order
    pub var ok:      bool = false;
    /// The TU's clang diagnostics, in Kairo terms. Drained by the driver.
    pub var sink:    BufferedDiagSink;

    fn run(self, r: *CodegenRun) {
        var be = r->be;
        // Per TU, as the CompilerInstance is: a ClangLocMap binds the one
        // SourceManager its rebind() saw, and the adapter asks it per
        // diagnostic.
        var locmap = std::create::<ClangLocMap>(be->ksm());
        var a = std::create::<ClangDiagAdapter>();
        a->sink   = &(self.sink);
        a->ksm    = be->ksm();
        a->kfid   = self.fid;
        a->locmap = locmap;
        a->BeginSourceFile(be->invocation()->getLangOpts(), &null);

        var cg = CodegenBackend(be, self.ctx, self.fid, &(self.ctx->codegen_alloc), self.ksize, r->psym, r->instances);
        cg.set_print_cg(self.print, self.path);
        cg.set_header_sets(self.sets);
        cg.set_codegen_pch(r->merged);
        cg.set_clang(be->codegen_vfs(&(r->mounts)), a, locmap);

        self.ok = true;
        for var k: usize = 0; k < self.kinds.size(); ++k {
            // Every run re-fills the same stream; print it once.
            if k > 0 { cg.set_print_cg(0, self.path); }
            if !cg.run(self.outs[k], self.kinds[k]) { self.ok = false; break; }
            self.written.push_back(self.outs[k]);
        }

        // Flush any builder still open BEFORE the sink is drained, or the
        // last diagnostic is silently dropped.
        a->EndSourceFile();
        a->finish();
        std::destroy(a);
        std::destroy(locmap);
    }
}

/// \class CodegenQueue
/// \brief The TUs of one fan-out, handed out one at a time to whichever
///        worker asks next (work()). Biggest first: the user's TU is often
///        several times the rest, and started last it would be the whole
///        tail. Which worker ran a TU never shows: each writes only its own
///        CodegenJob, and the driver reads them in TU order after the join.
class CodegenQueue {
    pub var run: obs::<CodegenRun>;
    priv var _jobs:  vec::<*CodegenJob>;
    priv var _order: vec::<usize>;
    priv var _next:  std::Atomic::<usize> = std::Atomic::<usize>(0);

    fn add(self, j: *CodegenJob) { self._jobs.push_back(j); }

    /// By Kairo byte size, descending; ties in TU order. A proxy for the
    /// TU's cost that needs no planning: emitted C++ grows with the source.
    fn schedule(self) {
        self._order.clear();
        for var i: usize = 0; i < self._jobs.size(); ++i {
            var at = self._order.size();
            while (at > 0) && (self._jobs[self._order[at - 1]]->ksize < self._jobs[i]->ksize) { at -= 1; }
            self._order.insert(self._order.begin() + at, i);
        }
    }

    /// One worker's loop: take the next TU until none is left.
    fn work(self) {
        while true {
            var i = self._next.fetch_add(1, std::MemoryOrder::relaxed);
            if i >= self._order.size() { return; }
            self._jobs[self._order[i]]->run(self.run);
        }
    }
}
