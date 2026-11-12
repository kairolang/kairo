/// --- The Kairo Project -------------------------- Tooling/LiveCheck.k --- ///
///
///   \brief One entry point, checked and kept: the API a process that stays
///          up calls when a file of the graph changes
///          (Compiler/Spec/IncrementalSema.md, phase 4).
///
///   check() type-checks the entry's graph. replace_file(path) says that
///   file's text changed (on disk, or through set_overlay) and brings the
///   result up to date. After either, the diagnostics are per file, as
///   objects (file_diags()), and flush() prints them as `kairo` would.
///
///   TODAY EVERY replace_file IS A FULL CHECK in a new CompilerInstance:
///   \c mode is always "full" and \c why says so. That is the fallback the
///   design keeps for whatever cannot be retracted soundly, made the only
///   path, so the API and its oracle (--incr-replay, and
///   Scripts/incr_replay_check.py which compares every step with a clean
///   run) exist before any reuse does. A step that re-checks in place has to
///   pass the same oracle; \c mode is where it will say what it did.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

ffi "c++" import "cstdio"
ffi "c++" import "cstdlib"
ffi "c++" import "csignal"
ffi "c++" import "chrono"
ffi "c++" import "Native/KShims.hh"
ffi "c++" import "Native/GlobalRecycler.hh"
ffi "c++" import "llvm/ADT/STLExtras.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/ADT/StringMap.h"

import Diagnostic::Diagnostic::Diagnostic
import Diagnostic::FileDiagnostics::FileDiagConsumer
import Diagnostic::Severity::DiagSeverity
import AST::Context::ASTContext::ASTContext
import Driver::CompilerInstance::CompilerInstance
import Driver::FrontendAction::FrontendAction
import Driver::TUStage::TUStage
import Resolution::ModulePath::ModulePath
import Support::FileIO::Path::Path
import API::FS::LinkFS
import Tooling::ParseAPI::{
    _apply_stop_at,
    release_all,
}
import std::io

/// Freed arena bytes from which a live check asks the allocator to give
/// its free pages back at once (kairo::heap_trim, a walk of the heap: a
/// few ms). Below it the pages are reused by the next edit anyway.
const LIVE_TRIM_BYTES: usize = 64 * 1024 * 1024

fn _live_us() -> i64 {
    var t = cxx::std::chrono::steady_clock::now()
    return cxx::std::chrono::duration_cast<cxx::std::chrono::microseconds>(t.time_since_epoch()).count() as i64
}

pub class LiveCheck {
    /// What the last check() / replace_file() did: "full" (every file
    /// checked, in a new CompilerInstance) is the only mode there is.
    pub var mode: string = ""
    pub var why:  string = ""
    /// The last step's counts.
    pub var errors:   u32   = 0
    pub var warnings: u32   = 0
    pub var files:    usize = 0
    /// Name the entry as the driver does (its module path under the -I
    /// roots), so a result equals `kairo`'s. kals checks a pathless entry
    /// and sets this false.
    pub var as_module: bool = true
    /// Re-check in place where it is sound: the edited file and every
    /// file that imports it, however far (the refresh set), against the
    /// rest of the graph as it stands. Off, every replace_file is a full
    /// check. \c mode is then "refresh" and \c why the set's size; an edit
    /// that cannot be re-checked in place is still "full", with the reason.
    pub var in_place: bool = false
    /// With \c in_place: replace_file re-checks the edited file alone (with
    /// the queued files it imports) and QUEUES the files that import it;
    /// drain() re-checks those, a slice at a time. \c pending is how many
    /// are queued. Until it is 0 the result is the edited files' new one and
    /// the queued files' old one; at 0 it is what a fresh run gives.
    pub var two_tier: bool  = false
    pub var pending:  usize = 0
    /// The last refresh's registry retraction: instances dropped (they
    /// named a declaration of the set) and re-armed (made live by the set).
    pub var dropped_instances: usize = 0
    pub var rearmed_instances: usize = 0
    /// Refuse to re-check in place when a kept C++ template instance was
    /// filled on behalf of a file of the refresh set: the fill runs once,
    /// for that file, and is not run again. Sound, and on a graph that
    /// uses C++ containers nearly every edit is then a full check. Off,
    /// such edits are re-checked in place, which the oracle has shown
    /// WRONG once (Compiler/Spec/IncrementalSema.md, "Known wrong result"):
    /// a tool that cannot run the oracle sets this.
    pub var strict_cxx: bool = false
    /// Kept C++ template shells the last refresh found filled for the set.
    pub var fills_owned: usize = 0
    /// More about why the last step was a full check, when there is more
    /// (which instance moved): for a log, not part of \c why.
    pub var detail: string = ""
    /// When set, the next step writes --dump-interface there.
    pub var dump_interface: string = ""

    priv var _words:   cxx::std::vector<string>
    priv var _ci:      unsafe *CompilerInstance = &null
    priv var _fd:      unsafe *FileDiagConsumer = &null
    priv var _action:  unsafe *FrontendAction   = &null
    priv var _pre:     usize                    = 0 ///< console diagnostics from before the check
    priv var _q:       cxx::std::vector<u32>        ///< two_tier: files queued, in Sema's order
    priv var _edited:  cxx::std::vector<u32>        ///< two_tier: files edited since the queue was last empty
    /// The files the last refresh re-checked, by name (empty after a full
    /// check: every file was).
    pub var rechecked: cxx::std::vector<string>
    /// A Tooling::SemaObserver for every file a step checks: all of them on
    /// a full check, the refresh set on a refresh. Installed in each new
    /// instance. A refresh that turns into a full check has called it for
    /// its set before the full check calls it for every file: a host reads
    /// \c mode before it uses what it collected.
    pub var observer: unsafe *void = &null

    /// Overlays, one slot per path. \c _ov_cur is the text the live
    /// instance VIEWS (the source manager does not copy): one heap string
    /// per slot, so its bytes never move and are freed only once the
    /// instance views something else. \c _ov_next is the text set since,
    /// which the next step that re-reads the file swaps in. \c _ov_gone: the
    /// overlay was cleared, the next step reads the disk. \c _ov_disk: the
    /// current text is this object's copy of the disk's (a file that was a
    /// buffer cannot go back to a mapping without a new fid).
    priv var _ov_path: cxx::std::vector<string>
    priv var _ov_cur:  cxx::std::vector<unsafe *string>
    priv var _ov_next: cxx::std::vector<unsafe *string>
    priv var _ov_gone: cxx::std::vector<u8>
    priv var _ov_disk: cxx::std::vector<u8>

    /// \param words  the compile command without its program name: the entry
    ///               and its flags. --type-check-only is added.
    pub fn LiveCheck(self, const words: cxx::std::vector<string>) {
        self._words = words
        self._words.push_back("--type-check-only")
    }

    @copy fn LiveCheck(self, const other: Self) = delete

    fn op finally (self) {
        self._drop()
        for var i: usize = 0; i < self._ov_path.size(); ++i {
            if self._ov_cur[i] != &null {
                kairo::std::destroy(self._ov_cur[i])
            }

            if self._ov_next[i] != &null {
                kairo::std::destroy(self._ov_next[i])
            }
        }
    }

    /// The first check of the entry's graph.
    pub fn check(self) -> bool {
        return self._full("the first check")
    }

    /// \p path's text changed. false when the command line was refused or
    /// names no entry; the diagnostics say which.
    pub fn replace_file(self, const path: string) -> bool {
        var why = "re-checking in place is not built"
        self.detail = ""
        self.rechecked.clear()
        if self.in_place {
            why = "no live check"
            if self._ci != &null && self._action != &null {
                if self.two_tier {
                    why = self._tier_begin(path)
                    if why.empty() && self._q.empty() {
                        why = self._tier_end()
                    }

                    if why.empty() {
                        self.pending = self._q.size()
                        self.why     = f"{self.rechecked.size()} of {self.files} files, {self.pending} pending"
                    }
                } else {
                    why = self._refresh(path)
                }
            }
        }

        if !why.empty() {
            return self._full(why)
        }

        self.mode = "refresh"
        self._count()
        return true
    }

    /// The files of an import edge list, as fids, sorted.
    priv fn _imports_of(self, fid: u32) -> cxx::std::vector<u32> {
        var out = cxx::std::vector<u32>()
        var unsafe *ctx = self._ci->global_scope()->get_context(fid)
        if ctx == &null || ctx->tu == &null {
            return out
        }

        for var i: usize = 0; i < ctx->tu->import_edges.size(); ++i {
            var unsafe *e = ctx->tu->import_edges.get(i)
            // The prelude edge is the driver's (injected when Sema
            // starts), not the text's.
            if e == &null || self._ci->is_foreign_fid(e->target_fid) {
                continue
            }

            if e->decl != &null && e->decl->is_prelude {
                continue
            }

            out.push_back(e->target_fid)
        }

        llvm::sort(out.begin(), out.end())
        return out
    }

    /// The refresh set of an edit of \p path (into \p set, the file first,
    /// with the files' names in \p names) and every reason it cannot be
    /// re-checked in place that is known before anything is touched. ""
    /// when it can be tried.
    priv fn _plan(self,
                  const path: string,
                  out_fid:    *u32,
                  set:        *cxx::std::vector<u32>,
                  names:      *cxx::std::vector<string>) -> string {
        var format = self._ci->invocation()->diag.format
        if format != "basic" && format != "json" {
            return "the pretty renderer coalesces across files"
        }

        if self._ci->invocation()->pp.prelude_path.size() > 0 || self._ci->invocation()->pp.force_includes.size() > 0 {
            return "--prelude or --force-include"
        }

        var fid = self._ci->sm()->find_fid(Path(path))
        *out_fid = fid
        if fid == u32::MAX {
            return "not a checked file of the graph"
        }

        var unsafe *ctx = self._ci->global_scope()->get_context(fid)
        if ctx == &null || ctx->tu == &null {
            return "not a checked file of the graph"
        }

        if self._ci->is_foreign_fid(fid) {
            return "a C or C++ header"
        }

        // The refresh set: the file and every file that imports it,
        // however far. Nothing outside it points into it. Over the graph's
        // edges turned round once: a core file's set is half the graph,
        // and asking each of its files who imports it walked every file
        // of the build per file.
        var rev    = self._importer_table()
        var in_set = llvm::DenseSet<u64>()
        var added  = cxx::std::vector<u32>()
        set->push_back(fid)
        in_set.insert(fid as u64)
        added.push_back(fid)
        self._grow(unsafe &rev, fid, set, unsafe &in_set, unsafe &added)

        // A file whose record a file of the set extends sees the
        // extension without importing it: it joins, with its importers.
        while !added.empty() {
            var extra = cxx::std::vector<u32>()
            self._action->refresh_extends(added, &extra)
            added.clear()
            for var x: u32 in extra {
                if in_set.contains(x as u64) {
                    continue
                }

                self._grow(unsafe &rev, x, set, unsafe &in_set, unsafe &added)
                in_set.insert(x as u64)
                set->push_back(x)
                added.push_back(x)
            }
        }

        var blocked = self._action->refresh_blocker(*set)
        if !blocked.empty() {
            return blocked
        }

        for var f: u32 in *set {
            if self._ci->global_scope()->is_builtin_fid(f) {
                return "a builtin file"
            }
        }

        // A diagnostic of one of the files that no Sema drain delivered
        // (the preprocessor's, the parser's) has no owner to replace it by.
        var is_name = llvm::StringMap<u32>()
        for var f: u32 in *set {
            names->push_back(self._ci->sm()->get_filename(f))
            is_name.try_emplace(kairo::sref(names->back()), 1 as u32)
        }

        for var i: usize = 0; i < self._fd->diags.size(); ++i {
            var unsafe *d = self._fd->diags[i]
            if !d->has_loc {
                continue
            }

            var at     = self._ci->sm()->get_filename(d->loc)
            var inside = is_name.find(kairo::sref(at)) != is_name.end()
            if self._fd->owners[i].empty() {
                if inside {
                    return "a diagnostic from before Sema"
                }

                continue
            }

            // A diagnostic a file of the set owns that is located outside
            // the set came out of an instance it was first to name. The
            // instance stays checked, so a re-check would not report it
            // again.
            var owner: string = self._fd->owners[i]
            var mine = is_name.find(kairo::sref(owner)) != is_name.end()
            if mine && !inside {
                return "a diagnostic from inside an instance"
            }
        }

        return ""
    }

    /// For each file id, the files with an import edge into it (any edge,
    /// as CompilerInstance::importers_of reads them).
    priv fn _importer_table(self) -> cxx::std::vector<cxx::std::vector<u32>> {
        var rev = cxx::std::vector<cxx::std::vector<u32>>()
        for var other: u32 in self._ci->global_scope()->all_fids() {
            var unsafe *octx = self._ci->global_scope()->get_context(other)
            if octx == &null || octx->tu == &null {
                continue
            }

            for var i: usize = 0; i < octx->tu->import_edges.size(); ++i {
                var unsafe *e = octx->tu->import_edges.get(i)
                if e == &null || e->target_fid == u32::MAX || e->target_fid == other {
                    continue
                }

                while rev.size() <= (e->target_fid as usize) {
                    rev.push_back(cxx::std::vector<u32>())
                }

                rev[e->target_fid as usize].push_back(other)
            }
        }

        return rev
    }

    /// Every file that imports \p root, however far, that \p in_set does
    /// not hold yet: appended to \p set and \p added, nearest first.
    priv fn _grow(self,
                  rev:    unsafe *cxx::std::vector<cxx::std::vector<u32>>,
                  root:   u32,
                  set:    *cxx::std::vector<u32>,
                  in_set: unsafe *llvm::DenseSet<u64>,
                  added:  unsafe *cxx::std::vector<u32>) {
        var frontier = cxx::std::vector<u32>()
        frontier.push_back(root)
        while !frontier.empty() {
            var next = cxx::std::vector<u32>()
            for var f: u32 in frontier {
                if (f as usize) >= rev->size() {
                    continue
                }

                for var imp: u32 in (*rev)[f as usize] {
                    if !in_set->insert(imp as u64).second {
                        continue
                    }

                    set->push_back(imp)
                    added->push_back(imp)
                    next.push_back(imp)
                }
            }

            frontier = next
        }
    }

    /// The diagnostics of the files \p names leave the per-file list and
    /// the engine (its duplicate filter, its counts, the poison scopes
    /// inside them): they go with the files' trees. Returns the size of
    /// the list afterwards.
    priv fn _forget(self, const names: cxx::std::vector<string>) -> usize {
        var is_name = llvm::StringMap<u32>()
        for var n: string in names {
            is_name.try_emplace(kairo::sref(n), 1 as u32)
        }

        // The files' diagnostics go with their trees.
        var kd = cxx::std::vector<unsafe *Diagnostic>()
        var ko = cxx::std::vector<string>()
        for var i: usize = 0; i < self._fd->diags.size(); ++i {
            var owner: string = self._fd->owners[i]
            if is_name.find(kairo::sref(owner)) == is_name.end() {
                kd.push_back(self._fd->diags[i])
                ko.push_back(owner)
            }
        }

        self._fd->diags  = kd
        self._fd->owners = ko

        // The engine forgets the files too: its duplicate filter, its
        // counts, and the poison scopes inside them.
        var scopes = self._ci->diag()->poison_scopes()
        var keep   = cxx::std::vector<u8>()
        for var i: usize = 0; i < scopes.size(); ++i {
            var at     = self._ci->sm()->get_filename(scopes[i].start)
            var inside = is_name.find(kairo::sref(at)) != is_name.end()
            keep.push_back(if (inside) => (0 as u8) else => (1 as u8))
        }

        self._ci->diag()->begin_recheck(&kd, &keep)
        return self._fd->diags.size()
    }

    /// Re-checks \p path's refresh set in place. "" when done (\c why then
    /// says how many files); otherwise the reason this edit takes a full
    /// check, with the instance possibly left half-refreshed: the caller
    /// replaces it.
    priv fn _refresh(self, const path: string) -> string {
        var fid: u32 = u32::MAX
        var set   = cxx::std::vector<u32>()
        var names = cxx::std::vector<string>()
        var no    = self._plan(path, &fid, &set, &names)
        if !no.empty() {
            return no
        }

        var old_imports = cxx::std::vector<cxx::std::vector<u32>>()
        var old_headers = cxx::std::vector<unsafe *void>()
        var mods        = cxx::std::vector<ModulePath>()
        for var f: u32 in set {
            old_headers.push_back(self._action->header_set_of(f))
            old_imports.push_back(self._imports_of(f))
            mods.push_back(self._ci->global_scope()->get_context(f)->module_base)
        }

        var n0 = self._forget(names)

        // Out of the instantiation registry, while the old trees can
        // still say which declarations are theirs.
        var rs = self._action->retract(set)
        self.dropped_instances = rs.dropped
        self.rearmed_instances = rs.rearmed
        self.fills_owned = rs.fills_owned
        if self.strict_cxx && rs.fills_owned > 0 {
            self.detail = f"{rs.fills_owned} such instances"
            return "a C++ template instance was first filled for an edited file"
        }

        // Importers first: no live tree may point into a file being re-read.
        for var i: usize = set.size(); i > 0; --i {
            if !self._reread(set[i - 1], names[i - 1], set[i - 1] == fid) {
                return "a file could not be re-read"
            }
        }

        for var i: usize = 0; i < set.size(); ++i {
            if !self._ci->pp()->preprocess_one(set[i], mods[i]) {
                return "the preprocessor refused a file"
            }
        }

        // Every hoisted table before any full parse: a file's parser reads
        // those of the files it imports, in whatever order they come here.
        for var i: usize = 0; i < set.size(); ++i {
            self._ci->index_one(set[i])
        }

        for var i: usize = 0; i < set.size(); ++i {
            if !self._ci->parse_one(set[i]) {
                return "a file did not parse"
            }

            var unsafe *nctx = self._ci->global_scope()->get_context(set[i])
            if nctx == &null || nctx->tu == &null {
                return "a file did not parse"
            }

            nctx->diag_sink.drain_into(self._ci->diag(), nctx->sm)
        }

        if self._fd->diags.size() != n0 {
            return "a diagnostic from before Sema"
        }

        // Another list of C or C++ headers is another header set, which
        // this instance never parsed.
        for var i: usize = 0; i < set.size(); ++i {
            if self._action->header_set_of(set[i]) != old_headers[i] {
                return "a C or C++ import was added or removed"
            }
        }

        for var i: usize = 0; i < set.size(); ++i {
            var now = self._imports_of(set[i])
            if now.size() != old_imports[i].size() || self._ci->unresolved_import_count(set[i]) > 0 {
                return "an import was added or removed"
            }

            for var k: usize = 0; k < now.size(); ++k {
                if now[k] != old_imports[i][k] {
                    return "an import was added or removed"
                }
            }
        }

        if !self.dump_interface.empty() {
            self._ci->invocation()->frontend.dump_interface = self.dump_interface
        }

        var moved = self._action->refresh(set)
        if !moved.empty() {
            self.detail = self._action->refresh_detail
            return moved
        }

        self.why = f"{set.size()} of {self.files} files"
        self.rechecked = names
        self._self_check()
        self._release_retired()
        return ""
    }

    /// KAIRO_LIVE_DEBUG: every file of the re-check is done, so nothing
    /// kept may name a replaced tree any more. Says so, or what does.
    priv fn _self_check(self) {
        if cxx::std::getenv(r"KAIRO_LIVE_DEBUG") == &null {
            return
        }

        var bad = self._action->verify_retired()
        io::eprintln(f"[live] self-check: {bad} of the purged stores' entries name a replaced tree ({self._ci->retired.size()} replaced trees held, {self._ci->retired_bytes() / 1048576} MB)")
        self._mem_report("re-check done")
    }

    /// \brief every file of every retraction is re-checked and the result
    ///        stands: the trees the re-checks replaced are freed, once
    ///        their addresses are out of the build-wide stores.
    ///
    /// \details KAIRO_LIVE_KEEP_RETIRED keeps them (what a live check did
    ///          before this was built: a way to rule the free out).
    ///          KAIRO_LIVE_POISON overwrites and keeps them instead, and
    ///          then searches the heap for a word that still points into
    ///          one: the use-after-free check, which the oracle runs under
    ///          (a stale read then reads 0xDD.., not a new tree's node).
    priv fn _release_retired(self) {
        if self._ci->retired.empty() || cxx::std::getenv(r"KAIRO_LIVE_KEEP_RETIRED") != &null {
            return
        }

        var dbg    = cxx::std::getenv(r"KAIRO_LIVE_DEBUG") != &null
        var poison = cxx::std::getenv(r"KAIRO_LIVE_POISON") != &null
        var dead   = kairo::AddrRanges()
        var own    = kairo::AddrRanges()
        own.label(kairo::std::to_std_string("a replaced tree's own"))
        self._ci->retired_ranges(unsafe &dead, unsafe &own, dbg || poison)
        var swept = self._action->sweep_retired(unsafe &dead)
        var n     = self._ci->retired.size()
        var bytes = self._ci->release_retired(poison)
        self.freed_files += n
        self.freed_bytes += bytes
        // A core file's set is a quarter of the process: back to the
        // system at once, not as later allocations happen to pass by (a
        // host reads the resident size; Analyzer/Tuning.k, LIVE_RSS_*).
        if bytes >= LIVE_TRIM_BYTES {
            kairo::heap_trim()
        }

        if dbg {
            io::eprintln(f"[live] {n} replaced trees freed ({bytes / 1048576} MB of arena blocks); swept {swept}")
            self._mem_report("replaced trees freed")
        }

        if (!poison) || (!dbg) {
            return
        }

        // Who points where: the kept trees and the two stores with an
        // arena of their own are named, the rest is "the heap".
        var where_ = kairo::AddrRanges()
        for var f: u32 in self._ci->global_scope()->all_fids() {
            var unsafe *c = self._ci->global_scope()->get_context(f)
            if c != &null {
                var nm = "the tree of " + self._ci->sm()->get_filename(f)
                c->ranges_into(unsafe &where_, where_.label(kairo::std::to_std_string(nm)))
            }
        }

        self._ci->global_scope()->types()->ranges_into(unsafe &where_, where_.label(kairo::std::to_std_string("the canonical types")))
        self._ci->global_scope()->instances()->ranges_into(unsafe &where_, where_.label(kairo::std::to_std_string("the instantiation registry")))
        where_.add(unsafe (self._ci as unsafe *const void), sizeof(CompilerInstance), where_.label(kairo::std::to_std_string("the CompilerInstance")))
        where_.add(unsafe (self._action as unsafe *const void), sizeof(FrontendAction), where_.label(kairo::std::to_std_string("the FrontendAction")))
        where_.add(unsafe (self._fd as unsafe *const void), sizeof(FileDiagConsumer), where_.label(kairo::std::to_std_string("the FileDiagConsumer")))
        where_.add(unsafe (self._ci->sm() as unsafe *const void), 256, where_.label(kairo::std::to_std_string("the SourceManager")))
        where_.add(unsafe (self._ci->diag() as unsafe *const void), 256, where_.label(kairo::std::to_std_string("the DiagEngine")))
        where_.add(unsafe (self._ci->pp() as unsafe *const void), 256, where_.label(kairo::std::to_std_string("the Preprocessor")))
        where_.add(unsafe (self._ci->global_scope() as unsafe *const void), 256, where_.label(kairo::std::to_std_string("the GlobalDisambigTable")))
        where_.seal()
        var total: usize = 0
        var rep = kairo::std::from_std_string<string>(kairo::heap_scan_report(dead, own, where_, 60, &total))
        self.dangling += total
        io::eprint(f"[live] heap scan: {rep}")

        // For a debugger: stop where the holders can still be read.
        if total > 0 && cxx::std::getenv(r"KAIRO_LIVE_SCAN_TRAP") != &null {
            cxx::std::fflush(kairo::std_err())
            cxx::std::raise(5) // SIGTRAP: a debugger stops here and goes on
        }
    }

    /// What _release_retired has freed since the last full check, and (under
    /// KAIRO_LIVE_POISON) how many words of the heap still pointed into a
    /// freed tree.
    pub var freed_files: usize = 0
    pub var freed_bytes: usize = 0
    pub var dangling:    usize = 0

    priv var _census: kairo::HeapCensus
    priv var _rss_kib: u64 = 0

    /// KAIRO_LIVE_DEBUG: where the process's memory is, and what moved
    /// since the last line.
    priv fn _mem_report(self, const what: string) {
        var now = kairo::HeapCensus()
        kairo::heap_census(&now)
        var rss = kairo::resident_kib() as u64
        var rb: usize = 0
        var rn: usize = 0
        kairo::GlobalRecycler::instance().stats(&rn, &rb)
        var d_use = ((now.in_use as i64) - (self._census.in_use as i64)) / 1024
        var d_rss = (rss as i64) - (self._rss_kib as i64)
        io::eprintln(f"[live] memory, {what}: resident {rss / 1024} MB ({d_rss} KB since), heap in use {now.in_use / 1048576} MB ({d_use} KB since) of {now.committed / 1048576} MB in pages, arena blocks recycled {rb / 1048576} MB; replaced trees: {if (self._ci != &null) => (self._ci->retired_profile()) else => "none"}")
        var delta = kairo::std::from_std_string<string>(kairo::heap_census_delta(self._census, now, 14))
        io::eprint(f"{delta}")
        self._census  = now
        self._rss_kib = rss
    }

    /// --- two tiers ---------------------------------------------------
    ///
    /// With \c two_tier an edit of F is two things. replace_file does the
    /// first: the whole refresh set leaves the build-wide stores (as one
    /// refresh does it), every file of it is queued (\c _q, kept in the
    /// order Sema runs files, an import cycle's members together:
    /// FrontendAction::group_order_of), and F is re-checked AT ONCE, with the queued
    /// files F imports before it. drain() does the second, a slice at a
    /// time: the rest of the queue, in order.
    ///
    /// THE RULE: a file is re-checked only when no file it imports,
    /// however far, is queued. Everything its Sema reads is then either
    /// kept (outside every refresh set) or already re-checked: a queued
    /// file still holds its old tree, which points at the replaced
    /// declarations of what it imports, and nothing reads it until its own
    /// turn. A queued file's diagnostics and rows stay as they were until
    /// then.

    /// The files \p fid imports, however far, that are queued; \p fid
    /// itself first.
    priv fn _closure(self, fid: u32) -> cxx::std::vector<u32> {
        var out  = cxx::std::vector<u32>()
        var seen = cxx::std::vector<u32>()
        var todo = cxx::std::vector<u32>()
        todo.push_back(fid)
        seen.push_back(fid)
        while !todo.empty() {
            var f = todo.back()
            todo.pop_back()
            if f == fid || self._queued(f) {
                out.push_back(f)
            }

            for var t: u32 in self._imports_of(f) {
                var have = false
                for var q: u32 in seen {
                    if q == t {
                        have = true
                    }
                }

                if !have {
                    seen.push_back(t)
                    todo.push_back(t)
                }
            }
        }

        return out
    }

    priv fn _queued(self, fid: u32) -> bool {
        for var q: u32 in self._q {
            if q == fid {
                return true
            }
        }

        return false
    }

    /// Re-checks \p target and the queued files it imports, in Sema's
    /// order, and takes them off the queue. \p edited: the file whose text
    /// changed (u32::MAX for a background slice).
    priv fn _tier_redo(self, target: u32, edited: u32) -> string {
        var group = self._action->order_of(self._closure(target))
        var names = cxx::std::vector<string>()
        var old_imports = cxx::std::vector<cxx::std::vector<u32>>()
        var old_headers = cxx::std::vector<unsafe *void>()
        var mods        = cxx::std::vector<ModulePath>()
        for var f: u32 in group {
            var unsafe *c = self._ci->global_scope()->get_context(f)
            if c == &null || c->tu == &null {
                return "not a checked file of the graph"
            }

            names.push_back(self._ci->sm()->get_filename(f))
            old_headers.push_back(self._action->header_set_of(f))
            old_imports.push_back(self._imports_of(f))
            mods.push_back(c->module_base)
        }

        // KAIRO_LIVE_DEBUG: a step of more than one file is an import
        // cycle (or an edited file with queued imports), which is what
        // cannot be pre-empted and what a first tier costs.
        if group.size() > 1 && cxx::std::getenv(r"KAIRO_LIVE_DEBUG") != &null {
            var all = ""
            for var n: string in names {
                all += " " + Path(n).filename()
            }

            io::eprintln(f"[live] one step of {group.size()} files:{all}")
        }

        var n0 = self._forget(names)
        for var i: usize = group.size(); i > 0; --i {
            if !self._reread(group[i - 1], names[i - 1], group[i - 1] == edited) {
                return "a file could not be re-read"
            }
        }

        for var i: usize = 0; i < group.size(); ++i {
            if !self._ci->pp()->preprocess_one(group[i], mods[i]) {
                return "the preprocessor refused a file"
            }
        }

        for var i: usize = 0; i < group.size(); ++i {
            self._ci->index_one(group[i])
        }

        for var i: usize = 0; i < group.size(); ++i {
            if !self._ci->parse_one(group[i]) {
                return "a file did not parse"
            }

            var unsafe *nctx = self._ci->global_scope()->get_context(group[i])
            if nctx == &null || nctx->tu == &null {
                return "a file did not parse"
            }

            nctx->diag_sink.drain_into(self._ci->diag(), nctx->sm)
        }

        if self._fd->diags.size() != n0 {
            return "a diagnostic from before Sema"
        }

        for var i: usize = 0; i < group.size(); ++i {
            if self._action->header_set_of(group[i]) != old_headers[i] {
                return "a C or C++ import was added or removed"
            }

            var now = self._imports_of(group[i])
            if now.size() != old_imports[i].size() || self._ci->unresolved_import_count(group[i]) > 0 {
                return "an import was added or removed"
            }

            for var k: usize = 0; k < now.size(); ++k {
                if now[k] != old_imports[i][k] {
                    return "an import was added or removed"
                }
            }
        }

        var moved = self._action->refresh(group)
        if !moved.empty() {
            self.detail = self._action->refresh_detail
            return moved
        }

        var rest = cxx::std::vector<u32>()
        for var q: u32 in self._q {
            var done = false
            for var f: u32 in group {
                if f == q {
                    done = true
                }
            }

            if !done {
                rest.push_back(q)
            }
        }

        self._q = rest
        for var n: string in names {
            self.rechecked.push_back(n)
        }

        return ""
    }

    /// The first tier of an edit of \p path.
    priv fn _tier_begin(self, const path: string) -> string {
        var fid: u32 = u32::MAX
        var set   = cxx::std::vector<u32>()
        var names = cxx::std::vector<string>()
        var dbg   = cxx::std::getenv(r"KAIRO_LIVE_DEBUG") != &null
        var t0    = _live_us()
        var no    = self._plan(path, &fid, &set, &names)
        if !no.empty() {
            return no
        }

        var t1 = _live_us()
        self._action->tiered = true
        var rs = self._action->retract(set)
        var t2 = _live_us()
        self.dropped_instances = rs.dropped
        self.rearmed_instances = rs.rearmed
        self.fills_owned = rs.fills_owned
        if self.strict_cxx && rs.fills_owned > 0 {
            self.detail = f"{rs.fills_owned} such instances"
            return "a C++ template instance was first filled for an edited file"
        }

        for var f: u32 in self._q {
            var have = false
            for var x: u32 in set {
                if x == f {
                    have = true
                }
            }

            if !have {
                set.push_back(f)
            }
        }

        self._q = self._action->group_order_of(set)
        self._edited.push_back(fid)
        var t3  = _live_us()
        var out = self._tier_redo(fid, fid)
        if dbg {
            io::eprintln(f"[live] first tier of {set.size()}: plan {t1 - t0} us, retract {t2 - t1} us, queue {t3 - t2} us, re-check {_live_us() - t3} us")
        }

        return out
    }

    /// The queue is empty: what one refresh of the whole set decides at
    /// its end.
    priv fn _tier_end(self) -> string {
        if !self.dump_interface.empty() {
            self._ci->invocation()->frontend.dump_interface = self.dump_interface
        }

        var why = self._action->tier_finish()
        self._edited.clear()
        if !why.empty() {
            self.detail = self._action->refresh_detail
        }

        self._self_check()
        if why.empty() {
            self._release_retired()
        }

        return why
    }

    /// \brief the second tier: re-checks queued files until \p max_files
    ///        more are done (a file's group is never split) or none is
    ///        left. \p prefer names files to do first, with what they
    ///        import (a tool's open buffers); the rest go in Sema's order.
    ///
    /// \return true while files are still queued. \c rechecked is what
    ///         this call re-checked, \c pending what is left; \c mode is
    ///         "full" when a slice could not be re-checked in place and
    ///         everything was (\c why says which reason).
    pub fn drain(self, max_files: usize, const prefer: cxx::std::vector<string>) -> bool {
        self.rechecked.clear()
        self.detail = ""
        if self._ci == &null || self._action == &null || self._q.empty() {
            self.pending = 0
            return false
        }

        var why = ""
        while (!self._q.empty()) && self.rechecked.size() < max_files && why.empty() {
            // Towards a preferred file, one step at a time: the first
            // queued file, in Sema's order, of what it imports. That file
            // imports nothing queued, so the step is one file (or one
            // cycle) and the caller gets to look up between steps; the
            // preferred file itself, with everything it imports, would be
            // one step of the whole queue when it is the entry.
            var target = self._q[0]
            for var i: usize = 0; i < prefer.size(); ++i {
                var pf = self._ci->sm()->find_fid(Path(prefer[i]))
                if pf != u32::MAX && self._queued(pf) {
                    // With the queued files that were first to use an
                    // instance it names: they keep their place before it
                    // (FrontendAction::prefer_first_users). When that
                    // cannot be arranged the queue's own order stands.
                    // KAIRO_LIVE_PREFER_UNORDERED: without that, as the
                    // control of the proof (the same scripts then take a
                    // full check where a first use moved).
                    var want = self._closure(pf)
                    var ok   = true
                    while ok && cxx::std::getenv(r"KAIRO_LIVE_PREFER_UNORDERED") == &null {
                        var first = cxx::std::vector<u32>()
                        ok = self._action->prefer_first_users(want, self._q, self._edited, &first)
                        if first.empty() {
                            break
                        }

                        for var x: u32 in first {
                            for var c: u32 in self._closure(x) {
                                var have = false
                                for var w: u32 in want {
                                    if w == c {
                                        have = true
                                    }
                                }

                                if !have {
                                    want.push_back(c)
                                }
                            }
                        }
                    }

                    if cxx::std::getenv(r"KAIRO_LIVE_DEBUG") != &null {
                        var how = if (ok) => (f"{want.size()} queued files are its") else => "an instance it names has no first user yet, the queue's order stands"
                        io::eprintln(f"[live] prefer {Path(prefer[i]).filename()}: {how}; next in order is {Path(self._ci->sm()->get_filename(self._q[0])).filename()}")
                    }

                    if !ok {
                        break
                    }

                    var hit = false
                    for var q: u32 in self._q {
                        for var w: u32 in want {
                            if w == q {
                                hit = true
                            }
                        }

                        if hit {
                            target = q
                            break
                        }
                    }

                    break
                }
            }

            why = self._tier_redo(target, u32::MAX)
        }

        if why.empty() && self._q.empty() {
            why = self._tier_end()
        }

        if !why.empty() {
            self._full(why)
            return false
        }

        self.mode    = "refresh"
        self.pending = self._q.size()
        self.why     = f"{self.rechecked.size()} of {self.files} files, {self.pending} pending"
        self._count()
        return !self._q.empty()
    }

    priv fn _slot(self, const path: string) -> usize {
        for var i: usize = 0; i < self._ov_path.size(); ++i {
            if self._ov_path[i] == path {
                return i
            }
        }

        return usize::MAX
    }

    /// Detaches \p fid and gives it the text it is re-checked from: the
    /// overlay set since the last step, the disk when the overlay was
    /// cleared (or the file never had one), and for a buffer nothing
    /// changed (an importer of the edited file) the bytes it has.
    priv fn _reread(self, fid: u32, const name: string, edited: bool) -> bool {
        var k = self._slot(name)
        var next: unsafe *string = &null
        var from_disk = false
        if k != usize::MAX && self._ov_next[k] != &null {
            next = self._ov_next[k]
        } else if k != usize::MAX && self._ov_cur[k] != &null {
            // A buffer, or this object's copy of the disk.
            if self._ov_gone[k] != 0 || (edited && self._ov_disk[k] != 0) {
                var text = ""
                if !LinkFS::read(name, &text) {
                    self._ci->detach_for_refresh(fid, &null, 0, false, false)
                    return false
                }

                next      = kairo::std::create<string>(text)
                from_disk = true
            } else {
                return self._ci->detach_for_refresh(fid, &null, 0, false, false)
            }
        } else {
            // The disk's own mapping.
            return self._ci->detach_for_refresh(fid, &null, 0, true, false)
        }

        var unsafe *bytes = unsafe ((next->raw() as unsafe *const u8) as kairo::std::ConstPtr<u8>)
        var ok = self._ci->detach_for_refresh(fid, bytes, next->size(), false, true)
        if !ok {
            if from_disk {
                kairo::std::destroy(next)
            }

            return false
        }

        // Only now: the instance viewed the old text until the swap.
        if self._ov_cur[k] != &null {
            kairo::std::destroy(self._ov_cur[k])
        }

        self._ov_cur[k]  = next
        self._ov_next[k] = &null
        self._ov_gone[k] = (0 as u8)
        self._ov_disk[k] = if (from_disk) => (1 as u8) else => (0 as u8)
        return true
    }

    /// The counts of the result as it stands, from the per-file list.
    priv fn _count(self) {
        self.errors   = 0
        self.warnings = 0
        for var i: usize = 0; i < self._fd->diags.size(); ++i {
            var sev = self._fd->diags[i]->code.severity()
            if sev == DiagSeverity::Error || sev == DiagSeverity::Fatal {
                self.errors += 1
            } else if sev == DiagSeverity::Warning {
                self.warnings += 1
            }
        }
    }

    /// The bytes to read wherever \p path would be read, from the next
    /// check() or replace_file() that re-reads it on: a refresh whose set
    /// holds the file, or any full check. Copied.
    pub fn set_overlay(self, const path: string, const text: string) {
        var k = self._slot(path)
        if k == usize::MAX {
            self._ov_path.push_back(path)
            self._ov_cur.push_back(&null)
            self._ov_next.push_back(&null)
            self._ov_gone.push_back(0 as u8)
            self._ov_disk.push_back(0 as u8)
            k = self._ov_path.size() - 1
        }

        if self._ov_next[k] != &null {
            kairo::std::destroy(self._ov_next[k])
        }

        self._ov_next[k] = kairo::std::create<string>(text)
        self._ov_gone[k] = (0 as u8)
    }

    /// \p path is read from the disk again, from the next step that
    /// re-reads it on.
    pub fn clear_overlay(self, const path: string) {
        var k = self._slot(path)
        if k == usize::MAX {
            return
        }

        if self._ov_next[k] != &null {
            kairo::std::destroy(self._ov_next[k])
            self._ov_next[k] = &null
        }

        self._ov_gone[k] = (1 as u8)
    }

    /// Has \p path an overlay set and not yet read, or one cleared and not
    /// yet dropped?
    pub fn overlay_pending(self, const path: string) -> bool {
        var k = self._slot(path)
        return k != usize::MAX && (self._ov_next[k] != &null || self._ov_gone[k] != 0)
    }

    /// Every file of the checked graph, by name, the entry first (as
    /// Tooling::ParsedUnit::fids names them).
    pub fn graph_files(self) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        if self._ci == &null || self._action == &null {
            return out
        }

        for var f: u32 in self._action->fids() {
            out.push_back(self._ci->sm()->get_filename(f))
        }

        return out
    }

    /// What the re-checks have replaced and still hold: the old trees of
    /// the files re-checked since the queue was last empty (their AST
    /// arenas' bytes, and how many trees). They are freed when the queue
    /// empties (_release_retired); until then a queued file's old tree may
    /// point into one.
    pub fn retired_bytes(self) -> usize {
        if self._ci == &null {
            return 0
        }

        return self._ci->retired_bytes()
    }

    pub fn retired_files(self) -> usize {
        if self._ci == &null {
            return 0
        }

        return self._ci->retired.size()
    }

    /// The live instance; null before check() and after a refused command.
    pub fn ci(self) -> unsafe *CompilerInstance {
        return self._ci
    }

    /// Every diagnostic of the current result with its owning file. The
    /// objects die with the next check() / replace_file().
    pub fn file_diags(self) -> unsafe *FileDiagConsumer {
        return self._fd
    }

    /// Prints the current result's diagnostics as `kairo` does at its end.
    pub fn flush(self) {
        if self._ci == &null {
            return
        }

        if self.mode == "full" {
            self._ci->flush_errors()
            return
        }

        // After a refresh the console consumer still holds the replaced
        // files' old diagnostics: the per-file list is the result, printed
        // as a run delivers it: what the instance reported while it was
        // set up, the driver's own, then each file's in the order the files
        // were first drained.
        io::eprint(f"{self._ci->incr_diag_text(0, self._pre)}")
        for var i: usize = 0; i < self._fd->diags.size(); ++i {
            if self._fd->owners[i].empty() {
                io::eprint(f"{self._ci->incr_render(self._fd->diags[i])}")
            }
        }

        for var k: usize = 0; k < self._fd->order.size(); ++k {
            for var i: usize = 0; i < self._fd->diags.size(); ++i {
                if self._fd->owners[i] == self._fd->order[k] {
                    io::eprint(f"{self._ci->incr_render(self._fd->diags[i])}")
                }
            }
        }

        cxx::std::fflush(kairo::std_err())
    }

    priv fn _drop(self) {
        if self._ci == &null {
            return
        }

        if self._fd != &null {
            self._ci->diag()->remove_consumer(self._fd)
        }

        if self._action != &null {
            kairo::std::destroy(self._action)
            self._action = &null
        }

        // A check that stops at Sema never reaches the driver's header
        // release (FrontendAction::run does it before codegen), and the
        // instance's end does not free the sets' clang ASTs.
        if self._ci->headers() != &null {
            self._ci->headers()->release_all()
        }

        // Every tree, token run and buffer the check made: nothing else
        // reclaims them before the instance dies, and its end leaves some.
        release_all(self._ci, TUStage::Lexing)
        // The trees re-checks replaced and kept (a re-check that turned
        // into this full check): nothing of the instance outlives it.
        self._ci->release_retired(false)
        self._ci->diag()->clear_retained()
        kairo::std::destroy(self._ci)
        self._ci = &null
        if self._fd != &null {
            kairo::std::destroy(self._fd)
            self._fd = &null
        }
    }

    priv fn _full(self, const why: string) -> bool {
        var dbg = cxx::std::getenv(r"KAIRO_LIVE_DEBUG") != &null
        if cxx::std::getenv(r"KAIRO_LIVE_POISON") != &null {
            // Before the first arena: see GlobalRecycler::scrub.
            kairo::GlobalRecycler::scrub.store(true)
        }

        // Where a destroyed instance's memory is: handed back to the
        // arena recycler (and taken again by the next check), still in use
        // in the C heap, or neither (Compiler/Spec/IncrementalSema.md,
        // "What a destroyed instance keeps").
        if dbg {
            var rb: usize = 0
            var rn: usize = 0
            kairo::GlobalRecycler::instance().stats(&rn, &rb)
            io::eprintln(f"[live] before the old instance goes: resident {kairo::resident_kib() / 1024} MB, heap in use {kairo::heap_in_use_kib() / 1024} MB, arena blocks recycled {rb / 1048576} MB")
        }

        self._drop()
        if dbg {
            var rb: usize = 0
            var rn: usize = 0
            kairo::GlobalRecycler::instance().stats(&rn, &rb)
            io::eprintln(f"[live] after it went: resident {kairo::resident_kib() / 1024} MB, heap in use {kairo::heap_in_use_kib() / 1024} MB, arena blocks recycled {rb / 1048576} MB")
            self._ci = &null
            self._mem_report("the old instance destroyed")
        }

        self._q.clear()
        self._edited.clear()
        self.pending  = 0
        self.mode     = "full"
        self.why      = why
        self.errors   = 0
        self.warnings = 0
        self.files    = 0
        var words = self._words
        self._ci = kairo::std::create<CompilerInstance>(words)
        if !self._ci->args_ok() {
            return false
        }

        self._ci->initialize(Path::cwd())
        var inputs = self._ci->invocation()->input_files
        if inputs.empty() {
            return false
        }

        // What the instance reported while it was set up (a note about the
        // toolchain) is before the per-file list and is printed before it.
        self._pre = self._ci->incr_diag_count()
        self._fd  = kairo::std::create<FileDiagConsumer>()
        self._ci->diag()->add_consumer(self._fd)
        self._ci->invocation()->frontend.file_diags = unsafe (self._fd as unsafe *void)
        if !self.dump_interface.empty() {
            self._ci->invocation()->frontend.dump_interface = self.dump_interface
        }

        // The source manager keeps a VIEW of an overlay's bytes: they are
        // this object's, one heap string each, and are not touched while
        // the instance views them. The old instance is gone, so every
        // staged text is the current one from here.
        for var i: usize = 0; i < self._ov_path.size(); ++i {
            if self._ov_next[i] != &null || self._ov_gone[i] != 0 || self._ov_disk[i] != 0 {
                if self._ov_cur[i] != &null {
                    kairo::std::destroy(self._ov_cur[i])
                }

                self._ov_cur[i]  = self._ov_next[i]
                self._ov_next[i] = &null
                self._ov_gone[i] = (0 as u8)
                self._ov_disk[i] = (0 as u8)
            }

            if self._ov_cur[i] == &null {
                continue
            }

            var unsafe *bytes = unsafe ((self._ov_cur[i]->raw() as unsafe *const u8) as kairo::std::ConstPtr<u8>)
            self._ci->sm()->stage_overlay(Path(self._ov_path[i]), bytes, self._ov_cur[i]->size())
        }

        self._ci->invocation()->frontend.sema_observer = self.observer

        // parse_file's steps, with the action kept: a refresh runs Sema
        // again through it.
        self._ci->invocation()->frontend.live_check = true
        // The interface facts of every file: a refresh compares a re-read
        // record's layout with the one it had (FrontendAction::refresh).
        self._ci->invocation()->frontend.incremental_sema = true
        _apply_stop_at(self._ci, TUStage::Sema)
        var mp = ModulePath()
        if self.as_module {
            mp = self._ci->input_module_path(Path(inputs[0]).full_path())
        }

        self._action = kairo::std::create<FrontendAction>(
            Path(inputs[0]),
            mp,
            self._ci->global_scope(),
            self._ci->imp(),
            self._ci,
        )

        self._action->run()
        self.errors   = self._ci->diag()->error_count()
        self.warnings = self._ci->diag()->warn_count()
        self.files    = self._action->fids().size()
        return true
    }
}
