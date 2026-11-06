/// --- The Kairo Project ------------------- Interop/Clang/HeaderSet.k --- ///
///
///   \brief Phase A of C++ header import: one clang parse per distinct
///          ORDERED header set, producing (a) a live clang AST that
///          Sema/Foreign walks and M2 queries. Phase B (codegen) loads
///          the merged CodegenPCH built from the sets' text instead.
///
///   \par Lifecycle
///     request()  driver thread, from PPWalker::_finalize. Mints the set,
///                enqueues build() on the pool (HEADER_BUILD_GROUP). Returns
///                at once; the build overlaps parse + sema of the importer.
///     build()    pool thread. Clang parse (a TU prefix). The instance is
///                kept ALIVE (BeginSourceFile + Execute, no EndSourceFile):
///                the ASTContext and Sema are what HeaderIndex walks and
///                what M2 asks for template members.
///     index()    driver thread, from FrontendAction::_sema after
///                wait_group(HEADER_BUILD_GROUP). Mints one Kairo fid per
///                header IN THE ORDER CLANG TOUCHED THEM, then hands the
///                AST to Sema::Foreign::HeaderIndex. Runs once per set.
///     release()  driver thread, after the last importing TU passes
///                Checked. EndSourceFile, instance destroyed, PCH bytes and
///                the include tree kept for phase B.
///
///   \par Locations
///     Header locs map to Kairo locs by FILE IDENTITY: `cfid_to_kfid` is
///     built at index() from the FileEntry behind each clang FileID we saw
///     enter. It is the ONE table where a clang FileID meets a Kairo fid.
///     Everything clang mints that is not a file (scratch buffers,
///     <built-in>) has no row and maps to an invalid loc. If that ever needs
///     to change, this table is the only thing to widen.
///
///   \par Threading
///     build() touches only its own CompilerInstance. Nothing here calls the
///     Kairo SourceManager / TCM / GlobalDisambigTable off the driver thread.
///     M2's on-demand instantiation goes through sema_lock().
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringMap.h";
ffi "c++" import "llvm/Support/FileSystem.h";
ffi "c++" import "llvm/Support/Path.h";
ffi "c++" import "llvm/ADT/SmallString.h";
ffi "c++" import "cstring";
ffi "c++" import "llvm/ADT/STLExtras.h";
ffi "c++" import "llvm/ADT/DenseMap.h";
ffi "c++" import "Native/Types.hh";
ffi "c++" import "Native/KShims.hh";   // header_set_late_uses
ffi "c++" import "clang/AST/ASTContext.h";
ffi "c++" import "clang/AST/ASTConsumer.h";
ffi "c++" import "clang/Basic/Diagnostic.h";
ffi "c++" import "clang/Basic/DiagnosticOptions.h";
ffi "c++" import "clang/Basic/FileEntry.h";
ffi "c++" import "clang/Basic/SourceManager.h";
ffi "c++" import "clang/Basic/TargetInfo.h";
ffi "c++" import "clang/Frontend/CompilerInstance.h";
ffi "c++" import "clang/Frontend/CompilerInvocation.h";
ffi "c++" import "clang/Frontend/FrontendAction.h";
ffi "c++" import "clang/Frontend/FrontendOptions.h";
ffi "c++" import "clang/Frontend/TextDiagnosticPrinter.h";
ffi "c++" import "clang/Lex/HeaderSearchOptions.h";
ffi "c++" import "clang/Lex/PPCallbacks.h";
ffi "c++" import "clang/Lex/Preprocessor.h";
ffi "c++" import "clang/Sema/Sema.h";
ffi "c++" import "clang/Serialization/ASTWriter.h";
ffi "c++" import "clang/Serialization/PCHContainerOperations.h";
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h";
ffi "c++" import "llvm/Support/Error.h";
ffi "c++" import "llvm/Support/MemoryBuffer.h";
ffi "c++" import "llvm/Support/VirtualFileSystem.h";
ffi "c++" import "llvm/Support/raw_ostream.h";

import Location::SourceManager::*;
import Support::FileIO::Path::*;
import Support::TimeReport::*;
import Interop::Clang::ClangBackend::*;
import Diagnostic::Engine::*;
import Diagnostic::BufferedDiagSink::*;
import Diagnostic::ClangDiagAdapter::*;

/// ThreadPool group for phase-A builds. 9 is CLANG_STARTUP_GROUP.
eval fn HEADER_BUILD_GROUP() -> u8 { return 10; }
/// The merged codegen PCH's early build (HeaderSetCache::prebuild_codegen_pch).
eval fn CODEGEN_PCH_GROUP() -> u8 { return 12; }

/// One header clang ENTERED during the parse, in first-touch order. The
/// FileID is the phase-A instance's and is only meaningful while it lives.
struct HeaderFile {
    var path:      string;      ///< real path (FileEntry name), the key into the Kairo SM.
    var cfid_hash: u32;         ///< clang::FileID::getHashValue() in the phase-A SM.
    var kfid:      u32 = 0;     ///< Kairo fid, minted at index(); 0 until then.
    var is_system: bool = false;
}

/// One `#include` edge, for the transitive closure `ffi import "c2.h"` folds.
struct IncludeEdge {
    var from_path: string;      ///< "" for the injected main (a direct import).
    var to_path:   string;
    var c_linkage: bool = false;   ///< a direct import written `ffi "c"`: phase B re-wraps it in extern "C".
}

/// Stage 0 forward: both classes below name HeaderSet before it is defined,
/// and one undeclared name there makes each of them ill-formed.
class HeaderSet;

/// Records what clang touched. Fires on the parse thread; writes only into
/// the owning set's vectors, which nothing reads until wait_group returns.
class HeaderSetPPCallbacks derives clang::PPCallbacks {
    pub var _set: obs::<HeaderSet>;
    pub var csm: obs::<clang::SourceManager>;

    override fn FileChanged(self, loc: clang::SourceLocation, reason: clang::PPCallbacks::FileChangeReason,
                            kind: clang::SrcMgr::CharacteristicKind, prev: clang::FileID);

    override fn InclusionDirective(self, hash_loc: clang::SourceLocation, include_tok: cref::<clang::Token>,
                                   file_name: llvm::StringRef, is_angled: bool,
                                   filename_range: clang::CharSourceRange,
                                   file: clang::OptionalFileEntryRef,
                                   search_path: llvm::StringRef, relative_path: llvm::StringRef,
                                   suggested_module: const_obs::<clang::Module>, module_imported: bool,
                                   file_type: clang::SrcMgr::CharacteristicKind);
}

/// The action: a plain ASTConsumer (no PCH, P380), TU_Prefix like GeneratePCHAction,
/// our callbacks installed before the parse. BeginSourceFile + Execute are
/// called by HeaderSet::build; EndSourceFile by HeaderSet::release.
class HeaderSetAction derives clang::ASTFrontendAction {
    pub var _set: obs::<HeaderSet>;

    override fn CreateASTConsumer(self, ci: ref!(clang::CompilerInstance), in_file: llvm::StringRef)
            -> libcxx::unique_ptr::<clang::ASTConsumer>;
    override fn getTranslationUnitKind(self) -> clang::TranslationUnitKind;
    override fn BeginSourceFileAction(self, ci: ref!(clang::CompilerInstance)) -> bool;
}

///
/// \class HeaderSet
/// \brief One distinct ordered header list -> one clang parse.
///
class HeaderSet {
    pub var key:      string;                 ///< headers joined by '\n', in source order, deduped.
    pub var headers:  vec::<string>;          ///< as spelled in the .k files.
    /// Parallel to `headers`: imported as `ffi "c"`. The set is parsed as C++,
    /// so a C header is included inside `extern "C" { }`; one that guards
    /// itself with `#ifdef __cplusplus` is unaffected, one that does not
    /// would otherwise get C++ linkage and never link against its C object.
    pub var c_linkage: vec::<bool>;
    pub var import_dir: string;               ///< directory of the first importing file: `-I` for quoted includes.
    /// Parallel to `headers`: the first importer's header-string span.
    pub var header_locs: vec::<SourceRange>;
    pub var id:       u32 = 0;                ///< cache-assigned, dense; names the PCH mount.

    // Filled by build() on the pool thread.
    pub var files:    vec::<HeaderFile>;      ///< every header entered, first-touch order.
    pub var includes: vec::<IncludeEdge>;
    pub var pch:      libcxx::shared_ptr::<clang::PCHBuffer>;
    pub var built:    std::Atomic::<bool> = false;
    pub var ok:       bool = false;

    // Filled by index() on the driver thread.
    pub var indexed:  bool = false;
    /// Phase B: the PCH bytes are in the backend's in-memory VFS at
    /// pch_path(). Once per set for the build; CodegenBackend::run sets it.
    pub var mounted:  bool = false;
    /// clang FileID hash -> Kairo fid. THE table.
    ///
    /// The key is the u32 hash WIDENED to u64. A FileID loaded from a PCH is
    /// negative (-2, -3, ...) and its hash is that int as unsigned, so u32
    /// keys reach 0xFFFFFFFE / 0xFFFFFFFF -- DenseMap<u32>'s tombstone and
    /// empty keys. Zero-extended to u64 they can never be ~0 / ~0-1.
    pub var cfid_to_kfid: llvm::DenseMap::<u64, u32>;

    // The live phase-A instance.
    priv var _ci:      opt::<clang::CompilerInstance> = &null;
    priv var _act:     opt::<HeaderSetAction>         = &null;
    /// BeginSourceFile succeeded. EndSourceFile on an action that never began
    /// walks a half-built Preprocessor, so release() must not pair blindly.
    priv var _began:   bool                           = false;
    priv var _printer: opt::<clang::TextDiagnosticPrinter> = &null;   ///< fallback client only; see begin_diag.
    priv var _ksm:     obs::<SourceManager> = &null;                  ///< the backend's; adapter spans.

    /// build()'s clang diagnostics. build() runs on a pool thread before any
    /// importer exists, so they buffer here and the driver drains them into
    /// its engine once the build has joined (drain_diags).
    pub var diag_buf:  BufferedDiagSink;
    priv var _clients: vec::<*clang::DiagnosticConsumer>;   ///< begin_diag's saved clients, innermost last.
    priv var _diag_opts: clang::DiagnosticOptions;
    priv var _main:    libcxx::string;                ///< the injected buffer; must outlive the parse.
    /// <injected> line - 1 -> the .k import that line includes; invalid for
    /// the extern "C" brace lines. The adapter's only way back from the
    /// buffer to Kairo source: without it every bad include is <injected>:1:10.
    priv var _main_locs: vec::<SourceRange>;
    /// clang::Sema is single-threaded. Recursive because a foreign fill can
    /// nest: importing one instance's members resolves a type path into
    /// another instance of the same set, and the outer fill still holds this.
    priv var _sema_mu: std::RecursiveMutex;

    /// closure_of / kfid_of_path indexes, built on their first call (driver
    /// thread, after index(): `files` and `includes` are final by then).
    /// The linear scans they replace were O(files x edges) per ffi import,
    /// about 10 s of serial driver time over the self-host graph.
    priv var _idx_built: bool = false;
    priv var _file_at:   llvm::StringMap::<u32>;          ///< path -> first index in `files`.
    priv var _out_edges: llvm::StringMap::<vec::<u32>>;   ///< from_path -> indices in `includes`, in order.
    /// The include graph by node number, for closure_kfids' walk: a node per
    /// distinct path, its edges' target nodes in include order, and its kfid
    /// (kfid_of_path, 0 when none). Built with the maps above.
    priv var _node_of:   llvm::StringMap::<u32>;
    priv var _node_out:  vec::<vec::<u32>>;
    priv var _node_path: vec::<string>;
    priv var _closure_memo: llvm::StringMap::<vec::<u32>>;  ///< spelled header -> closure_kfids' answer.

    fn HeaderSet(self) {
        self.pch = libcxx::make_shared::<clang::PCHBuffer>();
    }

    fn op delete (self) { self.release(); }

    // --- Accessors (valid between build() and release()) --------------------

    fn ast(self)  -> *clang::ASTContext {
        // Any use after indexing (a fill or a deduction retry through this
        // set, TypeExport stand-ins) may leave pointers into this AST: pin it.
        if self.indexed { self.contributed = true; }
        if (self._ci == &null) && (!self._revive()) { HeaderSet::_note_late(self.released); return &null; }
        if !self._ci->hasASTContext() { return &null; }
        return &(self._ci->getASTContext());
    }
    fn sema(self) -> *clang::Sema {
        // Any use after indexing (a fill or a deduction retry through this
        // set, TypeExport stand-ins) may leave pointers into this AST: pin it.
        if self.indexed { self.contributed = true; }
        if (self._ci == &null) && (!self._revive()) { HeaderSet::_note_late(self.released); return &null; }
        if !self._ci->hasSema() { return &null; }
        return &(self._ci->getSema());
    }
    fn csm(self)  -> *clang::SourceManager {
        // Any use after indexing (a fill or a deduction retry through this
        // set, TypeExport stand-ins) may leave pointers into this AST: pin it.
        if self.indexed { self.contributed = true; }
        if (self._ci == &null) && (!self._revive()) { HeaderSet::_note_late(self.released); return &null; }
        return &(self._ci->getSourceManager());
    }
    fn alive(self) -> bool {
        if self._ci == &null { self._revive(); }
        return self._ci != &null;
    }

    /// Set by HeaderIndex::index: this set minted a header TU or declared a
    /// decl, so imported decls point into its AST. One that did neither (85
    /// of the self-host graph's 115) is released right after indexing
    /// (release_unused) and only re-parsed if something asks for its AST.
    /// P417: this set is a VIEW (one TU list) whose headers were parsed as
    /// part of the build's one shared set; null for a set parsed itself.
    pub var shared: obs::<HeaderSet> = &null;
    pub var contributed: bool = true;
    pub var revivable:   bool = false;
    priv var _be_saved:  obs::<ClangBackend> = &null;
    priv var _macros:      llvm::StringMap::<bool>;   ///< release_unused's macro snapshot (names defined).
    priv var _macros_kept: bool = false;

    /// macro_defined() can answer: a live instance, or a released one's
    /// snapshot. EvalIfFolding asks this instead of alive(), which revives.
    fn macros_known(self) -> bool { return (self._ci != &null) || self._macros_kept || self.revivable; }

    /// MEM_STATS: the live instance's ASTContext bytes (AST + side tables),
    /// 0 when released. Never revives.
    fn ast_bytes(self) -> usize {
        if (self._ci == &null) || (!self._ci->hasASTContext()) { return 0; }
        var a = &(self._ci->getASTContext());
        return a->getASTAllocatedMemory() + a->getSideTableAllocatedMemory();
    }

    /// MEM_STATS: the live instance's file buffers (heap-read and mmapped),
    /// SourceManager tables and Preprocessor, in bytes; zeros when released.
    fn other_bytes(self, malloc_buf: *usize, mmap_buf: *usize, sm_tab: *usize, pp: *usize) {
        if self._ci == &null { return; }
        if self._ci->hasSourceManager() {
            var sm = &(self._ci->getSourceManager());
            var mb = sm->getMemoryBufferSizes();
            (*malloc_buf) += mb.malloc_bytes;
            (*mmap_buf)   += mb.mmap_bytes;
            (*sm_tab)     += sm->getDataStructureSizes();
        }
        if self._ci->hasPreprocessor() { (*pp) += self._ci->getPreprocessor().getTotalMemory(); }
    }

    /// Frees this set's clang instance after HeaderIndex took nothing from
    /// it; the include graph, file list and fid map stay. Driver thread.
    fn release_unused(self) {
        if self.contributed || (!self.ok) || (self._ci == &null) { return; }
        // `defined!` (EvalIfFolding) asks a TU's own set for its macros, and
        // most sets are some TU's own: keep the names defined at the end of
        // the parse, so that question never re-parses the set.
        if self._ci->hasPreprocessor() {
            var pp = &(self._ci->getPreprocessor());
            for var it = pp->macro_begin(true); it != pp->macro_end(true); ++it {
                var ii = it->first;
                if (ii != &null) && pp->isMacroDefined(ii) { self._macros.try_emplace(ii->getName(), true); }
            }
            self._macros_kept = true;
        }
        self.release();
        self.released  = false;   // not a late use: _revive answers instead.
        self.revivable = true;
    }

    /// Re-parse a release_unused() set on demand (a G62 fill retry in the
    /// demanding TU's set, or `defined!` asking its macros): the same buffer,
    /// VFS and invocation, so the same AST. Its diagnostics were already
    /// reported, so the re-parse's are suppressed, and the recorded file
    /// list and include graph are kept as they were. Once per set.
    priv fn _revive(self) -> bool {
        if self._ci != &null { return true; }
        if (!self.revivable) || (self._be_saved == &null) { return false; }
        self.revivable = false;
        var keep_files = self.files;
        var keep_inc   = self.includes;
        var keep_ok    = self.ok;
        self.files.clear();
        self.includes.clear();
        self.built.store(false);
        self.diag_buf.push_suppress();
        self.build(self._be_saved);
        self.diag_buf.pop_suppress();
        self.files    = keep_files;
        self.includes = keep_inc;
        self.ok       = keep_ok;
        kairo::header_set_revivals().fetch_add(1);
        Logger::info(Logger::Stage::Driver, f"HeaderSet {self.id}: revived after release_unused");
        return self._ci != &null;
    }

    /// A set released early (HeaderSetCache::release_all before codegen,
    /// P380) that something still asks for its AST: counted, and reported
    /// once at exit (HeaderSetCache::report_late_uses), never silent.
    pub var released: bool = false;
    static fn _note_late(released: bool) {
        if released { kairo::header_set_late_uses().fetch_add(1); }
    }
    /// Hold this around any clang::Sema call from sema (M2's RequireCompleteType).
    fn sema_lock(self) -> *std::RecursiveMutex { return &(self._sema_mu); }

    /// Is \p name a macro once the set's headers are read: a predefined one
    /// (`__linux__`) or one a header `#define`s. build() never ends the
    /// source file, so the preprocessor still holds every definition.
    /// Kairo's `defined!` (EVAL.md §4.3).
    fn macro_defined(self, name: string) -> bool {
        if (self._ci == &null) && self._macros_kept { return self._macros.find(sref(name)) != self._macros.end(); }
        if (self._ci == &null) && (!self._revive()) { return false; }
        if !self._ci->hasPreprocessor() { return false; }
        var slock = std::LockGuard(self._sema_mu);
        return self._ci->getPreprocessor().isMacroDefined(sref(name));
    }

    fn pch_path(self) -> string { return f"{HeaderSet::vfs_root()}/pch/{self.id}.pch"; }

    /// Phase B's textual include of this set: one in-memory header replaying
    /// the direct includes inside the header FP pragmas, the C ones inside
    /// extern "C". Preprocessor `Includes` cannot wrap a path themselves.
    fn wrap_path(self) -> string { return f"{HeaderSet::vfs_root()}/pch/{self.id}.h"; }

    /// \brief the `#include` line phase B's wrapper replays for the import
    ///        spelled \p spelled, or "" when phase A found no such header.
    ///
    /// \details By name, through the search path, unless phase A found it
    ///          beside the importing .k (the quoted dir only phase A
    ///          searches): then by that absolute path, which is the same
    ///          lookup. Never a system header by absolute path: a header
    ///          reached that way was found in no search dir, so its
    ///          `#include_next` starts over from the first one and finds
    ///          itself. libc++'s <math.h> is exactly that wrapper, and then
    ///          the C library's math.h (FP_NAN and the rest) never arrives.
    fn replay_include(self, spelled: string) -> string {
        for e: IncludeEdge in self.includes {
            if e.from_path.size() != 0 { continue; }
            if !self._spelling_matches(spelled, e.to_path) { continue; }
            var dir = self.import_dir;
            var local = (dir.size() > 0) && (e.to_path.size() > dir.size() + 1) && e.to_path.starts_with(dir);
            if local {
                var sep = e.to_path[dir.size()];
                local = (sep == '/') || (sep == '\\');
            }
            if local { return "#include \x22" + e.to_path + "\x22"; }
            return "#include <" + spelled + ">";
        }
        return "";
    }

    /// Phase B's replay of this set's imports, one `#include` per line in the
    /// order phase A wrote them, the C ones inside extern "C". Without the FP
    /// pragmas: whoever wraps the text puts them around it once.
    fn replay_lines(self) -> string {
        var w = "";
        for var e: usize = 0; e < self.headers.size(); ++e {
            var line = self.replay_include(self.headers[e]);
            if line.size() == 0 { continue; }
            var c = (e < self.c_linkage.size()) && self.c_linkage[e];
            // Two literals: Stage 0 copies escapes into C++ verbatim, where
            // \x is greedy, so one literal's `\x22` then `C` lexes as the
            // single char U+022C and the wrapper opened with garbage instead
            // of the quote.
            if c { w += "extern \x22"; w += "C\x22 {\n"; }
            w += line;
            w += "\n";
            if c { w += "}\n"; }
        }
        return w;
    }

    fn has_c_linkage(self) -> bool {
        for var i: usize = 0; i < self.c_linkage.size(); ++i { if self.c_linkage[i] { return true; } }
        return false;
    }

    /// Whether \p spelled (as written in the .k, unquoted) was imported `ffi "c"`.
    fn is_c_header(self, spelled: string) -> bool {
        for var i: usize = 0; i < self.headers.size(); ++i {
            if (self.headers[i] == spelled) && (i < self.c_linkage.size()) { return self.c_linkage[i]; }
        }
        return false;
    }

    /// A header as written in the .k, minus the literal's quotes (and angle
    /// brackets, if someone wrote `"<vector>"`). The one spelling: the PP keys
    /// the set on it, build() wraps it in `#include "..."`, and the driver
    /// matches it in closure_of. Two spellings of one header would silently
    /// miss the closure and import nothing.
    static fn unquote(lit: string) -> string {
        var s = lit;
        if (s.size() >= 2) && (s[0] == '\x22') && (s[s.size() - 1] == '\x22') {
            s = s.subslice(1, s.size() - 2);
        }
        if (s.size() >= 2) && (s[0] == '<') && (s[s.size() - 1] == '>') {
            s = s.subslice(1, s.size() - 2);
        }
        return s;
    }

    /// Kairo fid for a clang FileID in THIS set's SM, or 0.
    fn kfid_for(self, cfid: clang::FileID) -> u32 {
        var it = self.cfid_to_kfid.find(static_cast::<u64>(cfid.getHashValue()));
        if it == self.cfid_to_kfid.end() { return 0; }
        return it->second;
    }

    /// Transitive include closure of one header spelling, as PATHS, the
    /// header itself first. Empty if the spelling never resolved.
    priv fn _build_path_index(self) {
        if self._idx_built { return; }
        self._idx_built = true;
        for var i: usize = 0; i < self.files.size(); ++i {
            self._file_at.try_emplace(sref(self.files[i].path), static_cast::<u32>(i));
        }
        for var i: usize = 0; i < self.includes.size(); ++i {
            self._out_edges[sref(self.includes[i].from_path)].push_back(static_cast::<u32>(i));
        }
        for var i: usize = 0; i < self.includes.size(); ++i {
            var a = self._node(self.includes[i].from_path);
            var b = self._node(self.includes[i].to_path);
            self._node_out[a].push_back(b);
        }
    }

    priv fn _node(self, p: string) -> u32 {
        var it = self._node_of.find(sref(p));
        if it != self._node_of.end() { return it->second; }
        var n = static_cast::<u32>(self._node_path.size());
        self._node_of.try_emplace(sref(p), n);
        self._node_path.push_back(p);
        self._node_out.push_back(vec::<u32>());
        return n;
    }

    fn closure_of(self, spelled: string, out: ref!(vec::<string>)) {
        self._build_path_index();
        // The direct include from the injected main whose spelling matches.
        var root: string = "";
        var mit = self._out_edges.find(sref(""));
        if mit == self._out_edges.end() { return; }
        for var k: usize = 0; k < mit->second.size(); ++k {
            var e = &(self.includes[mit->second[k]]);
            if self._spelling_matches(spelled, e->to_path) { root = e->to_path; break; }
        }
        if root.size() == 0 { return; }
        var seen = set::<string>();
        var work = vec::<string>();
        work.push_back(root);
        while !work.empty() {
            var p = work[work.size() - 1];
            work.pop_back();
            if seen.contains(p) { continue; }
            seen.insert(p);
            out.push_back(p);
            var it = self._out_edges.find(sref(p));
            if it == self._out_edges.end() { continue; }
            for var k: usize = 0; k < it->second.size(); ++k {
                work.push_back(self.includes[it->second[k]].to_path);
            }
        }
    }

    /// closure_of(\p spelled) mapped through kfid_of_path, zeros dropped, in
    /// closure order: what _attach_ffi_edges stamps on an ffi import. Every
    /// TU sharing this set imports the same headers, so it is memoized per
    /// spelling (driver thread only, after index()).
    fn closure_kfids(self, spelled: string) -> *vec::<u32> {
        var it = self._closure_memo.find(sref(spelled));
        if it != self._closure_memo.end() { return &(it->second); }
        // closure_of's walk over node numbers: the same root (the first
        // direct include whose spelling matches), the same LIFO order with
        // children pushed in include order, so the same sequence.
        self._build_path_index();
        var ks = vec::<u32>();
        var root: string = "";
        var mit = self._out_edges.find(sref(""));
        if mit != self._out_edges.end() {
            for var k: usize = 0; k < mit->second.size(); ++k {
                var e = &(self.includes[mit->second[k]]);
                if self._spelling_matches(spelled, e->to_path) { root = e->to_path; break; }
            }
        }
        if root.size() > 0 {
            var seen = vec::<bool>();
            seen.resize(self._node_path.size(), false);
            var work = vec::<u32>();
            work.push_back(self._node(root));
            while !work.empty() {
                var p = work[work.size() - 1];
                work.pop_back();
                if seen[p] { continue; }
                seen[p] = true;
                var k = self.kfid_of_path(self._node_path[p]);
                if k != 0 { ks.push_back(k); }
                for var j: usize = 0; j < self._node_out[p].size(); ++j { work.push_back(self._node_out[p][j]); }
            }
        }
        var slot = &(self._closure_memo[sref(spelled)]);
        (*slot) = ks;
        return slot;
    }

    fn kfid_of_path(self, p: string) -> u32 {
        self._build_path_index();
        var it = self._file_at.find(sref(p));
        if it == self._file_at.end() { return 0; }
        return self.files[it->second].kfid;
    }

    priv fn _spelling_matches(self, spelled: string, path: string) -> bool {
        // `"c1.h"` vs `/abs/dir/c1.h`: suffix match on a path boundary.
        if path.size() < spelled.size() { return false; }
        var off = path.size() - spelled.size();
        if path.view().compare(off, spelled.size(), spelled.view()) != 0 { return false; }
        if off == 0 { return true; }
        var c = path[off - 1];
        return (c == '/') || (c == '\\');
    }

    // --- build (pool thread) ------------------------------------------------

    /// Parse the set and write the PCH. Keeps the instance alive.
    fn build(self, be: *ClangBackend) {
        var _t = TimeRegion("HeaderSetBuild");
        self._be_saved = be;
        be->startup();                                   // idempotent, mutex-guarded.
        if !be->ready() { self.ok = false; self.built.store(true); return; }

        // Own invocation: a COPY of the backend's, so LangOpts/target/header
        // search are byte-identical (the PCH reader validates them) and this
        // instance's Inputs/OutputFile edits touch nothing shared.
        var inv = libcxx::make_shared::<clang::CompilerInvocation>(*(be->invocation()));

        self._main = libcxx::string();
        self._main_locs.clear();
        // The headers keep C++'s FP semantics, not Kairo's (ClangBackend::
        // header_fp_pragmas). One _main_locs entry per line, as for every
        // other line here: the adapter maps clang's line numbers through it.
        var fp_open  = vec::<string>();
        var fp_close = vec::<string>();
        be->header_fp_pragmas(&fp_open, &fp_close);
        for l: string in fp_open {
            self._main.append(l.std_string());
            self._main.append(r"\n");
            self._main_locs.push_back(SourceRange::invalid());
        }
        for var i: usize = 0; i < self.headers.size(); ++i {
            var h = self.headers[i].std_string();
            var c = (i < self.c_linkage.size()) && self.c_linkage[i];
            var at = SourceRange::invalid();
            if i < self.header_locs.size() { at = self.header_locs[i]; }
            if c {
                self._main.append(r"extern \"C\" \x7B\n");
                self._main_locs.push_back(SourceRange::invalid());
            }
            self._main.append(r"#include \"");
            self._main.append(h);
            self._main.append(r"\"\n");
            self._main_locs.push_back(at);
            if c {
                self._main.append(r"\x7D\n");
                self._main_locs.push_back(SourceRange::invalid());
            }
        }
        // A header that ends mid-declaration runs on into these lines, and
        // clang's error then lands here: the last import is what ran out.
        var last_at = SourceRange::invalid();
        if self.header_locs.size() > 0 { last_at = self.header_locs[self.header_locs.size() - 1]; }
        for l: string in fp_close {
            self._main.append(l.std_string());
            self._main.append(r"\n");
            self._main_locs.push_back(last_at);
        }
        var buf = llvm::MemoryBuffer::getMemBuffer(
            llvm::StringRef(self._main.data(), self._main.size()), r"<injected>", false);
        var fe = &(inv->getFrontendOpts());
        fe->Inputs.clear();
        fe->Inputs.push_back(clang::FrontendInputFile(
            buf->getMemBufferRef(), clang::InputKind(clang::Language::CXX)));
        fe->DisableFree = true;                          // we own the AST's lifetime.
        // Kairo imports declarations; nothing reads a header function's body
        // (records' and enums' definitions are not bodies). Clang still
        // parses the bodies semantics needs -- constexpr, deduced return
        // types -- and codegen compiles against the merged PCH, which parses
        // every body. Bodies were most of each set's parse and AST (P380).
        fe->SkipFunctionBodies = 1;   // a 1-bit field: an integer, not a bool, for Stage 1.
        // A quoted include from a .k file resolves relative to that file's
        // directory, exactly as it would from a .cpp beside it. IgnoreSysRoot
        // (the last argument) MUST be true: the directory is a real absolute
        // path, and with `-isysroot` set clang would otherwise prefix it with
        // the sysroot and search /usr/<the .k's dir> -- every local ffi header
        // "file not found" the moment a sysroot is passed.
        if self.import_dir.size() > 0 {
            var e = clang::HeaderSearchOptions::Entry(
                self.import_dir.std_string(),
                clang::frontend::Quoted, false, true);
            inv->getHeaderSearchOpts().UserEntries.insert(
                inv->getHeaderSearchOpts().UserEntries.begin(), e);
        }
        inv->getPreprocessorOpts().Includes.clear();     // the buffer IS the includes.

        self._printer = std::create::<clang::TextDiagnosticPrinter>(llvm::errs(), self._diag_opts);
        self._ci = std::create::<clang::CompilerInstance>(inv);
        self._ci->setVirtualFileSystem(be->vfs());
        self._ci->createDiagnostics(self._printer, false);
        if !self._ci->hasDiagnostics() { self.ok = false; self.built.store(true); return; }

        // Every clang diagnostic of this set goes through the Kairo engine,
        // not the printer. Here there is no importer yet and no header fid
        // (cfid_to_kfid fills at index()), so they buffer in diag_buf, each
        // keeping clang's own file:line:col in its text.
        self._ksm = be->ksm();
        var bda = self.begin_diag(&self.diag_buf);
        finally { self.end_diag(bda); }
        self._ci->setTarget(clang::TargetInfo::CreateTargetInfo(
            self._ci->getDiagnostics(), self._ci->getInvocation().getTargetOpts()));
        if !self._ci->hasTarget() { self.ok = false; self.built.store(true); return; }
        self._ci->getTarget().adjust(self._ci->getDiagnostics(), self._ci->getLangOpts(), &null);

        self._act = std::create::<HeaderSetAction>();
        self._act->_set = &self;

        // BeginSourceFile + Execute, NOT ExecuteAction: EndSourceFile would
        // destroy the ASTContext, and the whole point is that it lives on.
        var input = fe->Inputs[0];
        if !self._act->BeginSourceFile(*(self._ci), input) {
            self.ok = false; self.built.store(true); return;
        }
        self._began = true;
        // llvm::Error: bool(err) is TRUE ON FAILURE, and an unconsumed Error
        // asserts on destruction.
        var err = self._act->Execute();
        var failed = bool(err);
        if failed { llvm::consumeError(libcxx::move(err)); }
        self.ok = (!failed) && (self._ci->getDiagnostics().getNumErrors() == 0);
        self.built.store(true, std::MemoryOrder::release);

        Logger::info(Logger::Stage::Driver,
            f"HeaderSet: built key={self.headers.size()} header(s), {self.files.size()} file(s) entered, ok={self.ok}");
    }

    // --- diagnostics ---------------------------------------------------------

    /// Route this set's clang diagnostics into \p sink until end_diag(), then
    /// back to whichever client was active before. Nests: a fill that
    /// spells a nested instance argument can fill again, and must hand the
    /// outer fill's adapter back, not the printer. Caller holds sema_lock(),
    /// or is build(), which owns the instance outright.
    fn begin_diag(self, sink: *BufferedDiagSink) -> *ClangDiagAdapter {
        var a = std::create::<ClangDiagAdapter>();
        a->sink   = sink;
        a->ksm    = self._ksm;
        a->fidmap = &(self.cfid_to_kfid);
        a->main_locs = &(self._main_locs);
        var de = &(self._ci->getDiagnostics());
        self._clients.push_back(de->getClient());
        de->setClient(a, false);
        a->BeginSourceFile(self._ci->getLangOpts(), &null);
        return a;
    }

    /// Flush \p a, restore the client begin_diag replaced, free \p a. Null is
    /// a no-op, so a caller with no sink can pair the two unconditionally.
    fn end_diag(self, a: *ClangDiagAdapter) {
        if a == &null { return; }
        a->EndSourceFile();
        a->finish();
        var prev: *clang::DiagnosticConsumer = self._printer;
        if !self._clients.empty() {
            prev = self._clients[self._clients.size() - 1];
            self._clients.pop_back();
        }
        self._ci->getDiagnostics().setClient(prev, false);
        std::destroy(a);
    }

    /// build()'s buffered diagnostics into the driver's engine. Driver
    /// thread, after the build joined. Idempotent: the buffer drains empty.
    fn drain_diags(self, engine: *DiagEngine, sm: *SourceManager) {
        self.diag_buf.drain_into(engine, sm);
    }

    /// Root of the in-memory VFS mount. Must be absolute on the HOST: on
    /// Windows a path with no drive letter is drive-relative, and the overlay
    /// resolves it against the cwd, so registration and lookup never agree.
    /// The drive is fake; the overlay serves it and nothing touches disk.
    static fn vfs_root() -> string {
        const eval if defined(_WIN32) {
            return "C:/kairo";
        }
        return "/kairo";
    }

    // --- release (driver thread) -------------------------------------------

    fn release(self) {
        if self._ci != &null { self.released = true; }
        if self._act != &null {
            // build() set DisableFree so the AST outlives the parse; left set,
            // EndSourceFile LEAKS Sema, ASTContext, Preprocessor and the
            // managers (BuryPointer) and a release frees nothing. ~200 MB a
            // set on the self-host graph (P380).
            if self._ci != &null { self._ci->getFrontendOpts().DisableFree = 0; }
            if (self._ci != &null) && self._began { self._act->EndSourceFile(); }
            self._began = false;
            std::destroy(self._act);
            self._act = &null;
        }
        if self._ci != &null      { std::destroy(self._ci);      self._ci = &null; }
        if self._printer != &null { std::destroy(self._printer); self._printer = &null; }
    }
}

///
/// \class CodegenPCHAction
/// \brief Writes CodegenPCH's bytes. A plain prefix parse: nothing walks the
///        AST afterwards, so no callbacks and no instance kept alive.
///
class CodegenPCHAction derives clang::ASTFrontendAction {
    pub var _buf: libcxx::shared_ptr::<clang::PCHBuffer>;

    override fn CreateASTConsumer(self, ci: ref!(clang::CompilerInstance), in_file: llvm::StringRef)
            -> libcxx::unique_ptr::<clang::ASTConsumer>;
    override fn getTranslationUnitKind(self) -> clang::TranslationUnitKind;
}

///
/// \class CodegenPCH
/// \brief Phase B's one implicit PCH: every header set a TU's emission
///        needs, in one parse.
///
/// clang loads one implicit PCH per TU, so with a PCH per set every set but
/// the first was `#include`d as text by every TU. The first was the TU's
/// own set -- for builtin's TUs the small rt/fmt.h one -- so libc++'s
/// <coroutine> (153 files, concept-heavy) was re-parsed by 22 of a
/// hello-sized program's 23 TUs: about 28 of each TU's 30 ms of backend time
/// (private/spikes/codegen-par). A PCH of all of them loads in about 1.5 ms.
///
/// Built from the same text phase B's textual wrappers replay, so it parses
/// what the TUs used to; a failed build leaves `ok` false and the TUs fall
/// back to that path.
///
class CodegenPCH {
    pub var pch:  libcxx::shared_ptr::<clang::PCHBuffer>;
    pub var ok:   bool = false;
    pub var path: string;
    /// The backend's VFS holds the bytes at `path`. Driver thread only.
    pub var mounted: bool = false;
    priv var _text: libcxx::string;   ///< the injected buffer; must outlive the parse.

    fn CodegenPCH(self) {
        self.pch = libcxx::make_shared::<clang::PCHBuffer>();
    }

    fn build(self, be: *ClangBackend, sets: ref!(vec::<*HeaderSet>)) {
        var _t = TimeRegion("CodegenPCHBuild");
        self.ok = false;
        if !be->ready() { return; }
        // A failed set already reported its errors; the fallback replays it.
        for var i: usize = 0; i < sets.size(); ++i { if !sets[i]->ok { return; } }

        var fp_open  = vec::<string>();
        var fp_close = vec::<string>();
        be->header_fp_pragmas(&fp_open, &fp_close);
        var text = "";
        for l: string in fp_open { text += l; text += "\n"; }
        for var i: usize = 0; i < sets.size(); ++i { text += sets[i]->replay_lines(); }
        for l: string in fp_close { text += l; text += "\n"; }
        self._text = text.std_string();

        // A COPY of the backend's invocation, as for every phase-A set: the
        // PCH reader rejects one whose options differ from the TU's.
        var inv = libcxx::make_shared::<clang::CompilerInvocation>(*(be->invocation()));
        var buf = llvm::MemoryBuffer::getMemBuffer(
            llvm::StringRef(self._text.data(), self._text.size()), r"<kairo-codegen-hdrs>", false);
        var fe = &(inv->getFrontendOpts());
        fe->Inputs.clear();
        fe->Inputs.push_back(clang::FrontendInputFile(
            buf->getMemBufferRef(), clang::InputKind(clang::Language::CXX)));
        fe->DisableFree = false;                          // nothing outlives the parse.
        inv->getPreprocessorOpts().Includes.clear();      // the buffer IS the includes.
        // -fpch-instantiate-templates: perform the headers' pending implicit
        // instantiations HERE, once, and store them in the PCH. Without it
        // every TU loading the PCH performed them all again at its end
        // (PerformPendingInstantiations): std::format, clang's DenseMaps,
        // ... -- 659 s of the 794 s clang frontend time over the self-host
        // graph's 316 TUs (P380). A Benign LangOpt: the TUs' own invocations
        // need not match it for the PCH to load.
        inv->getLangOpts().PCHInstantiateTemplates = 1;

        var ci = std::create::<clang::CompilerInstance>(inv);
        var ok = self._parse(ci, be, fe->Inputs[0]);
        std::destroy(ci);
        self.ok = ok;
        Logger::info(Logger::Stage::Driver,
            f"CodegenPCH: {sets.size()} set(s), {self.pch->Data.size()} bytes, ok={self.ok}");
    }

    /// The errors are the per-set builds' to report, and they already have:
    /// this parse only says whether the merged text holds together.
    priv fn _parse(self, ci: *clang::CompilerInstance, be: *ClangBackend, input: clang::FrontendInputFile) -> bool {
        ci->setVirtualFileSystem(be->vfs());
        ci->createDiagnostics(std::create::<clang::IgnoringDiagConsumer>(), true);
        if !ci->hasDiagnostics() { return false; }
        ci->setTarget(clang::TargetInfo::CreateTargetInfo(
            ci->getDiagnostics(), ci->getInvocation().getTargetOpts()));
        if !ci->hasTarget() { return false; }
        ci->getTarget().adjust(ci->getDiagnostics(), ci->getLangOpts(), &null);

        var act = CodegenPCHAction();
        act._buf = self.pch;
        if !act.BeginSourceFile(*ci, input) { return false; }
        // llvm::Error: bool(err) is TRUE ON FAILURE, and an unconsumed Error
        // asserts on destruction.
        var err = act.Execute();
        var failed = bool(err);
        if failed { llvm::consumeError(libcxx::move(err)); }
        var errors = ci->getDiagnostics().getNumErrors();
        act.EndSourceFile();
        return (!failed) && (errors == 0) && self.pch->IsComplete;
    }
}

///
/// \class HeaderSetCache
/// \brief key -> HeaderSet, one per build. Owned by CompilerInstance.
///
class HeaderSetCache {
    /// canonical key -> set. StringMap: probed with the key's own bytes.
    /// Minted from the parallel wave, so neither map nor `id` order is
    /// stable; all() sorts by key on the way out.
    priv var _sets: llvm::StringMap::<*HeaderSet>;
    /// ordered set ids -> phase B's merged PCH of them (codegen_pch).
    priv var _codegen: llvm::StringMap::<*CodegenPCH>;
    priv var _mu:   std::Mutex;
    priv var _be:   obs::<ClangBackend>;
    priv var _pool: obs::<ThreadPool>;
    /// P417: one clang parse for the build's header lists, not one per list.
    /// request() only records a list (a view); start_shared() parses their
    /// union. KAIRO_HEADER_SETS=per-set keeps one parse per list.
    priv var _shared_mode: bool = true;
    priv var _pending: vec::<*HeaderSet>;

    fn HeaderSetCache(self, be: *ClangBackend, pool: *ThreadPool) {
        self._be   = be;
        self._pool = pool;
        var mode = libcxx::getenv(r"KAIRO_HEADER_SETS");
        if (mode != &null) && (libcxx::strcmp(mode, r"per-set") == 0) { self._shared_mode = false; }
    }

    fn op delete (self) {
        for var it = self._sets.begin(); it != self._sets.end(); ++it { std::destroy(it->second); }
        self._sets.clear();
        for var it = self._codegen.begin(); it != self._codegen.end(); ++it { std::destroy(it->second); }
        self._codegen.clear();
    }

    /// The language is part of the key: one header imported as C and as C++
    /// is two parses with two linkages, never one shared set.
    static fn key_of(headers: ref!(vec::<string>), c_linkage: ref!(vec::<bool>)) -> string {
        var k: string = "";
        for var i: usize = 0; i < headers.size(); ++i {
            if (i < c_linkage.size()) && c_linkage[i] { k += "c:"; }
            k += headers[i];
            k += "\n";
        }
        return k;
    }

    /// Get-or-mint. Mint enqueues the build. Any thread: PPWalker::_finalize
    /// calls this from the pool (the wave walks files in parallel); `_mu`
    /// covers the map, and the build touches only the set it was given.
    fn request(self, headers: vec::<string>, c_linkage: vec::<bool>, locs: vec::<SourceRange>, import_dir: string) -> *HeaderSet {
        var key = HeaderSetCache::key_of(headers, c_linkage);
        var lock = std::LockGuard(self._mu);
        var it = self._sets.find(sref(key));
        if it != self._sets.end() { return it->second; }

        var hs = std::create::<HeaderSet>();
        hs->key        = key;
        hs->headers    = headers;
        hs->c_linkage  = c_linkage;
        hs->header_locs = locs;
        hs->import_dir = import_dir;
        hs->id         = static_cast::<u32>(self._sets.size());
        self._sets.try_emplace(sref(key), hs);

        if self._shared_mode {
            self._pending.push_back(hs);   // parsed by start_shared, with the others.
            return hs;
        }
        self._enqueue_build(hs);
        return hs;
    }

    /// Not priv: start_shared's pool task calls it through a captured pointer.
    fn _enqueue_build(self, set: *HeaderSet) {
        var be  = self._be;
        var rec = kairo::TimeReport::region(r"HeaderSets");
        self._pool->enqueue(fn () |set, be, rec| {
            var _kt = kairo::TimeReport::Worker(rec);
            set->build(be);
        }, HEADER_BUILD_GROUP());
    }

    /// Where a view's spelled header resolves: its importer's directory first,
    /// as that set's quoted -I entry made it, else the spelling itself, which
    /// every set resolves alike through the shared search path.
    static fn resolve_spelling(view: *HeaderSet, h: string) -> string {
        if view->import_dir.size() > 0 {
            var cand = view->import_dir + "/" + h;
            if llvm::sys::fs::exists(llvm::Twine(sref(cand))) {
                // Lexically normal: `Inputs/../x.h` from one list and `x.h`
                // from another's directory are one file, and must be one
                // union line and one closure key, or the second spelling's
                // lookup finds a path the parse never recorded.
                var norm: llvm::SmallString::<256>;
                norm.append(sref(cand));
                llvm::sys::path::remove_dots(norm, true);
                return string(norm.data(), norm.size());
            }
        }
        return h;
    }

    /// \brief P417: parse every list request() recorded since the last call
    ///        as ONE set, on the pool; each list's set becomes a view of it.
    ///
    /// \details Driver thread, after a preprocess. The union takes the lists
    ///          by key (a stable order), each header once (by resolved path and
    ///          linkage; include guards make a repeat a no-op anyway), and each
    ///          line's source location from the first list that names it, so a
    ///          header error lands on that import. Per-list parses instead --
    ///          today's behaviour -- when there is one list, when one header is
    ///          imported both as C and as C++, or when the union fails to
    ///          parse (its diagnostics are dropped; the per-list parses report).
    fn start_shared(self) {
        var views = vec::<*HeaderSet>();
        {
            var lock = std::LockGuard(self._mu);
            views = self._pending;
            self._pending.clear();
        }
        if views.size() == 0 { return; }
        if views.size() == 1 { self._enqueue_build(views[0]); return; }
        llvm::sort(views.begin(), views.end(),
            fn (const a: *HeaderSet, const b: *HeaderSet) || -> bool = a->key < b->key);

        var u_headers = vec::<string>();
        var u_c       = vec::<bool>();
        var u_locs    = vec::<SourceRange>();
        var seen      = llvm::StringMap::<bool>();   // resolved -> c linkage
        var conflict  = false;
        for v: *HeaderSet in views {
            for var i: usize = 0; i < v->headers.size(); ++i {
                var r = HeaderSetCache::resolve_spelling(v, v->headers[i]);
                var c = (i < v->c_linkage.size()) && v->c_linkage[i];
                var it = seen.find(sref(r));
                if it != seen.end() {
                    if it->second != c { conflict = true; }
                    continue;
                }
                seen.try_emplace(sref(r), c);
                u_headers.push_back(r);
                u_c.push_back(c);
                var at = SourceRange::invalid();
                if i < v->header_locs.size() { at = v->header_locs[i]; }
                u_locs.push_back(at);
            }
        }
        if conflict {
            for v: *HeaderSet in views { self._enqueue_build(v); }
            return;
        }

        var u = std::create::<HeaderSet>();
        u->key        = "<shared>\n" + HeaderSetCache::key_of(u_headers, u_c);
        u->headers    = u_headers;
        u->c_linkage  = u_c;
        u->header_locs = u_locs;
        u->import_dir = "";   // every quoted header is resolved above.
        {
            var lock = std::LockGuard(self._mu);
            u->id = static_cast::<u32>(self._sets.size());
            self._sets.try_emplace(sref(u->key), u);
        }
        var job = std::create::<vec::<*HeaderSet>>(views);
        var be  = self._be;
        var me  = &self;
        var rec = kairo::TimeReport::region(r"HeaderSets");
        self._pool->enqueue(fn () |u, job, be, me, rec| {
            var _kt = kairo::TimeReport::Worker(rec);
            u->build(be);
            if u->ok {
                for v: *HeaderSet in *job { v->shared = u; }
            } else {
                // The views report what is wrong, each as its own parse did.
                u->diag_buf.discard();
                for v: *HeaderSet in *job { me->_enqueue_build(v); }
            }
            std::destroy(job);
        }, HEADER_BUILD_GROUP());   // start_shared: the union parse.
    }

    fn find(self, key: string) -> *HeaderSet {
        var lock = std::LockGuard(self._mu);
        var it = self._sets.find(sref(key));
        if it == self._sets.end() { return &null; }
        return it->second;
    }

    fn wait_all(self) { self._pool->wait_group(HEADER_BUILD_GROUP()); }

    fn all(self, out: ref!(vec::<*HeaderSet>)) {
        var lock = std::LockGuard(self._mu);
        var first = out.size();
        for var it = self._sets.begin(); it != self._sets.end(); ++it { out.push_back(it->second); }
        // By canonical key: the one order independent of which wave thread
        // minted a set first.
        llvm::sort(out.begin() + first, out.end(),
            fn (const a: *HeaderSet, const b: *HeaderSet) || -> bool = a->key < b->key);
    }

    /// Every set's buffered build diagnostics into `engine`. Sema drains per
    /// importing TU; a run that stops before Sema (a parse error) never
    /// does, and an undrained BufferedDiagSink ICEs when the set dies.
    fn drain_all(self, engine: *DiagEngine, sm: *SourceManager) {
        self.wait_all();
        var sets: vec::<*HeaderSet>;
        self.all(sets);
        for var i: usize = 0; i < sets.size(); ++i { sets[i]->drain_diags(engine, sm); }
    }

    /// \brief phase B's one PCH for \p sets, in that order; built on first
    ///        request, then shared by every TU that asks for the same list.
    ///
    /// After wait_all(): it reads every set's includes. Built on the pool
    /// while Sema runs when prebuild_codegen_pch() was given the same list;
    /// the driver joins CODEGEN_PCH_GROUP before asking, so a hit is always
    /// a finished build. The cache owns it because each codegen TU's VFS
    /// mounts its bytes without a copy, so they must outlive every TU.
    fn codegen_pch(self, sets: ref!(vec::<*HeaderSet>)) -> *CodegenPCH {
        var key = "";
        for var i: usize = 0; i < sets.size(); ++i { key += f"{sets[i]->id}-"; }
        var p: *CodegenPCH = &null;
        {
            var lock = std::LockGuard(self._mu);
            var it = self._codegen.find(sref(key));
            if it != self._codegen.end() { return it->second; }
            p = std::create::<CodegenPCH>();
            p->path = f"{HeaderSet::vfs_root()}/pch/codegen-{self._codegen.size()}.pch";
            self._codegen.try_emplace(sref(key), p);
        }
        // Outside the lock: a 50 ms parse must not stall request()/find()
        // from the threads Sema is running on.
        p->build(self._be, sets);
        return p;
    }

    /// \brief starts codegen_pch(\p sets) on the pool, off the critical
    ///        path: it then overlaps Sema and the lowerings instead of
    ///        running on the driver thread at the start of codegen.
    ///
    /// \details Driver thread, after wait_all(). \p rec is the region the
    ///          build is billed under. The caller joins CODEGEN_PCH_GROUP
    ///          before its own codegen_pch() call, which then hits.
    fn prebuild_codegen_pch(self, sets: vec::<*HeaderSet>, rec: *kairo::KTimeRecord) {
        var job = std::create::<vec::<*HeaderSet>>(sets);
        var me  = &self;
        self._pool->enqueue(fn () |me, job, rec| {
            var _kt = kairo::TimeReport::Worker(rec);
            me->codegen_pch(*job);
            std::destroy(job);
        }, CODEGEN_PCH_GROUP());
    }

    fn wait_codegen_pch(self) { self._pool->wait_group(CODEGEN_PCH_GROUP()); }

    fn release_all(self) {
        // A build still in flight owns the very clang::CompilerInstance
        // release() destroys. --syntax-only and --preprocess stop before
        // _sema(), which is the only other place phase A is joined, so
        // without this drain the driver tears the instance down underneath
        // the parse thread: a SEGV in ~Preprocessor, or a hang.
        self.wait_all();
        // And the merged PCH a stop before codegen never joined: it reads
        // the sets and parses on the backend's invocation.
        self.wait_codegen_pch();
        var lock = std::LockGuard(self._mu);
        for var it = self._sets.begin(); it != self._sets.end(); ++it {
            it->second->release();
            // Final: no revival past here, and any later read is a late use.
            it->second->revivable = false;
            it->second->released  = true;
        }
    }
}

fn HeaderSetPPCallbacks::FileChanged(
        loc: clang::SourceLocation, reason: clang::PPCallbacks::FileChangeReason,
        kind: clang::SrcMgr::CharacteristicKind, prev: clang::FileID) {
    if reason != clang::PPCallbacks::EnterFile { return; }
    var fid = self.csm->getFileID(loc);
    var fe  = self.csm->getFileEntryRefForID(fid);
    if !fe { return; }                                   // <built-in>, scratch: not a file.
    var name = fe->getName();
    var p    = string(name.data(), name.size());
    if p == "<injected>" { return; }
    for var i: usize = 0; i < self._set->files.size(); ++i {
        if self._set->files[i].cfid_hash == fid.getHashValue() { return; }   // re-entered (guard miss); once.
    }
    var hf = HeaderFile{};
    hf.path      = p;
    hf.cfid_hash = fid.getHashValue();
    hf.is_system = clang::SrcMgr::isSystem(kind);
    self._set->files.push_back(hf);
}

fn HeaderSetPPCallbacks::InclusionDirective(
        hash_loc: clang::SourceLocation, include_tok: cref::<clang::Token>,
        file_name: llvm::StringRef, is_angled: bool,
        filename_range: clang::CharSourceRange,
        file: clang::OptionalFileEntryRef,
        search_path: llvm::StringRef, relative_path: llvm::StringRef,
        suggested_module: const_obs::<clang::Module>, module_imported: bool,
        file_type: clang::SrcMgr::CharacteristicKind) {
    if !file { return; }
    var e = IncludeEdge{};
    var to = file->getName();
    e.to_path = string(to.data(), to.size());
    var from_fid = self.csm->getFileID(hash_loc);
    var from_fe  = self.csm->getFileEntryRefForID(from_fid);
    if from_fe {
        var fn_ = from_fe->getName();
        e.from_path = string(fn_.data(), fn_.size());
        if e.from_path == "<injected>" { e.from_path = ""; }
    }
    if e.from_path.size() == 0 {
        e.c_linkage = self._set->is_c_header(string(file_name.data(), file_name.size()));
    }
    self._set->includes.push_back(e);
}


fn HeaderSetAction::CreateASTConsumer(ci: ref!(clang::CompilerInstance), in_file: llvm::StringRef)
        -> libcxx::unique_ptr::<clang::ASTConsumer> {
    // No PCHGenerator (P380): phase B loads the merged CodegenPCH, built
    // for every graph with a header set, and falls back to the sets' text,
    // never to a set's own PCH. Serializing each of the self-host graph's
    // 115 sets was ~11% of their build CPU, and the bytes were kept for the
    // whole run. The parse is still a TU prefix (getTranslationUnitKind).
    return libcxx::make_unique::<clang::ASTConsumer>();
}

fn HeaderSetAction::getTranslationUnitKind() -> clang::TranslationUnitKind {
    return clang::TU_Prefix;     // a PCH is a prefix, never a whole TU.
}

fn HeaderSetAction::BeginSourceFileAction(ci: ref!(clang::CompilerInstance)) -> bool {
    if !clang::ASTFrontendAction::BeginSourceFileAction(ci) { return false; }
    var cb = libcxx::make_unique::<HeaderSetPPCallbacks>();
    cb->_set = self._set;
    cb->csm = &(ci.getSourceManager());
    ci.getPreprocessor().addPPCallbacks(libcxx::move(cb));
    return true;
}
fn CodegenPCHAction::CreateASTConsumer(ci: ref!(clang::CompilerInstance), in_file: llvm::StringRef)
        -> libcxx::unique_ptr::<clang::ASTConsumer> {
    // Same generator and arguments as HeaderSetAction's (ASTWriter.h:1015).
    return libcxx::make_unique::<clang::PCHGenerator>(
        ci.getPreprocessor(), ci.getModuleCache(),
        llvm::StringRef(r"<kairo-codegen-hdrs>.pch"), llvm::StringRef(r""),
        self._buf,
        ci.getCodeGenOpts(),
        ci.getFrontendOpts().ModuleFileExtensions,
        false, false);
}

fn CodegenPCHAction::getTranslationUnitKind() -> clang::TranslationUnitKind {
    return clang::TU_Prefix;
}
