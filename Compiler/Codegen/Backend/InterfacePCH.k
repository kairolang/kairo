/// --- The Kairo Project --------------- Codegen/Backend/InterfacePCH.k --- ///
///
///   \brief The program's interface PCH: every module's declarations and
///          template / inline bodies, parsed once, chained on the merged
///          header PCH. Every TU of the build loads it and emits only what
///          its own object defines.
///
///   Why (Compiler/Spec/Codegen.md#the-interface-pch): a TU's stream was
///   its whole preamble -- every declaration it reaches, own and foreign --
///   plus every foreign template and inline body visible to it, and its own
///   bodies last. Over the compiler's own 316 TUs that was 38 M tokens for
///   10 MB of source, 90 % of them interface that clang parsed again in
///   every TU that imports it.
///
///   The stream is the kcc include model (IncludeEmitter) run over every TU
///   of the build: one Preamble plan per TU, each entry and body admitted
///   once (IncludedDecls), so the result is the union of what the TUs used
///   to write, in an order each plan already made valid. A TU then prunes
///   its own plan by the same keys (IncludedDecls::has) and its bodies by
///   the same set (EmitIR::pch_bodies); what is left is its tier 3 and the
///   bodies only its object defines.
///
///   A Backend/ file because it imports emitters (see CodegenBackend.k's
///   import rule).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Basic/TargetInfo.h"
ffi "c++" import "clang/Frontend/CompilerInstance.h"
ffi "c++" import "clang/Frontend/CompilerInvocation.h"
ffi "c++" import "clang/Frontend/FrontendAction.h"
ffi "c++" import "clang/Frontend/FrontendOptions.h"
ffi "c++" import "clang/Lex/Preprocessor.h"
ffi "c++" import "clang/Lex/PreprocessorOptions.h"
ffi "c++" import "clang/Lex/Token.h"
ffi "c++" import "clang/Serialization/ASTWriter.h"
ffi "c++" import "clang/Serialization/PCHContainerOperations.h"
ffi "c++" import "llvm/Support/Error.h"
ffi "c++" import "llvm/Support/MemoryBuffer.h"
ffi "c++" import "llvm/Support/VirtualFileSystem.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/TokenArray.hh"
ffi "c++" import "memory"
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::InstantiationRegistry::InstantiationRegistry
import Codegen::Backend::IncludeEmitter::{
    IncludeEmitter,
    IncludedDecls,
}
import Codegen::EmitPlan::EmitPlan
import Codegen::Sink::TokenSink::TokenSink
import Diagnostic::BufferedDiagSink::BufferedDiagSink
import Diagnostic::ClangDiagAdapter::ClangDiagAdapter
import Interop::Clang::ClangBackend::{
    ClangBackend,
    CodegenMounts,
}
import Interop::Clang::ClangLocMap::ClangLocMap
import Interop::Clang::CodegenPCH::CodegenPCH
import Location::SourceManager::FileID
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Support::TimeReport::TimeRegion

/// \class InterfacePCHAction
/// \brief Writes InterfacePCH's bytes: a prefix parse of the injected
///        stream (InterfacePCH::inject), as CodegenPCHAction is of the
///        headers' text.
pub class InterfacePCHAction derives clang::ASTFrontendAction {
    pub var _buf:  cxx::std::shared_ptr<clang::PCHBuffer>
    pub var owner: unsafe *InterfacePCH                   = &null

    override fn CreateASTConsumer(self, @inout ci: clang::CompilerInstance, in_file: llvm::StringRef)
            -> cxx::std::unique_ptr<clang::ASTConsumer>
    override fn getTranslationUnitKind(self) -> clang::TranslationUnitKind
    override fn BeginSourceFileAction(self, @inout ci: clang::CompilerInstance) -> bool
}

/// \class InterfacePCH
/// \brief One build's interface PCH and the keys of what it holds.
///
/// Built on the driver thread after CodegenRun::mount and before the
/// fan-out; read-only from then on, by every worker (`seen` is only ever
/// probed: has(), body_set()). A failed build leaves `ok` false and every TU
/// writes its whole stream as before, so a clang error in Kairo's C++ is
/// still reported by the TU that owns it.
pub class InterfacePCH {
    pub var pch:     cxx::std::shared_ptr<clang::PCHBuffer>
    pub var ok:      bool                                   = false
    pub var path:    string
    pub var mounted: bool                                   = false
    /// What the stream wrote, by IncludedDecls' keys.
    pub var seen: IncludedDecls
    /// The stream's size, for -v.
    pub var tokens: usize = 0
    /// What the build's clang said, in Kairo terms. Drained only on
    /// request (--verbose): the TUs report the same errors.
    pub var diag: BufferedDiagSink

    priv var _ctxs:   cxx::std::vector<unsafe *ASTContext>
    priv var _fids:   cxx::std::vector<FileID>
    priv var _ksizes: cxx::std::vector<u32>
    priv var _plans:  cxx::std::vector<unsafe *EmitPlan>
    priv var _psym:   unsafe *PreprocessorSymbolTable      = &null
    priv var _insts:  unsafe *InstantiationRegistry        = &null
    priv var _locmap: unsafe *ClangLocMap                  = &null
    /// The sinks own what their tokens' locations and literals point into:
    /// alive until the parse is over.
    priv var _keep:  cxx::std::vector<unsafe *TokenSink>
    priv var _lines: cxx::std::vector<string>

    fn InterfacePCH(self) {
        self.pch = cxx::std::make_shared<clang::PCHBuffer>()
    }

    fn op finally(self) {
        self._free_sinks()
    }

    priv fn _free_sinks(self) {
        for var i: usize = 0; i < self._keep.size(); ++i {
            kairo::std::destroy(self._keep[i])
        }

        self._keep.clear()
    }

    /// One TU of the build, in the order its stream joins the PCH's, with
    /// its Preamble plan already run (or null to plan in the stream): plans
    /// are most of the stream's own cost and need nothing serial, so the
    /// driver runs them on the pool first and the TU's compile reuses them.
    pub fn add(self, ctx: unsafe *ASTContext, fid: FileID, ksize: u32, plan: unsafe *EmitPlan) {
        self._ctxs.push_back(ctx)
        self._fids.push_back(fid)
        self._ksizes.push_back(ksize)
        self._plans.push_back(plan)
    }

    /// \brief builds the PCH over every add()ed TU.
    ///
    /// \param header  the merged header PCH (CodegenPCH), or null: the
    ///                interface PCH chains on it, so a TU still loads one
    ///                implicit PCH.
    /// \param mounts  what the build's VFS holds (CodegenRun::mount), the
    ///                header PCH among it.
    pub fn build(self,
                 be:     unsafe *ClangBackend,
                 header: unsafe *CodegenPCH,
                 mounts: *CodegenMounts,
                 psym:   unsafe *PreprocessorSymbolTable,
                 insts:  unsafe *InstantiationRegistry) {
        var _t = TimeRegion("InterfacePCHBuild")
        self.ok = false
        if !be->ready() || self._ctxs.size() == 0 {
            return
        }

        self._psym  = psym
        self._insts = insts

        // A COPY of the backend's invocation, as for the header PCH: the
        // PCH reader rejects one whose options differ from the TU's.
        var inv = cxx::std::make_shared<clang::CompilerInvocation>(*be->invocation())
        var empty = llvm::MemoryBuffer::getMemBuffer(
            llvm::StringRef(r"", 0),
            kairo::sref(r"<injected>"),
            false,
        )

        var *fe = &inv->getFrontendOpts()
        fe->Inputs.clear()
        fe->Inputs.push_back(
            clang::FrontendInputFile(
                empty->getMemBufferRef(),
                clang::InputKind(clang::Language::CXX),
            ),
        )

        fe->DisableFree = 0
        var *ppo = &inv->getPreprocessorOpts()
        ppo->Includes.clear()
        if header != &null && header->ok {
            ppo->ImplicitPCHInclude = kairo::std::to_std_string(header->path)
        }

        // The pending implicit instantiations of the modules' inline and
        // template bodies, performed here once (CodegenPCH::build says why).
        inv->getLangOpts().PCHInstantiateTemplates = 1

        var unsafe *ci = kairo::std::create<clang::CompilerInstance>(inv)
        self._locmap = kairo::std::create<ClangLocMap>(be->ksm())
        var unsafe *a = kairo::std::create<ClangDiagAdapter>()
        a->sink   = unsafe &self.diag
        a->ksm    = be->ksm()
        a->kfid   = self._fids[0]
        a->locmap = self._locmap
        a->BeginSourceFile(be->invocation()->getLangOpts(), &null)

        var ok = self._parse(ci, be, mounts, a, fe->Inputs[0])
        kairo::std::destroy(ci)
        a->EndSourceFile()
        a->finish()
        kairo::std::destroy(a)
        kairo::std::destroy(self._locmap)
        self._locmap = &null
        self._free_sinks()
        self.ok = ok
        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"InterfacePCH: {self._ctxs.size()} TU(s), {self.tokens} tokens, {self.pch->Data.size()} bytes, ok={self.ok}",
        )
    }

    priv fn _parse(self,
                   ci:     unsafe *clang::CompilerInstance,
                   be:     unsafe *ClangBackend,
                   mounts: *CodegenMounts,
                   a:      unsafe *ClangDiagAdapter,
                   input:  clang::FrontendInputFile) -> bool {
        ci->setVirtualFileSystem(be->codegen_vfs(mounts))
        ci->createDiagnostics(a, false)
        if !ci->hasDiagnostics() {
            return false
        }

        ci->setVerboseOutputStream(&llvm::nulls())
        ci->setTarget(
            clang::TargetInfo::CreateTargetInfo(
                &ci->getDiagnostics(),
                &ci->getInvocation().getTargetOpts(),
            ),
        )

        if !ci->hasTarget() {
            return false
        }

        ci->getTarget().adjust(&ci->getDiagnostics(), &ci->getLangOpts(), &null)

        var act = InterfacePCHAction()
        act._buf  = self.pch
        act.owner = unsafe &self
        if !act.BeginSourceFile(&*ci, input) {
            return false
        }

        // llvm::Error: bool(err) is TRUE ON FAILURE, and an unconsumed Error
        // asserts on destruction.
        var err    = act.Execute()
        var failed = err as bool
        if failed {
            llvm::consumeError(cxx::std::move(err))
        }

        var errors = ci->getDiagnostics().getNumErrors()
        act.EndSourceFile()
        return !failed && errors == 0 && self.pch->IsComplete
    }

    /// The stream, entered from the action's BeginSourceFileAction: every
    /// Kairo fid registered in this SourceManager (the one rebind of the
    /// build), then each TU's interface through IncludeEmitter in program
    /// mode, one shared `seen`, then eof.
    fn inject(self, @inout ci: clang::CompilerInstance) -> bool {
        var _t = TimeRegion("InterfaceEmit")
        if !self._locmap->rebind(unsafe &ci) {
            return false
        }

        var toks = cxx::std::vector<clang::Token>()
        for var i: usize = 0; i < self._ctxs.size(); ++i {
            var em = IncludeEmitter()
            if !em.emit(
                unsafe &ci,
                self._locmap,
                self._ctxs[i],
                self._fids[i],
                self._ksizes[i],
                self._psym,
                self._insts,
                unsafe &toks,
                unsafe &self._keep,
                unsafe &self._lines,
                unsafe &self.seen,
                true,
                self._plans[i],
            ) {
                kairo::Logger::info(
                    kairo::Logger::Stage::Driver,
                    f"InterfacePCH: stream failed: {em.error}",
                )

                return false
            }
        }

        if self._keep.size() == 0 {
            return false
        }

        // The system headers the streams asked for (TokenSink::system_header),
        // ahead of them: through Includes, because a PCH below this one makes
        // the reader rebuild the predefines from them (KairoInject::begin).
        var *ppo = &ci.getPreprocessorOpts()
        var *pp  = &ci.getPreprocessor()
        var hdrs = cxx::std::vector<string>()
        for var s: *TokenSink in self._keep {
            for var h: string in s->system_headers {
                var dup = false
                for var x: string in hdrs {
                    if x == h {
                        dup = true
                        break
                    }
                }

                if !dup {
                    hdrs.push_back(h)
                }
            }
        }

        for var h: string in hdrs {
            ppo->Includes.push_back(kairo::std::to_std_string(h))
            var pre  = kairo::std::to_std_string(pp->getPredefines())
            var line = "#include <" + h + ">\n"
            pre.append(kairo::std::to_std_string(line))
            pp->setPredefines(pre)
        }

        // The stream's end, on the last TU's last byte as a TU's own is.
        var unsafe *last = self._keep.back()
        last->eof()
        toks.push_back(*last->get_token(last->token_count() - 1))
        self.tokens = toks.size()

        var n   = toks.size()
        var arr = cxx::std::make_unique<kairo::TokenArray>(n)
        for var i: usize = 0; i < n; ++i {
            arr[i] = toks[i]
        }

        pp->EnterTokenStream(cxx::std::move(arr), n as u32, true, true)
        return true
    }
}

override fn InterfacePCHAction::CreateASTConsumer(self, @inout ci: clang::CompilerInstance, in_file: llvm::StringRef)
        -> cxx::std::unique_ptr<clang::ASTConsumer> {
    // Same generator and arguments as CodegenPCHAction's (ASTWriter.h:1015).
    return cxx::std::unique_ptr<clang::ASTConsumer>(
        cxx::std::make_unique<clang::PCHGenerator>(
            ci.getPreprocessor(),
            ci.getModuleCache(),
            llvm::StringRef(r"<kairo-interface>.pch"),
            llvm::StringRef(r""),
            self._buf,
            ci.getCodeGenOpts(),
            ci.getFrontendOpts().ModuleFileExtensions,
            false,
            false,
        ),
    )
}

override fn InterfacePCHAction::getTranslationUnitKind(self) -> clang::TranslationUnitKind {
    return clang::TU_Prefix
}

override fn InterfacePCHAction::BeginSourceFileAction(self,
                                                      @inout ci: clang::CompilerInstance) -> bool {
    if !clang::ASTFrontendAction::BeginSourceFileAction(self, &ci) {
        return false
    }

    return self.owner->inject(&ci)
}
