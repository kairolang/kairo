/// --- The Kairo Project ------------- Codegen/Backend/IncludeEmitter.k --- ///
///
///   \brief The third consumer of a plan, beside CodegenBackend (an object)
///          and EmitCXXHeader (a header): the tokens `#include "foo.k"`
///          splices into a C++ TU. A Backend/ file because it imports
///          emitters (see CodegenBackend.k's import rule).
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
ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "clang/Lex/Token.h";
ffi "c++" import "llvm/Support/MemoryBuffer.h";

import Interop::Clang::ClangLocMap::*;
import Location::SourceLocation::*;
import Codegen::Sink::TokenSink::*;
import Codegen::EmitPlan::*;
import Codegen::CodegenContext::*;
import Codegen::Emit::InterfaceEmitter::*;

import AST::Context::ASTContext::*;
import AST::Context::InstantiationRegistry::*;
import Preprocessor::PreprocessorSymbolTable::*;

/// \class IncludeEmitter
/// \brief The tokens a C++ TU gets for `#include "foo.k"`
///        (Interop/Clang/KairoInclude.k): foo.k's preamble interface -- every
///        declaration, own and foreign, as CodegenBackend::fill opens with --
///        emitted into a TokenSink bound to the HOST's preprocessor. No
///        bodies (they are foo.o's), no tok::eof (it would end the host TU).
class IncludeEmitter {
    /// Why the last emit() failed.
    pub var error: string;

    /// \brief appends foo.k's interface to \p out.
    ///
    /// \param locmap  bound to \p ci (ClangLocMap::rebind), so every Kairo fid
    ///                is a FileID in the host's SourceManager.
    /// \param keep    receives the sink: it owns state the tokens' locations
    ///                were built from, and lives as long as the host TU.
    fn emit(self, ci: *clang::CompilerInstance, locmap: *ClangLocMap, ctx: *ASTContext,
            kfid: FileID, ksize: u32, psym: *PreprocessorSymbolTable,
            instances: *InstantiationRegistry, out: *libcxx::vector::<clang::Token>,
            keep: *vec::<*TokenSink>) -> bool {
        var pp  = &(ci->getPreprocessor());
        var csm = &(ci->getSourceManager());
        var live = locmap->clang_fid_of(kfid);
        if !live.isValid() {
            self.error = "it has no location in this translation unit";
            return false;
        }
        var sink = std::create::<TokenSink>(pp, csm, locmap, live, kfid, ksize, &(ctx->codegen_alloc));
        keep->push_back(sink);

        var cg = CodegenContext(ctx, sink, psym, instances);
        var plan = EmitPlan(&cg, PlanMode::Preamble);
        plan.run();
        cg.advance_phase(CodegenPhase::Planned);
        var ie = InterfaceEmitter(&cg, &plan);
        ie.run();

        // A token stream has no line for an #include, and the host is past
        // the point where Kairo's own TUs enter them (KairoInject).
        if !sink->system_headers.empty() {
            var hs = "";
            for var i: usize = 0; i < sink->system_headers.size(); ++i {
                if i > 0 { hs += ", "; }
                hs += "<" + sink->system_headers[i] + ">";
            }
            self.error = f"its interface needs {hs}, and an included Kairo file cannot bring system headers yet";
            return false;
        }

        if sink->has_arena() {
            var view = sink->seal_arena();
            var buf  = llvm::MemoryBuffer::getMemBufferCopy(view, r"<kairo-literals>");
            var afid = csm->createFileID(libcxx::move(buf), clang::SrcMgr::C_User);
            sink->patch_pending(afid);
        }

        for var i: usize = 0; i < sink->token_count(); ++i { out->push_back(*(sink->get_token(i))); }
        return true;
    }
}
