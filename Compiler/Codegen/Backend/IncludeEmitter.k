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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Frontend/CompilerInstance.h"
ffi "c++" import "clang/Frontend/FrontendOptions.h"
ffi "c++" import "clang/Basic/SourceManager.h"
ffi "c++" import "clang/Lex/Token.h"
ffi "c++" import "llvm/Support/MemoryBuffer.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "utility"

import AST::Context::ASTContext::ASTContext
import AST::Context::InstantiationRegistry::{
    InstanceEntry,
    InstantiationRegistry,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::Node::Base::Decl
import AST::Node::Casting::dyn_cast
import AST::Node::Declarations::{
    FunctionDecl,
    VariableDecl,
}
import AST::VisibilityFacts::{
    module_dir_of_path,
    tu_module_dir,
}
import Codegen::CodegenContext::{
    CodegenContext,
    CodegenPhase,
}
import Codegen::Emit::CXXSpell::CXXSpell
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::InterfaceEmitter::InterfaceEmitter
import Codegen::EmitPlan::{
    EmitPlan,
    PlanEntry,
    PlanMode,
    PlanTier,
}
import Codegen::Sink::TokenSink::TokenSink
import Interop::Clang::ClangLocMap::ClangLocMap
import Interop::Clang::HeaderSet::HeaderSet
import Location::SourceManager::FileID
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable

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
///        spelled name, which Pipeline.md invariant 24 makes the same text everywhere.
pub class IncludedDecls {
    pub var helpers:       bool                  = false ///< InterfaceEmitter::have_helpers
    pub var ctor_slots:    bool                  = false ///< InterfaceEmitter::have_ctor_slots
    pub var fn_value:      bool                  = false ///< InterfaceEmitter::have_fn_value
    pub var fmt_dyn:       bool                  = false ///< InterfaceEmitter::have_fmt_dyn
    pub var eval_helpers:  bool                  = false ///< InterfaceEmitter::have_eval_helpers
    pub var niche_helpers: bool                  = false ///< InterfaceEmitter::have_niche_helpers
    pub var pack_union:    bool                  = false ///< InterfaceEmitter::have_pack_union
    pub var panic_helpers: bool                  = false ///< InterfaceEmitter::have_panic_helpers
    pub var site_type:     bool                  = false ///< InterfaceEmitter::have_site_type
    pub var panic_api:     bool                  = false ///< InterfaceEmitter::have_panic_api
    pub var raw_slot:      bool                  = false ///< InterfaceEmitter::have_raw_slot
    pub var nopanic:       bool                  = false ///< InterfaceEmitter::have_nopanic
    pub var cxx_alloc:     bool                  = false ///< InterfaceEmitter::have_cxx_alloc
    pub var tid_seen:      cxx::std::vector<u64>         ///< InterfaceEmitter::tid_seen
    pub var estr_seen:     cxx::std::vector<u64>         ///< InterfaceEmitter::estr_seen
    /// A decl or instance with its tier in the low bits (nodes are 8-aligned):
    /// `class X;` is not `class X { ... };`, and a Fwd entry must not keep
    /// a later include from defining X.
    priv var _keys: llvm::DenseSet<u64>
    /// Scope and witness keys (admit). A map, not a list: the interface PCH
    /// holds every scope of the build, and each TU probes it per entry.
    priv var _scopes: llvm::StringMap<u8>
    /// Template and inline bodies (EmitPlan::include_bodies), by defining
    /// FunctionDecl: two modules that use one builtin template carry its
    /// members' bodies both.
    priv var _bodies: llvm::DenseSet<u64>
    /// #include lines already entered (system headers, ffi header sets).
    priv var _lines: cxx::std::vector<string>

    fn IncludedDecls(self) { }

    pub fn clear(self) {
        // Every flag: the next host TU has none of what this one was given.
        self.helpers       = false
        self.ctor_slots    = false
        self.fn_value      = false
        self.fmt_dyn       = false
        self.eval_helpers  = false
        self.niche_helpers = false
        self.pack_union    = false
        self.panic_helpers = false
        self.site_type     = false
        self.panic_api     = false
        self.raw_slot      = false
        // Easy to miss when a flag is added: left set, the next host TU's
        // streams skip the block while its records still call into it
        // (the second .cc of a build lost `__kairo_cxx_got`).
        self.nopanic   = false
        self.cxx_alloc = false
        self.tid_seen.clear()
        self.estr_seen.clear()
        self._keys.clear()
        self._scopes.clear()
        self._bodies.clear()
        self._lines.clear()
    }

    /// True the first time directive line \p l is offered.
    fn admit_line(self, const l: string) -> bool {
        for var i: usize = 0; i < self._lines.size(); ++i {
            if self._lines[i] == l {
                return false
            }
        }

        self._lines.push_back(l)
        return true
    }

    /// True the first time body \p f is offered.
    fn admit_body(self, f: unsafe *FunctionDecl) -> bool {
        var key = (f as usize as u64)
        if self._bodies.contains(key) {
            return false
        }

        self._bodies.insert(key)
        return true
    }

    /// Whether body or eval binding \p d was already offered (admit_body,
    /// admit_eval_var), without offering it.
    fn has_body(self, d: unsafe *Decl) -> bool {
        return self._bodies.contains(d as usize as u64)
    }

    /// True the first time eval binding \p v's definition is offered
    /// (EmitPlan::include_eval_vars). Keyed with the bodies: a decl's
    /// address is unique whatever its kind.
    fn admit_eval_var(self, v: unsafe *VariableDecl) -> bool {
        var key = (v as usize as u64)
        if self._bodies.contains(key) {
            return false
        }

        self._bodies.insert(key)
        return true
    }

    /// Whether \p e was already admitted, without offering it: the read-only
    /// probe a TU compiled against the interface PCH makes (InterfacePCH),
    /// from any worker. The keys are admit()'s.
    fn has(self, plan: unsafe *EmitPlan, e: unsafe *PlanEntry) -> bool {
        if e->witness != &null {
            var k = if (e->tier == PlanTier::Definitions) => ("wdef ")
                    else => (if (e->is_concept) => ("wcon ") else => "wfwd ")
            k += e->witness->key
            return self._scopes.find(kairo::sref(k)) != self._scopes.end()
        }

        if e->scope != &null {
            var k = if (e->tier == PlanTier::Definitions) => ("def ") else => "fwd "
            k += plan->spell()->ns_join(&e->scope->ns)
            k += "::"
            k += e->scope->name
            return self._scopes.find(kairo::sref(k)) != self._scopes.end()
        }

        var node = if (e->tier == PlanTier::Instantiations) => (e->inst as usize as u64)
                   else => (e->decl as usize as u64)
        return self._keys.contains(node | (e->tier as u8 as u64))
    }

    /// The bodies and eval bindings admitted so far (admit_body,
    /// admit_eval_var), by decl address: what EmitIR::pch_bodies skips.
    fn body_set(self) -> unsafe *llvm::DenseSet<u64> {
        return unsafe &self._bodies
    }

    /// What the host TU already has, handed to the emitter that writes the
    /// next stream: the helper blocks, the type-id specializations and the
    /// long compile-time strings it must not write again.
    fn give(self, ie: unsafe *InterfaceEmitter) {
        ie->have_helpers       = self.helpers
        ie->have_ctor_slots    = self.ctor_slots
        ie->have_fn_value      = self.fn_value
        ie->have_fmt_dyn       = self.fmt_dyn
        ie->have_eval_helpers  = self.eval_helpers
        ie->have_niche_helpers = self.niche_helpers
        ie->have_pack_union    = self.pack_union
        ie->have_panic_helpers = self.panic_helpers
        ie->have_site_type     = self.site_type
        ie->have_panic_api     = self.panic_api
        ie->have_raw_slot      = self.raw_slot
        ie->have_nopanic       = self.nopanic
        ie->have_cxx_alloc     = self.cxx_alloc
        for var k: usize = 0; k < self.tid_seen.size(); ++k {
            ie->tid_seen.push_back(self.tid_seen[k])
        }

        for var k: usize = 0; k < self.estr_seen.size(); ++k {
            ie->estr_seen.push_back(self.estr_seen[k])
        }
    }

    /// The other direction: what \p ie wrote is the host TU's now.
    fn take(self, ie: unsafe *InterfaceEmitter) {
        self.helpers       = ie->have_helpers
        self.ctor_slots    = ie->have_ctor_slots
        self.fn_value      = ie->have_fn_value
        self.fmt_dyn       = ie->have_fmt_dyn
        self.eval_helpers  = ie->have_eval_helpers
        self.niche_helpers = ie->have_niche_helpers
        self.pack_union    = ie->have_pack_union
        self.panic_helpers = ie->have_panic_helpers
        self.site_type     = ie->have_site_type
        self.panic_api     = ie->have_panic_api
        self.raw_slot      = ie->have_raw_slot
        self.nopanic       = ie->have_nopanic
        self.cxx_alloc     = ie->have_cxx_alloc
        self.tid_seen.clear()
        for var k: usize = 0; k < ie->tid_seen.size(); ++k {
            self.tid_seen.push_back(ie->tid_seen[k])
        }

        self.estr_seen.clear()
        for var k: usize = 0; k < ie->estr_seen.size(); ++k {
            self.estr_seen.push_back(ie->estr_seen[k])
        }
    }

    /// True the first time \p e is offered: it is new to the host TU.
    fn admit(self, plan: unsafe *EmitPlan, e: unsafe *PlanEntry) -> bool {
        if e->witness != &null {
            // One primary or specialization per key, whichever include wrote it.
            var k = if (e->tier == PlanTier::Definitions) => ("wdef ")
                    else => (if (e->is_concept) => ("wcon ") else => "wfwd ")
            k += e->witness->key
            return self._scopes.try_emplace(kairo::sref(k), 1 as u8).second
        }

        if e->scope != &null {
            // Tiers 0 and 1 only: the declaration and the definition.
            var k = if (e->tier == PlanTier::Definitions) => ("def ") else => "fwd "
            k += plan->spell()->ns_join(&e->scope->ns)
            k += "::"
            k += e->scope->name
            return self._scopes.try_emplace(kairo::sref(k), 1 as u8).second
        }

        var node = if (e->tier == PlanTier::Instantiations) => (e->inst as usize as u64)
                   else => (e->decl as usize as u64)
        var key = node | (e->tier as u8 as u64)
        if self._keys.contains(key) {
            return false
        }

        self._keys.insert(key)
        return true
    }
}

/// \p tu's ffi header set into \p sets, once.
pub fn _add_set(tu: unsafe *TranslationUnit, @inout sets: cxx::std::vector<unsafe *HeaderSet>) {
    if tu == &null || tu->header_set == &null {
        return
    }

    var unsafe *hs = unsafe (tu->header_set as unsafe *HeaderSet)
    if !hs->ok {
        return
    }

    for var i: usize = 0; i < sets.size(); ++i {
        if (sets)[i] == hs {
            return
        }
    }

    sets.push_back(hs)
}

/// \p hs's direct includes as lines, as a Kairo TU gets a set it cannot
/// take as its PCH (CodegenBackend::run): by resolved path, the `ffi "c"`
/// ones inside extern "C".
pub fn _set_lines(hs:           unsafe *HeaderSet,
                  seen:         unsafe *IncludedDecls,
                  @inout lines: cxx::std::vector<string>) {
    for var e: usize = 0; e < hs->includes.size(); ++e {
        if hs->includes[e].from_path.size() != 0 { // direct includes; the rest follow.
            continue
        }

        var l = ""
        if hs->includes[e].c_linkage {
            l += "extern \"C\" {\n"
        }

        l += "#include \""
        l += hs->includes[e].to_path
        l += "\""
        if hs->includes[e].c_linkage {
            l += "\n}"
        }

        if seen->admit_line(l) {
            lines.push_back(l)
        }
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
pub class IncludeEmitter {
    /// Why the last emit() failed.
    pub var error: string

    /// The C++ TU being compiled (clang's main file) is under the module
    /// directory of the Kairo file \p ctx: the same nearest module.k.
    priv fn _host_in_module(self,
                            csm: unsafe *clang::SourceManager,
                            ctx: unsafe *ASTContext) -> bool {
        var dir = tu_module_dir(ctx->tu)
        if dir.empty() {
            return false
        }

        var fe = csm->getFileEntryRefForID(csm->getMainFileID())
        if !fe.has_value() {
            return false
        }

        var name = fe->getName()
        var host = string(unsafe ((name.data() as unsafe *const u8) as *const u8), name.size())
        return module_dir_of_path(host) == dir
    }

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
    /// \param program the interface PCH's stream (InterfacePCH) instead of a
    ///                kcc include: a Preamble plan, so every declaration of
    ///                the module is there, priv ones too (its own object's
    ///                bodies name them), and no ffi header set lines (the
    ///                merged header PCH below it holds every set).
    /// \param pre     the TU's Preamble plan, already run (program mode), or
    ///                null to plan here.
    pub fn emit(self,
                ci:        unsafe *clang::CompilerInstance,
                locmap:    unsafe *ClangLocMap,
                ctx:       unsafe *ASTContext,
                kfid:      FileID,
                ksize:     u32,
                psym:      unsafe *PreprocessorSymbolTable,
                instances: unsafe *InstantiationRegistry,
                out:       unsafe *cxx::std::vector<clang::Token>,
                keep:      unsafe *cxx::std::vector<unsafe *TokenSink>,
                lines:     unsafe *cxx::std::vector<string>,
                seen:      unsafe *IncludedDecls,
                program:   bool = false,
                pre:       unsafe *EmitPlan = &null) -> bool {
        var unsafe *pp  = unsafe &ci->getPreprocessor()
        var unsafe *csm = unsafe &ci->getSourceManager()
        var        live = locmap->clang_fid_of(kfid)
        if !live.isValid() {
            self.error = "it has no location in this translation unit"
            return false
        }

        var unsafe *sink = kairo::std::create<TokenSink>(
            pp,
            csm,
            locmap,
            live,
            kfid,
            ksize,
            unsafe &ctx->codegen_alloc,
        )

        keep->push_back(sink)
        // -E prints each token's bytes, which a borrowed punctuator does not
        // have (TokenSink::arena_puncts), and decides on spaces by reading
        // them too: every token gets one instead.
        var printing = ci->getFrontendOpts().ProgramAction == clang::frontend::PrintPreprocessedInput
        sink->arena_puncts = printing

        // A plan made ahead (InterfacePCH::plan_all, on the pool) is the
        // one the TU's own compile will prune again: bound to this sink for
        // the emission, and its entries put back after.
        var cg_own = CodegenContext(ctx, sink, psym, instances)
        var plan_own = EmitPlan(
            unsafe &cg_own,
            if (program) => (PlanMode::Preamble) else => PlanMode::Include,
        )

        var unsafe *cgp  = unsafe &cg_own
        var unsafe *plan = unsafe &plan_own
        if pre != &null {
            cgp           = pre->cg()
            cgp->sink     = sink
            sink->ice_ctx = ctx
            plan          = pre
        } else {
            // A C++ TU of this file's module sees its `prot` declarations
            // too (AST/VisibilityFacts.k); any other sees its `pub` ones.
            if !program {
                plan_own.host_in_module = self._host_in_module(csm, ctx)
            }

            plan_own.run()
            cg_own.advance_phase(CodegenPhase::Planned)
        }

        var planned = plan->entries

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
        var fresh  = cxx::std::vector<PlanEntry>()
        var pruned = cxx::std::vector<unsafe *InstanceEntry>()
        for var i: usize = 0; i < plan->entries.size(); ++i {
            if plan->entries[i].tier == PlanTier::Instantiations {
                if plan->entries[i].inst != &null {
                    pruned.push_back(plan->entries[i].inst)
                }

                continue
            }

            // An early item (EmitPlan::early) an earlier include already
            // defined, as an early item or among its bodies: defined once.
            var unsafe *ei = plan->entries[i].eval_item
            if ei != &null && seen->has_body(ei) {
                continue
            }

            if seen->admit(plan, unsafe &plan->entries[i]) {
                fresh.push_back(plan->entries[i])
            }
        }

        plan->entries = fresh

        var ir = EmitIR(cgp)
        var ie = InterfaceEmitter(cgp, plan)
        ie.ir = unsafe &ir
        seen->give(unsafe &ie)
        // The C++ view's throwing half needs the host's exceptions on: clang
        // rejects a `throw` in a template it only defines.
        // Not the interface PCH's: it is spelled as a Kairo TU's own stream
        // is, which never gets that half.
        ie.cxx_exceptions = !program && ci->getLangOpts().CXXExceptions != 0
        for var k: usize = 0; k < pruned.size(); ++k {
            ie.pruned_insts.push_back(pruned[k])
        }

        ie.run()
        // The early items it defined are bodies this host TU has now: the
        // body list below, and a later include, leave them out.
        for var i: usize = 0; i < plan->entries.size(); ++i {
            var unsafe *ei = plan->entries[i].eval_item
            if ei == &null {
                continue
            }

            var unsafe *ef = dyn_cast<FunctionDecl>(ei)
            if ef != &null {
                seen->admit_body(ef)
                continue
            }

            var unsafe *ev = dyn_cast<VariableDecl>(ei)
            if ev != &null {
                seen->admit_eval_var(ev)
            }
        }

        seen->take(unsafe &ie)

        var bodies = cxx::std::vector<unsafe *FunctionDecl>()
        var all    = plan->include_bodies()
        for var i: usize = 0; i < all.size(); ++i {
            if seen->admit_body(all[i]) {
                bodies.push_back(all[i])
            }
        }

        var vars = cxx::std::vector<unsafe *VariableDecl>()
        var allv = plan->include_eval_vars()
        for var i: usize = 0; i < allv.size(); ++i {
            if seen->admit_eval_var(allv[i]) {
                vars.push_back(allv[i])
            }
        }

        ir.emit_bodies(bodies, vars)

        for var i: usize = 0; i < sink->system_headers.size(); ++i {
            var l = "#include <" + sink->system_headers[i] + ">"
            if seen->admit_line(l) {
                lines->push_back(l)
            }
        }

        if !program { // no set lines (see \p program).
            var sets = cxx::std::vector<unsafe *HeaderSet>()
            for var i: usize = 0; i < plan->entries.size(); ++i {
                _add_set(CXXSpell::tu_of(plan->entries[i].decl), &sets)
            }

            for var i: usize = 0; i < bodies.size(); ++i {
                _add_set(CXXSpell::tu_of(unsafe (bodies[i] as unsafe *Decl)), &sets)
            }

            for var i: usize = 0; i < sets.size(); ++i {
                _set_lines(sets[i], seen, &*lines)
            }
        }

        if pre != &null {
            pre->entries = planned
            cgp->sink    = &null   // the sink is the PCH build's, gone before the TU compiles.
        }

        if sink->has_arena() {
            var view = sink->seal_arena()
            var buf = llvm::MemoryBuffer::getMemBufferCopy(
                view,
                llvm::Twine(kairo::sref(r"<kairo-literals>")),
            )

            var afid = csm->createFileID(cxx::std::move(buf), clang::SrcMgr::C_User)
            sink->patch_pending(afid)
        }

        for var i: usize = 0; i < sink->token_count(); ++i {
            out->push_back(*sink->get_token(i))
            if printing {
                out->back().setFlag(clang::Token::LeadingSpace)
            }
        }

        return true
    }
}
