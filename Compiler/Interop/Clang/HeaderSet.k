/// --- The Kairo Project -------------------- Interop/Clang/HeaderSet.k --- ///
///
///   HeaderSet: one clang parse per ordered header set, for C++ imports.
///
///   Phase A of C++ header import: a live clang AST that Sema/Foreign walks and
///   M2 queries. Phase B (codegen) loads the merged CodegenPCH built from the
///   sets' text instead.
///
///   \par Lifecycle
///     request()  HeaderSetCache, any thread (PPWalker::_finalize runs on the
///                pool). Get-or-mint: one HeaderSet per distinct ordered list,
///                a view until the shared parse is chosen.
///     start_shared()
///                HeaderSetCache, driver thread, after preprocessing. Enqueues
///                build() on the pool (HEADER_BUILD_GROUP) for the union of
///                every list, or for each list alone when there is only one or
///                the union cannot be used. Returns at once; the build overlaps
///                parse + sema of the importer.
///     build()    pool thread. Clang parse (a TU prefix). The instance is kept
///                ALIVE (BeginSourceFile + Execute, no EndSourceFile): the
///                ASTContext and Sema are what HeaderIndex walks and what M2
///                asks for template members.
///     index()    HeaderIndex::index, driver thread, from FrontendAction::_sema
///                after wait_group(HEADER_BUILD_GROUP). Mints one Kairo fid per
///                header IN THE ORDER CLANG TOUCHED THEM, then walks the AST.
///                Runs once per set.
///     release()  HeaderSetCache::release_all, driver thread, once the build is
///                done with the AST. EndSourceFile, instance destroyed, PCH
///                bytes and the include tree kept for phase B.
///
///   \par Locations
///     Header locs map to Kairo locs by FILE IDENTITY: `cfid_to_kfid` is built
///     at index() from the FileEntry behind each clang FileID we saw enter. It
///     is the ONE table where a clang FileID meets a Kairo fid. Everything
///     clang mints that is not a file (scratch buffers, <built-in>) has no row
///     and maps to an invalid loc. If that ever needs to change, this table is
///     the only thing to widen.
///
///   \par Threading
///     build() touches only its own CompilerInstance. Nothing here calls the
///     Kairo SourceManager / TCM / GlobalDisambigTable off the driver thread.
///     M2's on-demand instantiation goes through sema_lock().
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "llvm/ADT/StringSet.h"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Path.h"
ffi "c++" import "llvm/ADT/SmallString.h"
ffi "c++" import "cstring"
ffi "c++" import "llvm/ADT/STLExtras.h"
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KShims.hh" // header_set_late_uses
ffi "c++" import "clang/AST/ASTContext.h"
ffi "c++" import "clang/AST/ASTConsumer.h"
ffi "c++" import "clang/Basic/Diagnostic.h"
ffi "c++" import "clang/Basic/DiagnosticOptions.h"
ffi "c++" import "clang/Basic/FileEntry.h"
ffi "c++" import "clang/Basic/SourceManager.h"
ffi "c++" import "clang/Basic/TargetInfo.h"
ffi "c++" import "clang/Frontend/CompilerInstance.h"
ffi "c++" import "clang/Frontend/CompilerInvocation.h"
ffi "c++" import "clang/Frontend/FrontendAction.h"
ffi "c++" import "clang/Frontend/FrontendOptions.h"
ffi "c++" import "clang/Frontend/TextDiagnosticPrinter.h"
ffi "c++" import "clang/Lex/HeaderSearchOptions.h"
ffi "c++" import "clang/Lex/PPCallbacks.h"
ffi "c++" import "clang/Lex/Preprocessor.h"
ffi "c++" import "clang/Sema/Sema.h"
ffi "c++" import "clang/Serialization/ASTWriter.h"
ffi "c++" import "clang/Serialization/PCHContainerOperations.h"
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h"
ffi "c++" import "llvm/Support/Error.h"
ffi "c++" import "llvm/Support/MemoryBuffer.h"
ffi "c++" import "llvm/Support/VirtualFileSystem.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/KTimeReport.hh"
ffi "c++" import "memory"
ffi "c++" import "vector"
ffi "c++" import "string"
ffi "c++" import "utility"
ffi "c++" import "cstdlib"

import Diagnostic::BufferedDiagSink::BufferedDiagSink
import Diagnostic::ClangDiagAdapter::ClangDiagAdapter
import Diagnostic::Engine::DiagEngine
import Interop::Clang::ClangBackend::ClangBackend
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Support::TimeReport::TimeRegion

/// ThreadPool group for phase-A builds. 9 is CLANG_STARTUP_GROUP.
pub
const HEADER_BUILD_GROUP: u8 = 10
/// The merged codegen PCH's early build (HeaderSetCache::prebuild_codegen_pch).
pub
const CODEGEN_PCH_GROUP: u8 = 12

/// One header clang ENTERED during the parse, in first-touch order. The
/// FileID is the phase-A instance's and is only meaningful while it lives.
pub struct HeaderFile {
    pub var path:      string ///< real path (FileEntry name), the key into the Kairo SM.
    pub var cfid_hash: u32 ///< clang::FileID::getHashValue() in the phase-A SM.
    pub var kfid:      u32    = 0 ///< Kairo fid, minted at index(); 0 until then.
    pub var is_system: bool   = false ///< clang counts it a system header (ObjectCache: -g header order).
}

/// One `#include` edge, for the transitive closure `ffi import "c2.h"` folds.
pub struct IncludeEdge {
    pub var from_path: string ///< "" for the injected main (a direct import).
    pub var to_path:   string
    pub var c_linkage: bool   = false ///< a direct import written `ffi "c"`: phase B re-wraps it in extern "C".
}

/// Records what clang touched. Fires on the parse thread; writes only into
/// the owning set's vectors, which nothing reads until wait_group returns.
pub class HeaderSetPPCallbacks derives clang::PPCallbacks {
    pub var _set: *HeaderSet
    pub var csm:  unsafe *clang::SourceManager

    override fn FileChanged(self,
                            loc:    clang::SourceLocation,
                            reason: clang::PPCallbacks::FileChangeReason,
                            kind:   clang::SrcMgr::CharacteristicKind,
                            prev:   clang::FileID)

    override fn InclusionDirective(self,
                                   hash_loc:          clang::SourceLocation,
                                   const include_tok: clang::Token,
                                   file_name:         llvm::StringRef,
                                   is_angled:         bool,
                                   filename_range:    clang::CharSourceRange,
                                   file:              clang::OptionalFileEntryRef,
                                   search_path:       llvm::StringRef,
                                   relative_path:     llvm::StringRef,
                                   suggested_module:  unsafe *const clang::Module,
                                   module_imported:   bool,
                                   file_type:         clang::SrcMgr::CharacteristicKind)
}

/// The action: a plain ASTConsumer (no PCH), TU_Prefix like GeneratePCHAction,
/// our callbacks installed before the parse. BeginSourceFile + Execute are
/// called by HeaderSet::build; EndSourceFile by HeaderSet::release.
pub class HeaderSetAction derives clang::ASTFrontendAction {
    pub var _set: *HeaderSet

    override fn CreateASTConsumer(self, @inout ci: clang::CompilerInstance, in_file: llvm::StringRef)
            -> cxx::std::unique_ptr<clang::ASTConsumer>
    override fn getTranslationUnitKind(self) -> clang::TranslationUnitKind
    override fn BeginSourceFileAction(self, @inout ci: clang::CompilerInstance) -> bool
}

///
/// \class HeaderSet
/// \brief One distinct ordered header list -> one clang parse.
///
pub class HeaderSet {
    pub var key:     string                   ///< headers joined by '\n', in source order, deduped.
    pub var headers: cxx::std::vector<string> ///< as spelled in the .k files.
    /// Parallel to `headers`: imported as `ffi "c"`. The set is parsed as C++,
    /// so a C header is included inside `extern "C" { }`; one that guards
    /// itself with `#ifdef __cplusplus` is unaffected, one that does not
    /// would otherwise get C++ linkage and never link against its C object.
    pub var c_linkage:  cxx::std::vector<u8>
    pub var import_dir: string ///< directory of the first importing file: `-I` for quoted includes.
    /// Parallel to `headers`: the first importer's header-string span.
    pub var header_locs: cxx::std::vector<SourceRange>
    pub var id:          u32                           = 0 ///< cache-assigned, dense; names the PCH mount.

    // Filled by build() on the pool thread.
    pub var files:    cxx::std::vector<HeaderFile> ///< every header entered, first-touch order.
    pub var includes: cxx::std::vector<IncludeEdge>
    pub var pch:      cxx::std::shared_ptr<clang::PCHBuffer>
    pub var built:    kairo::std::Atomic<bool>               = kairo::std::Atomic<bool>(false)
    pub var ok:       bool                                   = false

    // Filled by index() on the driver thread.
    pub var indexed: bool = false
    /// Phase B: the PCH bytes are in the backend's in-memory VFS at
    /// pch_path(). Once per set for the build; CodegenBackend::run sets it.
    pub var mounted: bool = false
    /// clang FileID hash -> Kairo fid. THE table.
    ///
    /// The key is the u32 hash WIDENED to u64. A FileID loaded from a PCH is
    /// negative (-2, -3, ...) and its hash is that int as unsigned, so u32
    /// keys reach 0xFFFFFFFE / 0xFFFFFFFF -- DenseMap<u32>'s tombstone and
    /// empty keys. Zero-extended to u64 they can never be ~0 / ~0-1.
    pub var cfid_to_kfid: llvm::DenseMap<u64, u32>

    // The live phase-A instance.
    priv var _ci:  unsafe *clang::CompilerInstance = &null
    priv var _act: unsafe *HeaderSetAction         = &null
    /// BeginSourceFile succeeded. EndSourceFile on an action that never began
    /// walks a half-built Preprocessor, so release() must not pair blindly.
    priv var _began:   bool                                 = false
    priv var _printer: unsafe *clang::TextDiagnosticPrinter = &null ///< fallback client only; see begin_diag.
    priv var _ksm:     unsafe *SourceManager                = &null ///< the backend's; adapter spans.

    /// build()'s clang diagnostics. build() runs on a pool thread before any
    /// importer exists, so they buffer here and the driver drains them into
    /// its engine once the build has joined (drain_diags).
    pub var  diag_buf:   BufferedDiagSink
    priv var _clients:   cxx::std::vector<unsafe *clang::DiagnosticConsumer> ///< begin_diag's saved clients, innermost last.
    priv var _diag_opts: clang::DiagnosticOptions
    priv var _main:      cxx::std::string ///< the injected buffer; must outlive the parse.
    /// <injected> line - 1 -> the .k import that line includes; invalid for
    /// the extern "C" brace lines. The adapter's only way back from the
    /// buffer to Kairo source: without it every bad include is <injected>:1:10.
    priv var _main_locs: cxx::std::vector<SourceRange>
    /// clang::Sema is single-threaded. Recursive because a foreign fill can
    /// nest: importing one instance's members resolves a type path into
    /// another instance of the same set, and the outer fill still holds this.
    priv var _sema_mu: kairo::std::RecursiveMutex

    /// closure_of / kfid_of_path indexes, built on their first call (driver
    /// thread, after index(): `files` and `includes` are final by then).
    /// The linear scans they replace were O(files x edges) per ffi import,
    /// about 10 s of serial driver time over the self-host graph.
    priv var _idx_built: bool                                   = false
    priv var _file_at:   llvm::StringMap<u32> ///< path -> first index in `files`.
    priv var _out_edges: llvm::StringMap<cxx::std::vector<u32>> ///< from_path -> indices in `includes`, in order.
    /// The include graph by node number, for closure_kfids' walk: a node per
    /// distinct path, its edges' target nodes in include order, and its kfid
    /// (kfid_of_path, 0 when none). Built with the maps above.
    priv var _node_of:      llvm::StringMap<u32>
    priv var _node_out:     cxx::std::vector<cxx::std::vector<u32>>
    priv var _node_path:    cxx::std::vector<string>
    priv var _closure_memo: llvm::StringMap<cxx::std::vector<u32>> ///< spelled header -> closure_kfids' answer.

    fn HeaderSet(self) {
        self.pch = cxx::std::make_shared<clang::PCHBuffer>()
    }

    fn op finally (self) {
        self.release()
    }

    /// # Accessors (valid between build() and release())

    pub fn ast(self) -> unsafe *clang::ASTContext {
        // Any use after indexing (a fill or a deduction retry through this
        // set, TypeExport stand-ins) may leave pointers into this AST: pin it.
        if self.indexed {
            self.contributed = true
        }

        if self._ci == &null && !self._revive() {
            HeaderSet::_note_late(self.released)
            return &null
        }

        if !self._ci->hasASTContext() {
            return &null
        }

        return unsafe &self._ci->getASTContext()
    }

    pub fn sema(self) -> unsafe *clang::Sema {
        // Any use after indexing (a fill or a deduction retry through this
        // set, TypeExport stand-ins) may leave pointers into this AST: pin it.
        if self.indexed {
            self.contributed = true
        }

        if self._ci == &null && !self._revive() {
            HeaderSet::_note_late(self.released)
            return &null
        }

        if !self._ci->hasSema() {
            return &null
        }

        return unsafe &self._ci->getSema()
    }

    pub fn csm(self) -> unsafe *clang::SourceManager {
        // Any use after indexing (a fill or a deduction retry through this
        // set, TypeExport stand-ins) may leave pointers into this AST: pin it.
        if self.indexed {
            self.contributed = true
        }

        if self._ci == &null && !self._revive() {
            HeaderSet::_note_late(self.released)
            return &null
        }

        return unsafe &self._ci->getSourceManager()
    }

    pub fn alive(self) -> bool {
        if self._ci == &null {
            self._revive()
        }

        return self._ci != &null
    }

    /// Set by HeaderIndex::index: this set minted a header TU or declared a
    /// decl, so imported decls point into its AST. One that did neither (85
    /// of the self-host graph's 115) is released right after indexing
    /// (release_unused) and only re-parsed if something asks for its AST.
    /// This set is a VIEW (one TU list) whose headers were parsed as
    /// part of the build's one shared set; null for a set parsed itself.
    pub var  shared:       unsafe *HeaderSet     = &null
    pub var  contributed:  bool                  = true
    pub var  revivable:    bool                  = false
    priv var _be_saved:    unsafe *ClangBackend  = &null
    priv var _macros:      llvm::StringMap<bool> ///< release_unused's macro snapshot (names defined).
    priv var _macros_kept: bool                  = false

    /// macro_defined() can answer: a live instance, or a released one's
    /// snapshot. EvalIfFolding asks this instead of alive(), which revives.
    pub fn macros_known(self) -> bool {
        return self._ci != &null || self._macros_kept || self.revivable
    }

    /// --print-stats: the live instance's ASTContext bytes (AST + side tables),
    /// 0 when released. Never revives.
    pub fn ast_bytes(self) -> usize {
        if self._ci == &null || !self._ci->hasASTContext() {
            return 0
        }

        var *a = &self._ci->getASTContext()
        return a->getASTAllocatedMemory() + a->getSideTableAllocatedMemory()
    }

    /// --print-stats: the live instance's file buffers (heap-read and mmapped),
    /// SourceManager tables and Preprocessor, in bytes; zeros when released.
    pub fn other_bytes(self,
                       malloc_buf: unsafe *usize,
                       mmap_buf:   unsafe *usize,
                       sm_tab:     unsafe *usize,
                       pp:         unsafe *usize) {
        if self._ci == &null {
            return
        }

        if self._ci->hasSourceManager() {
            var *sm = &self._ci->getSourceManager()
            var mb  = sm->getMemoryBufferSizes()
            *malloc_buf += mb.malloc_bytes
            *mmap_buf += mb.mmap_bytes
            *sm_tab += sm->getDataStructureSizes()
        }

        if self._ci->hasPreprocessor() {
            *pp += self._ci->getPreprocessor().getTotalMemory()
        }
    }

    /// Frees this set's clang instance after HeaderIndex took nothing from
    /// it; the include graph, file list and fid map stay. Driver thread.
    pub fn release_unused(self) {
        if self.contributed || !self.ok || self._ci == &null {
            return
        }

        // `defined!` (EvalIfFolding) asks a TU's own set for its macros, and
        // most sets are some TU's own: keep the names defined at the end of
        // the parse, so that question never re-parses the set.
        if self._ci->hasPreprocessor() {
            var *pp = &self._ci->getPreprocessor()
            for var it = pp->macro_begin(true); it != pp->macro_end(true); ++it {
                var unsafe *ii = it->first
                if ii != &null && pp->isMacroDefined(ii) {
                    self._macros.try_emplace(ii->getName(), true)
                }
            }

            self._macros_kept = true
        }

        self.release()
        self.released  = false // not a late use: _revive answers instead.
        self.revivable = true
    }

    /// Re-parse a release_unused() set on demand (a fill retry in the
    /// demanding TU's set, or `defined!` asking its macros): the same buffer,
    /// VFS and invocation, so the same AST. Its diagnostics were already
    /// reported, so the re-parse's are suppressed, and the recorded file
    /// list and include graph are kept as they were. Once per set.
    priv fn _revive(self) -> bool {
        if self._ci != &null {
            return true
        }

        if !self.revivable || self._be_saved == &null {
            return false
        }

        self.revivable = false
        var keep_files = self.files
        var keep_inc   = self.includes
        var keep_ok    = self.ok
        self.files.clear()
        self.includes.clear()
        self.built.store(false)
        self.diag_buf.push_suppress()
        self.build(self._be_saved)
        self.diag_buf.pop_suppress()
        self.files    = keep_files
        self.includes = keep_inc
        self.ok       = keep_ok
        kairo::header_set_revivals().fetch_add(1)
        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"HeaderSet {self.id}: revived after release_unused",
        )

        return self._ci != &null
    }

    /// A set released early (HeaderSetCache::release_all before codegen)
    /// that something still asks for its AST: counted, and reported
    /// once at exit (HeaderSetCache::report_late_uses), never silent.
    pub var released: bool = false
    static fn _note_late(released: bool) {
        if released {
            kairo::header_set_late_uses().fetch_add(1)
        }
    }

    /// Hold this around any clang::Sema call from sema (M2's RequireCompleteType).
    pub fn sema_lock(self) -> unsafe *kairo::std::RecursiveMutex {
        return unsafe &self._sema_mu
    }

    /// Is \p name a macro once the set's headers are read: a predefined one
    /// (`__linux__`) or one a header `#define`s. build() never ends the
    /// source file, so the preprocessor still holds every definition.
    /// Kairo's `defined!` (Compiler/Spec/Eval.md#defined).
    pub fn macro_defined(self, const name: string) -> bool {
        if self._ci == &null && self._macros_kept {
            return self._macros.find(kairo::sref(name)) != self._macros.end()
        }

        if self._ci == &null && !self._revive() {
            return false
        }

        if !self._ci->hasPreprocessor() {
            return false
        }

        var slock = kairo::std::LockGuard(self._sema_mu)
        return self._ci->getPreprocessor().isMacroDefined(kairo::sref(name))
    }

    /// Is `::name` declared by these headers as anything but a namespace
    /// (`::malloc`, `::exit`; through `extern "C"` too, which lookup sees
    /// through)? A Kairo module whose top C++ namespace would be \p name
    /// cannot open `namespace name {` in a TU that loads them
    /// (CXXSpell::decide_tops); a namespace is only reopened. Reads the live
    /// instance directly: ast() would pin the set (contributed), which
    /// release_unused must still be free to drop.
    pub fn declares_global(self, const name: string) -> bool {
        if self._ci == &null && !self._revive() {
            return false
        }

        if !self._ci->hasASTContext() {
            return false
        }

        var        slock = kairo::std::LockGuard(self._sema_mu)
        var unsafe *a    = unsafe &self._ci->getASTContext()
        var unsafe *tu   = unsafe (a->getTranslationUnitDecl() as unsafe *clang::DeclContext)
        var res = tu->lookup(clang::DeclarationName(unsafe &a->Idents.get(kairo::sref(name))))
        for r in res {
            if !llvm::isa<clang::NamespaceDecl>(r) {
                return true
            }
        }

        return false
    }

    pub fn pch_path(self) -> string {
        return f"{HeaderSet::vfs_root()}/pch/{self.id}.pch"
    }

    /// Phase B's textual include of this set: one in-memory header replaying
    /// the direct includes inside the header FP pragmas, the C ones inside
    /// extern "C". Preprocessor `Includes` cannot wrap a path themselves.
    pub fn wrap_path(self) -> string {
        return f"{HeaderSet::vfs_root()}/pch/{self.id}.h"
    }

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
    fn replay_include(self, const spelled: string) -> string {
        for *e in self.includes {
            if e->from_path.size() != 0 {
                continue
            }

            if !self._spelling_matches(spelled, e->to_path) {
                continue
            }

            var dir = self.import_dir
            var local = dir.size() > 0
                && e->to_path.size() > dir.size() + 1
                && e->to_path.starts_with(dir)
            if local {
                var sep = e->to_path[dir.size()]
                local = sep == ('/' as u8) || sep == ('\\' as u8)
            }

            if local {
                return "#include \"" + e->to_path + "\""
            }

            return "#include <" + spelled + ">"
        }

        return ""
    }

    /// Phase B's replay of this set's imports, one `#include` per line in the
    /// order phase A wrote them, the C ones inside extern "C". Without the FP
    /// pragmas: whoever wraps the text puts them around it once.
    pub fn replay_lines(self) -> string {
        var w = ""
        for var e: usize = 0; e < self.headers.size(); ++e {
            var line = self.replay_include(self.headers[e])
            if line.size() == 0 {
                continue
            }

            var c = e < self.c_linkage.size() && self.c_linkage[e] != 0
            if c {
                w += "extern \"C\" {\n"
            }

            w += line
            w += "\n"
            if c {
                w += "}\n"
            }
        }

        return w
    }

    fn has_c_linkage(self) -> bool {
        for var i: usize = 0; i < self.c_linkage.size(); ++i {
            if self.c_linkage[i] != 0 {
                return true
            }
        }

        return false
    }

    /// Whether \p spelled (as written in the .k, unquoted) was imported `ffi "c"`.
    fn is_c_header(self, const spelled: string) -> bool {
        for var i: usize = 0; i < self.headers.size(); ++i {
            if self.headers[i] == spelled && i < self.c_linkage.size() {
                return self.c_linkage[i] != 0
            }
        }

        return false
    }

    /// A header as written in the .k, minus the literal's quotes (and angle
    /// brackets, if someone wrote `"<vector>"`). The one spelling: the PP keys
    /// the set on it, build() wraps it in `#include "..."`, and the driver
    /// matches it in closure_of. Two spellings of one header would silently
    /// miss the closure and import nothing.
    pub static fn unquote(const lit: string) -> string {
        var s = lit
        if s.size() >= 2 && s[0] == ('\x22' as u8) && s[s.size() - 1] == ('\x22' as u8) {
            s = s.subslice(1, s.size() - 2)
        }

        if s.size() >= 2 && s[0] == ('<' as u8) && s[s.size() - 1] == ('>' as u8) {
            s = s.subslice(1, s.size() - 2)
        }

        return s
    }

    /// Kairo fid for a clang FileID in THIS set's SM, or 0.
    pub fn kfid_for(self, cfid: clang::FileID) -> u32 {
        var it = self.cfid_to_kfid.find(cfid.getHashValue() as u64)
        if it == self.cfid_to_kfid.end() {
            return 0
        }

        return it->second
    }

    /// Transitive include closure of one header spelling, as PATHS, the
    /// header itself first. Empty if the spelling never resolved.
    priv fn _build_path_index(self) {
        if self._idx_built {
            return
        }

        self._idx_built = true
        for var i: usize = 0; i < self.files.size(); ++i {
            self._file_at.try_emplace(kairo::sref(self.files[i].path), i as u32)
        }

        for var i: usize = 0; i < self.includes.size(); ++i {
            self._out_edges[kairo::sref(self.includes[i].from_path)].push_back(i as u32)
        }

        for var i: usize = 0; i < self.includes.size(); ++i {
            var a = self._node(self.includes[i].from_path)
            var b = self._node(self.includes[i].to_path)
            self._node_out[a].push_back(b)
        }
    }

    priv fn _node(self, const p: string) -> u32 {
        var it = self._node_of.find(kairo::sref(p))
        if it != self._node_of.end() {
            return it->second
        }

        var n = (self._node_path.size() as u32)
        self._node_of.try_emplace(kairo::sref(p), n)
        self._node_path.push_back(p)
        self._node_out.push_back(cxx::std::vector<u32>())
        return n
    }

    fn closure_of(self, const spelled: string, @inout out: cxx::std::vector<string>) {
        self._build_path_index()
        // The direct include from the injected main whose spelling matches.
        var root: string = ""
        var mit          = self._out_edges.find(kairo::sref(""))
        if mit == self._out_edges.end() {
            return
        }

        for var k: usize = 0; k < mit->second.size(); ++k {
            var *e = &self.includes[mit->second[k]]
            if self._spelling_matches(spelled, e->to_path) {
                root = e->to_path
                break
            }
        }

        if root.size() == 0 {
            return
        }

        var seen = llvm::StringSet<llvm::MallocAllocator>() // membership only: `out` keeps the walk order
        var work = cxx::std::vector<string>()
        work.push_back(root)
        while !work.empty() {
            var p = work[work.size() - 1]
            work.pop_back()
            if !seen.insert(kairo::sref(p)).second {
                continue
            }

            out.push_back(p)
            var it = self._out_edges.find(kairo::sref(p))
            if it == self._out_edges.end() {
                continue
            }

            for var k: usize = 0; k < it->second.size(); ++k {
                work.push_back(self.includes[it->second[k]].to_path)
            }
        }
    }

    /// closure_of(\p spelled) mapped through kfid_of_path, zeros dropped, in
    /// closure order: what _attach_ffi_edges stamps on an ffi import. Every
    /// TU sharing this set imports the same headers, so it is memoized per
    /// spelling (driver thread only, after index()).
    pub fn closure_kfids(self, const spelled: string) -> unsafe *cxx::std::vector<u32> {
        var it = self._closure_memo.find(kairo::sref(spelled))
        if it != self._closure_memo.end() {
            return unsafe &it->second
        }

        // closure_of's walk over node numbers: the same root (the first
        // direct include whose spelling matches), the same LIFO order with
        // children pushed in include order, so the same sequence.
        self._build_path_index()
        var ks           = cxx::std::vector<u32>()
        var root: string = ""
        var mit          = self._out_edges.find(kairo::sref(""))
        if mit != self._out_edges.end() {
            for var k: usize = 0; k < mit->second.size(); ++k {
                var *e = &self.includes[mit->second[k]]
                if self._spelling_matches(spelled, e->to_path) {
                    root = e->to_path
                    break
                }
            }
        }

        if root.size() > 0 {
            var seen = cxx::std::vector<u8>()
            seen.resize(self._node_path.size(), 0)
            var work = cxx::std::vector<u32>()
            work.push_back(self._node(root))
            while !work.empty() {
                var p = work[work.size() - 1]
                work.pop_back()
                if seen[p] != 0 {
                    continue
                }

                seen[p] = 1
                var k = self.kfid_of_path(self._node_path[p])
                if k != 0 {
                    ks.push_back(k)
                }

                for var j: usize = 0; j < self._node_out[p].size(); ++j {
                    work.push_back(self._node_out[p][j])
                }
            }
        }

        var unsafe *slot = unsafe &self._closure_memo[kairo::sref(spelled)]
        *slot = ks
        return slot
    }

    fn kfid_of_path(self, const p: string) -> u32 {
        self._build_path_index()
        var it = self._file_at.find(kairo::sref(p))
        if it == self._file_at.end() {
            return 0
        }

        return self.files[it->second].kfid
    }

    priv fn _spelling_matches(self, const spelled: string, const path: string) -> bool {
        // `"c1.h"` vs `/abs/dir/c1.h`: suffix match on a path boundary.
        if path.size() < spelled.size() {
            return false
        }

        var off = path.size() - spelled.size()
        if kairo::std::to_std_string(path).compare(
            off,
            spelled.size(),
            kairo::std::to_std_string(spelled),
        ) != 0 {
            return false
        }

        if off == 0 {
            return true
        }

        var c = path[off - 1]
        return c == ('/' as u8) || c == ('\\' as u8)
    }

    /// # build (pool thread)

    /// Parse the set and write the PCH. Keeps the instance alive.
    fn build(self, be: unsafe *ClangBackend) {
        var _t = TimeRegion("HeaderSetBuild")
        self._be_saved = be
        be->startup() // idempotent, mutex-guarded.
        if !be->ready() {
            self.ok = false
            self.built.store(true)
            return
        }

        // Own invocation: a COPY of the backend's, so LangOpts/target/header
        // search are byte-identical (the PCH reader validates them) and this
        // instance's Inputs/OutputFile edits touch nothing shared.
        var inv = cxx::std::make_shared<clang::CompilerInvocation>(*be->invocation())

        self._main = cxx::std::string()
        self._main_locs.clear()
        // The headers keep C++'s FP semantics, not Kairo's (ClangBackend::
        // header_fp_pragmas). One _main_locs entry per line, as for every
        // other line here: the adapter maps clang's line numbers through it.
        var fp_open  = cxx::std::vector<string>()
        var fp_close = cxx::std::vector<string>()
        be->header_fp_pragmas(unsafe &fp_open, unsafe &fp_close)
        for *l in fp_open {
            self._main.append(kairo::std::to_std_string(*l))
            self._main.append("\n")
            self._main_locs.push_back(SourceRange::invalid())
        }

        for var i: usize = 0; i < self.headers.size(); ++i {
            var h  = kairo::std::to_std_string(self.headers[i])
            var c  = i < self.c_linkage.size() && self.c_linkage[i] != 0
            var at = SourceRange::invalid()
            if i < self.header_locs.size() {
                at = self.header_locs[i]
            }

            if c {
                self._main.append("extern \"C\" {\n")
                self._main_locs.push_back(SourceRange::invalid())
            }

            self._main.append("#include \"")
            self._main.append(h)
            self._main.append("\"\n")
            self._main_locs.push_back(at)
            if c {
                self._main.append("}\n")
                self._main_locs.push_back(SourceRange::invalid())
            }
        }

        // A header that ends mid-declaration runs on into these lines, and
        // clang's error then lands here: the last import is what ran out.
        var last_at = SourceRange::invalid()
        if self.header_locs.size() > 0 {
            last_at = self.header_locs[self.header_locs.size() - 1]
        }

        for *l in fp_close {
            self._main.append(kairo::std::to_std_string(*l))
            self._main.append("\n")
            self._main_locs.push_back(last_at)
        }

        var buf = llvm::MemoryBuffer::getMemBuffer(
            llvm::StringRef(self._main.data(), self._main.size()),
            kairo::sref(r"<injected>"),
            false,
        )

        var *fe = &inv->getFrontendOpts()
        fe->Inputs.clear()
        fe->Inputs.push_back(
            clang::FrontendInputFile(
                buf->getMemBufferRef(),
                clang::InputKind(clang::Language::CXX),
            ),
        )

        fe->DisableFree = 1 // we own the AST's lifetime.
        // Kairo imports declarations; nothing reads a header function's body
        // (records' and enums' definitions are not bodies). Clang still
        // parses the bodies semantics needs -- constexpr, deduced return
        // types -- and codegen compiles against the merged PCH, which parses
        // every body. Bodies were most of each set's parse and AST.
        fe->SkipFunctionBodies = 1 // a 1-bit field: an integer, not a bool, for Stage 1.
        // A quoted include from a .k file resolves relative to that file's
        // directory, exactly as it would from a .cpp beside it. IgnoreSysRoot
        // (the last argument) MUST be true: the directory is a real absolute
        // path, and with `-isysroot` set clang would otherwise prefix it with
        // the sysroot and search /usr/<the .k's dir> -- every local ffi header
        // "file not found" the moment a sysroot is passed.
        if self.import_dir.size() > 0 {
            var e = clang::HeaderSearchOptions::Entry(
                llvm::StringRef(kairo::std::to_std_string(self.import_dir)),
                clang::frontend::Quoted,
                false,
                true,
            )

            inv->getHeaderSearchOpts().UserEntries.insert(
                inv->getHeaderSearchOpts().UserEntries.cbegin(),
                e,
            )
        }

        inv->getPreprocessorOpts().Includes.clear() // the buffer IS the includes.

        self._printer = kairo::std::create<clang::TextDiagnosticPrinter>(
            llvm::errs(),
            self._diag_opts,
        )

        self._ci = kairo::std::create<clang::CompilerInstance>(inv)
        self._ci->setVirtualFileSystem(be->vfs())
        self._ci->createDiagnostics(self._printer, false)
        if !self._ci->hasDiagnostics() {
            self.ok = false
            self.built.store(true)
            return
        }

        // Every clang diagnostic of this set goes through the Kairo engine,
        // not the printer. Here there is no importer yet and no header fid
        // (cfid_to_kfid fills at index()), so they buffer in diag_buf, each
        // keeping clang's own file:line:col in its text.
        self._ksm = be->ksm()
        var unsafe *bda = self.begin_diag(unsafe &self.diag_buf)
        finally {
            self.end_diag(bda)
        }

        self._ci->setTarget(
            clang::TargetInfo::CreateTargetInfo(
                &self._ci->getDiagnostics(),
                &self._ci->getInvocation().getTargetOpts(),
            ),
        )

        if !self._ci->hasTarget() {
            self.ok = false
            self.built.store(true)
            return
        }

        self._ci->getTarget().adjust(&self._ci->getDiagnostics(), &self._ci->getLangOpts(), &null)

        self._act       = kairo::std::create<HeaderSetAction>()
        self._act->_set = &self

        // BeginSourceFile + Execute, NOT ExecuteAction: EndSourceFile would
        // destroy the ASTContext, and the whole point is that it lives on.
        var input = fe->Inputs[0]
        if !self._act->BeginSourceFile(&*self._ci, input) {
            self.ok = false
            self.built.store(true)
            return
        }

        self._began = true
        // llvm::Error: bool(err) is TRUE ON FAILURE, and an unconsumed Error
        // asserts on destruction.
        var err    = self._act->Execute()
        var failed = err as bool
        if failed {
            llvm::consumeError(cxx::std::move(err))
        }

        self.ok = !failed && self._ci->getDiagnostics().getNumErrors() == 0
        self.built.store(true, kairo::std::MemoryOrder::release)

        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"HeaderSet: built key={self.headers.size()} header(s), {self.files.size()} file(s) entered, ok={self.ok}",
        )
    }

    /// # diagnostics

    /// Route this set's clang diagnostics into \p sink until end_diag(), then
    /// back to whichever client was active before. Nests: a fill that
    /// spells a nested instance argument can fill again, and must hand the
    /// outer fill's adapter back, not the printer. Caller holds sema_lock(),
    /// or is build(), which owns the instance outright.
    pub fn begin_diag(self, sink: unsafe *BufferedDiagSink) -> unsafe *ClangDiagAdapter {
        var unsafe *a = kairo::std::create<ClangDiagAdapter>()
        a->sink      = sink
        a->ksm       = self._ksm
        a->fidmap    = unsafe &self.cfid_to_kfid
        a->main_locs = unsafe &self._main_locs
        var *de = &self._ci->getDiagnostics()
        self._clients.push_back(de->getClient())
        de->setClient(a, false)
        a->BeginSourceFile(self._ci->getLangOpts(), &null)
        return a
    }

    /// Flush \p a, restore the client begin_diag replaced, free \p a. Null is
    /// a no-op, so a caller with no sink can pair the two unconditionally.
    pub fn end_diag(self, a: unsafe *ClangDiagAdapter) {
        if a == &null {
            return
        }

        a->EndSourceFile()
        a->finish()
        var prev: unsafe *clang::DiagnosticConsumer = self._printer
        if !self._clients.empty() {
            prev = self._clients[self._clients.size() - 1]
            self._clients.pop_back()
        }

        self._ci->getDiagnostics().setClient(prev, false)
        kairo::std::destroy(a)
    }

    /// build()'s buffered diagnostics into the driver's engine. Driver
    /// thread, after the build joined. Idempotent: the buffer drains empty.
    pub fn drain_diags(self, engine: unsafe *DiagEngine, sm: unsafe *SourceManager) {
        self.diag_buf.drain_into(engine, sm)
    }

    /// Root of the in-memory VFS mount. Must be absolute on the HOST: on
    /// Windows a path with no drive letter is drive-relative, and the overlay
    /// resolves it against the cwd, so registration and lookup never agree.
    /// The drive is fake; the overlay serves it and nothing touches disk.
    pub static fn vfs_root() -> string {
        eval if defined!(_WIN32) {
            return "C:/kairo"
        }

        return "/kairo"
    }

    /// # release (driver thread)

    fn release(self) {
        if self._ci != &null {
            self.released = true
        }

        if self._act != &null {
            // build() set DisableFree so the AST outlives the parse; left set,
            // EndSourceFile LEAKS Sema, ASTContext, Preprocessor and the
            // managers (BuryPointer) and a release frees nothing. ~200 MB a
            // set on the self-host graph.
            if self._ci != &null {
                self._ci->getFrontendOpts().DisableFree = 0
            }

            if self._ci != &null && self._began {
                self._act->EndSourceFile()
            }

            self._began = false
            kairo::std::destroy(self._act)
            self._act = &null
        }

        if self._ci != &null {
            kairo::std::destroy(self._ci)
            self._ci = &null
        }

        if self._printer != &null {
            kairo::std::destroy(self._printer)
            self._printer = &null
        }
    }
}

override fn HeaderSetPPCallbacks::FileChanged(self,
                                              loc:    clang::SourceLocation,
                                              reason: clang::PPCallbacks::FileChangeReason,
                                              kind:   clang::SrcMgr::CharacteristicKind,
                                              prev:   clang::FileID) {
    if reason != clang::PPCallbacks::EnterFile {
        return
    }

    var fid = self.csm->getFileID(loc)
    var fe  = self.csm->getFileEntryRefForID(fid)
    if !fe.has_value() { // <built-in>, scratch: not a file.
        return
    }

    var name = fe->getName()
    var p    = string(unsafe ((name.data() as unsafe *const u8) as *const u8), name.size())
    if p == "<injected>" {
        return
    }

    for var i: usize = 0; i < self._set->files.size(); ++i {
        if self._set->files[i].cfid_hash == fid.getHashValue() { // re-entered (guard miss); once.
            return
        }
    }

    var hf = HeaderFile{}
    hf.path      = p
    hf.cfid_hash = fid.getHashValue()
    hf.is_system = clang::SrcMgr::isSystem(kind)
    self._set->files.push_back(hf)
}

override fn HeaderSetPPCallbacks::InclusionDirective(
    self,
    hash_loc:          clang::SourceLocation,
    const include_tok: clang::Token,
    file_name:         llvm::StringRef,
    is_angled:         bool,
    filename_range:    clang::CharSourceRange,
    file:              clang::OptionalFileEntryRef,
    search_path:       llvm::StringRef,
    relative_path:     llvm::StringRef,
    suggested_module:  unsafe *const clang::Module,
    module_imported:   bool,
    file_type:         clang::SrcMgr::CharacteristicKind,
) {
    if !file.has_value() {
        return
    }

    var e  = IncludeEdge{}
    var to = file->getName()
    e.to_path = string(unsafe ((to.data() as unsafe *const u8) as *const u8), to.size())
    var from_fid = self.csm->getFileID(hash_loc)
    var from_fe  = self.csm->getFileEntryRefForID(from_fid)
    if from_fe.has_value() {
        var fn_ = from_fe->getName()
        e.from_path = string(unsafe ((fn_.data() as unsafe *const u8) as *const u8), fn_.size())
        if e.from_path == "<injected>" {
            e.from_path = ""
        }
    }

    if e.from_path.size() == 0 {
        e.c_linkage = self._set->is_c_header(
            string(unsafe ((file_name.data() as unsafe *const u8) as *const u8), file_name.size()),
        )
    }

    self._set->includes.push_back(e)
}


override fn HeaderSetAction::CreateASTConsumer(self, @inout ci: clang::CompilerInstance, in_file: llvm::StringRef)
        -> cxx::std::unique_ptr<clang::ASTConsumer> {
    // No PCHGenerator: phase B loads the merged CodegenPCH, built
    // for every graph with a header set, and falls back to the sets' text,
    // never to a set's own PCH. Serializing each of the self-host graph's
    // 115 sets was ~11% of their build CPU, and the bytes were kept for the
    // whole run. The parse is still a TU prefix (getTranslationUnitKind).
    return cxx::std::make_unique<clang::ASTConsumer>()
}

override fn HeaderSetAction::getTranslationUnitKind(self) -> clang::TranslationUnitKind {
    return clang::TU_Prefix // a PCH is a prefix, never a whole TU.
}

override fn HeaderSetAction::BeginSourceFileAction(self,
                                                   @inout ci: clang::CompilerInstance) -> bool {
    if !clang::ASTFrontendAction::BeginSourceFileAction(self, &ci) {
        return false
    }

    var cb = cxx::std::make_unique<HeaderSetPPCallbacks>()
    cb->_set = self._set
    cb->csm  = unsafe &ci.getSourceManager()
    ci.getPreprocessor().addPPCallbacks(cxx::std::unique_ptr<clang::PPCallbacks>(cb.release()))
    return true
}
