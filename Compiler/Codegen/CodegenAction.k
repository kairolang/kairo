/// --- The Kairo Project ------------------- Codegen/CodegenAction.k ------ ///
///
///   \brief The clang FrontendAction subclass that injects the token
///          stream. Owns the phase-2 sequence, in order:
///
///            1. base BeginSourceFileAction (sets up PP, sema plumbing)
///            2. construct TokenSink against the LIVE Preprocessor
///            3. filler->fill(sink)          tokens emitted (phase 1)
///            4. seal_arena + createFileID   <kairo-literals> registered
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
import Diagnostic::ClangDiagAdapter::*;

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
    pub var kpath:   string;                     ///< path of the .k to register in-action
    pub var adapter: obs::<ClangDiagAdapter>;    ///< fid fixup target; may be null
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

        // FileIDs minted before ExecuteAction are DEAD: FrontendAction::
        // BeginSourceFile calls SourceManager::clearIDTables() on the SM-reuse
        // path, which resets NextLocalOffset and re-seeds the SLoc tables.
        // The .k must be (re)registered HERE, inside the action window.
        // FileManager::FileInfos survives clearIDTables, so this is a
        // ContentCache hit, not a re-read.
        var np   = std::string_to_nstring(self.kpath);
        var fref = ci.getFileManager().getFileRef(
            llvm::StringRef(np.raw(), np.size()), true);
        if !fref { return false; }
        var live_cfid = csm->createFileID(
            *fref, clang::SourceLocation(), clang::SrcMgr::C_User);

        // The diag adapter's fid comparison must use the LIVE id too, or
        // _to_kairo_loc rejects every location and diags render loc-less.
        if self.adapter != &null {
            self.adapter->clang_kfid = live_cfid;
        }

        self.sink = std::create::<TokenSink>(pp, csm, live_cfid, self.ksize, self.arena);
        self.filled = self.filler->fill(self.sink);
        if !self.filled { return false; }

        if self.sink->has_arena() {
            var view = self.sink->seal_arena();
            var buf  = llvm::MemoryBuffer::getMemBuffer(
                view, r"<kairo-literals>", false);
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