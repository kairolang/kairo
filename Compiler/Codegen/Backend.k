/// --- The Kairo Project ------------------------- Codegen/Backend.k ------ ///
///
///   \brief The codegen DRIVER: entry point, stage schedule, state. Zero
///          emission logic. Mirrors Sema.k's discipline exactly: every time
///          an emit_* helper wants to land here, it is an emitter (own file
///          under Emit/, borrows *CodegenContext, writes to TokenSink)
///          never a method on this class.
///
///   Import rule (the anti-rot law of this layer):
///     - Backend.k is the ONLY file that imports emitters.
///     - Emitters import CodegenContext, never this file. They reach the
///       sink through cg->sink.
///     - Only Backend.k, CodegenAction.k, TokenSink.k, and
///       Printer/TokenStreamPrinter.k may import clang headers. An
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
ffi "c++" import "llvm/Support/MemoryBuffer.h";

import Interop::Clang::ClangBackend::*;
import Location::SourceLocation::*;
import Codegen::TokenSink::*;
import Codegen::CodegenAction::*;
import Codegen::CodegenContext::*;
import Codegen::Printer::TokenStreamPrinter::*;

// Backend is the ONLY file that imports emitters (see header).
import Codegen::Emit::EmitIR::*;

import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Node::Program::*;

/// \class CodegenBackend
/// \brief Per-TU codegen run over the shared ClangBackend. Constructed by
///        FrontendAction::_codegen between begin_tu()/end_tu(); the diag
///        adapter is already installed when run() executes, so every clang
///        diagnostic flows through ClangDiagAdapter into the TU's
///        BufferedDiagSink with Kairo spans.
class CodegenBackend derives TokenFiller {
    priv var _be:    obs::<ClangBackend>;
    priv var _ctx:   obs::<ASTContext>;
    priv var _kfid:  FileID;
    priv var _arena: obs::<ArenaAllocator>;
    priv var _ksize: u32 = 0;
    priv var _print: bool = false;   ///< --print-cg
    priv var _path:  string;         ///< for the printer header

    fn CodegenBackend(self, be: *ClangBackend, ctx: *ASTContext, kfid: FileID,
                      arena: *ArenaAllocator, ksize: u32) {
        self._be    = be;
        self._ctx   = ctx;
        self._kfid  = kfid;
        self._arena = arena;
        self._ksize = ksize;
    }

    fn set_print_cg(self, on: bool, path: string) {
        self._print = on;
        self._path  = path;
    }

    /// M2 filler: emitter dispatch over the TU's top-level items.
    ///
    /// This replaces M1's hand-written stream. The regression test is that
    /// for m1_hello.k the two are BYTE-IDENTICAL   run --print-cg against
    /// both and diff.
    override fn fill(self, sink: *TokenSink) -> bool {
        var tu = reinterpret_cast::<*TranslationUnit>(self._ctx->tu);
        if tu == &null { return false; }
        if tu->program == &null { return false; }

        var cg = CodegenContext(self._ctx, sink);

        // EmitPlan is M3. For a single TU of free functions the plan is the
        // identity transform, so enter Planned trivially rather than
        // pretending a pass ran.
        cg.advance_phase(CodegenPhase::Planned);

        var ir = EmitIR(&cg);

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl { ir.emit(item.as_decl()); }
                default {
                    // Top-level stmts/exprs are not emittable C++ at M2.
                    std::ICE(false,
                        "CodegenBackend: top-level statements are not "
                        "supported at M2");
                }
            }
        }

        sink->eof();
        cg.advance_phase(CodegenPhase::Emitted);

        if self._print {
            TokenStreamPrinter::print(sink, self._path);
        }

        return true;
    }

    /// The diag adapter is NOT passed here anymore. It holds the ClangLocMap
    /// and asks it per diagnostic, so there is no fid to fix up after
    /// registration   which is what the old adapter argument was for.
    fn run(self, out_obj: string) -> bool {
        std::ICE(self._be->ready(), "CodegenBackend::run before backend ready");

        var ci = self._be->ci();

        var cfe = &(ci->getInvocation().getFrontendOpts());
        var empty = llvm::MemoryBuffer::getMemBuffer(
            llvm::StringRef(r"", 0), r"<injected>", false);
        cfe->Inputs.clear();
        cfe->Inputs.push_back(clang::FrontendInputFile(
            empty->getMemBufferRef(), clang::InputKind(clang::Language::CXX)));
        cfe->ProgramAction = clang::frontend::EmitObj;
        cfe->OutputFile    = std::string_to_nstring(out_obj).raw_string();

        var act = KairoEmitAction();
        act.filler = &self;
        act.locmap = self._be->locmap();
        act.kfid   = self._kfid;
        act.ksize  = self._ksize;
        act.arena  = self._arena;
        return ci->ExecuteAction(act);
    }
}