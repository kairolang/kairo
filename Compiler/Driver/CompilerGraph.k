/// --- The Kairo Project ----------------------- Driver/CompilerGraph.k --- ///
///
///   CompilerInstance, part: the input and import graph. The order inputs
///   run in (_kairo_order), the .k files C++ inputs include
///   (_discover_includes), and the incremental API tools drive per file
///   (release, invalidate, evict, parse_one, the importer queries). An
///   `extend` of the class in CompilerInstance.k (Driver/module.k).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "clang/Frontend/FrontendActions.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "vector"

import API::Text::LinkText
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import Driver::CompilerInstance::CompilerInstance
import Driver::InputKinds::{
    InputClass,
    InputKind,
    classify_input,
}
import Driver::TUStage::TUStage
import Interop::Clang::KairoIncludeScan::KairoIncludeScan
import Parser::ASTParse::ASTParse
import Support::FileIO::Path::Path

extend CompilerInstance {
    /// \brief adds every .k a C++ or Objective-C++ input includes, and the
    ///        command line does not name, as a Kairo input after the named
    ///        ones (KairoIncludeScan). After _plan_outputs: a discovered
    ///        file is no output -o can name, and before _kairo_order, which
    ///        loads the inputs.
    prot fn _discover_includes(self) {
        var scan = KairoIncludeScan(self._quote_dirs(), self._angle_dirs())
        var any  = false
        for *k in self._inputs {
            if k->cls != InputClass::Source && k->cls != InputClass::Header {
                continue
            }

            if !clang::driver::types::isCXX(k->ty) {
                continue
            }

            scan.scan(k->path)
            any = true
        }

        if !any {
            return
        }

        self._includes_kairo = scan.found.size() > 0
        for *f in scan.found {
            var named = false
            for *k in self._inputs {
                if k->cls != InputClass::Kairo {
                    continue
                }

                if Path::absolute_if_exists(k->path) == *f {
                    named = true
                    break
                }
            }

            if named {
                continue
            }

            var nk = classify_input(*f, "")
            nk.discovered = true
            kairo::Logger::info(
                kairo::Logger::Stage::Driver,
                f"CompilerInstance: {(*f)} is included by a C++ input; building it",
            )

            self._inputs.push_back(nk)
        }
    }

    /// The host's angled search path (-I): _quote_dirs without -iquote.
    priv fn _angle_dirs(self) -> cxx::std::vector<string> {
        var out = self.invocation()->clang_include_dirs()
        var *fl = &self.invocation()->codegen.cxx_flags
        for var i: usize = 0; i < fl->size(); ++i {
            var w = (*fl)[i]
            if w == "-iquote" {
                i += 1
                continue
            }

            if w == "-I" {
                if i + 1 < fl->size() {
                    out.push_back((*fl)[i + 1])
                }

                i += 1
                continue
            }

            if LinkText::starts_with(w, "-I") {
                out.push_back(
                    string(unsafe (((w.raw() as unsafe *const u8) + 2) as *const u8), w.size() - 2),
                )
            }
        }

        return out
    }

    /// The host's quoted search path after the includer's own directory:
    /// -iquote, then -I, as clang orders them. The -I come in the order
    /// FlagTranslator::to_driver writes them for a C/C++ input:
    /// clang_include_dirs (-I, --ffi-include, --cxx-include), then the words
    /// in --cxx-flags.
    priv fn _quote_dirs(self) -> cxx::std::vector<string> {
        var quote = cxx::std::vector<string>()
        var angle = self.invocation()->clang_include_dirs()
        var *fl   = &self.invocation()->codegen.cxx_flags
        for var i: usize = 0; i < fl->size(); ++i {
            var w    = (*fl)[i]
            var next = if (i + 1 < fl->size()) => ((*fl)[i + 1]) else => ""
            if w == "-iquote" {
                quote.push_back(next)
                i += 1
                continue
            }

            if w == "-I" {
                angle.push_back(next)
                i += 1
                continue
            }

            if LinkText::starts_with(w, "-iquote") {
                quote.push_back(
                    string(unsafe (((w.raw() as unsafe *const u8) + 7) as *const u8), w.size() - 7),
                )

                continue
            }

            if LinkText::starts_with(w, "-I") {
                angle.push_back(
                    string(unsafe (((w.raw() as unsafe *const u8) + 2) as *const u8), w.size() - 2),
                )

                continue
            }
        }

        for *d in angle {
            quote.push_back(*d)
        }

        return quote
    }

    /// \brief _inputs, with every Kairo input another one imports moved
    ///        after the rest (stable otherwise).
    ///
    /// \details Written when an input was an ENTRY with no module path, and
    ///          a file's identity was set by its first walk: run first, the
    ///          importer walked it as module `foo` and claimed it
    ///          (claim_fid). An input now takes the path an import gives it
    ///          (_input_module_path), so the order no longer decides identity,
    ///          and this can go. Left in place for now: it is harmless, the
    ///          importer still claims the file it reaches first. The fid-0
    ///          placeholder below is still needed either way.
    prot fn _kairo_order(self) -> cxx::std::vector<InputKind> {
        var nk: usize = 0
        for *k in self._inputs {
            if k->cls == InputClass::LinkInput
                || k->cls == InputClass::Source
                || k->cls == InputClass::Header {
                continue
            }

            nk += 1
        }

        if nk < 2 || self._pp == &null {
            return self._inputs
        }

        // Fid 0 is "unresolved" to the import chain (FileImportIndex::record,
        // ImportDecl::resolved_fid, the TU's import edges). One input is never
        // imported, so it can hold fid 0; of several, the first loaded may be
        // the one another imports, whose import would then resolve to
        // nothing. A placeholder takes fid 0 instead. It relies on nothing
        // loading a Kairo input before this runs (_plan_outputs does not);
        // inputs found any other way (M3's include discovery) must be added
        // to _inputs ahead of this, not loaded.
        if self._sm->file_count() == 0 {
            self._sm->load_virtual(
                Path(r"<kairo-batch>"),
                unsafe (self._fid0_text.raw() as kairo::std::ConstPtr<u8>),
                self._fid0_text.size(),
            )
        }

        var kfids = cxx::std::vector<u32>()
        for *k in self._inputs {
            if k->cls == InputClass::LinkInput
                || k->cls == InputClass::Source
                || k->cls == InputClass::Header {
                continue
            }

            kfids.push_back(self._sm->load_file(Path(k->path)))
        }

        // An input reached from ANOTHER input (not from itself).
        var reached = llvm::DenseSet<u64>()
        for var i: usize = 0; i < kfids.size(); ++i {
            if kfids[i] == u32::MAX {
                continue
            }

            var r = self._pp->reach(kfids[i])
            for var j: usize = 0; j < kfids.size(); ++j {
                if j != i && kfids[j] != kfids[i] && r.contains(kfids[j]) {
                    reached.insert(kfids[j] as u64)
                }
            }
        }

        if reached.empty() {
            return self._inputs
        }

        var first       = cxx::std::vector<InputKind>()
        var last        = cxx::std::vector<InputKind>()
        var n:    usize = 0
        for *k in self._inputs {
            if k->cls == InputClass::LinkInput
                || k->cls == InputClass::Source
                || k->cls == InputClass::Header {
                first.push_back(*k)
                continue
            }

            var f = kfids[n]
            n += 1
            if f != u32::MAX && reached.contains(f) {
                last.push_back(*k)
            } else {
                first.push_back(*k)
            }
        }

        for *k in last {
            first.push_back(*k)
        }

        return first
    }

    /// \brief frees everything \p fid produced at \p from and every LATER stage.
    ///
    /// \details The one entry point tools should use to reclaim a file. Batch
    ///          compilation never needs it   the process exits   but anything
    ///          that walks many files (kfmt over a tree) or re-processes one
    ///          (LSP on edit) does, because nothing is otherwise reclaimed
    ///          until the CompilerInstance dies.
    ///
    /// ORDERING. Artifacts are torn down newest-stage-first, because every
    /// stage's output points into the stages before it:
    ///
    ///   Codegen/Sema/Parsing  -> ASTContext arenas   (via GlobalDisambigTable)
    ///   Preprocessing         -> the ASTContext itself
    ///   Lexing                -> TokenCacheManager slot (tokens + imm table)
    ///   Loading               -> SourceManager file buffer
    ///
    /// The cascade is mandatory, not a convenience: AST nodes address
    /// identifiers by `imm` index into the fid's ImmediateTable, so an AST that
    /// outlived its tokens has unresolvable names. Releasing at Lexing
    /// therefore MUST take the AST with it, and this ordering is what
    /// guarantees it.
    ///
    /// \return false if nothing was released   unknown fid, or the guard below
    ///         refused.
    ///
    /// \note REFUSES while another loaded file still imports \p fid.
    ///       TranslationUnit::import_edges holds a *Decl into the imported
    ///       file's arena, so releasing it out from under a live importer
    ///       dangles those edges. Release leaves of the import graph first, or
    ///       release the whole batch.
    pub fn release(self, fid: u32, from: TUStage) -> bool {
        // A header TU is nobody's to reclaim alone: its decls are shared by
        // every importer through the ForeignRegistry, and tearing down its
        // context would dangle all of them. It lives as long as the build.
        if self.is_foreign_fid(fid) {
            kairo::Logger::warn(
                kairo::Logger::Stage::Driver,
                f"CompilerInstance::release: fid={fid} is an imported C++ header; refusing",
            )

            return false
        }

        if self._has_inbound_edges(fid) {
            kairo::Logger::warn(
                kairo::Logger::Stage::Driver,
                f"CompilerInstance::release: fid={fid} still imported by a live TU; refusing",
            )

            return false
        }

        var did = self._g_scope->release_from(fid, from)

        // The PP's walked-set has to die with the context, not with the fid.
        // Preprocessing is what CREATES the ASTContext and TranslationUnit, so
        // a fid still marked walked after its context is gone never gets them
        // back   the next parse returns a null ctx. This was masked for as long
        // as release(Loading) re-minted the fid on every pass; see
        // PreProcessor::forget.
        if (from as u8) <= (TUStage::Preprocessing as u8) {
            if self._pp != &null {
                did = self._pp->forget(fid) || did
            }
        }

        if (from as u8) <= (TUStage::Lexing as u8) {
            if self._tcm != &null {
                did = self._tcm->release(fid) || did
            }
        }

        if (from as u8) <= (TUStage::Loading as u8) {
            if self._sm != &null {
                did = self._sm->release(fid) || did
            }
        }

        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"CompilerInstance::release: fid={fid} released={did}",
        )

        return did
    }

    /// \brief re-reads \p fid from disk and drops everything derived from it.
    ///
    /// \details The edit path. Releases this fid's artifacts (AST, context,
    ///          tokens, imm table, walked mark, macros), then re-maps the file
    ///          so the next parse sees the new bytes.
    ///
    ///          Identity is KEPT: the fid, and every index keyed on it, is the
    ///          same afterwards. That is what makes an edit cheap   the rest of
    ///          the import graph keeps its mappings, line indices and (unless
    ///          separately released) its parsed state.
    ///
    ///          Releases at Lexing rather than Loading on purpose: Loading
    ///          would drop the SourceManager entry, and the file would come
    ///          back under a new fid on the next load, which is the churn this
    ///          whole path exists to avoid.
    ///
    /// \return false if \p fid is unknown, virtual, or could not be re-read.
    pub fn invalidate(self, fid: u32) -> bool {
        // Dependents FIRST, and this is not an optimization.
        //
        // Two independent reasons, either one fatal on its own:
        //
        //   1. release() REFUSES while another live TU imports this fid, because
        //      TranslationUnit::import_edges holds a *Decl into this file's
        //      arena. Releasing the importers is what clears that refusal.
        //   2. An importer's AST is DERIVED from this file: import edges point
        //      into its arena, and the parser resolved that file's generics and
        //      types through this file's hoisted DisambigTable. Once these bytes
        //      change, those ASTs describe text that no longer exists.
        //
        // Get this wrong and the failure is silent: the fid is stable, so the
        // buffer swaps underneath artifacts that still index into it by offset,
        // and every SourceRange into this file silently addresses different
        // text. Stale-but-coherent is recoverable; this is not.
        var dependents = self.transitive_importers(fid)

        // Importers can import each other, so a single sweep can hit a file
        // whose own importer has not gone yet and be refused. Repeat until a
        // full pass frees nothing   same shape as release_all.
        // Bounded by the worklist size: each sweep must free at least one more
        // file or there is nothing left to unblock, and a dependency chain can
        // be at most as long as the list. Belt-and-braces against a release()
        // that over-reports progress   an unbounded "until no progress" loop
        // over a FIXED list hangs outright if it ever does.
        var sweeps:  usize = 0
        var progress       = true
        while progress && sweeps <= dependents.size() {
            progress = false
            sweeps += 1
            for var d: u32 in dependents {
                if self.release(d, TUStage::Lexing) {
                    progress = true
                }
            }
        }

        // Only a REFUSAL aborts. release() returning false is ambiguous: it also
        // means "nothing to release", which is the normal state for a file whose
        // artifacts an earlier cascade already dropped   reparsing it again must
        // still work. Ask the guard directly instead of reading it off the
        // return value.
        if self._has_inbound_edges(fid) {
            // An importer we could not clear. Leave the bytes ALONE: a stale
            // parse is correct-if-old, whereas re-mapping now would leave live
            // artifacts describing replaced text.
            var ndep = dependents.size()
            kairo::Logger::warn(
                kairo::Logger::Stage::Driver,
                f"CompilerInstance::invalidate: fid={fid} still imported after releasing {ndep} dependent(s); not re-mapping",
            )

            return false
        }

        self.release(fid, TUStage::Lexing)

        if self._sm == &null {
            return false
        }

        return self._sm->invalidate(fid)
    }

    /// \brief fids whose TU holds a resolved import edge directly into \p fid.
    fn importers_of(self, fid: u32) -> cxx::std::vector<u32> {
        var out = cxx::std::vector<u32>()

        for var other: u32 in self._g_scope->all_fids() {
            if other == fid {
                continue
            }

            var unsafe *octx = self._g_scope->get_context(other)
            if octx == &null {
                continue
            }

            var unsafe *otu = octx->tu
            if otu == &null {
                continue
            }

            for var i: usize = 0; i < otu->import_edges.size(); ++i {
                var unsafe *e = otu->import_edges.get(i)
                if e == &null {
                    continue
                }

                if e->target_fid == fid {
                    out.push_back(other)
                    break
                }
            }
        }

        return out
    }

    /// \brief every fid that transitively imports \p fid, nearest first.
    ///
    /// \details The blast radius of changing \p fid's bytes. Transitive because
    ///          the dependency is transitive: if C imports B and B imports A,
    ///          C's AST was built against A's symbols through B.
    ///
    ///          Excludes \p fid itself. Cycle-safe   a fid already queued is
    ///          not queued again, so an import cycle terminates.
    pub fn transitive_importers(self, fid: u32) -> cxx::std::vector<u32> {
        var out  = cxx::std::vector<u32>()
        var seen = llvm::DenseSet<u64>() // membership only; `as u64` keeps clear of the reserved keys
        seen.insert(fid as u64)

        var frontier = cxx::std::vector<u32>()
        frontier.push_back(fid)

        while !frontier.empty() {
            var next = cxx::std::vector<u32>()

            for var f: u32 in frontier {
                for var imp: u32 in self.importers_of(f) {
                    if !seen.insert(imp as u64).second {
                        continue
                    }

                    out.push_back(imp)
                    next.push_back(imp)
                }
            }

            frontier = next
        }

        return out
    }

    /// \brief drops \p fid completely, identity included. See SourceManager::evict.
    ///
    /// \details For a deleted file or reclaiming memory   NOT for an edit. The
    ///          fid is retired; loading the same path afterwards mints a new one.
    fn evict(self, fid: u32) -> bool {
        self.release(fid, TUStage::Lexing)

        if self._sm == &null {
            return false
        }

        return self._sm->evict(fid)
    }

    /// \brief index-parses then full-parses a single \p fid, on this thread.
    ///
    /// \details The per-fid body of FrontendAction::_parse, without the fan-out.
    ///          The batch path spreads these across the pool and runs an ordered
    ///          diagnostic flusher behind them so a multi-file build reports in
    ///          fid order; with one file there is nothing to order or overlap,
    ///          and the caller drains the sink itself.
    ///
    /// \return false if \p fid has no context (not preprocessed).
    pub fn parse_one(self, fid: u32) -> bool {
        var unsafe *ctx = self._g_scope->get_context(fid)
        if ctx == &null {
            return false
        }

        var unsafe *gs = unsafe (self._g_scope as unsafe *GlobalDisambigTable)

        // Index first: the full parse disambiguates against the hoisted
        // table this builds. begin_index returns null if it is already
        // indexed, which is the case a reparse must NOT hit   release
        // cleared ctx->hoisted, so this rebuilds it.
        var unsafe *ictx = gs->begin_index(fid)
        if ictx != &null {
            var indexer = ASTParse(ictx, &null, gs, ASTParse::ParseMode::Index)
            indexer.index()
            gs->finish_index(fid)
        }

        var        parser     = ASTParse(ctx, &null, gs, ASTParse::ParseMode::Full)
        var unsafe *parsed_tu = parser.parse()
        ctx->tu = parsed_tu

        return true
    }

    /// \brief import edges of \p fid whose target has no live context.
    ///
    /// \details After a single-file reparse this counts imports the edit ADDED:
    ///          preprocess_one does not resolve them, so their targets were
    ///          never loaded. Non-zero means the unit is only partially
    ///          resolved and a full parse_file() is needed to make it whole.
    pub fn unresolved_import_count(self, fid: u32) -> usize {
        var unsafe *ctx = self._g_scope->get_context(fid)
        if ctx == &null {
            return 0
        }

        var unsafe *tu = ctx->tu
        if tu == &null {
            return 0
        }

        var n: usize = 0
        for var i: usize = 0; i < tu->import_edges.size(); ++i {
            var unsafe *e = tu->import_edges.get(i)
            if e == &null {
                continue
            }

            if e->target_fid == u32::MAX {
                n += 1
                continue
            }

            if self._g_scope->get_context(e->target_fid) == &null {
                n += 1
            }
        }

        return n
    }

    /// \brief true if any OTHER live context holds a resolved import edge into
    ///        \p fid.
    ///
    /// \details Lives here rather than on GlobalDisambigTable because walking
    ///          import_edges needs TranslationUnit, which that module cannot
    ///          import without a cycle.
    priv fn _has_inbound_edges(self, fid: u32) -> bool {
        var fids = self._g_scope->all_fids()

        for var other: u32 in fids {
            if other == fid {
                continue
            }

            var unsafe *octx = self._g_scope->get_context(other)
            if octx == &null {
                continue
            }

            var unsafe *otu = octx->tu
            if otu == &null {
                continue
            }

            for var i: usize = 0; i < otu->import_edges.size(); ++i {
                var unsafe *e = otu->import_edges.get(i)
                if e == &null {
                    continue
                }

                if e->target_fid == fid {
                    return true
                }
            }
        }

        return false
    }
}
