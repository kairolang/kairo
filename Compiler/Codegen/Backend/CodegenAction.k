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
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/ClangSemaAgree.hh"
ffi "c++" import "Native/KTimeClang.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "utility"

import AST::Context::ASTContext::ASTContext
import Codegen::Sink::TokenSink::TokenSink
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Interop::Clang::ClangLocMap::ClangLocMap
import Location::SourceLocation::SourceLocation
import Location::SourceManager::FileID
import Location::SourceRange::SourceRange
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

/// Whether the Sema agreement pass reports what it finds (I012W) under
/// -fsema-agreement's value \p want (1 on, 0 off, -1 not given) and
/// --test-sema-agreement-quiet's \p quiet: asked for it reports; not
/// asked, it reports when the compiler's build does so unasked
/// (kairo::sema_agree_reports_unasked) and \p quiet does not say otherwise.
pub fn sema_agree_reports(want: i32, quiet: bool) -> bool {
    return want == 1 || want != 0 && !quiet && kairo::sema_agree_reports_unasked()
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
    /// The Sema agreement pass's table for this run (Native/ClangSemaAgree.hh),
    /// or null when the pass is off. Owned. The fill's records go into it
    /// once the sink's locations are final; the walk reads it as clang
    /// parses; agree_report reads what the walk found.
    pub var agree: unsafe *kairo::SemaAgreeTable = &null
    /// Whether agree_report reports the walk's findings or only logs its
    /// counts (agree_start).
    pub var agree_says: bool = false

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

        self.sink->agree_on = self.agree != &null
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
        self._agree_fill()
        self.sink->drain_into_pp()
        kairo::ktime_clang_mark_fill_end()
        return true
    }

    /// Turns the Sema agreement pass on for this run unless \p want is 0
    /// (-fno-sema-agreement). It reports what it finds when \p want is 1
    /// (-fsema-agreement), or, the flag not given, when \p quiet is false
    /// and the compiler's build reports unasked
    /// (kairo::sema_agree_reports_unasked); otherwise it only counts.
    /// Before ExecuteAction: the action's consumer takes the table when
    /// clang creates it.
    fn agree_start(self, want: i32, quiet: bool, repair: bool, count_unrecorded: bool) {
        if want == 0 {
            return
        }

        self.agree_says = sema_agree_reports(want, quiet)

        if self.agree == &null {
            self.agree = kairo::std::create<kairo::SemaAgreeTable>()
        }

        self.agree->repair           = repair
        self.agree->count_unrecorded = count_unrecorded
    }

    /// The sink's records as the walk reads them: a token's location is
    /// final now that finish() has run, and before clang lexes it.
    priv fn _agree_fill(self) {
        if self.agree == &null {
            return
        }

        self.agree->block_base = self.locmap->block_base()
        self.agree->block_n    = self.locmap->mapped_count() as u32
        for var i: usize = 0; i < self.sink->agree_sites.size(); ++i {
            var s        = self.sink->agree_sites[i]
            var len: u32 = 0
            if s.decl.is_valid() {
                len = s.decl.size() as u32
            }

            self.agree->add(
                self.sink->token_raw_loc(s.tok as usize),
                self.sink->clang_raw_loc(s.name.start),
                self.sink->clang_raw_loc(s.decl.start),
                len,
            )
        }

        self._agree_fill_alts()
    }

    priv fn _agree_fill_alts(self) {
        for var i: usize = 0; i < self.sink->agree_alts.size(); ++i {
            var a = self.sink->agree_alts[i]
            self.agree->add_alt(a.site, self.sink->clang_raw_loc(a.name.start))
        }
    }

    /// Reports each disagreement the walk found as I012W into \p ctx's
    /// sink, and returns how many it reported: none when the run only
    /// counts (agree_start). \p path names the TU in the INFO line that
    /// gives the walk's counts, which is logged either way.
    fn agree_report(self, ctx: unsafe *ASTContext, const path: string) -> usize {
        if self.agree == &null || self.sink == &null {
            return 0
        }

        var unsafe *t = self.agree
        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"sema agreement: {t->call_count()} calls recorded, {t->seen} joined, {t->agreed} agreed ({t->agreed_inside} by range), {t->dependent} dependent, {t->by_instance} chosen per instance, {t->unchecked} unchecked, {t->unrecorded} unrecorded, {t->finding_count()} disagreed in {path}",
        )

        if !self.agree_says {
            return 0
        }

        var n = t->finding_count()
        for var i: usize = 0; i < n; ++i {
            var ci = t->finding_call(i) as usize
            if ci >= self.sink->agree_sites.size() {
                continue
            }

            var s = self.sink->agree_sites[ci]
            var cn = kairo::std::from_std_string<string>(
                t->finding_clang_name(i),
            )

            var kn = "<unnamed>"
            if s.name.is_valid() {
                kn = ctx->get_spelling(s.name)
            }

            var how = "found by argument-dependent lookup; "
            if !t->finding_adl(i) {
                how = ""
            }

            var why     = t->finding_why(i)
            var outcome = "the call now goes to the declaration Kairo chose"
            if why == 1 {
                outcome = "left as clang resolved it (-fno-sema-agreement-repair)"
            } else if why == 2 {
                outcome = "left as clang resolved it: the declaration Kairo chose has no counterpart clang can call here"
            } else if why == 3 {
                outcome = "left as clang resolved it: the two declarations have different types, so the argument conversions would change"
            } else if why == 4 {
                outcome = "left as clang resolved it: the two declarations are of different kinds"
            } else if why == 5 {
                outcome = "left as clang resolved it: the call does not name its callee in a form that can be re-pointed"
            }

            var b = ctx->diag_sink.report(
                DiagCode(DiagID::I012W),
                s.at.start,
                f"internal: clang resolved this call to '{cn}', but Kairo's Sema chose '{kn}'; this is a compiler bug, please report it with the source that triggered it",
            )

            b.first(s.at, how + outcome)
            if s.name.is_valid() {
                b.note(s.name.start, "Kairo's Sema chose this declaration")->child_first(
                    s.name,
                )
            } else if s.decl.is_valid() {
                b.note(s.decl.start, "Kairo's Sema chose this declaration")
            }

            var cl = self.locmap->to_kairo(
                clang::SourceLocation::getFromRawEncoding(
                    t->finding_clang_at(i),
                ),
            )

            if cl.is_valid() {
                b.note(cl, "clang resolved the call to this declaration")->child_first(
                    SourceRange::from_bounds(cl, t->finding_clang_len(i)),
                )
            }

            b.emit()
        }

        return n
    }

    fn KairoInject(self) = default

    // Move-only: the destructor destroys `sink`, so a copy would destroy it
    // twice. The source is left with no sink.
    @move fn KairoInject(self, other: Self) {
        self.filler     = other.filler
        self.locmap     = other.locmap
        self.kfid       = other.kfid
        self.ksize      = other.ksize
        self.arena      = other.arena
        self.sink       = other.sink
        self.filled     = other.filled
        self.agree      = other.agree
        self.agree_says = other.agree_says
        other.sink      = &null
        other.agree     = &null
    }

    fn op finally (self) {
        if self.sink != &null {
            kairo::std::destroy(self.sink)
            self.sink = &null
        }

        if self.agree != &null {
            kairo::std::destroy(self.agree)
            self.agree = &null
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

    /// Clang's CodeGen consumer behind the Sema agreement walk, which sees
    /// each declaration first (Native/ClangSemaAgree.hh).
    override fn CreateASTConsumer(self, @inout ci: clang::CompilerInstance, in_file: llvm::StringRef)
        -> cxx::std::unique_ptr<clang::ASTConsumer> {
        return kairo::sema_agree_wrap(
            clang::EmitObjAction::CreateASTConsumer(self, &ci, in_file),
            self.inj.agree,
        )
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

    /// Clang's CodeGen consumer behind the Sema agreement walk, which sees
    /// each declaration first (Native/ClangSemaAgree.hh).
    override fn CreateASTConsumer(self, @inout ci: clang::CompilerInstance, in_file: llvm::StringRef)
        -> cxx::std::unique_ptr<clang::ASTConsumer> {
        return kairo::sema_agree_wrap(
            clang::EmitAssemblyAction::CreateASTConsumer(self, &ci, in_file),
            self.inj.agree,
        )
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

    /// Clang's CodeGen consumer behind the Sema agreement walk, which sees
    /// each declaration first (Native/ClangSemaAgree.hh).
    override fn CreateASTConsumer(self, @inout ci: clang::CompilerInstance, in_file: llvm::StringRef)
        -> cxx::std::unique_ptr<clang::ASTConsumer> {
        return kairo::sema_agree_wrap(
            clang::EmitLLVMAction::CreateASTConsumer(self, &ci, in_file),
            self.inj.agree,
        )
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

    /// Clang's CodeGen consumer behind the Sema agreement walk, which sees
    /// each declaration first (Native/ClangSemaAgree.hh).
    override fn CreateASTConsumer(self, @inout ci: clang::CompilerInstance, in_file: llvm::StringRef)
        -> cxx::std::unique_ptr<clang::ASTConsumer> {
        return kairo::sema_agree_wrap(
            clang::EmitBCAction::CreateASTConsumer(self, &ci, in_file),
            self.inj.agree,
        )
    }
}
