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
///     - Emitters write to an EmitSink (EmitSink.k), never to a concrete
///       sink. The sink files are EmitSink.k (the interface), TokenSink.k
///       (clang tokens, the real build) and TextSink.k (C++ text). This
///       file uses only TokenSink; TextSink's callers are the driver's
///       --print-cxx dump and EmitCXXHeader, both of which run in sema and
///       need no clang.
///     - Only Backend.k, CodegenAction.k, the sink files, and
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
ffi "c++" import "clang/Lex/PreprocessorOptions.h";
ffi "c++" import "llvm/Support/MemoryBuffer.h";

import Interop::Clang::ClangBackend::*;
import Interop::Clang::HeaderSet::*;
import Location::SourceLocation::*;
import Codegen::EmitSink::*;
import Codegen::TokenSink::*;
import Codegen::EmitPlan::*;
import Codegen::CodegenAction::*;
import Codegen::CodegenContext::*;
import Codegen::Printer::TokenStreamPrinter::*;

// Backend is the ONLY file that imports emitters (see header).
import Codegen::Emit::EmitIR::*;
import Codegen::Emit::InterfaceEmitter::*;

import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::InstantiationRegistry::*;
import AST::Node::Program::*;
import Preprocessor::PreprocessorSymbolTable::*;

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
    priv var _print: u8 = 0;   ///< bit 0: print-cg, bit 1: print-ir
    priv var _path:  string;         ///< for the printer header
    priv var _sets:  vec::<*HeaderSet>;  ///< header sets this TU's graph requested, main file's first
    priv var _psym:      obs::<PreprocessorSymbolTable>;  ///< module_base segments -> namespace names
    priv var _instances: obs::<InstantiationRegistry>;    ///< tier 3 of the plan

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

    /// Header sets whose PCHs this TU's emission loads. The MAIN file's set
    /// must be first: it is the one that becomes the implicit PCH.
    fn set_header_sets(self, sets: vec::<*HeaderSet>) { self._sets = sets; }

    /// M2 filler: emitter dispatch over the TU's top-level items.
    ///
    /// This replaces M1's hand-written stream. The regression test is that
    /// for m1_hello.k the two are BYTE-IDENTICAL   run --print-cg against
    /// both and diff.
    override fn fill(self, sink: *TokenSink) -> bool {
        var tu = reinterpret_cast::<*TranslationUnit>(self._ctx->tu);
        if tu == &null { return false; }
        if tu->program == &null { return false; }

        var cg = CodegenContext(self._ctx, sink, self._psym, self._instances);
        var plan = EmitPlan(&cg, PlanMode::Preamble);
        plan.run();
        cg.advance_phase(CodegenPhase::Planned);

        // Every declaration, own and foreign, before any body: the item
        // loop below then only ever defines what is already declared.
        var ie = InterfaceEmitter(&cg, &plan);
        ie.run();

        // Bodies, driven by the plan: the same order the interface used, so
        // a definition always follows the declaration it matches.
        var ir = EmitIR(&cg);
        ir.emit_tu(&plan);

        // Home instantiation definitions last: they only instantiate members
        // whose definitions precede them.
        ie.emit_home_instantiations();

        sink->eof();
        cg.advance_phase(CodegenPhase::Emitted);

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

    /// The diag adapter is NOT passed here anymore. It holds the ClangLocMap
    /// and asks it per diagnostic, so there is no fid to fix up after
    /// registration   which is what the old adapter argument was for.
    fn run(self, out_obj: string) -> bool {
        ICE_IF(!self._be->ready(), "CodegenBackend::run before backend ready");

        var ci = self._be->ci();

        var cfe = &(ci->getInvocation().getFrontendOpts());
        var empty = llvm::MemoryBuffer::getMemBuffer(
            llvm::StringRef(r"", 0), r"<injected>", false);
        cfe->Inputs.clear();
        cfe->Inputs.push_back(clang::FrontendInputFile(
            empty->getMemBufferRef(), clang::InputKind(clang::Language::CXX)));
        cfe->ProgramAction = clang::frontend::EmitObj;
        cfe->OutputFile    = std::string_to_nstring(out_obj).raw_string();

        // Phase B: the headers were parsed once already (HeaderSet). Mount
        // each set's PCH bytes in the backend's in-memory VFS -- once per set
        // for the build -- and hand clang the MAIN file's set as the implicit
        // PCH, so emission starts from phase A's AST instead of re-parsing.
        //
        // LIMITATION: one PCH per clang TU. A Kairo TU whose import graph
        // spans two header sets uses the main file's; every other set's
        // headers are `#include`d textually through Includes, by the paths
        // phase A resolved them to (so no quoted-dir search is needed).
        // Correct -- same headers, same order within each set -- just
        // re-parsed.
        //
        // The invocation is shared by every TU's run: restore what this one
        // changed, or the next TU inherits this TU's PCH.
        var ppo       = &(ci->getInvocation().getPreprocessorOpts());
        var saved_pch = ppo->ImplicitPCHInclude;
        var saved_inc = ppo->Includes;
        finally {
            ppo->ImplicitPCHInclude = saved_pch;
            ppo->Includes           = saved_inc;
        }
        if self._sets.size() > 0 {
            for var i: usize = 0; i < self._sets.size(); ++i {
                var s = self._sets[i];
                if s->mounted || (!s->ok) { continue; }
                self._be->mount_pch(s->pch_path(), &(s->pch->Data));
                s->mounted = true;
            }
            ppo->Includes.clear();
            var textual_from: usize = 0;
            if self._sets[0]->mounted {
                ppo->ImplicitPCHInclude = libcxx::string(std::string_to_nstring(self._sets[0]->pch_path()).raw_string());
                textual_from = 1;
            }
            for var i: usize = textual_from; i < self._sets.size(); ++i {
                var s = self._sets[i];
                for var e: usize = 0; e < s->includes.size(); ++e {
                    if s->includes[e].from_path.size() != 0 { continue; }   // direct includes; the rest follow.
                    ppo->Includes.push_back(libcxx::string(std::string_to_nstring(s->includes[e].to_path).raw_string()));
                }
            }
        }

        var act = KairoEmitAction();
        act.filler = &self;
        act.locmap = self._be->locmap();
        act.kfid   = self._kfid;
        act.ksize  = self._ksize;
        act.arena  = self._arena;
        return ci->ExecuteAction(act);
    }
}