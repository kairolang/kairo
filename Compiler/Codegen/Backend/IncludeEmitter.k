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
ffi "c++" import "llvm/ADT/DenseSet.h";

import Interop::Clang::ClangLocMap::*;
import Location::SourceLocation::*;
import Codegen::Sink::TokenSink::*;
import Codegen::EmitPlan::*;
import Codegen::CodegenContext::*;
import Codegen::Emit::InterfaceEmitter::*;

import AST::Context::ASTContext::*;
import AST::Context::InstantiationRegistry::*;
import Preprocessor::PreprocessorSymbolTable::*;

/// \class IncludedDecls
/// \brief What the earlier `#include "*.k"` lines of one C++ TU already
///        put in it, so a later one leaves that out. Each stream is a
///        preamble (every declaration its module reaches, own and foreign),
///        so two modules that share a third, or the builtin root, would
///        otherwise define its records twice. A header guards those with
///        `#ifndef`; a token stream has no directive, so the guard is kept
///        here, one per host TU (Driver/KairoIncludes.k clears it at end_tu).
///
///        Keyed by decl: one build is one session, so geo::Point is the same
///        node whether geo.k or a module importing it is being emitted, and
///        so is a tuple record (one per arity) and an instance. Extension
///        scopes are the exception, built per plan; they are keyed by their
///        spelled name, which invariant 11 makes the same text everywhere.
class IncludedDecls {
    pub var helpers:    bool = false;   ///< InterfaceEmitter::have_helpers
    pub var ctor_slots: bool = false;   ///< InterfaceEmitter::have_ctor_slots
    /// A decl or instance with its tier in the low bits (nodes are 8-aligned):
    /// `class X;` is not `class X { ... };`, and a Fwd entry must not keep
    /// a later include from defining X.
    priv var _keys:   llvm::DenseSet::<u64>;
    priv var _scopes: vec::<string>;

    fn IncludedDecls(self) { }

    fn clear(self) {
        self.helpers    = false;
        self.ctor_slots = false;
        self._keys.clear();
        self._scopes.clear();
    }

    /// True the first time \p e is offered: it is new to the host TU.
    fn admit(self, plan: *EmitPlan, e: *PlanEntry) -> bool {
        if e->scope != &null {
            // Tiers 0 and 1 only: the declaration and the definition.
            var k = ("def ") if (e->tier == PlanTier::Definitions) else ("fwd ");
            k += plan->spell()->ns_join(e->scope->ns);
            k += "::";
            k += e->scope->name;
            for var i: usize = 0; i < self._scopes.size(); ++i { if self._scopes[i] == k { return false; } }
            self._scopes.push_back(k);
            return true;
        }
        var node = (reinterpret_cast::<u64>(e->inst)) if (e->tier == PlanTier::Instantiations) else (reinterpret_cast::<u64>(e->decl));
        var key = node | static_cast::<u64>(e->tier);
        if self._keys.contains(key) { return false; }
        self._keys.insert(key);
        return true;
    }
}

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
    /// \param headers receives the system headers the tokens need
    ///                (TokenSink::system_header), for the hook to enter
    ///                ahead of them: a token stream has no line for an
    ///                #include.
    /// \param seen    what the host TU's earlier includes emitted; left out
    ///                here, and this include's entries added.
    fn emit(self, ci: *clang::CompilerInstance, locmap: *ClangLocMap, ctx: *ASTContext,
            kfid: FileID, ksize: u32, psym: *PreprocessorSymbolTable,
            instances: *InstantiationRegistry, out: *libcxx::vector::<clang::Token>,
            keep: *vec::<*TokenSink>, headers: *vec::<string>, seen: *IncludedDecls) -> bool {
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

        // Pruned before the emitter runs, which reads the entries to decide
        // what else to write (<new>, the const-field helpers): a record an
        // earlier include defined must not ask for them again.
        var fresh = vec::<PlanEntry>();
        for var i: usize = 0; i < plan.entries.size(); ++i {
            if seen->admit(&plan, &(plan.entries[i])) { fresh.push_back(plan.entries[i]); }
        }
        plan.entries = fresh;

        var ie = InterfaceEmitter(&cg, &plan);
        ie.have_helpers    = seen->helpers;
        ie.have_ctor_slots = seen->ctor_slots;
        ie.run();
        seen->helpers    = ie.have_helpers;
        seen->ctor_slots = ie.have_ctor_slots;

        for var i: usize = 0; i < sink->system_headers.size(); ++i { headers->push_back(sink->system_headers[i]); }

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
