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
ffi "c++" import "clang/Frontend/FrontendOptions.h";
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
import Codegen::Emit::EmitIR::*;
import Codegen::Emit::CXXSpell::*;
import Codegen::Emit::EmitWitness::*;
import Interop::Clang::HeaderSet::*;
import AST::Context::TranslationUnit::*;
import AST::Node::Declarations::*;

import AST::Context::ASTContext::*;
import AST::Context::InstantiationRegistry::*;
import Preprocessor::PreprocessorSymbolTable::*;

/// \class IncludedDecls
/// \brief What the earlier `#include "*.k"` lines of one C++ TU already
///        put in it, so a later one leaves that out. Each stream carries
///        every declaration its module's interface reaches, own and foreign,
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
    pub var fn_value:   bool = false;   ///< InterfaceEmitter::have_fn_value
    pub var eval_helpers: bool = false; ///< InterfaceEmitter::have_eval_helpers
    /// A decl or instance with its tier in the low bits (nodes are 8-aligned):
    /// `class X;` is not `class X { ... };`, and a Fwd entry must not keep
    /// a later include from defining X.
    priv var _keys:   llvm::DenseSet::<u64>;
    priv var _scopes: vec::<string>;
    /// Template and inline bodies (EmitPlan::include_bodies), by defining
    /// FunctionDecl: two modules that use one builtin template carry its
    /// members' bodies both.
    priv var _bodies: llvm::DenseSet::<u64>;
    /// #include lines already entered (system headers, ffi header sets).
    priv var _lines:  vec::<string>;

    fn IncludedDecls(self) { }

    fn clear(self) {
        self.helpers    = false;
        self.ctor_slots = false;
        self._keys.clear();
        self._scopes.clear();
        self._bodies.clear();
        self._lines.clear();
    }

    /// True the first time directive line \p l is offered.
    fn admit_line(self, l: string) -> bool {
        for var i: usize = 0; i < self._lines.size(); ++i { if self._lines[i] == l { return false; } }
        self._lines.push_back(l);
        return true;
    }

    /// True the first time body \p f is offered.
    fn admit_body(self, f: *FunctionDecl) -> bool {
        var key = reinterpret_cast::<u64>(f);
        if self._bodies.contains(key) { return false; }
        self._bodies.insert(key);
        return true;
    }

    /// True the first time \p e is offered: it is new to the host TU.
    fn admit(self, plan: *EmitPlan, e: *PlanEntry) -> bool {
        if e->witness != &null {
            // One primary or specialization per key, whichever include wrote it.
            var k = ("wdef ") if (e->tier == PlanTier::Definitions) else ((("wcon ") if (e->is_concept) else ("wfwd ")));
            k += e->witness->key;
            for var i: usize = 0; i < self._scopes.size(); ++i { if self._scopes[i] == k { return false; } }
            self._scopes.push_back(k);
            return true;
        }
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

/// \p tu's ffi header set into \p sets, once.
fn _add_set(tu: *TranslationUnit, sets: *vec::<*HeaderSet>) {
    if (tu == &null) || (tu->header_set == &null) { return; }
    var hs = reinterpret_cast::<*HeaderSet>(tu->header_set);
    if !hs->ok { return; }
    for var i: usize = 0; i < sets->size(); ++i { if (*sets)[i] == hs { return; } }
    sets->push_back(hs);
}

/// \p hs's direct includes as lines, as a Kairo TU gets a set it cannot
/// take as its PCH (CodegenBackend::run): by resolved path, the `ffi "c"`
/// ones inside extern "C".
fn _set_lines(hs: *HeaderSet, seen: *IncludedDecls, lines: *vec::<string>) {
    for var e: usize = 0; e < hs->includes.size(); ++e {
        if hs->includes[e].from_path.size() != 0 { continue; }   // direct includes; the rest follow.
        // Two literals: \x is greedy in Stage 0's output (see CodegenBackend).
        var l = "";
        if hs->includes[e].c_linkage { l += "extern \x22"; l += "C\x22 {\n"; }
        l += "#include \x22";
        l += hs->includes[e].to_path;
        l += "\x22";
        if hs->includes[e].c_linkage { l += "\n}"; }
        if seen->admit_line(l) { lines->push_back(l); }
    }
}

/// \class IncludeEmitter
/// \brief The tokens a C++ TU gets for `#include "foo.k"`
///        (Interop/Clang/KairoInclude.k): foo.k's interface -- an Include plan:
///        its pub declarations and what they reach, own and foreign --
///        emitted into a TokenSink bound to the HOST's preprocessor, then
///        the template and inline bodies the host compiles itself
///        (EmitPlan::include_bodies). No other body (they are foo.o's and
///        the other modules' objects'), no tok::eof (it would end the host
///        TU).
class IncludeEmitter {
    /// Why the last emit() failed.
    pub var error: string;

    /// \brief appends foo.k's interface to \p out.
    ///
    /// \param locmap  bound to \p ci (ClangLocMap::rebind), so every Kairo fid
    ///                is a FileID in the host's SourceManager.
    /// \param keep    receives the sink: it owns state the tokens' locations
    ///                were built from, and lives as long as the host TU.
    /// \param lines   receives the `#include` lines the tokens need, for the
    ///                hook to enter ahead of them (a token stream has no line
    ///                for a directive): the system headers
    ///                (TokenSink::system_header), then the ffi header set of
    ///                every module a declaration or body here comes from,
    ///                by the paths phase A resolved them to. Each once per
    ///                host TU.
    /// \param seen    what the host TU's earlier includes emitted; left out
    ///                here, and this include's entries added.
    fn emit(self, ci: *clang::CompilerInstance, locmap: *ClangLocMap, ctx: *ASTContext,
            kfid: FileID, ksize: u32, psym: *PreprocessorSymbolTable,
            instances: *InstantiationRegistry, out: *libcxx::vector::<clang::Token>,
            keep: *vec::<*TokenSink>, lines: *vec::<string>, seen: *IncludedDecls) -> bool {
        var pp  = &(ci->getPreprocessor());
        var csm = &(ci->getSourceManager());
        var live = locmap->clang_fid_of(kfid);
        if !live.isValid() {
            self.error = "it has no location in this translation unit";
            return false;
        }
        var sink = std::create::<TokenSink>(pp, csm, locmap, live, kfid, ksize, &(ctx->codegen_alloc));
        keep->push_back(sink);
        // -E prints each token's bytes, which a borrowed punctuator does not
        // have (TokenSink::arena_puncts), and decides on spaces by reading
        // them too: every token gets one instead.
        var printing = (ci->getFrontendOpts().ProgramAction == clang::frontend::PrintPreprocessedInput);
        sink->arena_puncts = printing;

        var cg = CodegenContext(ctx, sink, psym, instances);
        var plan = EmitPlan(&cg, PlanMode::Include);
        plan.run();
        cg.advance_phase(CodegenPhase::Planned);

        // Pruned before the emitter runs, which reads the entries to decide
        // what else to write (<new>, the const-field helpers): a record an
        // earlier include defined must not ask for them again.
        //
        // No explicit instantiations at all, not even `extern template`:
        // the host may be compiled by a different run than foo.o (kcc -c
        // x.cc; kcc -c foo.k), and which TU homes an instance is decided per
        // run. The host instantiates what it uses implicitly (linkonce_odr),
        // the homes' explicit definitions are weak_odr, and the linker keeps
        // one.
        var fresh = vec::<PlanEntry>();
        for var i: usize = 0; i < plan.entries.size(); ++i {
            if plan.entries[i].tier == PlanTier::Instantiations { continue; }
            if seen->admit(&plan, &(plan.entries[i])) { fresh.push_back(plan.entries[i]); }
        }
        plan.entries = fresh;

        var ie = InterfaceEmitter(&cg, &plan);
        ie.have_helpers    = seen->helpers;
        ie.have_ctor_slots = seen->ctor_slots;
        ie.have_fn_value   = seen->fn_value;
        ie.have_eval_helpers = seen->eval_helpers;
        ie.run();
        seen->helpers    = ie.have_helpers;
        seen->ctor_slots = ie.have_ctor_slots;
        seen->fn_value   = ie.have_fn_value;
        seen->eval_helpers = ie.have_eval_helpers;

        var bodies = vec::<*FunctionDecl>();
        var all = plan.include_bodies();
        for var i: usize = 0; i < all.size(); ++i {
            if seen->admit_body(all[i]) { bodies.push_back(all[i]); }
        }
        var ir = EmitIR(&cg);
        ir.emit_bodies(bodies);

        for var i: usize = 0; i < sink->system_headers.size(); ++i {
            var l = "#include <" + sink->system_headers[i] + ">";
            if seen->admit_line(l) { lines->push_back(l); }
        }
        var sets = vec::<*HeaderSet>();
        for var i: usize = 0; i < plan.entries.size(); ++i { _add_set(CXXSpell::tu_of(plan.entries[i].decl), &sets); }
        for var i: usize = 0; i < bodies.size(); ++i { _add_set(CXXSpell::tu_of(static_cast::<*Decl>(bodies[i])), &sets); }
        for var i: usize = 0; i < sets.size(); ++i { _set_lines(sets[i], seen, lines); }

        if sink->has_arena() {
            var view = sink->seal_arena();
            var buf  = llvm::MemoryBuffer::getMemBufferCopy(view, r"<kairo-literals>");
            var afid = csm->createFileID(libcxx::move(buf), clang::SrcMgr::C_User);
            sink->patch_pending(afid);
        }

        for var i: usize = 0; i < sink->token_count(); ++i {
            out->push_back(*(sink->get_token(i)));
            if printing { out->back().setFlag(clang::Token::LeadingSpace); }
        }
        return true;
    }
}
