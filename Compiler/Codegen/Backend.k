/// --- The Kairo Project ------------------------- Codegen/Backend.k ------ ///
///
///   \brief The codegen DRIVER: entry point, stage schedule, state. Zero
///          emission logic. Mirrors Sema.k's discipline exactly: every
///          time an emit_* helper wants to land here, it is an emitter
///          (own file under Emit/, borrows *CodegenContext, writes to
///          TokenSink) never a method on this class.
///
///   Import rule (the anti-rot law of this layer):
///     - Backend.k is the ONLY file that imports emitters.
///     - Emitters import CodegenContext + TokenSink + NamePolicy, never
///       this file and never clang headers.
///     - Only Backend.k and CodegenAction.k may import ClangBackend /
///       ffi clang headers. An `ffi "c++" import "clang/..."` appearing
///       in Emit/ is a layer-fusion bug, full stop.
///
///   Codegen owns NO intermediate representation. Sema's Lower/ stage
///   produces the codegen-shaped tree; the only structure built here is
///   the EmitPlan (C++-legal decl order + fwd-decl set). One AST node in,
///   identical C++ token stream out.
///
///   Poisoned nodes reaching this layer are a sema gate failure: assert,
///   never diagnose. "One error, one home" codegen is not a home.
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
ffi "c++" import "llvm/Support/MemoryBuffer.h";

import Interop::Clang::ClangBackend::*;
import Location::SourceLocation::*;
import Codegen::TokenSink::*;
import Codegen::CodegenAction::*;

// Emitter imports land here as each becomes real (M2+), e.g.:
//   import Codegen::Emit::EmitDecls::*;
// Backend is the ONLY file that imports emitters (see header).

/// \class CodegenBackend
/// \brief Per-TU codegen run over the shared ClangBackend. Constructed by
///        FrontendAction::_codegen between begin_tu()/end_tu(); the diag
///        adapter is already installed when run_m0() executes, so every
///        clang diagnostic flows through ClangDiagAdapter into the TU's
///        BufferedDiagSink with Kairo spans.
class CodegenBackend derives TokenFiller {
    priv var _be:    obs::<ClangBackend>;
    priv var _kfid:  FileID;
    priv var _arena: obs::<ArenaAllocator>;
    priv var _ksize: u32 = 0;

    fn CodegenBackend(self, be: *ClangBackend, kfid: FileID, arena: *ArenaAllocator, ksize: u32) {
        self._be    = be;
        self._kfid  = kfid;
        self._arena = arena;
        self._ksize = ksize;
    }

    /// M1 filler: hand-written token stream for m1_hello.k. Proves the full
    /// injection pipeline (sink -> arena -> patch -> EnterTokenStream ->
    /// EmitObj) inside the REAL shared-CI pipeline. Replaced by emitter
    /// dispatch at M2.
    override fn fill(self, sink: *TokenSink) -> bool {
        sink->punct(clang::tok::kw_void,   0, 2);
        sink->id_lit(r"man2", 4, 3, 4);
        sink->punct(clang::tok::l_paren,   7, 1);
        sink->punct(clang::tok::r_paren,   8, 1);
        sink->punct(clang::tok::l_brace,  10, 1);
        sink->punct(clang::tok::kw_return, 16, 6);
        sink->num_lit(r"0", 1, 23);
        sink->punct(clang::tok::semi,     23, 1);
        sink->punct(clang::tok::r_brace,  25, 1);
        sink->eof(26);
        return true;
    }

    fn run_m1(self, out_obj: string, kpath: string, adapter: *ClangDiagAdapter) -> bool {
        std::ICE(self._be->ready(), "run_m1 before backend ready");

        var ci   = self._be->ci();
        var cfid = self._be->locmap()->clang_fid(self._kfid);

        var cfe = &(ci->getInvocation().getFrontendOpts());
        var empty = llvm::MemoryBuffer::getMemBuffer(
            llvm::StringRef(r"", 0), r"<injected>", false);
        cfe->Inputs.clear();
        cfe->Inputs.push_back(clang::FrontendInputFile(
            empty->getMemBufferRef(), clang::InputKind(clang::Language::CXX)));
        cfe->ProgramAction = clang::frontend::EmitObj;
        cfe->OutputFile    = std::string_to_nstring(out_obj).raw_string();

        var act = KairoEmitAction();
        act.filler  = &self;
        act.kpath   = kpath;
        act.adapter = adapter;
        act.ksize   = self._ksize;
        act.arena   = self._arena;
        return ci->ExecuteAction(act);
    }
}