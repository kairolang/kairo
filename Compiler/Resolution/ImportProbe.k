/// --- The Kairo Project --------------------- Resolution/ImportProbe.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
/// \file ImportResolver.k
/// \brief module and file resolution subsystem for the kairo compiler frontend
///
/// this file implements the import resolution machinery used during semantic
/// analysis to map qualified import paths (e.g. `Include::FileSystem`)
/// to concrete filesystem paths. the resolver maintains a priority-ordered
/// list of search roots and builds a trie-based directory index for fast
/// lookups.
///
/// the indexing operation can be performed asynchronously via a thread pool.
/// callers must either check `is_index_ready()` or call `wait_for_index()`
/// before invoking resolution methods. all resolution methods block on index
/// completion internally, so external synchronization is not strictly
/// required but may avoid unnecessary spinning.
///
/// \note the cache uses a simple string key and does not track filesystem
///       modifications. call `invalidate_cache()` or `rebuild_all()` after
///       external changes to the search paths.
///
/// \warning ambiguous module resolution (file and directory with same stem)
///          returns `ResolveError::AmbiguousModule` even though a valid path
///          is cached. this is intentional-callers should treat ambiguity as
///          a diagnostic-worthy condition.
///
///-----------------------------------------------------------------------------

// FIXME(permission-denied): filesystem::directory_iterator throws
//      std::filesystem::filesystem_error when it hits an unreadable directory,
//      which currently unwinds to std::terminate. SearchRoot::build_index needs
//      a try/catch around each directory traversal step so partial indexing can
//      continue on accessible siblings. Denied roots should be flagged with a
//      `permission_denied` bool so resolution skips traversal but still returns
//      ResolveError::PermissionDenied (not NotFound) when a lookup targets a
//      denied root giving the preprocessor enough signal to emit a useful
//      diagnostic rather than a silent "module not found".

// FIXME(async-indexing): currently the resolver builds the index synchronously
//      on the calling thread. this is because libcxx::filesystem touches locale
//      state on first use and throws std::runtime_error when invoked on worker
//      threads where libc++ locale state is uninitialized. rn in kairo/ the
//      walk phase alone takes up seconds of time, since kairo/ has all of llvm
//      and all of libc source in its search paths its awfully slow to index.

ffi "c++" import "Native/Types.hh";

import Support::FileIO::Path::*;
import Support::FileIO::FileSystem::*;
import Memory::MappedFileBuffer::*;
import Threading::ThreadPool::*;
import Support::Timer::*;
import Support::Assert::*;
import Resolution::FileExtensions::*;
import Resolution::DirEntry::*;
import Resolution::SearchRoot::*;

/// \enum ResolveError
/// \brief error conditions returned by resolution methods
enum ResolveError {
    NotFound,         ///< no matching file or module found in any search root
    AmbiguousModule,  ///< both a file and directory match the final segment
    InvalidLibrary,   ///< reserved
    PermissionDenied, ///< reserved
    CyclicImport,     ///< reserved
}

/// \enum ModuleOrigin
/// \brief which candidate set produced a module resolution.
enum ModuleOrigin derives u8 {
    Root = 0,   ///< found by walking the search roots (cwd + -m/-I dirs).
    Sibling,    ///< found in the IMPORTING file's own directory.
}

/// \class ModuleResolution
/// \brief the result of a relative-aware module resolution.
///
/// \details `canonical` is the module's IDENTITY: the path segments from the
///          owning search root down to the file, NOT the segments the import
///          spelled. Two files never share a canonical path, and one file
///          always has exactly one, no matter how it was reached. Codegen
///          derives the C++ namespace path from this (CODEGEN.md 1: the
///          bijection module-path <-> namespace-path is what makes mangling
///          deterministic and ODR-safe), so it must never depend on the
///          importer's spelling.
///
///          `ambiguous` means the name matched BOTH a sibling module and a
///          root module: a hard error at the import site (R017E). The sibling
///          is still returned so resolution does not cascade into a second
///          "not found" for the same import.
class ModuleResolution {
    pub var found:      bool         = false;
    pub var path:       Path;                        ///< the resolved file.
    pub var canonical:  vec::<string>;               ///< identity segments from the search root.
    pub var origin:     ModuleOrigin = ModuleOrigin::Root;
    pub var ambiguous:  bool         = false;        ///< sibling AND root both matched.
    pub var other_path: Path;                        ///< the losing (root) candidate, iff ambiguous.
    pub var file_dir:   bool         = false;        ///< a file AND a directory matched the last segment.
}

/// \class ModuleNameCollision
/// \brief two files in one directory claiming a single module identity.
///
/// \details Same class of fault as an ambiguous import, one layer down: the
///          module name is derived from the filename, so `Foo.k`/`foo.k` (two
///          files on Linux, ONE on default macOS/Windows) and `foo-bar.k`/
///          `foo_bar.k` (both spell module `foo_bar`) are non-portable or
///          outright ambiguous. Discovered during module discovery, once per
///          directory; reported by the caller that owns a DiagEngine.
class ModuleNameCollision {
    pub var dir:       string;         ///< absolute directory that holds both.
    pub var a:         string;         ///< first name, sorted order.
    pub var b:         string;         ///< second name.
    pub var ident:     string;         ///< the module identity they both claim.
    pub var case_only: bool = false;   ///< true: differ only by case (portability).
}

/// \class ImportResolver
/// \brief resolves qualified module paths and file names against a set of
///        indexed search roots
///
/// the resolver is constructed via the nested `Builder` class. once built,
/// the index is populated either synchronously or via a thread pool. all
/// resolution methods block until indexing completes.
///
/// ownership semantics:
/// - search roots are heap-allocated and owned by this resolver
/// - the `FileExtensions` config is optionally owned depending on whether
///   one was provided at construction time
///
/// \note the resolver uses raw pointers (`*T`) rather than managed handles.
///       ensure the resolver outlives any references to returned paths.
class ImportResolver {
    priv var _cache:           map::<string, Path>;      ///< resolution cache keyed by "prefix:seg1::seg2::..."
    priv var _roots:           vec::<own::<SearchRoot>>; ///< priority-sorted search roots (index 0 = cwd)
    priv var _ext_cfg:         oot::<FileExtensions>;    ///< file extension classification config
    priv var _owns_ext_cfg:    bool;                     ///< true if destructor should free `_ext_cfg`

    /// Transient roots for sibling-relative probing, keyed by absolute dir.
    /// Owned; built lazily (SearchRoot construction is a couple of stats, the
    /// walk is lazy) so importing files in N directories costs N of these.
    priv var _sibling_roots:    map::<string, own::<SearchRoot>>;

    /// Directories already swept for module-name collisions, and the findings
    /// not yet drained. Reporting is deferred because discovery runs in the
    /// DepScanner (no DiagEngine) before it runs in the PP walk (which has
    /// one) - see take_collisions().
    priv var _swept_dirs:       set::<string>;
    priv var _collisions:       vec::<ModuleNameCollision>;

    /// \class Builder
    /// \brief fluent builder for constructing an `ImportResolver`
    ///
    /// usage:
    /// \code
    ///   var resolver = ImportResolver::Builder()
    ///       .cwd(my_cwd)
    ///       .add_include(some_path)
    ///       .extensions(&ext_cfg)
    ///       .build(&pool);
    /// \endcode
    ///
    /// if `build()` is called with a non-null thread pool, indexing is
    /// enqueued and returns immediately. otherwise indexing blocks.
    pub class Builder {
        priv var _cwd:           std::Nullable::<Path>;
        priv var _include_paths: vec::<Path>;
        priv var _ext_cfg:       *FileExtensions;
        priv var _pool:          *ThreadPool;

        /// \brief default constructor; initializes all fields to null/empty
        fn Builder(self) {
            self._cwd           = null;
            self._include_paths = vec::<Path>();
            self._ext_cfg       = &null;
            self._pool          = &null;
        }

        /// \brief sets the current working directory as the highest-priority search root
        /// \param path the directory to use as cwd
        /// \return pointer to self for chaining
        fn cwd(self, path: Path) -> ref!(Builder) {
            self._cwd = path;
            return self;
        }

        /// \brief appends a single include path to the search list
        /// \param path the directory to add
        /// \return pointer to self for chaining
        fn add_include(self, path: Path) -> ref!(Builder) {
            self._include_paths.push_back(path);
            return self;
        }

        /// \brief appends multiple include paths to the search list
        /// \param paths vector of directories to add
        /// \return pointer to self for chaining
        fn add_includes(self, paths: vec::<Path>) -> ref!(Builder) {
            for p: Path in paths {
                self._include_paths.push_back(p);
            }
            return self;
        }

        /// \brief sets the file extension configuration
        /// \param cfg pointer to an existing config; if null, a default is created
        /// \return pointer to self for chaining
        fn extensions(self, cfg: *FileExtensions) -> ref!(Builder) {
            self._ext_cfg = cfg;
            return self;
        }

        /// \brief constructs the resolver and initiates indexing
        /// \param pool optional thread pool for async indexing; if null, blocks until done
        /// \return heap-allocated resolver; caller assumes ownership
        fn create_ptr(self, pool: *ThreadPool = &null) -> *ImportResolver {
            var cwd_path = self._cwd.value_or(Path(
                libcxx::filesystem::current_path().generic_wstring(),
                false
            ));
            var resolver = std::create::<ImportResolver>(self._ext_cfg);

            // Always index synchronously on the calling (main) thread.
            // libcxx::filesystem::directory_iterator touches locale on first use
            // and throws std::runtime_error on worker threads where libc++ locale
            // state is uninitialised. Async indexing bought nothing anyway since
            // CompilationBatch::run() calls wait_for_index() before dispatching
            // any TU tasks - the spin was immediate and free-threaded for zero gain.
            resolver->build_index(cwd_path, self._include_paths, &null);
            return resolver;
        }
    }

    /// \brief direct constructor; prefer using `Builder` instead
    /// \param ext_cfg optional extension config; if null, a default is allocated and owned
    fn ImportResolver(self, ext_cfg: *FileExtensions = &null) {
        self._roots = vec::<*SearchRoot>();
        self._cache = map::<string, Path>();

        if ext_cfg != &null {
            self._ext_cfg      = ext_cfg;
            self._owns_ext_cfg = false;
        } else {
            self._ext_cfg      = std::create::<FileExtensions>();
            self._owns_ext_cfg = true;
        }
    }

    /// \brief builds the directory index for all search roots
    /// \param cwd the current working directory (priority 0)
    /// \param include_paths additional include directories (priority 1+)
    /// \param pool optional thread pool; currently unused in body but reserved for parallel indexing
    fn build_index(self, cwd: Path, include_paths: vec::<Path>, pool: *ThreadPool = &null) {
        Logger::info(Logger::Stage::Preprocessor,
            f"ImportResolver::build_index: cwd='{cwd.full_path()}' roots={include_paths.size() + 1}");

        // Build the root list. Cheap: path checks only. SearchRoot's constructor
        // stamps each root's fs_path and ext_cfg so it can probe lazily on first
        // access; there is no eager directory walk here anymore.
        if cwd.exists() && cwd.is_directory() {
            var root = std::create::<SearchRoot>(cwd, 0, self._ext_cfg);
            self._roots.push_back(root);
        }

        var priority: u32 = 1;
        for p: Path in include_paths {
            if p.exists() && p.is_directory() {
                var root = std::create::<SearchRoot>(p, priority, self._ext_cfg);
                self._roots.push_back(root);
                priority += 1;
            }
        }

        // `pool` retained for signature compatibility; lazy resolution needs no
        // worker dispatch. Resolution methods probe on demand; wait_for_index() is
        // a no-op.
        Logger::info(Logger::Stage::Preprocessor,
            f"ImportResolver::build_index: registered roots={self._roots.size()}");
    }

    /// \brief destructor; frees all owned search roots and optionally the extension config
    fn op delete (self) {
        for root: *SearchRoot in self._roots {
            if root != &null {
                std::destroy(root);
            }
        }
        self._roots.clear();
        self._cache.clear();

        for var it = self._sibling_roots.begin(); it != self._sibling_roots.end(); ++it {
            if it->second != &null {
                std::destroy(it->second);
            }
        }
        self._sibling_roots.clear();

        if self._owns_ext_cfg && (self._ext_cfg != &null) {
            std::destroy(self._ext_cfg);
        }
    }

    /// \brief returns the extension configuration in use
    /// \return non-owning pointer to the extension config
    fn extensions(self) -> *FileExtensions {
        return self._ext_cfg;
    }

    /// \brief spin-waits until indexing is complete
    ///
    /// uses `libcxx::this_thread::yield()` to avoid busy-waiting.
    fn wait_for_index(self) {
        // Lazy resolution: no index to wait on. Retained for API compatibility.
    }

    /// \brief checks whether indexing has finished
    /// \return true if the index is ready for queries
    fn is_index_ready(self) -> bool {
        return true;
    }

    /// \brief resolves a qualified module path to a filesystem path
    /// \param segments path segments, e.g. ["Core", "Include", "FileSystem"]
    /// \return the resolved path, or an error
    ///
    /// resolution order:
    /// 1. traverse directories matching segments[0..n-1]
    /// 2. look for a file with stem matching segments[n-1] and category KairoSource
    /// 3. if no file, look for a directory with that name containing `module.k`
    ///
    /// \note returns `AmbiguousModule` if both a file and directory match, but still
    ///       caches and returns the file path. this is arguably a bug-callers receiving
    ///       `AmbiguousModule` cannot distinguish success from failure without inspecting
    ///       the cache manually.
    fn resolve_module(self, segments: vec::<string>)
        -> std::Expected::<Path, ResolveError>
    {
        self.wait_for_index();

        if segments.size() == 0 {
            return ResolveError::NotFound;
        }

        var cache_key = self.make_cache_key("mod", segments);

        if self._cache.contains(cache_key) {
            return self._cache[cache_key];
        }

        for root: *SearchRoot in self._roots {
            var node = root->root;
            for i in range::<usize>(0, segments.size() - 1) {
                node = node->find_dir(segments[i]);
                if node == &null {
                    break;
                }
            }

            if node == &null {
                continue;
            }

            var last = segments[segments.size() - 1];

            var file_node = node->find_by_stem_and_category(last, FileCategory::KairoSource);
            if (file_node != &null) && (file_node->file_path) {
                self._cache[cache_key] = *(file_node->file_path);

                var dir_node = node->find_dir(last);
                if dir_node != &null {
                    return ResolveError::AmbiguousModule;
                }

                return *(file_node->file_path);
            }

            var dir_node = node->find_dir(last);
            if dir_node != &null {
                var mod_node = dir_node->find_by_stem_and_category("module", FileCategory::KairoSource);
                if (mod_node != &null) && (mod_node->file_path) {
                    self._cache[cache_key] = *(mod_node->file_path);
                    return *(mod_node->file_path);
                }
            }
        }

        Logger::debug(Logger::Stage::Preprocessor, f"ImportResolver::resolve_module: not found key='{cache_key}\x27");
        return ResolveError::NotFound;
    }

    /// \brief resolves a module directory path and returns its `module.k` entry point
    /// \param segments path segments identifying the directory
    /// \return path to `module.k` inside the directory, or an error
    fn resolve_module_dir(self, segments: vec::<string>)
        -> std::Expected::<Path, ResolveError>
    {
        self.wait_for_index();

        for root: *SearchRoot in self._roots {
            var node = root->traverse(segments);

            if (node == &null) || (!node->is_dir) {
                continue;
            }

            var mod_node = node->find_by_stem_and_category("module", FileCategory::KairoSource);

            if (mod_node != &null) && (mod_node->category == FileCategory::KairoSource) {
                return (*(mod_node->file_path));
            }
        }

        Logger::debug(Logger::Stage::Preprocessor, f"ImportResolver::resolve_module_dir: not found segments={segments.size()}");
        return ResolveError::NotFound;
    }

    //  Relative-aware module resolution (THE home of import path semantics)
    //
    //  `import baz` inside `root/Foo/bar.k` means:
    //    1. `Foo/baz.k`  - the importing file's OWN directory, first;
    //    2. `root/baz.k` - the search roots, second;
    //    3. if BOTH exist and they are different files: hard error, qualify.
    //
    //  Rule 3 is the whole point. Sibling-first without it is Python 2's
    //  implicit relative import, which Python removed in 3 because adding
    //  `root/baz.k` silently changed what `import baz` meant three directories
    //  away. Erroring on the collision keeps the ergonomics and kills the
    //  action-at-a-distance: the day the tree becomes ambiguous, you are told,
    //  at the import that became ambiguous.
    //
    //  Module IDENTITY never comes from the spelling - see canonical_module_path.

    /// \brief resolves a module path, probing the importing file's directory
    ///        before the search roots.
    /// \param segments  the path as written (e.g. ["baz"] or ["util","fmt"])
    /// \param is_module true for `import module Foo` (directory modules only)
    /// \param from_dir  the IMPORTING file's directory
    /// \param has_from  false when there is no importing file (entry point)
    /// \return a resolution carrying the file, its canonical identity, and
    ///         whether the sibling/root candidates collided.
    fn resolve_module_rel(self, segments: vec::<string>, is_module: bool,
                          from_dir: Path, has_from: bool) -> ModuleResolution {
        var out = ModuleResolution{};
        if segments.size() == 0 { return out; }

        var sib_hit  = false;
        var sib_path: Path;

        // 1. sibling candidate. Skipped when the importing file already lives
        //    in a search root: the two probes would be the same probe.
        if (has_from) && (!self._is_root_dir(from_dir)) {
            var sib_root = self._sibling_root_for(from_dir);
            if sib_root != &null {
                var h = self._probe_root(sib_root, segments, is_module);
                if h.found { sib_hit = true; sib_path = h.path; out.file_dir = h.file_dir; }
            }
        }

        // 2. root candidate (priority order: cwd, then -m/-I dirs).
        var root_hit  = false;
        var root_path: Path;
        var ri: usize = 0;
        while (ri < self._roots.size()) && (!root_hit) {
            var h = self._probe_root(self._roots[ri], segments, is_module);
            if h.found {
                root_hit  = true;
                root_path = h.path;
                if !sib_hit { out.file_dir = h.file_dir; }
            }
            ri += 1;
        }

        if (!sib_hit) && (!root_hit) { return out; }

        if sib_hit {
            out.found  = true;
            out.path   = sib_path;
            out.origin = ModuleOrigin::Sibling;
            // 3. collision. Same file reached two ways is not a collision.
            if root_hit && (root_path.full_path() != sib_path.full_path()) {
                out.ambiguous  = true;
                out.other_path = root_path;
            }
        } else {
            out.found  = true;
            out.path   = root_path;
            out.origin = ModuleOrigin::Root;
        }

        out.canonical = self.canonical_module_path(out.path);
        if out.canonical.size() == 0 {
            // Resolved outside every search root (rare: an absolute -I sibling
            // walk). Fall back to the written spelling rather than handing
            // codegen an empty namespace path.
            out.canonical = segments;
        }
        return out;
    }

    /// \brief the module IDENTITY of a file: its path segments relative to the
    ///        deepest search root that contains it.
    ///
    /// \details This, not the import spelling, is what a file's module path
    ///          means. `root/Foo/baz.k` is `Foo::baz` whether it was reached as
    ///          `import Foo::baz` from the root or `import baz` from its
    ///          sibling. `root/std/mem/module.k` is `std::mem` - the `module`
    ///          leaf names the directory's entry point, not a segment.
    ///          `-` maps to `_` per the filename policy (CODEGEN.md 2).
    /// \return the segments, or empty if the file is under no search root.
    fn canonical_module_path(self, file: Path) -> vec::<string> {
        var out = vec::<string>();

        var best_rel = "";
        var best_len: usize = 0;
        for var i: usize = 0; i < self._roots.size(); ++i {
            var root = self._roots[i];
            var rel  = self._relative_to(file, root->base_path);
            if rel.size() == 0 { continue; }
            // Deepest containing root wins, so a nested -I dir does not get
            // shadowed by an outer one into a longer, wrong identity.
            var base_len = root->base_path.full_path().size();
            if (best_rel.size() == 0) || (base_len > best_len) {
                best_rel = rel;
                best_len = base_len;
            }
        }
        if best_rel.size() == 0 { return out; }

        var parts = self.split_path(best_rel);
        if parts.size() == 0 { return out; }

        // strip the extension off the leaf
        var leaf     = parts[parts.size() - 1];
        var dot_pos  = leaf.rfind(".");
        if dot_pos != null { leaf = leaf.raw_string().substr(0, (*dot_pos)); }
        parts[parts.size() - 1] = leaf;

        // `Foo/module.k` IS module `Foo`; the leaf names the directory entry.
        if (leaf == "module") && (parts.size() > 1) { parts.pop_back(); }

        for var i: usize = 0; i < parts.size(); ++i {
            out.push_back(self.module_ident(parts[i]));
        }
        return out;
    }

    /// \brief drains module-name collisions found during discovery.
    ///
    /// \details Discovery runs first in the DepScanner, which has no
    ///          DiagEngine, so findings are queued here and drained by the PP
    ///          walk (FileImportIndex), which does. Each directory is swept
    ///          exactly once, so every collision is reported exactly once no
    ///          matter how many imports pass through it.
    fn take_collisions(self) -> vec::<ModuleNameCollision> {
        var out = self._collisions;
        self._collisions.clear();
        return out;
    }

    /// \brief the module identity a filename claims: `-` folded to `_`.
    ///
    /// \details `foo-bar.k` names module `foo_bar` (CODEGEN.md 2): module path
    ///          segments must be valid identifiers, and `-` is the one
    ///          pragmatic exception rather than an escaping scheme that would
    ///          leak into mangled names forever.
    fn module_ident(self, name: string) -> string {
        var out = name;
        inline "c++" {
            auto &r = out.raw_string();
            for (size_t i = 0; i < r.size(); ++i) {
                if (r[i] == WIDE_STR('-')) { r[i] = WIDE_STR('_'); }
            }
        }
        return out;
    }

    // --- relative resolution internals ---------------------------------------

    struct RootHit {
        var found:    bool = false;
        var path:     Path;
        var file_dir: bool = false;   ///< a file AND a directory matched the leaf
    }

    /// One root, one probe. Mirrors resolve_module/resolve_module_dir for a
    /// single root so sibling and root candidates are resolved by identical
    /// rules. Sweeps the containing directory for name collisions on the way.
    priv fn _probe_root(self, root: *SearchRoot, segments: vec::<string>,
                        is_module: bool) -> RootHit {
        var out = RootHit{};
        if root == &null { return out; }

        var node = root->root;
        for var i: usize = 0; (i + 1) < segments.size(); ++i {
            node = node->find_dir(segments[i]);
            if node == &null { return out; }
        }

        var last = segments[segments.size() - 1];
        self._sweep_dir(node);

        if !is_module {
            var file_node = node->find_by_stem_and_category(last, FileCategory::KairoSource);
            if (file_node != &null) && (file_node->file_path) {
                out.found    = true;
                out.path     = *(file_node->file_path);
                out.file_dir = (node->find_dir(last) != &null);
                return out;
            }
        }

        var dir_node = node->find_dir(last);
        if dir_node != &null {
            var mod_node = dir_node->find_by_stem_and_category("module", FileCategory::KairoSource);
            if (mod_node != &null) && (mod_node->file_path) {
                out.found = true;
                out.path  = *(mod_node->file_path);
                return out;
            }
        }
        return out;
    }

    /// Get-or-create the transient SearchRoot for an importing file's dir.
    priv fn _sibling_root_for(self, dir: Path) -> *SearchRoot {
        var key = dir.full_path();
        if self._sibling_roots.contains(key) { return self._sibling_roots[key]; }
        if (!dir.exists()) || (!dir.is_directory()) { return &null; }

        // priority u32(-1): never competes with a real root, and is only ever
        // reached through resolve_module_rel.
        var r = std::create::<SearchRoot>(dir, u32(-1), self._ext_cfg);
        self._sibling_roots[key] = r;
        return r;
    }

    priv fn _is_root_dir(self, dir: Path) -> bool {
        var full = dir.full_path();
        for var i: usize = 0; i < self._roots.size(); ++i {
            if self._roots[i]->base_path.full_path() == full { return true; }
        }
        return false;
    }

    /// `file` relative to `base`, or "" when `file` is not under `base`.
    priv fn _relative_to(self, file: Path, base: Path) -> string {
        var rel = string();
        inline "c++" {
            auto r = file.path_data.lexically_relative(base.path_data);
            if (!r.empty()) {
                auto s = r.generic_wstring();
                // "..", "../x", "" all mean: not contained.
                if (s != WIDE_STR(".") &&
                    !(s.size() >= 2 && s[0] == WIDE_STR('.') && s[1] == WIDE_STR('.'))) {
                    rel = s;
                }
            }
        }
        return rel;
    }

    // --- module-name collision sweep (module discovery) ----------------------

    /// One readdir per directory that actually hosts a resolved module, ever.
    /// Two names claiming one module identity is the same fault as an ambiguous
    /// import, one layer down, so it gets found in the same pass that resolves
    /// the import. Directories nobody imports from are never scanned - the
    /// lazy-probe design survives.
    priv fn _sweep_dir(self, dir: *DirEntry) {
        if (dir == &null) || (!dir->is_dir) { return; }
        if !dir->fs_path { return; }

        var key = (*(dir->fs_path)).full_path();
        if self._swept_dirs.contains(key) { return; }
        self._swept_dirs.insert(key);

        dir->ensure_scanned();

        // Sorted, so a collision is reported with the same pair ordering on
        // every run (children is an unordered_map).
        var names = vec::<string>();
        for var it = dir->children.begin(); it != dir->children.end(); ++it {
            var child = it->second;
            if child == &null { continue; }
            if child->name.size() == 0 { continue; }
            if (!child->is_dir) && (child->category != FileCategory::KairoSource) { continue; }
            names.push_back(child->name);
        }
        libcxx::sort(names.begin(), names.end());

        var seen = map::<string, string>();   // identity -> first claimant
        for var i: usize = 0; i < names.size(); ++i {
            var raw   = names[i];
            var ident = self._lower(self.module_ident(raw));
            if !seen.contains(ident) { seen[ident] = raw; continue; }

            var other = seen[ident];
            if other == raw { continue; }     // a dir and its own module.k, etc.

            var c = ModuleNameCollision{};
            c.dir       = key;
            c.a         = other;
            c.b         = raw;
            c.ident     = self.module_ident(other);
            c.case_only = self._lower(other) == self._lower(raw);
            self._collisions.push_back(c);
        }
    }

    priv fn _lower(self, s: string) -> string {
        var out = s;
        inline "c++" {
            auto &r = out.raw_string();
            for (size_t i = 0; i < r.size(); ++i) {
                if (r[i] >= WIDE_STR('A') && r[i] <= WIDE_STR('Z')) {
                    r[i] = static_cast<::std::remove_reference_t<decltype(r[i])>>(r[i] + 32);
                }
            }
        }
        return out;
    }

    /// \brief resolves a kairo library (.hlib) by name
    /// \param name library stem without extension
    /// \return the resolved path, or NotFound
    fn resolve_library(self, name: string)
        -> std::Expected::<Path, ResolveError>
    {
        self.wait_for_index();

        for root: *SearchRoot in self._roots {
            var node = root->root->find_by_stem_and_category(name, FileCategory::KairoLibrary);
            if (node != &null) && (node->file_path) {
                return *(node->file_path);
            }
        }

        return ResolveError::NotFound;
    }

    /// \brief collects all exportable module names under a given path
    /// \param segments path to the directory to scan
    /// \return vector of file stems (excluding "module")
    ///
    /// stops after the first root that yields results.
    fn collect_exports(self, segments: vec::<string>) -> vec::<string> {
        var result = vec::<string>();

        for root: *SearchRoot in self._roots {
            var node = root->traverse(segments);

            if (node == &null) || (!node->is_dir) {
                continue;
            }

            var files = node->collect_by_category(FileCategory::KairoSource);

            for f: *DirEntry in files {
                if f->name != "module" {
                    result.push_back(f->name);
                }
            }

            if result.size() > 0 {
                break;
            }
        }

        return result;
    }

    /// \brief resolves a C++ header by stem
    /// \param name header stem without extension
    /// \return the resolved path, or NotFound
    fn resolve_cxx_header(self, name: string)
        -> std::Expected::<Path, ResolveError>
    {
        self.wait_for_index();

        return self.resolve_by_category(name, FileCategory::CxxHeader);
    }

    /// \brief resolves a C++ source file by stem
    /// \param name source stem without extension
    /// \return the resolved path, or NotFound
    fn resolve_cxx_source(self, name: string)
        -> std::Expected::<Path, ResolveError>
    {
        self.wait_for_index();

        return self.resolve_by_category(name, FileCategory::CxxSource);
    }

    /// \brief resolves a C header by stem
    /// \param name header stem without extension
    /// \return the resolved path, or NotFound
    fn resolve_c_header(self, name: string)
        -> std::Expected::<Path, ResolveError>
    {
        self.wait_for_index();

        return self.resolve_by_category(name, FileCategory::CHeader);
    }

    /// \brief resolves a C source file by stem
    /// \param name source stem without extension
    /// \return the resolved path, or NotFound
    fn resolve_c_source(self, name: string)
        -> std::Expected::<Path, ResolveError>
    {
        self.wait_for_index();

        return self.resolve_by_category(name, FileCategory::CSource);
    }

    /// \brief resolves a C/C++ include path as written in `#include` directives
    /// \param include_path the path string, e.g. "foo/bar.h" or "baz"
    /// \return the resolved path, or NotFound
    ///
    /// if no extension is provided, tries all known C++ header extensions.
    fn resolve_cxx_include(self, include_path: string)
        -> std::Expected::<Path, ResolveError>
    {
        self.wait_for_index();

        var segments = self.split_path(include_path);

        if segments.size() == 0 {
            return ResolveError::NotFound;
        }

        var last = segments[segments.size() - 1];
        segments.pop_back();

        var dot_pos = last.rfind(".");
        var stem    = last;
        var ext     = string();

        if dot_pos != null {
            stem = last.raw_string().substr(0, (*dot_pos));
            ext  = last.raw_string().substr((*dot_pos) + 1);
        }

        for root: *SearchRoot in self._roots {
            var node = root->traverse(segments);

            if node == &null {
                node = root->root;
            }

            if ext.size() > 0 {
                var file_node = node->find_with_ext(stem, ext);
                if (file_node != &null) && (file_node->file_path) {
                    return (*(file_node->file_path));
                }
            } else {
                var header_exts = self._ext_cfg->cxx_header_exts();
                for hext: string in header_exts {
                    var file_node = node->find_with_ext(stem, hext);
                    if (file_node != &null) && (file_node->file_path) {
                        return (*(file_node->file_path));
                    }
                }
            }
        }

        return ResolveError::NotFound;
    }

    /// \brief resolves a file by category in the root directories (non-recursive)
    /// \param name file stem
    /// \param cat category to match
    /// \return the resolved path, or NotFound
    fn resolve_by_category(self, name: string, cat: FileCategory)
        -> std::Expected::<Path, ResolveError>
    {
        self.wait_for_index();

        for root: *SearchRoot in self._roots {
            var node = root->root->find(name);

            if (node != &null) && (node->category == cat) {
                return (*(node->file_path));
            }
        }

        return ResolveError::NotFound;
    }

    /// \brief resolves a file by stem and explicit extension
    /// \param name file stem
    /// \param ext extension without leading dot
    /// \return the resolved path, or NotFound
    fn resolve_by_ext(self, name: string, ext: string)
        -> std::Expected::<Path, ResolveError>
    {
        self.wait_for_index();

        for root: *SearchRoot in self._roots {
            var node = root->root->find_with_ext(name, ext);

            if (node != &null) && (node->file_path) {
                return (*(node->file_path));
            }
        }

        return ResolveError::NotFound;
    }

    /// \brief resolves an arbitrary file given path segments
    /// \param segments path components; last element is the filename
    /// \return the resolved path, or NotFound
    ///
    /// if the filename has no extension, attempts to match any file with that stem.
    fn resolve_file(self, segments: vec::<string>) -> std::Expected::<Path, ResolveError> {
        self.wait_for_index();

        if segments.size() == 0 {
            return ResolveError::NotFound;
        }

        var dir_segments = segments;
        var file_name    = dir_segments[dir_segments.size() - 1];
        dir_segments.pop_back();

        for root: *SearchRoot in self._roots {
            var node = root->root;

            if dir_segments.size() > 0 {
                node = root->traverse(dir_segments);
            }

            if node == &null {
                continue;
            }

            var file_node = node->find(file_name);

            if (file_node == &null) && (file_name.rfind(".") == null) {
                for entry in node->children {
                    var child = entry.second;
                    if (!child->is_dir) && (child->name == file_name) && (child->ext.size() == 0) {
                        file_node = child;
                        break;
                    }
                }
            }

            if (file_node != &null) && (!file_node->is_dir) && (file_node->file_path) {
                return *(file_node->file_path);
            }
        }

        return ResolveError::NotFound;
    }

    /// \brief resolves a relative path from the location of another file
    /// \param rel_path the relative path string
    /// \param from_file the file whose directory is used as the base
    /// \return the resolved path, or NotFound
    ///
    /// falls back to searching search roots if not found relative to `from_file`.
    fn resolve_path(self, rel_path: string, from_file: Path)
        -> std::Expected::<Path, ResolveError>
    {
        self.wait_for_index();

        var parent_path  = from_file.path_data.parent_path();
        var candidate_fs = parent_path / libcxx::filesystem::path(rel_path.raw_string());

        if libcxx::filesystem::exists(candidate_fs) {
            return (
                Path(candidate_fs.generic_wstring(), false)
            );
        }

        for root: *SearchRoot in self._roots {
            candidate_fs = root->base_path.path_data / libcxx::filesystem::path(rel_path.raw_string());

            if libcxx::filesystem::exists(candidate_fs) {
                return (
                    Path(candidate_fs.generic_wstring(), false)
                );
            }
        }

        return ResolveError::NotFound;
    }

    /// \brief checks if a relative path exists under any search root
    /// \param rel_path the relative path to check
    /// \return true if the path exists
    fn path_exists(self, rel_path: string) -> bool {
        for root: *SearchRoot in self._roots {
            var candidate = root->base_path.path_data / libcxx::filesystem::path(rel_path.raw_string());

            if libcxx::filesystem::exists(candidate) {
                return true;
            }
        }

        return false;
    }

    /// \brief collects all files matching a category across all roots (recursive)
    /// \param cat the file category to collect
    /// \return vector of paths; duplicates are filtered by full path string
    fn collect_all_by_category(self, cat: FileCategory) -> vec::<Path> {
        var result = vec::<Path>();
        var seen   = map::<string, bool>();

        for root: *SearchRoot in self._roots {
            self.collect_recursive(root->root, cat, &result, &seen);
        }

        return result;
    }

    priv fn collect_recursive(
        self,
        node:   *DirEntry,
        cat:    FileCategory,
        result: *vec::<Path>,
        seen:   *map::<string, bool>
    ) {
        var files = node->collect_by_category(cat);

        for f: *DirEntry in files {
            var path_str = (*(f->file_path)).full_path();
            if !(seen->contains(path_str)) {
                (*seen)[path_str] = true;
                result->push_back(*(f->file_path));
            }
        }

        for entry in node->children {
            var child = entry.second;
            if child->is_dir {
                self.collect_recursive(child, cat, result, seen);
            }
        }
    }


    /// \brief clears the resolution cache
    fn invalidate_cache(self) {
        self._cache.clear();
    }

    /// \brief rebuilds a single search root by index
    /// \param index the root index in `_roots`
    ///
    /// destroys and recreates the root, then invalidates the cache.
    fn rebuild_root(self, index: usize) {
        if index >= self._roots.size() {
            return;
        }

        var old      = self._roots[index];
        var path     = old->base_path;
        var priority = old->priority;

        std::destroy(old);
        self._roots[index] = std::create::<SearchRoot>(path, priority, self._ext_cfg);

        self.invalidate_cache();
    }

    /// \brief rebuilds all search roots
    fn rebuild_all(self) {
        for i in range::<usize>(0, self._roots.size()) {
            self.rebuild_root(i);
        }
    }

    /// \brief returns a human-readable dump of search paths with priorities
    fn dump_search_paths(self) -> string {
        var result = "ImportResolver search paths:\n";

        for i in range::<usize>(0, self._roots.size()) {
            var root = self._roots[i];
            result += f"  [{root->priority}] {root->base_path.full_path()}\n";
        }

        return result;
    }

    /// \brief returns a summary of cache statistics
    fn cache_stats(self) -> string {
        return f"ImportResolver cache: {self._cache.size()} entries";
    }

    /// \brief returns a human-readable dump of all indexed files matching a category
    /// \param cat the category to dump
    fn dump_indexed_files(self, cat: FileCategory) -> string {
        var files  = self.collect_all_by_category(cat);
        var result = f"Indexed files (category {static_cast::<u32>(cat)}):\n";

        for p: Path in files {
            result += f"  {p.full_path()}\n";
        }

        return result;
    }

    priv fn make_cache_key(self, prefix: string, segments: vec::<string>) -> string {
        var key = prefix + ":";

        for i in range::<usize>(0, segments.size()) {
            if i > 0 {
                key += "::";
            }
            key += segments[i];
        }

        return key;
    }

    priv fn split_path(self, path: string) -> vec::<string> {
        var result  = vec::<string>();
        var current = string();

        for i in range::<usize>(0, path.size()) {
            var c = path[i];

            if (c == '/') || (c == '\\') {
                if current.size() > 0 {
                    result.push_back(current);
                    current = string();
                }
            } else {
                current += c;
            }
        }

        if current.size() > 0 {
            result.push_back(current);
        }

        return result;
    }

    /// \brief returns a complete dump of the entire index structure
    ///
    /// includes all roots, directory trees, and cache entries. useful for debugging.
    fn dump_full_index(self) -> string {
        var result = "Full ImportResolver Index Dump:\n";

        for i in range::<usize>(0, self._roots.size()) {
            var root = self._roots[i];
            result += f"\n[Root {i}] priority={root->priority} path={root->base_path.full_path()}\n";
            result += self.dump_node(root->root, 1);
        }

        result += f"\n=== Cache: {self._cache.size()} entries ===\n";
        for entry in self._cache {
            result += f"  {entry.first} -> {entry.second.full_path()}\n";
        }

        return result;
    }

    priv fn dump_node(self, node: *DirEntry, depth: usize) -> string {
        var result = string();
        var indent = string();

        for _ in range::<usize>(0, depth) {
            indent += "  ";
        }

        if node->is_dir {
            result += f"{indent}[DIR] {node->name}/\n";
        } else {
            var cat_str = self.category_to_string(node->category);
            var path_str = "<null>";

            if node->file_path {
                path_str = (*(node->file_path)).full_path();
            }

            if node->ext.size() > 0 {
                result += f"{indent}[FILE] {node->name}.{node->ext} ({cat_str})\n";
            } else {
                result += f"{indent}[FILE] {node->name} ({cat_str})\n";
            }

            result += f"{indent}       -> {path_str}\n";
        }

        for entry in node->children {
            result += self.dump_node(entry.second, depth + 1);
        }

        return result;
    }

    priv fn category_to_string(self, cat: FileCategory) -> string {
        if cat == FileCategory::KairoSource  { return "KairoSource"; }
        if cat == FileCategory::KairoLibrary { return "KairoLibrary"; }
        if cat == FileCategory::CxxSource    { return "CxxSource"; }
        if cat == FileCategory::CxxHeader    { return "CxxHeader"; }
        if cat == FileCategory::CSource      { return "CSource"; }
        if cat == FileCategory::CHeader      { return "CHeader"; }
        if cat == FileCategory::Other        { return "Other"; }
        return "Ignored";
    }
}

fn Test() -> i32 {
    std::print("=== ImportResolver Test ===\n");

    // create a temp test directory structure
    var test_root = libcxx::filesystem::temp_directory_path() / libcxx::filesystem::path(r"hlx_import_test");
    var include_root = libcxx::filesystem::temp_directory_path() / libcxx::filesystem::path(r"hlx_include_test");

    // clean up if exists from previous run
    if libcxx::filesystem::exists(test_root) {
        libcxx::filesystem::remove_all(test_root);
    }

    if libcxx::filesystem::exists(include_root) {
        libcxx::filesystem::remove_all(include_root);
    }

    // create directory structure:
    // hlx_import_test/
    //   ├-- std/
    //   │   ├-- io.k
    //   │   ├-- mem/
    //   │   │   ├-- module.k
    //   │   │   └-- alloc.k
    //   │   └-- net.k
    //   ├-- mylib.hlib
    //   ├-- util.k
    //   ├-- cpp/
    //   │   ├-- helper.hpp
    //   │   ├-- helper.cpp
    //   │   └-- legacy.h
    //   ├-- Assets/
    //   │   ├-- config.json
    //   │   ├-- data.txt
    //   │   └-- README
    //   └-- Makefile
    //
    // hlx_include_test/
    //   ├-- util.k (conflict - should lose to cwd)
    //   └-- extra.k (unique - should be found)

    libcxx::filesystem::create_directories(test_root / libcxx::filesystem::path(r"std/mem"));
    libcxx::filesystem::create_directories(test_root / libcxx::filesystem::path(r"cpp"));
    libcxx::filesystem::create_directories(test_root / libcxx::filesystem::path(r"Assets"));
    libcxx::filesystem::create_directories(include_root);

    // create dummy files
    var files_to_create = vec::<libcxx::filesystem::path>();

    // kairo files
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"std/io.k"));
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"std/net.k"));
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"std/mem/module.k"));
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"std/mem/alloc.k"));
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"mylib.hlib"));
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"util.k"));

    // c++ files
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"cpp/helper.hpp"));
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"cpp/helper.cpp"));
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"cpp/legacy.h"));

    // random files (json, txt, no extension)
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"Assets/config.json"));
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"Assets/data.txt"));
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"Assets/README"));
    files_to_create.emplace_back(test_root / libcxx::filesystem::path(r"Makefile"));

    // include path files
    files_to_create.emplace_back(include_root / libcxx::filesystem::path(r"util.k"));
    files_to_create.emplace_back(include_root / libcxx::filesystem::path(r"extra.k"));

    for p: libcxx::filesystem::path in files_to_create {
        __inline_cpp("libcxx::ofstream ofs(p); ofs.close();");
    }

    var test_path = Path(test_root.generic_wstring(), false);
    var include_path = Path(include_root.generic_wstring(), false);
    var includes = vec::<Path>();
    includes.push_back(include_path);

    var pool = std::create::<ThreadPool>(4);

    finally {
        std::destroy(pool);
    }

    var resolver = ImportResolver::Builder()
        .cwd(test_path)
        .add_includes(includes)
        .create_ptr();

    finally { // cleanup
        std::destroy(resolver);
        libcxx::filesystem::remove_all(test_root);
        libcxx::filesystem::remove_all(include_root);
    }

    std::print(resolver->dump_full_index());

    var failed = 0;
    var passed = 0;

    var fail_string = "\033[31m[FAIL]\033[0m";
    var pass_string = "\033[32m[PASS]\033[0m";

    var suite = Assert("ImportResolver Tests");

    // KAIRO MODULE RESOLUTION

    suite.equal::<i32>("resolve_module std::io", 1, fn () -> i32 {
        var segments: vec::<string> = ["std", "io"];
        var result = resolver->resolve_module(segments);

        if result {
            var p = *result;
            if p.filename() == "io.k" {
                return 1;
            } else {
                return 0;
            }
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("resolve directory module (std::mem -> std/mem/module.k)", 1, fn () -> i32 {
        var segments: vec::<string> = ["std", "mem"];
        var result = resolver->resolve_module(segments);

        if result {
            var p = *result;
            if p.filename() == "module.k" {
                return 1;
            } else {
                return 0;
            }
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("resolve nested module (std::mem::alloc -> std/mem/alloc.k)", 1, fn () -> i32 {
        var segments: vec::<string> = ["std", "mem", "alloc"];
        var result = resolver->resolve_module(segments);

        if result {
            var p = *result;
            if p.filename() == "alloc.k" {
                return 1;
            } else {
                return 0;
            }
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("resolve library (mylib -> mylib.hlib)", 1, fn () -> i32 {
        var result = resolver->resolve_library("mylib");

        if result {
            var p = *result;
            if p.filename() == "mylib.hlib" {
                return 1;
            } else {
                return 0;
            }
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("resolve top-level module (util -> util.k)", 1, fn () -> i32 {
        var segments: vec::<string> = ["util"];
        var result = resolver->resolve_module(segments);

        if result {
            var p = *result;
            if p.filename() == "util.k" {
                return 1;
            } else {
                return 0;
            }
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("resolve_module_dir explicitly", 1, fn () -> i32 {
        var segments: vec::<string> = ["std", "mem"];
        var result = resolver->resolve_module_dir(segments);

        if result && ((*result).filename() == "module.k") {
            return 1;
        } else {
            return 0;
        }

        // should fail for non-directory module
        var segments2: vec::<string> = ["std", "io"];
        var result2 = resolver->resolve_module_dir(segments2);

        if !result2 {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("module not found", 1, fn () -> i32 {
        var segments: vec::<string> = ["nonexistent", "module"];
        var result = resolver->resolve_module(segments);

        if !result {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("collect exports (std::mem::*)", 1, fn () -> i32 {
        var segments: vec::<string> = ["std", "mem"];
        var exports = resolver->collect_exports(segments);

        var found_alloc = false;
        var found_module = false;

        for name: string in exports {
            if name == "alloc" {
                found_alloc = true;
            }
            if name == "module" {
                found_module = true;
            }
        }

        if found_alloc && !found_module {
            return 1;
        }

        return 0;
    }, 10000);

    // C/C++ RESOLUTION

    suite.equal::<i32>("resolve c++ header with extension", 1, fn () -> i32 {
        var result = resolver->resolve_cxx_include("cpp/helper.hpp");

        if result {
            var p = *result;
            if p.filename() == "helper.hpp" {
                return 1;
            } else {
                return 0;
            }
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("resolve c++ header without extension", 1, fn () -> i32 {
        var result = resolver->resolve_cxx_include("cpp/helper");

        if result {
            var p = *result;
            if (p.filename() == "helper.hpp") || (p.filename() == "helper.h") {
                return 1;
            } else {
                return 0;
            }
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("resolve c header", 1, fn () -> i32 {
        var result = resolver->resolve_cxx_include("cpp/legacy.h");

        if result {
            var p = *result;
            if p.filename() == "legacy.h" {
                return 1;
            } else {
                return 0;
            }
        }

        return 0;
    }, 10000);

    // RANDOM FILES / NO EXTENSION

    suite.equal::<i32>("resolve json file", 1, fn () -> i32 {
        var segments: vec::<string> = ["Assets", "config.json"];
        var result = resolver->resolve_file(segments);

        if result && ((*result).filename() == "config.json") {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("resolve txt file", 1, fn () -> i32 {
        var segments: vec::<string> = ["Assets", "data.txt"];
        var result = resolver->resolve_file(segments);

        if result && ((*result).filename() == "data.txt") {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("resolve file with no extension (README)", 1, fn () -> i32 {
        var segments: vec::<string> = ["Assets", "README"];
        var result = resolver->resolve_file(segments);

        if result && ((*result).filename() == "README") {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("resolve Makefile (no extension, root level)", 1, fn () -> i32 {
        var segments: vec::<string> = ["Makefile"];
        var result = resolver->resolve_file(segments);

        if result && ((*result).filename() == "Makefile") {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("resolve_by_ext", 1, fn () -> i32 {
        var result = resolver->resolve_by_ext("mylib", "hlib");

        if result && ((*result).filename() == "mylib.hlib") {
            return 1;
        }

        return 0;
    }, 10000);

    // PATH RESOLUTION (for embed!, etc)

    suite.equal::<i32>("path_exists", 1, fn () -> i32 {
        if resolver->path_exists("std/io.k") {
            return 1;
        } else {
            return 0;
        }

        if !resolver->path_exists("does/not/exist.k") {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("resolve_path relative to source file", 1, fn () -> i32 {
        var from_file = Path((test_root / libcxx::filesystem::path(r"std/io.k")).generic_wstring(), false);

        // resolve sibling file
        var result = resolver->resolve_path("net.k", from_file);
        if result && ((*result).filename() == "net.k") {
            return 1;
        } else {
            return 0;
        }

        // resolve into subdirectory
        var result2 = resolver->resolve_path("mem/alloc.k", from_file);
        if result2 && ((*result2).filename() == "alloc.k") {
            return 1;
        } else {
            return 0;
        }

        // resolve nonexistent
        var result3 = resolver->resolve_path("nope.k", from_file);
        if !result3 {
            return 1;
        }

        return 0;
    }, 10000);

    // INCLUDE PATH PRIORITY

    suite.equal::<i32>("cwd takes priority over include paths", 1, fn () -> i32 {
        var segments: vec::<string> = ["util"];
        var result = resolver->resolve_module(segments);

        if result {
            var p = (*result).full_path();
            // should resolve to cwd version, not include path
            if (p.raw_string().find("hlx_import_test")) != string::npos {
                return 1;
            } else {
                return 0;
            }
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("fallback to include path for unique modules", 1, fn () -> i32 {
        var segments: vec::<string> = ["extra"];
        var result = resolver->resolve_module(segments);

        if result && ((*result).filename() == "extra.k") {
            return 1;
        }

        return 0;
    }, 10000);

    // COLLECT BY CATEGORY

    suite.equal::<i32>("collect_all_by_category KairoSource", 1, fn () -> i32 {
        var all_hlx = resolver->collect_all_by_category(FileCategory::KairoSource);

        // cwd: io, net, module, alloc, util = 5
        // include: util (dup), extra = 1 unique
        // total = 6
        if all_hlx.size() == 7 {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("collect_all_by_category CxxSource", 1, fn () -> i32 {
        var all_cpp = resolver->collect_all_by_category(FileCategory::CxxSource);

        if all_cpp.size() == 1 {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("collect_all_by_category CxxHeader", 1, fn () -> i32 {
        var all_hdr = resolver->collect_all_by_category(FileCategory::CxxHeader);

        // helper.hpp, legacy.h = 2
        if all_hdr.size() == 2 {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("collect_all_by_category Other (json, txt, no-ext)", 1, fn () -> i32 {
        var all_other = resolver->collect_all_by_category(FileCategory::Other);

        // config.json, data.txt, README, Makefile = 4
        if all_other.size() == 4 {
            return 1;
        }

        return 0;
    }, 10000);

    // CACHE BEHAVIOR

    suite.equal::<i32>("cache consistency", 1, fn () -> i32 {
        var segments: vec::<string> = ["std", "io"];

        var r1 = resolver->resolve_module(segments);
        var r2 = resolver->resolve_module(segments);

        if r1 && r2 {
            if ((*r1).full_path()) == ((*r2).full_path()) {
                return 1;
            } else {
                return 0;
            }
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("cache invalidation", 1, fn () -> i32 {
        var segments: vec::<string> = ["std", "io"];

        var r1 = resolver->resolve_module(segments);
        resolver->invalidate_cache();
        var r2 = resolver->resolve_module(segments);

        if r1 && r2 && (((*r1).full_path()) == ((*r2).full_path())) {
            return 1;
        }

        return 0;
    }, 10000);

    // REBUILD

    suite.equal::<i32>("rebuild picks up new files", 1, fn () -> i32 {
        // add new file after indexing
        var new_file = test_root / libcxx::filesystem::path(r"newmodule.k");
        __inline_cpp("libcxx::ofstream ofs(new_file); ofs.close();");

        // should NOT find it yet (stale index)
        var segments: vec::<string> = ["newmodule"];
        var result = resolver->resolve_module(segments);

        if !result {
            return 1;
        } else {
            return 0;
        }

        // rebuild and try again
        resolver->rebuild_all();

        var result2 = resolver->resolve_module(segments);
        if result2 && ((*result2).filename() == "newmodule.k") {
            return 1;
        } else {
            return 0;
        }

        libcxx::filesystem::remove(new_file);
    }, 10000);

    // EDGE CASES

    suite.equal::<i32>("empty segments", 1, fn () -> i32 {
        var empty = vec::<string>();
        var result = resolver->resolve_module(empty);

        if !result {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("single dot path", 1, fn () -> i32 {
        var result = resolver->resolve_cxx_include(".");

        if !result {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("empty string", 1, fn () -> i32 {
        var result = resolver->resolve_cxx_include("");

        if !result {
            return 1;
        }

        return 0;
    }, 10000);

    suite.equal::<i32>("deeply nested path", 1, fn () -> i32 {
        var segments: vec::<string> = ["std", "mem", "module"];
        var result = resolver->resolve_module(segments);

        // std/mem/module.k exists but as a file, not std/mem/module/module.k
        // this should find it as a direct file
        if result && ((*result).filename() == "module.k") {
            return 1;
        }

        return 0;
    }, 10000);

    return failed;
}
