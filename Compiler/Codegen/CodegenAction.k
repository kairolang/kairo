/// --- The Kairo Project ------------------- Codegen/CodegenAction.k ------ ///
///
///   \brief The clang FrontendAction subclass that injects the token
///          stream. Owns the phase-2 sequence, in order:
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
///            5. patch_pending               divergent tokens get real
///                                             ExpansionLocs
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "clang/Frontend/CompilerInstance.h";
ffi "c++" import "clang/Frontend/FrontendActions.h";
ffi "c++" import "clang/CodeGen/CodeGenAction.h";
ffi "c++" import "llvm/Support/MemoryBuffer.h";

import Codegen::TokenSink::*;
import Memory::ArenaAllocator::*;
import Interop::Clang::ClangLocMap::*;
import Location::SourceLocation::*;

class TokenFiller {
    virtual fn fill(self, sink: *TokenSink) -> bool {
        return false; // abstract; Backend overrides
    }
}

/// \class KairoEmitAction
/// \brief EmitObjAction that swaps clang's lexer output for our injected
///        stream. One instance per TU run, stack-scoped in Backend.
class KairoEmitAction derives clang::EmitObjAction {
    pub var filler: obs::<TokenFiller>;          ///< wired by Backend pre-ExecuteAction
    pub var locmap: obs::<ClangLocMap>;          ///< rebound in-action; THE registration point
    pub var kfid:   FileID;                      ///< Kairo fid of the TU being emitted
    pub var ksize:  u32 = 0;                     ///< byte size of the Kairo file
    pub var arena:  obs::<ArenaAllocator>;       ///< donor for the sink's lists (TU node arena)
    pub var sink:   opt::<TokenSink> = &null;    ///< owned; alive past ExecuteAction (arena text!)
    pub var filled: bool = false;                ///< fill() result, readable post-run

    override fn BeginSourceFileAction(self, ci: ref!(clang::CompilerInstance)) -> bool {
        if !clang::EmitObjAction::BeginSourceFileAction(ci) {
            return false;
        }

        var pp  = &(ci.getPreprocessor());
        var csm = &(ci.getSourceManager());

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
        ICE_IF(self.locmap == &null, "KairoEmitAction: no ClangLocMap wired");
        if !self.locmap->rebind(&ci) { return false; }

        // This TU's fid is the block base plus its Kairo fid. Nothing here
        // caches the clang FileID beyond this action   the map owns it.
        var live_cfid = self.locmap->clang_fid_of(self.kfid);
        if !live_cfid.isValid() { return false; }

        // kbase is the Kairo raw loc of byte 0 of this file. The sink derives
        // its own delta from it and owns every location conversion from here
        // on   there is exactly one place that arithmetic lives.
        var kbase = self.locmap->kairo_base(self.kfid);

        self.sink = std::create::<TokenSink>(
            pp, csm, live_cfid, kbase, self.ksize, self.arena);
        self.filled = self.filler->fill(self.sink);
        if !self.filled { return false; }

        if self.sink->has_arena() {
            var view = self.sink->seal_arena();
            var buf  = llvm::MemoryBuffer::getMemBufferCopy(view, r"<kairo-literals>");
            var afid = csm->createFileID(libcxx::move(buf), clang::SrcMgr::C_User);
            self.sink->patch_pending(afid);
        }

        self.sink->drain_into_pp();
        return true;
    }

    fn op delete (self) {
        if self.sink != &null {
            std::destroy(self.sink);
            self.sink = &null;
        }
    }
}