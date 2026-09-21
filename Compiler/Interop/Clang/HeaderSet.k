/// --- The Kairo Project ------------------- Interop/Clang/HeaderSet.k --- ///
///
///   \brief Phase A of C++ header import: one clang parse per distinct
///          ORDERED header set, producing (a) a live clang AST that
///          Sema/Foreign walks and M2 queries, and (b) an in-memory PCH that
///          phase B (codegen) loads instead of re-parsing.
///
///   \par Lifecycle
///     request()  driver thread, from PPWalker::_finalize. Mints the set,
///                enqueues build() on the pool (HEADER_BUILD_GROUP). Returns
///                at once; the build overlaps parse + sema of the importer.
///     build()    pool thread. Clang parse + PCHGenerator. The instance is
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

ffi "c++" import "Native/Types.hh";
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

/// The action: PCHGenerator as the consumer, TU_Prefix like GeneratePCHAction,
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
    pub var import_dir: string;               ///< directory of the first importing file: `-I` for quoted includes.
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
    pub var cfid_to_kfid: libcxx::unordered_map::<u32, u32>;   ///< clang FileID hash -> Kairo fid. THE table.

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
    /// clang::Sema is single-threaded. Recursive because a foreign fill can
    /// nest: importing one instance's members resolves a type path into
    /// another instance of the same set, and the outer fill still holds this.
    priv var _sema_mu: std::RecursiveMutex;

    fn HeaderSet(self) {
        self.pch = libcxx::make_shared::<clang::PCHBuffer>();
    }

    fn op delete (self) { self.release(); }

    // --- Accessors (valid between build() and release()) --------------------

    fn ast(self)  -> *clang::ASTContext {
        if self._ci == &null { return &null; }
        if !self._ci->hasASTContext() { return &null; }
        return &(self._ci->getASTContext());
    }
    fn sema(self) -> *clang::Sema {
        if self._ci == &null { return &null; }
        if !self._ci->hasSema() { return &null; }
        return &(self._ci->getSema());
    }
    fn csm(self)  -> *clang::SourceManager {
        if self._ci == &null { return &null; }
        return &(self._ci->getSourceManager());
    }
    fn alive(self) -> bool { return self._ci != &null; }
    /// Hold this around any clang::Sema call from sema (M2's RequireCompleteType).
    fn sema_lock(self) -> *std::RecursiveMutex { return &(self._sema_mu); }

    fn pch_path(self) -> string { return f"/kairo/pch/{self.id}.pch"; }

    /// A header as written in the .k, minus the literal's quotes (and angle
    /// brackets, if someone wrote `"<vector>"`). The one spelling: the PP keys
    /// the set on it, build() wraps it in `#include "..."`, and the driver
    /// matches it in closure_of. Two spellings of one header would silently
    /// miss the closure and import nothing.
    static fn unquote(lit: string) -> string {
        var s = lit;
        if (s.size() >= 2) && (s[0] == '\x22') && (s[s.size() - 1] == '\x22') {
            s = string(s.raw_string().substr(1, s.size() - 2));
        }
        if (s.size() >= 2) && (s[0] == '<') && (s[s.size() - 1] == '>') {
            s = string(s.raw_string().substr(1, s.size() - 2));
        }
        return s;
    }

    /// Kairo fid for a clang FileID in THIS set's SM, or 0.
    fn kfid_for(self, cfid: clang::FileID) -> u32 {
        var it = self.cfid_to_kfid.find(cfid.getHashValue());
        if it == self.cfid_to_kfid.end() { return 0; }
        return it->second;
    }

    /// Transitive include closure of one header spelling, as PATHS, the
    /// header itself first. Empty if the spelling never resolved.
    fn closure_of(self, spelled: string, out: ref!(vec::<string>)) {
        // The direct include from the injected main whose spelling matches.
        var root: string = "";
        for var i: usize = 0; i < self.includes.size(); ++i {
            var e = self.includes[i];
            if e.from_path.size() != 0 { continue; }
            if self._spelling_matches(spelled, e.to_path) { root = e.to_path; break; }
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
            for var i: usize = 0; i < self.includes.size(); ++i {
                if self.includes[i].from_path == p { work.push_back(self.includes[i].to_path); }
            }
        }
    }

    fn kfid_of_path(self, p: string) -> u32 {
        for var i: usize = 0; i < self.files.size(); ++i {
            if self.files[i].path == p { return self.files[i].kfid; }
        }
        return 0;
    }

    priv fn _spelling_matches(self, spelled: string, path: string) -> bool {
        // `"c1.h"` vs `/abs/dir/c1.h`: suffix match on a path boundary.
        if path.size() < spelled.size() { return false; }
        var off = path.size() - spelled.size();
        if path.raw_string().compare(off, spelled.size(), spelled.raw_string()) != 0 { return false; }
        if off == 0 { return true; }
        var c = path[off - 1];
        return (c == '/') || (c == '\\');
    }

    // --- build (pool thread) ------------------------------------------------

    /// Parse the set and write the PCH. Keeps the instance alive.
    fn build(self, be: *ClangBackend) {
        var _t = TimeRegion("HeaderSetBuild");
        be->startup();                                   // idempotent, mutex-guarded.
        if !be->ready() { self.ok = false; self.built.store(true); return; }

        // Own invocation: a COPY of the backend's, so LangOpts/target/header
        // search are byte-identical (the PCH reader validates them) and this
        // instance's Inputs/OutputFile edits touch nothing shared.
        var inv = libcxx::make_shared::<clang::CompilerInvocation>(*(be->invocation()));

        self._main = libcxx::string();
        for var i: usize = 0; i < self.headers.size(); ++i {
            var h = std::string_to_nstring(self.headers[i]).raw_string();
            self._main.append(r"#include \"");
            self._main.append(h);
            self._main.append(r"\"\n");
        }
        var buf = llvm::MemoryBuffer::getMemBuffer(
            llvm::StringRef(self._main.data(), self._main.size()), r"<injected>", false);
        var fe = &(inv->getFrontendOpts());
        fe->Inputs.clear();
        fe->Inputs.push_back(clang::FrontendInputFile(
            buf->getMemBufferRef(), clang::InputKind(clang::Language::CXX)));
        fe->DisableFree = true;                          // we own the AST's lifetime.
        // A quoted include from a .k file resolves relative to that file's
        // directory, exactly as it would from a .cpp beside it. IgnoreSysRoot
        // (the last argument) MUST be true: the directory is a real absolute
        // path, and with `-isysroot` set clang would otherwise prefix it with
        // the sysroot and search /usr/<the .k's dir> -- every local ffi header
        // "file not found" the moment a sysroot is passed.
        if self.import_dir.size() > 0 {
            var e = clang::HeaderSearchOptions::Entry(
                std::string_to_nstring(self.import_dir).raw_string(),
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
        self.ok = (!failed) && (self._ci->getDiagnostics().getNumErrors() == 0) && (self.pch->IsComplete);
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

    // --- release (driver thread) -------------------------------------------

    fn release(self) {
        if self._act != &null {
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
/// \class HeaderSetCache
/// \brief key -> HeaderSet, one per build. Owned by CompilerInstance.
///
class HeaderSetCache {
    priv var _sets: libcxx::unordered_map::<libcxx::string, *HeaderSet>;
    priv var _mu:   std::Mutex;
    priv var _be:   obs::<ClangBackend>;
    priv var _pool: obs::<ThreadPool>;

    fn HeaderSetCache(self, be: *ClangBackend, pool: *ThreadPool) {
        self._be   = be;
        self._pool = pool;
    }

    fn op delete (self) {
        for var it = self._sets.begin(); it != self._sets.end(); ++it { std::destroy(it->second); }
        self._sets.clear();
    }

    static fn key_of(headers: ref!(vec::<string>)) -> string {
        var k: string = "";
        for var i: usize = 0; i < headers.size(); ++i { k += headers[i]; k += "\n"; }
        return k;
    }

    /// Get-or-mint. Mint enqueues the build. Any thread: PPWalker::_finalize
    /// calls this from the pool (the wave walks files in parallel); `_mu`
    /// covers the map, and the build touches only the set it was given.
    fn request(self, headers: vec::<string>, import_dir: string) -> *HeaderSet {
        var key = HeaderSetCache::key_of(headers);
        var nk  = libcxx::string(std::string_to_nstring(key).raw_string());
        var lock = std::LockGuard(self._mu);
        var it = self._sets.find(nk);
        if it != self._sets.end() { return it->second; }

        var hs = std::create::<HeaderSet>();
        hs->key        = key;
        hs->headers    = headers;
        hs->import_dir = import_dir;
        hs->id         = static_cast::<u32>(self._sets.size());
        self._sets.insert(libcxx::make_pair(nk, hs));

        inline "c++" {
            auto* set = hs;
            auto* be  = _be;
            auto* rec = ::kairo::TimeReport::region("HeaderSets");
            _pool->enqueue([set, be, rec]() {
                KTIME_WORKER(rec);
                set->build(be);
            }, HEADER_BUILD_GROUP());
        }
        return hs;
    }

    fn find(self, key: string) -> *HeaderSet {
        var nk = libcxx::string(std::string_to_nstring(key).raw_string());
        var lock = std::LockGuard(self._mu);
        var it = self._sets.find(nk);
        if it == self._sets.end() { return &null; }
        return it->second;
    }

    fn wait_all(self) { self._pool->wait_group(HEADER_BUILD_GROUP()); }

    fn all(self, out: ref!(vec::<*HeaderSet>)) {
        var lock = std::LockGuard(self._mu);
        for var it = self._sets.begin(); it != self._sets.end(); ++it { out.push_back(it->second); }
    }

    fn release_all(self) {
        // A build still in flight owns the very clang::CompilerInstance
        // release() destroys. --syntax-only and --preprocess stop before
        // _sema(), which is the only other place phase A is joined, so
        // without this drain the driver tears the instance down underneath
        // the parse thread: a SEGV in ~Preprocessor, or a hang.
        self.wait_all();
        var lock = std::LockGuard(self._mu);
        for var it = self._sets.begin(); it != self._sets.end(); ++it { it->second->release(); }
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
    self._set->includes.push_back(e);
}


fn HeaderSetAction::CreateASTConsumer(ci: ref!(clang::CompilerInstance), in_file: llvm::StringRef)
        -> libcxx::unique_ptr::<clang::ASTConsumer> {
    // VERIFY(22.x): ctor order (PP, ModCache, OutputFile, isysroot, Buffer,
    // CodeGenOpts, Extensions, AllowASTWithErrors, IncludeTimestamps, ...)
    // confirmed against release/22.x ASTWriter.h:1015.
    return libcxx::make_unique::<clang::PCHGenerator>(
        ci.getPreprocessor(), ci.getModuleCache(),
        llvm::StringRef(r"<kairo-hdrs>.pch"), llvm::StringRef(r""),
        self._set->pch,
        ci.getCodeGenOpts(),
        ci.getFrontendOpts().ModuleFileExtensions,
        false, false);
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