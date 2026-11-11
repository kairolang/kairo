/// --- The Kairo Project -------------- Codegen/Backend/CodegenAction.k --- ///
///
///   \brief The clang FrontendAction subclasses that inject the token
///          stream, one per backend output (EmitKind). Owns the phase-2
///          sequence, in order:
///
///            1. base BeginSourceFileAction (sets up PP, sema plumbing)
///            2. locmap->rebind               EVERY Kairo fid registered as
///                                              one contiguous FileID block.
///                                              The only registration site in
///                                              the compiler; it lives here
///                                              because clearIDTables killed
///                                              anything minted earlier.
///            3. construct TokenSink against the LIVE Preprocessor
///            4. filler->fill(sink)          tokens emitted (phase 1)
///            5. sink->finish                the literal arena becomes a
///                                             buffer; divergent tokens get
///                                             real ExpansionLocs
///            6. drain_into_pp               EnterTokenStream
///
///          Clang's parser then consumes the injected stream instead of
///          lexing the (garbage-as-C++) .kro buffer.
///
///   Why the filler indirection: the Preprocessor exists only inside
///   ExecuteAction, but emitters must never import clang. Backend
///   implements TokenFiller and drives emitters against the sink; this
///   file is the only place the PP lifetime is visible.
///
///   Import law: clang-touching file #3 of 3 (Backend, TokenSink, this).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Basic/SourceManager.h"
ffi "c++" import "clang/Frontend/CompilerInstance.h"
ffi "c++" import "clang/Frontend/FrontendActions.h"
ffi "c++" import "clang/CodeGen/CodeGenAction.h"
ffi "c++" import "clang/Lex/Preprocessor.h"
ffi "c++" import "clang/Lex/PreprocessorOptions.h"
ffi "c++" import "llvm/Support/MemoryBuffer.h"
ffi "c++" import "Native/KTimeClang.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "utility"

import Codegen::Sink::TokenSink::TokenSink
import Interop::Clang::ClangLocMap::ClangLocMap
import Location::SourceManager::FileID
import Memory::ArenaAllocator::ArenaAllocator
import Support::TimeReport::TimeRegion

pub class TokenFiller {
    fn TokenFiller(self) = default

    // Polymorphic base whose destructor owns nothing; moving it is memberwise.
    @move fn TokenFiller(self, other: Self) = default

    virtual fn op finally(self) { }
    virtual fn fill(self, sink: unsafe *TokenSink) -> bool {
        return false // abstract; Backend overrides
    }
}

/// What one codegen run writes: clang's backend action, picked by which
/// CodeGenAction subclass runs. `--emit` asks for any set of these; each is
/// one ExecuteAction over the same injected stream.
pub enum EmitKind derives u8 {
    Obj = 0, ///< `.o`  (EmitObjAction)
    Asm,     ///< `.s`  (EmitAssemblyAction)
    LLVMIR,  ///< `.ll` (EmitLLVMAction)
    LLVMBC,  ///< `.bc` (EmitBCAction)
}

/// \class KairoInject
/// \brief The token injection every Kairo codegen action runs after its
///        base BeginSourceFileAction (steps 2-6 above). Separate from the
///        actions because clang picks the backend output by SUBCLASS
///        (CodeGenAction's constructor takes it, and Kairo cannot pass a base
///        constructor argument), so there is one action per EmitKind and
///        this is what they share.
pub class KairoInject {
    pub var filler: *TokenFiller                ///< wired by Backend pre-ExecuteAction
    pub var locmap: unsafe *ClangLocMap         ///< rebound in-action; THE registration point
    pub var kfid:   FileID                      ///< Kairo fid of the TU being emitted
    pub var ksize:  u32                 = 0     ///< byte size of the Kairo file
    pub var arena:  *ArenaAllocator             ///< donor for the sink's lists (TU node arena)
    pub var sink:   unsafe *TokenSink   = &null ///< owned; alive past ExecuteAction (arena text!)
    pub var filled: bool                = false ///< fill() result, readable post-run

    fn begin(self, @inout ci: clang::CompilerInstance) -> bool {
        // The fill's bounds, for --time-passes: what clang spends before it
        // is the TU's setup, what it spends after it up to ParseAST is the
        // PCH load (Native/KTimeClang.hh). No-ops with timing off.
        kairo::ktime_clang_mark_fill_begin()
        var *pp  = &ci.getPreprocessor()
        var *csm = &ci.getSourceManager()

        // THE registration point   the only one in the compiler.
        //
        // FileIDs minted before ExecuteAction are DEAD: FrontendAction::
        // BeginSourceFile calls SourceManager::clearIDTables() on the SM-reuse
        // path, which resets NextLocalOffset and re-seeds the SLoc tables. So
        // every Kairo fid is registered HERE, inside the action window, as one
        // contiguous FileID block. FileManager::FileInfos survives
        // clearIDTables, so this is ContentCache hits, not re-reads.
        //
        // rebind() maps ALL fids, not just this TU's. Kairo loads fids during
        // index and parse (imports, and C++ headers it needs to query), so the
        // set is only final after preprocess   and clang must be able to
        // translate a loc in any of them, not just the one being emitted.
        // Correctness here rests on the contiguity ICE inside rebind(), which
        // is O(1) per fid and always on. The exhaustive round-trip lives in
        // ClangLocMap's Test block, where the adversarial cases (clearIDTables
        // mid-flight, post-block FileIDs, virtual fids) can actually be
        // constructed   a user's source files will never produce them.
        if self.locmap == &null {
            kairo::std::ice_fail("KairoInject: no ClangLocMap wired")
        }

        {
            var _tr = TimeRegion("Rebind")
            if !self.locmap->rebind(unsafe &ci) {
                return false
            }
        }

        // This TU's fid is the block base plus its Kairo fid. Nothing here
        // caches the clang FileID beyond this action   the map owns it.
        var live_cfid = self.locmap->clang_fid_of(self.kfid)
        if !live_cfid.isValid() {
            return false
        }

        // The sink translates every location through the map, not a per-file
        // delta: preamble tokens borrow spans from OTHER registered fids.
        self.sink = kairo::std::create<TokenSink>(
            pp,
            csm,
            self.locmap,
            live_cfid,
            self.kfid,
            self.ksize,
            self.arena,
        )

        // fill() runs on whichever worker runs this TU, beside other TUs'
        // fills: it reads the shared AST and writes only this TU's own
        // state (Compiler/Spec/Codegen.md, "Parallel codegen").
        self.filled = self.filler->fill(self.sink)
        if !self.filled {
            return false
        }

        // Handing the filled stream to the preprocessor: its own row, so the
        // TU's time between the fill and the PCH load is not untraced.
        var _td = TimeRegion("TokenDrain")

        // The system headers the stream needs (TokenSink::system_header),
        // entered ahead of it as a header set's textual includes are. Both
        // routes, because clang reads only one: without a PCH the predefines
        // buffer was built from PreprocessorOptions::Includes before this
        // action began, so the line is appended to it; with one, the PCH
        // reader rebuilds the predefines from Includes after this point and
        // drops an append. Backend::run restores Includes after the run.
        var *ppo = &ci.getPreprocessorOpts()
        for var i: usize = 0; i < self.sink->system_headers.size(); ++i {
            var h = self.sink->system_headers[i]
            ppo->Includes.push_back(kairo::std::to_std_string(h))
            var pre  = kairo::std::to_std_string(pp->getPredefines())
            var line = "#include <" + h + ">\n"
            pre.append(kairo::std::to_std_string(line))
            pp->setPredefines(pre)
        }

        self.sink->finish()
        self.sink->drain_into_pp()
        kairo::ktime_clang_mark_fill_end()
        return true
    }

    fn KairoInject(self) = default

    // Move-only: the destructor destroys `sink`, so a copy would destroy it
    // twice. The source is left with no sink.
    @move fn KairoInject(self, other: Self) {
        self.filler = other.filler
        self.locmap = other.locmap
        self.kfid   = other.kfid
        self.ksize  = other.ksize
        self.arena  = other.arena
        self.sink   = other.sink
        self.filled = other.filled
        other.sink  = &null
    }

    fn op finally (self) {
        if self.sink != &null {
            kairo::std::destroy(self.sink)
            self.sink = &null
        }
    }
}

/// One action per EmitKind, each a clang CodeGenAction subclass that swaps
/// clang's lexer output for the injected stream. One instance per TU run,
/// stack-scoped in Backend.
pub class KairoEmitObj derives clang::EmitObjAction {
    pub var inj: KairoInject
    override fn BeginSourceFileAction(self, @inout ci: clang::CompilerInstance) -> bool {
        if !clang::EmitObjAction::BeginSourceFileAction(self, &ci) {
            return false
        }

        return self.inj.begin(&ci)
    }
}

pub class KairoEmitAsm derives clang::EmitAssemblyAction {
    pub var inj: KairoInject
    override fn BeginSourceFileAction(self, @inout ci: clang::CompilerInstance) -> bool {
        if !clang::EmitAssemblyAction::BeginSourceFileAction(self, &ci) {
            return false
        }

        return self.inj.begin(&ci)
    }
}

pub class KairoEmitLLVMIR derives clang::EmitLLVMAction {
    pub var inj: KairoInject
    override fn BeginSourceFileAction(self, @inout ci: clang::CompilerInstance) -> bool {
        if !clang::EmitLLVMAction::BeginSourceFileAction(self, &ci) {
            return false
        }

        return self.inj.begin(&ci)
    }
}

pub class KairoEmitLLVMBC derives clang::EmitBCAction {
    pub var inj: KairoInject
    override fn BeginSourceFileAction(self, @inout ci: clang::CompilerInstance) -> bool {
        if !clang::EmitBCAction::BeginSourceFileAction(self, &ci) {
            return false
        }

        return self.inj.begin(&ci)
    }
}
