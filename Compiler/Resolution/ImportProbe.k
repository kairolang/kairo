/// --- The Kairo Project --------------------- Resolution/ImportProbe.k --- ///
///
///   ImportResolver: maps import paths to files through ordered roots.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
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
//      on the calling thread. this was forced by libcxx::filesystem, which
//      touched locale state on first use and threw on worker threads; the walk
//      is on llvm::sys::fs now, so that constraint is gone and async indexing
//      can be revisited. rn in kairo/ the
//      walk phase alone takes up seconds of time, since kairo/ has all of llvm
//      and all of libc source in its search paths its awfully slow to index.

ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "vector"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "llvm/ADT/StringSet.h"
ffi "c++" import "map"
ffi "c++" import "set"
ffi "c++" import "algorithm"
ffi "c++" import "string"

import Resolution::DirEntry::DirEntry
import Resolution::FileExtensions::{
    FileCategory,
    FileExtensions,
}
import Resolution::SearchRoot::{
    SearchRoot,
    read_module_pin,
    root_name_matches,
    root_names_equal,
    split_module_name,
}
import Support::Assert::Assert
import Support::FileIO::FileSystem::FileType
import Support::FileIO::Path::Path
import Threading::ThreadPool::ThreadPool
import std::io

/// \enum ResolveError
/// \brief error conditions returned by resolution methods
pub enum ResolveError {
    NotFound,         ///< no matching file or module found in any search root
    AmbiguousModule,  ///< both a file and directory match the final segment
    InvalidLibrary,   ///< reserved
    PermissionDenied, ///< reserved
    CyclicImport,     ///< reserved
}

/// \enum ModuleOrigin
/// \brief which candidate set produced a module resolution.
pub enum ModuleOrigin derives u8 {
    Root = 0, ///< found by walking the search roots (cwd + -m/-I dirs).
    Sibling,  ///< found in one directory: `self::`/`module::`'s anchor, or a
    ///  plain import's migration fallback (resolve_module_in).
}

/// \class ModuleResolution
/// \brief the result of a relative-aware module resolution.
///
/// \details `canonical` is the module's IDENTITY: the path segments from the
///          owning search root down to the file, NOT the segments the import
///          spelled. Two files never share a canonical path, and one file
///          always has exactly one, no matter how it was reached. Codegen
///          derives the C++ namespace path from this (Compiler/Spec/Codegen.md#pipeline: the
///          bijection module-path <-> namespace-path is what makes mangling
///          deterministic and ODR-safe), so it must never depend on the
///          importer's spelling.
///
///          `ambiguous` (always with `cross_root`) means two different files
///          answered through two unnamed search dirs: a hard error at the
///          import site (R017E). The winner is still returned so resolution
///          does not cascade into a second "not found" for the same import.
pub class ModuleResolution {
    pub var found:      bool                     = false
    pub var path:       Path ///< the resolved file.
    pub var canonical:  cxx::std::vector<string> ///< identity segments from the search root.
    pub var origin:     ModuleOrigin             = ModuleOrigin::Root
    pub var ambiguous:  bool                     = false ///< two unnamed search dirs both matched.
    pub var other_path: Path ///< the losing candidate, iff ambiguous.
    pub var cross_root: bool                     = false ///< ambiguous between two unnamed search dirs.
    pub var file_dir:   bool                     = false ///< `foo.k` AND `foo/module.k` matched the last segment in one place.
    pub var dir_path:   Path ///< that `foo/module.k`, iff file_dir.
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
pub class ModuleNameCollision {
    pub var dir:       string         ///< absolute directory that holds both.
    pub var a:         string         ///< first name, sorted order.
    pub var b:         string         ///< second name.
    pub var ident:     string         ///< the module identity they both claim.
    pub var case_only: bool   = false ///< true: differ only by case (portability).
}

/// \class RootNameCollision
/// \brief two search roots registered under one module name.
///
/// \details A root's name is the leading segment of every module under it, so
///          two roots sharing one name make a module path mean two files.
///          A build error, reported before anything is parsed; never
///          first-wins, never a merge (Compiler/Spec/Imports.md#path-resolution).
pub class RootNameCollision {
    pub var name:   string
    pub var a:      string         ///< the root already registered.
    pub var b:      string         ///< the one that collided with it.
    pub var pinned: bool   = false ///< `b` took its name from a pinned module.k, not -I.

    /// Not two roots: ONE directory the driver registers under `name` while
    /// its module.k pins `pin`. The registration wins (it is what the
    /// driver's own lookups -- the prelude, lang items -- address), so the
    /// pin would be a second, silently ignored answer to "what is this
    /// library called". `a` is the directory.
    pub var mismatch: bool   = false
    pub var pin:      string

    /// The diagnostic text, one home for the driver (registration time) and
    /// the PP walk (a pin found later, by canonical_module_path's walk up).
    pub fn message(self) -> string {
        if self.mismatch {
            return f"'{self.a}/module.k' pins `module {self.pin}`, but this directory is registered as library '{self.name}', and the registration wins; make the pin `module {self.name}` or remove it"
        }

        // Only the driver's own registrations (builtin, kairo::std) name a
        // root without a pin, so either way the fix is a pin.
        if self.pinned {
            return f"duplicate module root '{self.name}': '{self.a}' and '{self.b}' both claim it; rename one library's `module` declaration in its module.k"
        }

        return f"duplicate module root '{self.name}': '{self.a}' and '{self.b}' both claim it; rename the library's `module` declaration in its module.k"
    }
}

/// \class ModuleIdentityCollision
/// \brief two different files that one module path names.
///
/// \details A module path is a file's identity and its C++ namespace
///          (ModuleResolution::canonical), so it must name ONE file. Two can
///          still land on one path without any root sharing a name: a pin
///          below a root's immediate subdirectories that claims a
///          registered library's name, two inputs reached through two
///          search dirs, two pins naming one library from different places.
///          Each pair is recorded once, at the first resolution (or input)
///          that makes it visible; Compiler/Spec/Imports.md#path-resolution, decision E.
pub class ModuleIdentityCollision {
    pub var ident: string ///< the module path, `::`-joined.
    pub var a:     string ///< the file that claimed it first.
    pub var b:     string ///< the other file.

    fn message(self) -> string {
        return f"'{self.a}' and '{self.b}' are both module '{self.ident}'; a module path names one file, and these two would share one C++ namespace and one object file: rename or move one, or make one part of a library with a pinned module.k"
    }
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
pub class ImportResolver {
    priv var _cache:        cxx::std::map<string, Path> ///< resolution cache keyed by "prefix:seg1::seg2::..."
    priv var _roots:        cxx::std::vector<unsafe *SearchRoot> ///< priority-sorted search roots (index 0 = cwd)
    priv var _ext_cfg:      unsafe *FileExtensions ///< file extension classification config
    priv var _owns_ext_cfg: bool ///< true if destructor should free `_ext_cfg`

    /// Transient roots for sibling-relative probing, keyed by absolute dir.
    /// Owned; built lazily (SearchRoot construction is a couple of stats, the
    /// walk is lazy) so importing files in N directories costs N of these.
    priv var _sibling_roots: llvm::StringMap<unsafe *SearchRoot>

    /// Directories already swept for module-name collisions, and the findings
    /// not yet drained. Reporting is deferred because discovery runs in the
    /// DepScanner (no DiagEngine) before it runs in the PP walk (which has
    /// one) - see take_collisions().
    priv var _swept_dirs: llvm::StringSet<llvm::MallocAllocator>
    priv var _collisions: cxx::std::vector<ModuleNameCollision>

    /// Duplicate root names found at build_index time. Same deferral reason as
    /// _collisions: the resolver has no DiagEngine.
    priv var _root_collisions: cxx::std::vector<RootNameCollision>

    /// Per-directory answer to "does this directory's module.k pin a library
    /// name?", keyed by absolute dir; an empty vec is a cached NO. Written by
    /// index-time discovery and by canonical_module_path's walk up, so each
    /// module.k is read at most once per build.
    priv var _dir_pins: llvm::StringMap<cxx::std::vector<string>>

    /// Module identity -> the REAL path of the file that holds it, and the
    /// pairs already reported (ModuleIdentityCollision). Written by every
    /// resolution and by the driver for each input (claim_identity).
    priv var _identities:     llvm::StringMap<string>
    priv var _identity_files: llvm::StringMap<string> ///< the same file as first spelled, for messages.
    priv var _reported_pairs: llvm::StringSet<llvm::MallocAllocator>

    /// R018E findings made AFTER build_index -- a pinned directory the walk
    /// up found colliding (_check_pin_dir), two files on one module path
    /// (claim_identity) -- as their messages, in the order they were found.
    /// ONE queue, drained whole: the PP walks files on several threads, and
    /// two queues let two threads each drain one, so the same build printed
    /// the pair in either order.
    priv var _late_collisions: cxx::std::vector<string>

    /// Every entry point that reads or writes the maps above (and the lazy
    /// caches beside them) holds this: the PP resolves imports from every
    /// file of a wave at once (WaveExecutor). Recursive, because the entry
    /// points call one another (resolve_module_rel -> canonical_module_path
    /// -> _library_of).
    priv var _mu: kairo::std::RecursiveMutex

    /// A pinned directory no root registered, by the library name it pins
    /// -> its real path: the first such directory seen to claim the name.
    /// A second directory pinning one name, or a registered library's, is
    /// the R018E two named roots would be (_check_pin_dir).
    priv var _lib_pins:     llvm::StringMap<string>
    priv var _lib_pin_dirs: llvm::StringMap<string> ///< the same directory as first spelled.

    /// Transient roots over pinned directories that no root registered,
    /// keyed by directory: what a file inside such a library resolves its
    /// own imports against (resolve_module_rel, step 2a'). Owned, like
    /// _sibling_roots.
    priv var _pinned_roots: llvm::StringMap<unsafe *SearchRoot>

    /// Symlink-resolved spellings, cached: identity comparisons ask the same
    /// directories again and again.
    priv var _real_paths: llvm::StringMap<string>

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
        priv var _cwd:               Path?
        priv var _include_paths:     cxx::std::vector<Path>
        priv var _include_names:     cxx::std::vector<cxx::std::vector<string>> ///< parallel to _include_paths.
        priv var _include_spellings: cxx::std::vector<cxx::std::vector<string>> ///< parallel; empty = the name.
        priv var _ext_cfg:           unsafe *FileExtensions
        priv var _pool:              *ThreadPool?

        /// \brief default constructor; initializes all fields to null/empty
        pub fn Builder(self) {
            self._cwd               = null
            self._include_paths     = cxx::std::vector<Path>()
            self._include_names     = cxx::std::vector<cxx::std::vector<string>>()
            self._include_spellings = cxx::std::vector<cxx::std::vector<string>>()
            self._ext_cfg           = &null
            self._pool              = &null
        }

        /// \brief sets the current working directory as the highest-priority search root
        /// \param path the directory to use as cwd
        /// \return pointer to self for chaining
        pub fn cwd(self, const path: Path) -> unsafe *Self {
            self._cwd = path
            return unsafe &self
        }

        /// \brief appends a single include path to the search list
        /// \param path the directory to add
        /// \return pointer to self for chaining
        /// \param name the root's MODULE name -- the leading SEGMENTS every
        ///             module under it carries (Compiler/Spec/Imports.md#path-resolution), written as a
        ///             module path (`kairo::std`). Empty means "whatever
        ///             the directory's module.k pins, else an unnamed search
        ///             dir" -- what every `-I dir` is. Only the driver's own
        ///             registrations (builtin, kairo::std) pass a name.
        ///
        /// \param spelling what an import writes to reach the root, when it
        ///             differs from the name (SearchRoot::spelling). Empty
        ///             means "the name".
        ///
        /// The `::` split happens HERE and nowhere else, so the driver's own
        /// registrations and any future caller agree on what a dotted name
        /// means.
        pub fn add_include(self,
                           const path:     Path,
                           const name:     string = "",
                           const spelling: string = "") -> unsafe *Self {
            self._include_paths.push_back(path)
            // Empty stays empty: build_index tells an EXPLICIT name from
            // none by it, because only a nameless dir takes its pinned
            // module.k's name.
            self._include_names.push_back(split_module_name(name))
            self._include_spellings.push_back(split_module_name(spelling))
            return unsafe &self
        }

        /// \brief appends multiple include paths to the search list
        /// \param paths vector of directories to add
        /// \return pointer to self for chaining
        fn add_includes(self, paths: cxx::std::vector<Path>) -> unsafe *Self {
            for *p in paths {
                self.add_include(*p, "")
            }

            return unsafe &self
        }

        /// \brief sets the file extension configuration
        /// \param cfg pointer to an existing config; if null, a default is created
        /// \return pointer to self for chaining
        fn extensions(self, cfg: unsafe *FileExtensions) -> unsafe *Self {
            self._ext_cfg = cfg
            return unsafe &self
        }

        /// \brief constructs the resolver and initiates indexing
        /// \param pool optional thread pool for async indexing; if null, blocks until done
        /// \return heap-allocated resolver; caller assumes ownership
        pub fn create_ptr(self, pool: unsafe *ThreadPool = &null) -> unsafe *ImportResolver {
            var        cwd_path  = self._cwd ?? Path::cwd()
            var unsafe *resolver = kairo::std::create<ImportResolver>(self._ext_cfg)

            // Always index synchronously on the calling (main) thread. (The
            // original reason, libcxx::filesystem throwing on worker threads,
            // left with the move to llvm::sys::fs.) Async indexing bought nothing since
            // CompilationBatch::run() calls wait_for_index() before dispatching
            // any TU tasks - the spin was immediate and free-threaded for zero gain.
            resolver->build_index(
                cwd_path,
                self._include_paths,
                &null,
                self._include_names,
                self._include_spellings,
            )

            return resolver
        }
    }

    /// \brief direct constructor; prefer using `Builder` instead
    /// \param ext_cfg optional extension config; if null, a default is allocated and owned
    fn ImportResolver(self) {
        var ext_cfg: unsafe *FileExtensions = &null
        self._roots = cxx::std::vector<unsafe *SearchRoot>()
        self._cache = cxx::std::map<string, Path>()

        if ext_cfg != &null {
            self._ext_cfg      = ext_cfg
            self._owns_ext_cfg = false
        } else {
            self._ext_cfg      = kairo::std::create<FileExtensions>()
            self._owns_ext_cfg = true
        }
    }

    fn ImportResolver(self, ext_cfg: unsafe *FileExtensions) {
        self._roots = cxx::std::vector<unsafe *SearchRoot>()
        self._cache = cxx::std::map<string, Path>()

        if ext_cfg != &null {
            self._ext_cfg      = ext_cfg
            self._owns_ext_cfg = false
        } else {
            self._ext_cfg      = kairo::std::create<FileExtensions>()
            self._owns_ext_cfg = true
        }
    }

    /// \brief builds the directory index for all search roots
    /// \param cwd the current working directory (priority 0)
    /// \param include_paths additional include directories (priority 1+)
    /// \param pool optional thread pool; currently unused in body but reserved for parallel indexing
    fn build_index(
        self,
        cwd:                     Path,
        const include_paths:     cxx::std::vector<Path>,
        pool:                    *ThreadPool? = &null,
        const include_names:     cxx::std::vector<cxx::std::vector<string>> = cxx::std::vector<cxx::std::vector<string>>(),
        const include_spellings: cxx::std::vector<cxx::std::vector<string>> = cxx::std::vector<cxx::std::vector<string>>(),
    ) {
        kairo::Logger::info(
            kairo::Logger::Stage::Preprocessor,
            f"ImportResolver::build_index: cwd='{cwd.full_path()}' roots={include_paths.size() + 1}",
        )

        // Build the root list. Cheap: path checks only. SearchRoot's constructor
        // stamps each root's fs_path and ext_cfg so it can probe lazily on first
        // access; there is no eager directory walk here anymore.
        if cwd.exists() && cwd.is_directory() {
            var unsafe *root = kairo::std::create<SearchRoot>(cwd, 0, self._ext_cfg)
            self._roots.push_back(root)
        }

        var priority: u32 = 1
        for var i: usize = 0; i < include_paths.size(); ++i {
            var p = include_paths[i]
            if !p.exists() || !p.is_directory() {
                continue
            }

            var nm = if (i < include_names.size()) => (include_names[i])
                     else => cxx::std::vector<string>()
            var sp = if (i < include_spellings.size()) => (include_spellings[i])
                     else => cxx::std::vector<string>()
            if sp.size() == 0 {
                sp = nm
            }

            // An explicit name (the driver's builtin and kairo::std; the CLI
            // has no way to give one) is checked against the directory's own
            // pin. The registration wins -- the prelude and the lang items
            // address builtin by it, and std's spelling `std` is not
            // expressible as a pin at all -- so a pin saying something else
            // would be a second, silently ignored name.
            if nm.size() > 0 {
                var own_pin = self._pin_of_dir(p.full_path())
                if own_pin.size() > 0 && !root_names_equal(own_pin, nm) {
                    var c = RootNameCollision{}
                    c.mismatch = true
                    c.name     = self._name_str(nm)
                    c.pin      = self._name_str(own_pin)
                    c.a        = p.full_path()
                    self._root_collisions.push_back(c)
                }
            }

            // The same directory twice -- `-I inc -I inc`, an -I naming the
            // cwd, or one directory through a symlink and its real path -- is
            // one search dir, as it is to clang: a second root over it would
            // make every file in it ambiguous with itself. When the later
            // entry is an explicit registration it is folded INTO the
            // earlier root, never dropped: `-I Lib/std` ahead of the driver's
            // own std registration otherwise kept std's pin name with no
            // `std` spelling (so `import std::io` stopped resolving), and
            // `-I Lib/builtin` left builtin a discovered library without the
            // last-resort probe. Folded in place, so the search order the
            // user gave is kept.
            var unsafe *prior = self._root_at_real(self._real(p.full_path()))
            if prior != &null {
                if nm.size() > 0 {
                    self._check_root_name(p, nm, sp, false, prior)
                    prior->name       = nm
                    prior->spelling   = sp
                    prior->discovered = false
                }

                continue
            }

            // No explicit name: the directory's own pin names it, or it
            // stays an UNNAMED search dir, as the cwd is -- never its
            // basename, which made every `-I .../include` the same root.
            var pinned = false
            if nm.size() == 0 {
                nm     = self._pin_of_dir(p.full_path())
                pinned = nm.size() > 0
                sp     = nm
            }

            var unsafe *r = self._add_root(p, priority, nm, sp, pinned)
            // A pinned -I dir is a library like a pinned subdirectory, and
            // reached the same way: by its declared name only. Left
            // undiscovered, the last-resort probe of every root found its
            // files by their bare paths too, so `-I geometry` with a
            // `module geo` made `import vec` reach `geo::vec`. The
            // driver's builtin and kairo::std are explicit names, not
            // pins, and keep that probe.
            if pinned {
                r->discovered = true
            }

            priority += 1
        }

        // Pinned libraries: a module.k whose first declaration is `module foo`
        // makes its directory the root of library `foo`, found by the declared
        // name whatever the folder is called. Looked for ONLY in each root's
        // immediate subdirectories -- one readdir per root, one probe and a
        // few bytes read per subdirectory -- never by walking a root, which
        // can be a whole repository. A pin deeper than that still fixes its
        // files' module paths (canonical_module_path walks up to it); it is
        // just not importable by its name from outside.
        // Over a snapshot of the registered roots: the libraries pushed here
        // are not themselves searched for nested libraries.
        var registered = self._roots.size()
        for var ri: usize = 0; ri < registered; ++ri {
            var unsafe *dir = self._roots[ri]->root
            if dir == &null {
                continue
            }

            dir->ensure_scanned()
            for var child: *DirEntry? in dir->sorted_children() {
                if child == &null || !child->is_dir || !child->fs_path? {
                    continue
                }

                var cpath = unwrap!(child->fs_path)
                // A directory already registered keeps the registration: the
                // driver's `Lib/std` is an explicit root AND a subdirectory of
                // `Lib`, and must not collide with itself.
                if self._is_root_dir(cpath) {
                    continue
                }

                if child->find_by_stem_and_category("module", FileCategory::KairoSource) == &null {
                    continue
                }

                var pin = self._pin_of_dir(cpath.full_path())
                if pin.size() == 0 {
                    continue
                }

                var unsafe *lib = self._add_root(cpath, priority, pin, pin, true)
                lib->discovered = true
                priority += 1
            }
        }

        // `pool` retained for signature compatibility; lazy resolution needs no
        // worker dispatch. Resolution methods probe on demand; wait_for_index() is
        // a no-op.
        kairo::Logger::info(
            kairo::Logger::Stage::Preprocessor,
            f"ImportResolver::build_index: registered roots={self._roots.size()}",
        )
    }

    /// Registers one root, checking it against every root before it. Two
    /// roots claiming one name is a build error, never first-wins and never
    /// a merge (Compiler/Spec/Imports.md#path-resolution). EQUAL names only: one name being a PREFIX
    /// of another is legal, because resolve_module_rel matches longest-first
    /// and so has exactly one answer for every path. The spelling collides
    /// too: two roots an import reaches by one path would make that path
    /// ambiguous even with two names. One home for the check, so a pinned
    /// library colliding with a -I root or with another pin is the same R018E.
    ///
    /// Unnamed search dirs (the cwd, every unpinned -I) never collide here:
    /// an empty name prefixes no module path, so two of them share nothing a
    /// root name could clash on. What they CAN share is one module path
    /// spelled by two files, and that is decided per import, by the files
    /// that exist (resolve_module_rel), not by registering the dirs.
    priv fn _add_root(self,
                      p:        Path,
                      priority: u32,
                      nm:       cxx::std::vector<string>,
                      sp:       cxx::std::vector<string>,
                      pinned:   bool) -> unsafe *SearchRoot {
        self._check_root_name(p, nm, sp, pinned, &null)
        var unsafe *root = kairo::std::create<SearchRoot>(p, priority, self._ext_cfg, nm, sp)
        self._roots.push_back(root)
        return root
    }

    /// The R018E half of _add_root, also run when an explicit registration
    /// renames an existing root in place. \p skip is that root itself.
    priv fn _check_root_name(self,
                             const p: Path,
                             nm:      cxx::std::vector<string>,
                             sp:      cxx::std::vector<string>,
                             pinned:  bool,
                             skip:    unsafe *SearchRoot) {
        var real = self._real(p.full_path())
        for var k: usize = 0; nm.size() > 0 && k < self._roots.size(); ++k {
            var unsafe *r = self._roots[k]
            if r == skip || r->name.size() == 0 {
                continue
            }

            // One directory under two spellings is one library.
            if r->real_dir == real {
                continue
            }

            if !root_names_equal(r->name, nm) && !root_names_equal(r->spelling, sp) {
                continue
            }

            var c = RootNameCollision{}
            c.name = if (root_names_equal(r->name, nm)) => (self._name_str(nm))
                     else => self._name_str(sp)
            c.a      = r->base_path.full_path()
            c.b      = p.full_path()
            c.pinned = pinned
            self._root_collisions.push_back(c)
        }
    }

    /// The registered root over the directory whose real path is \p real,
    /// or null.
    priv fn _root_at_real(self, const real: string) -> unsafe *SearchRoot {
        for var i: usize = 0; i < self._roots.size(); ++i {
            if self._roots[i]->real_dir == real {
                return self._roots[i]
            }
        }

        return &null
    }

    /// \p p with its symlinks resolved, cached per spelling.
    priv fn _real(self, const p: string) -> string {
        if self._real_paths.contains(kairo::sref(p)) {
            return self._real_paths[kairo::sref(p)]
        }

        var r = Path::real_path_of(p)
        self._real_paths[kairo::sref(p)] = r
        return r
    }

    /// The library name \p dir's module.k pins, or empty. Cached per
    /// directory, hits and misses alike.
    priv fn _pin_of_dir(self, const dir: string) -> cxx::std::vector<string> {
        if self._dir_pins.contains(kairo::sref(dir)) {
            return self._dir_pins[kairo::sref(dir)]
        }

        var pin   = cxx::std::vector<string>()
        var mod_k = Path::join_str(dir, "module.k")
        if Path::exists_at(mod_k) {
            pin = read_module_pin(mod_k)
        }

        self._dir_pins[kairo::sref(dir)] = pin
        return pin
    }

    /// \brief destructor; frees all owned search roots and optionally the extension config
    fn op finally (self) {
        for var root: unsafe *SearchRoot in self._roots {
            if root != &null {
                kairo::std::destroy(root)
            }
        }

        self._roots.clear()
        self._cache.clear()

        for var it = self._sibling_roots.begin(); it != self._sibling_roots.end(); ++it {
            if it->second != &null {
                kairo::std::destroy(it->second)
            }
        }

        self._sibling_roots.clear()

        for var it = self._pinned_roots.begin(); it != self._pinned_roots.end(); ++it {
            if it->second != &null {
                kairo::std::destroy(it->second)
            }
        }

        self._pinned_roots.clear()

        if self._owns_ext_cfg && self._ext_cfg != &null {
            kairo::std::destroy(self._ext_cfg)
        }
    }

    /// \brief returns the extension configuration in use
    /// \return non-owning pointer to the extension config
    fn extensions(self) -> unsafe *FileExtensions {
        return self._ext_cfg
    }

    /// \brief spin-waits until indexing is complete
    ///
    /// uses `libcxx::this_thread::yield()` to avoid busy-waiting.
    pub fn wait_for_index(self) {
        // Lazy resolution: no index to wait on. Retained for API compatibility.
    }

    /// \brief checks whether indexing has finished
    /// \return true if the index is ready for queries
    fn is_index_ready(self) -> bool {
        return true
    }

    /// \brief resolves a qualified module path to a filesystem path
    /// \param segments path segments, e.g. ["Core", "Include", "FileSystem"]
    /// \return the resolved path; panics a ResolveError when there is none
    ///
    /// resolution order:
    /// 1. traverse directories matching segments[0..n-1]
    /// 2. look for a file with stem matching segments[n-1] and category KairoSource
    /// 3. if no file, look for a directory with that name containing `module.k`
    ///
    /// \note panics `AmbiguousModule` if both a file and directory match, but still
    ///       caches the file path, so a second call returns it. this is arguably a bug-callers catching
    ///       `AmbiguousModule` cannot distinguish success from failure without inspecting
    ///       the cache manually.
    fn resolve_module(self, const segments: cxx::std::vector<string>)
        panic(ResolveError) -> Path {
        self.wait_for_index()

        if segments.size() == 0 {
            panic ResolveError::NotFound
        }

        var cache_key = self.make_cache_key("mod", segments)

        if self._cache.contains(cache_key) {
            return self._cache[cache_key]
        }

        for var root: *SearchRoot in self._roots {
            var unsafe *node = root->root
            for i in (0 as usize)..(segments.size() - 1) {
                node = node->find_dir(segments[i])
                if node == &null {
                    break
                }
            }

            if node == &null {
                continue
            }

            var last = segments[segments.size() - 1]

            var unsafe *file_node = node->find_by_stem_and_category(last, FileCategory::KairoSource)
            if file_node != &null && file_node->file_path? {
                self._cache[cache_key] = unwrap!(file_node->file_path)

                var unsafe *dir_node = node->find_dir(last)
                if dir_node != &null {
                    panic ResolveError::AmbiguousModule
                }

                return unwrap!(file_node->file_path)
            }

            var unsafe *dir_node = node->find_dir(last)
            if dir_node != &null {
                var unsafe *mod_node = dir_node->find_by_stem_and_category(
                    "module",
                    FileCategory::KairoSource,
                )

                if mod_node != &null && mod_node->file_path? {
                    self._cache[cache_key] = unwrap!(mod_node->file_path)
                    return unwrap!(mod_node->file_path)
                }
            }
        }

        kairo::Logger::debug(
            kairo::Logger::Stage::Preprocessor,
            f"ImportResolver::resolve_module: not found key='{cache_key}'",
        )

        panic ResolveError::NotFound
    }

    /// \brief resolves a module directory path and returns its `module.k` entry point
    /// \param segments path segments identifying the directory
    /// \return path to `module.k` inside the directory; panics ResolveError::NotFound when there is none
    fn resolve_module_dir(self, segments: cxx::std::vector<string>)
        panic(ResolveError) -> Path {
        self.wait_for_index()

        for var root: *SearchRoot in self._roots {
            var unsafe *node = root->traverse(segments)

            if node == &null || !node->is_dir {
                continue
            }

            var unsafe *mod_node = node->find_by_stem_and_category(
                "module",
                FileCategory::KairoSource,
            )

            if mod_node != &null && mod_node->category == FileCategory::KairoSource {
                return unwrap!(mod_node->file_path)
            }
        }

        kairo::Logger::debug(
            kairo::Logger::Stage::Preprocessor,
            f"ImportResolver::resolve_module_dir: not found segments={segments.size()}",
        )

        panic ResolveError::NotFound
    }

    //  Module resolution (THE home of import path semantics)
    //
    //  Each import form looks in exactly one place
    //  (Compiler/Spec/Imports.md#path-resolution):
    //    `import baz`          the search roots, here (resolve_module_rel);
    //    `import self::baz`    the importing file's directory,
    //    `import module::baz`  its module root -- both resolve_module_in.
    //
    //  The plain form used to try the importing file's directory FIRST and
    //  error when a root answered too. Sibling-first is Python 2's implicit
    //  relative import, which Python removed because adding `root/baz.k`
    //  silently changed what `import baz` meant three directories away; the
    //  collision error kept that from being silent but still let a new root
    //  file break a build far from it. Spelling the place in the import
    //  removes the question instead.
    //
    //  Module IDENTITY never comes from the spelling - see canonical_module_path.

    /// \brief resolves a PLAIN module path against the search roots.
    /// \param segments  the path as written (e.g. ["baz"] or ["util","fmt"])
    /// \param from_dir  the IMPORTING file's directory
    /// \param has_from  false when there is no importing file (entry point)
    /// \return a resolution carrying the file and its canonical identity.
    ///         The importing file's own directory is NOT a place this form
    ///         looks; the callers' migration fallback probes it separately
    ///         (resolve_module_in), after every root has missed every prefix.
    pub fn resolve_module_rel(self,
                              const segments: cxx::std::vector<string>,
                              const from_dir: Path,
                              has_from:       bool) -> ModuleResolution {
        var lock = kairo::std::LockGuard(self._mu)
        var out  = ModuleResolution{}
        if segments.size() == 0 {
            return out
        }

        // Root candidates, in the order Compiler/Spec/Imports.md#path-resolution fixes:
        //      a. the importing file's OWN root, with the path as written
        //      b. any root whose NAME is the leading segment, with the rest
        //      c. every other root with the path as written -- except that a
        //         file under a NAMED root never falls back into an unnamed
        //         search dir (the cwd, an unpinned -I): a library cannot
        //         depend on what happens to sit on one build's command line.
        var own_root: unsafe *SearchRoot = &null
        if has_from {
            own_root = self.root_for_dir(from_dir)
        }

        var root_hit                      = false
        var root_path: Path
        var hit_root:  unsafe *SearchRoot = &null // the root that answered, for the search-dir check

        if own_root != &null {
            var h = self._probe_root(own_root, segments)
            if h.found {
                root_hit  = true
                root_path = h.path
                hit_root  = own_root
                self._take_file_dir(&out, h)
            }
        }

        // 2a'. The importing file's own LIBRARY when no root registered it:
        //      a pin deeper than a root's immediate subdirectories, or one
        //      above the cwd (`cd geometry/inner && kcc -c x.k`). Its files
        //      already take its name (canonical_module_path walks up to it);
        //      without this they could not import one another, neither by
        //      the path as written nor by the library's name (2b below), so
        //      a file inside such a library compiled on its own failed at
        //      its first intra-library import.
        var lib_root: unsafe *SearchRoot = &null
        if has_from {
            lib_root = self._pinned_root_for(from_dir)
        }

        if !root_hit && lib_root != &null {
            var h = self._probe_root(lib_root, segments)
            if h.found {
                root_hit  = true
                root_path = h.path
                hit_root  = lib_root
                self._take_file_dir(&out, h)
            }
        }

        // Named roots, LONGEST SPELLING FIRST. A root is reached by its
        // spelling (SearchRoot::spelling: its name unless it registered a
        // shorter one, as std does), a module path matched on the leading N
        // segments of the import: with roots spelled `kairo::x` and `kairo`,
        // `import kairo::x::vec` is the former's `vec.k` and never the
        // latter's `x/vec.k`.
        // Longest-first is also what makes prefix pairs legal -- only EQUAL
        // names are the R018E collision.
        //
        // A name consuming the WHOLE path (empty tail) names the root itself,
        // and what that resolves to is the root's own entry point, its
        // module.k. `_probe_root` cannot serve that case: it addresses
        // segments[size-1] and would read off the front of an empty vec.
        // Without it a root named `builtin` is reachable as
        // `builtin::containers` but never as `builtin` -- the spelling the
        // prelude uses -- and `import std` never resolves at all.
        if !root_hit {
            var cands = cxx::std::vector<unsafe *SearchRoot>()
            for var ni: usize = 0; ni < self._roots.size(); ++ni {
                var unsafe *r = self._roots[ni]
                if r->spelling.size() == 0 {
                    continue
                }

                if !root_name_matches(r->spelling, segments) {
                    continue
                }

                cands.push_back(r)
            }

            if lib_root != &null && root_name_matches(lib_root->spelling, segments) {
                cands.push_back(lib_root)
            }

            // Insertion sort, descending by name length. The candidate set is
            // the roots whose name prefixes ONE import path: one or two in
            // every real build.
            for var a: usize = 1; a < cands.size(); ++a {
                var unsafe *c = cands[a]
                var        b  = a
                while b > 0 && cands[b - 1]->spelling.size() < c->spelling.size() {
                    cands[b] = cands[b - 1]
                    b -= 1
                }

                cands[b] = c
            }

            var ci: usize = 0
            while ci < cands.size() && !root_hit {
                var unsafe *r = cands[ci]
                ci += 1

                var tail = cxx::std::vector<string>()
                for var ti: usize = r->spelling.size(); ti < segments.size(); ++ti {
                    tail.push_back(segments[ti])
                }

                if tail.size() == 0 {
                    var unsafe *snode = r->root
                    if snode == &null {
                        continue
                    }

                    self._sweep_dir(snode)
                    var unsafe *smod = snode->find_by_stem_and_category(
                        "module",
                        FileCategory::KairoSource,
                    )

                    if smod != &null && smod->file_path? {
                        root_hit = true
                        root_path = unwrap!(smod->file_path)
                    }

                    continue
                }

                var h = self._probe_root(r, tail)
                if h.found {
                    root_hit  = true
                    root_path = h.path
                    self._take_file_dir(&out, h)
                }
            }
        }

        // A file in a library, registered or found walking up (lib_root):
        // which library holds a file is a property of the file, so whether
        // it may reach into the command line's unnamed dirs must not depend
        // on whether this run happened to register its library.
        var from_library       = own_root != &null && own_root->name.size() > 0 || lib_root != &null
        var ri:          usize = 0
        while ri < self._roots.size() && !root_hit {
            var unsafe *r = self._roots[ri]
            ri += 1
            if r == own_root { // already tried
                continue
            }

            if from_library && r->name.size() == 0 { // library -> unnamed search dir
                continue
            }

            if r->discovered { // a pinned library: by name only
                continue
            }

            var h = self._probe_root(r, segments)
            if h.found {
                root_hit  = true
                root_path = h.path
                hit_root  = r
                self._take_file_dir(&out, h)
            }
        }

        // 4. Two unnamed search dirs answering one path with two files. Both
        //    are that path's module -- an unnamed dir adds no prefix -- so
        //    they would be one module identity and one C++ namespace, and
        //    the first-searched would win silently: the day `inc/a.k`
        //    appears beside `./a.k`, an `import a` elsewhere changes meaning.
        //    The fault the anchored forms exist to prevent, and the same error
        //    (Compiler/Spec/Imports.md#path-resolution, decision E). Every unnamed dir is probed,
        //    not just those after the winner: the importer's own dir wins
        //    the search but must not hide a twin. A library never searches
        //    unnamed dirs.
        var other_hit        = false
        var other_path: Path
        if root_hit && hit_root != &null && hit_root->name.size() == 0 {
            var oi: usize = 0
            while oi < self._roots.size() && !other_hit {
                var unsafe *r = self._roots[oi]
                oi += 1
                if r == hit_root || r->name.size() > 0 || r->discovered {
                    continue
                }

                var h = self._probe_root(r, segments)
                if h.found && h.path.full_path() != root_path.full_path() {
                    other_hit  = true
                    other_path = h.path
                }
            }
        }

        if !root_hit {
            return out
        }

        out.found  = true
        out.path   = root_path
        out.origin = ModuleOrigin::Root
        if other_hit {
            out.ambiguous  = true
            out.cross_root = true
            out.other_path = other_path
        }

        return self._finish(out, segments)
    }

    /// \brief resolves a module path in ONE directory: `import self::x`
    ///        (the importing file's directory) or `import module::x` (its
    ///        module root). No search root is consulted, so no root file can
    ///        change what the import means.
    /// \param segments the path as written after the anchor
    /// \param dir      the anchor directory
    pub fn resolve_module_in(self,
                             segments:  cxx::std::vector<string>,
                             const dir: Path) -> ModuleResolution {
        var lock = kairo::std::LockGuard(self._mu)
        var out  = ModuleResolution{}
        if segments.size() == 0 {
            return out
        }

        var h = self._probe_root(self._sibling_root_for(dir), segments)
        if !h.found {
            return out
        }

        out.found  = true
        out.path   = h.path
        out.origin = ModuleOrigin::Sibling
        self._take_file_dir(&out, h)
        return self._finish(out, segments)
    }

    /// The winning probe's `foo.k`-and-`foo/module.k` finding, onto \p out.
    priv fn _take_file_dir(self, out: *ModuleResolution, h: Self::RootHit) {
        out->file_dir = h.file_dir
        if h.file_dir {
            out->dir_path = h.dir_path
        }
    }

    /// Identity for a found resolution; shared by both entry points so a
    /// file reached through `self::` and through a root is one module.
    priv fn _finish(self,
                    out:      ModuleResolution,
                    segments: cxx::std::vector<string>) -> ModuleResolution {
        var res = out
        res.canonical = self.canonical_module_path(res.path)
        self.claim_identity(res.canonical, res.path)
        if res.canonical.size() == 0 {
            // Resolved outside every search root (rare: an absolute -I sibling
            // walk). Fall back to the written spelling rather than handing
            // codegen an empty namespace path.
            res.canonical = segments
        }

        return res
    }

    /// \brief the module IDENTITY of a file: its path below the library
    ///        that holds it, prefixed by that library's name; or, under no
    ///        library, its path relative to the deepest search root that
    ///        contains it.
    ///
    /// \details This, not the import spelling, is what a file's module path
    ///          means. `root/Foo/baz.k` is `Foo::baz` whether it was reached as
    ///          `import Foo::baz` from the root or `import baz` from its
    ///          sibling. `root/std/mem/module.k` is `std::mem` - the `module`
    ///          leaf names the directory's entry point, not a segment.
    ///          `-` maps to `_` per the filename policy (Compiler/Spec/Codegen.md#sinks).
    ///
    ///          The library is found by walking UP from the file
    ///          (_library_of), past every search root if need be: a file's
    ///          module path is a property of the FILE (Compiler/Spec/Imports.md#module-pinning), so `cd geometry/inner && kairo x.k` and `-I
    ///          geometry/inner` give `geo::inner::x` exactly as an importer
    ///          above the library does. Stopping at the deepest root made
    ///          those two runs emit `namespace x`, and a `kcc -c` from inside
    ///          a library defined symbols no importer calls.
    /// \return the segments, or empty if no library and no search root
    ///         holds the file.
    fn canonical_module_path(self, const file: Path) -> cxx::std::vector<string> {
        var lock = kairo::std::LockGuard(self._mu)
        var out  = cxx::std::vector<string>()

        var best_rel  = ""
        var best_name = cxx::std::vector<string>()
        var lib       = self._library_of(Path::parent_of(file.full_path()))
        if lib.found {
            best_name = lib.name
            best_rel  = file.relative_to(Path::from_known(lib.dir, FileType::directory_file))
        } else {
            // No library above the file: the deepest search root holding it
            // (necessarily unnamed -- the walk stops at every named root).
            // Deepest, so a nested -I dir is not shadowed by an outer one
            // into a longer, wrong identity.
            var best_len: usize = 0
            for var i: usize = 0; i < self._roots.size(); ++i {
                var unsafe *root = self._roots[i]
                var        rel   = self._relative_to(file, root->base_path)
                if rel.size() == 0 {
                    continue
                }

                var base_len = root->base_path.full_path().size()
                if best_rel.size() == 0 || base_len > best_len {
                    best_rel = rel
                    best_len = base_len
                }
            }
        }

        if best_rel.size() == 0 {
            return out
        }

        // The library's name is the leading SEGMENTS: `~/foo/a.k` under a
        // `~/foo/module.k` pinning `foo` is `foo::a` from EVERY importer, and
        // `Lib/std/vec.k` under the driver's `kairo::std` root is
        // `kairo::std::vec`. That is what makes a file's identity -- and
        // therefore its C++ namespace -- independent of who imported it. An
        // unnamed search dir (the cwd, an unpinned -I) contributes no prefix.
        for var bi: usize = 0; bi < best_name.size(); ++bi {
            out.push_back(self.module_ident(best_name[bi]))
        }

        var parts = self.split_path(best_rel)
        if parts.size() == 0 {
            return out
        }

        // strip the extension off the leaf
        var leaf    = parts[parts.size() - 1]
        var dot_pos = leaf.rfind(".")
        if dot_pos != usize::MAX {
            leaf = leaf.subslice(0, dot_pos)
        }

        parts[parts.size() - 1] = leaf

        // `Foo/module.k` IS module `Foo`; the leaf names the directory entry.
        // At a library's TOP level the directory is the library itself, so
        // its NAME is already the whole path and the leaf drops there too.
        // Without the second clause `Lib/std/module.k` under `kairo::std`
        // would be `kairo::std::module`, its synthetic module_self would be
        // named `module`, and every decl in it would emit one C++ namespace
        // too deep. (Same latent bug for `Lib/builtin/module.k`, which was
        // `builtin::module`; unexercised only because the prelude folds it as
        // a wildcard and never binds its handle.)
        if leaf == "module" && (parts.size() > 1 || out.size() > 0) {
            parts.pop_back()
        }

        // The module.k at the top of an unnamed, unpinned dir names that dir,
        // which has no name: the file has no module path (it is outside every
        // library), not the path `module`.
        if leaf == "module" && parts.size() == 1 && out.size() == 0 {
            return out
        }

        for var i: usize = 0; i < parts.size(); ++i {
            out.push_back(self.module_ident(parts[i]))
        }

        return out
    }

    struct LibraryHit {
        var found: bool                     = false
        var dir:   string                           ///< the library's directory, as walked.
        var name:  cxx::std::vector<string>         ///< its name: the root's, or the pin's.
        var root:  unsafe *SearchRoot       = &null ///< the registered root, when it is one.
    }

    /// \brief the library holding directory \p start: the nearest directory
    ///        at or above it that is a NAMED root, or whose module.k pins a
    ///        name.
    ///
    /// \details A named root is asked before the pin at the same level: the
    ///          driver's registration of std and builtin outranks their own
    ///          module.k (build_index checks the two agree). Bounded by the
    ///          filesystem root and never downward: one stat per directory
    ///          walked, cached in _dir_pins, so every file of a build shares
    ///          the walk of its ancestors.
    priv fn _library_of(self, const start: string) -> Self::LibraryHit {
        var out  = Self::LibraryHit{}
        var walk = start
        while walk.size() > 0 {
            for var i: usize = 0; i < self._roots.size(); ++i {
                var unsafe *r = self._roots[i]
                if r->name.size() > 0 && r->base_path.full_path() == walk {
                    out.found = true
                    out.dir   = walk
                    out.name  = r->name
                    out.root  = r
                    return out
                }
            }

            var pin = self._pin_of_dir(walk)
            if pin.size() > 0 {
                self._check_pin_dir(walk, pin)
                out.found = true
                out.dir   = walk
                out.name  = pin
                return out
            }

            // Stop BEFORE an empty parent: joining "" with module.k is a
            // relative path, and the probe would read the cwd's module.k.
            var up = Path::parent_of(walk)
            if up.size() == 0 || up.size() >= walk.size() {
                break
            }

            walk = up
        }

        return out
    }

    /// A pinned directory that no root registered (a pin deeper than a
    /// root's immediate subdirectories, or one above every root) names a
    /// library all the same, so it collides like a registered one: with a
    /// named root of that name or spelling, or with another such directory
    /// pinning it. Without this, `d/vendor/g2/module.k` saying `module geo`
    /// beside a discovered `d/geometry` (`module geo`) put both libraries'
    /// files in one module path and one C++ namespace, with no diagnostic
    /// but a link error. Same R018E as two registered roots; each directory
    /// reported once.
    priv fn _check_pin_dir(self, const dir: string, pin: cxx::std::vector<string>) {
        var real = self._real(dir)
        // A registered library reached through another spelling (a symlink)
        // is that library, already checked when it was registered. An
        // UNNAMED root that pins -- the cwd inside a library -- is not, and
        // falls through.
        var unsafe *at = self._root_at_real(real)
        if at != &null && at->name.size() > 0 {
            return
        }

        var key   = self._name_str(pin)
        var other = string()
        for var k: usize = 0; k < self._roots.size(); ++k {
            var unsafe *r = self._roots[k]
            if r->name.size() == 0 || r->real_dir == real {
                continue
            }

            if root_names_equal(r->name, pin) || root_names_equal(r->spelling, pin) {
                other = r->base_path.full_path()
                break
            }
        }

        var other_real = string()
        if other.empty() {
            if !self._lib_pins.contains(kairo::sref(key)) {
                self._lib_pins[kairo::sref(key)]     = real
                self._lib_pin_dirs[kairo::sref(key)] = dir
                return
            }

            if self._lib_pins[kairo::sref(key)] == real {
                return
            }

            other      = self._lib_pin_dirs[kairo::sref(key)]
            other_real = self._lib_pins[kairo::sref(key)]
        } else {
            other_real = self._real(other)
        }

        var pair = other_real + "\n" + real
        if self._reported_pairs.contains(kairo::sref(pair)) {
            return
        }

        self._reported_pairs.insert(kairo::sref(pair))
        var c = RootNameCollision{}
        c.name   = key
        c.a      = other
        c.b      = dir
        c.pinned = true
        self._late_collisions.push_back(c.message())
    }

    /// \brief records that \p file holds module path \p ident; a different
    ///        file already holding it is a ModuleIdentityCollision.
    ///
    /// \details Called for every resolution and, by the driver, for every
    ///          input before any is compiled, so two inputs that one path
    ///          names (`./a.k` and `inc/a.k` under `-I inc`) are rejected
    ///          before either writes the object path they share. Files are
    ///          compared by real path: one file through a symlink is still
    ///          one module.
    pub fn claim_identity(self, ident: cxx::std::vector<string>, const file: Path) {
        var lock = kairo::std::LockGuard(self._mu)
        if ident.size() == 0 {
            return
        }

        var key  = self._name_str(ident)
        var real = self._real(file.full_path())
        if !self._identities.contains(kairo::sref(key)) {
            self._identities[kairo::sref(key)]     = real
            self._identity_files[kairo::sref(key)] = file.full_path()
            return
        }

        var first = self._identities[kairo::sref(key)]
        if first == real {
            return
        }

        var pair = first + "\n" + real
        if self._reported_pairs.contains(kairo::sref(pair)) {
            return
        }

        self._reported_pairs.insert(kairo::sref(pair))
        var c = ModuleIdentityCollision{}
        c.ident = key
        c.a     = self._identity_files[kairo::sref(key)]
        c.b     = file.full_path()
        self._late_collisions.push_back(c.message())
    }

    /// \brief drains the R018E findings made after build_index (a pinned
    ///        directory found walking up, two files on one module path), as
    ///        messages in the order found, for whoever owns a DiagEngine: the
    ///        PP walk after each resolution, the driver after claiming its
    ///        inputs.
    pub fn take_late_collisions(self) -> cxx::std::vector<string> {
        var lock = kairo::std::LockGuard(self._mu)
        var out  = self._late_collisions
        self._late_collisions.clear()
        return out
    }

    /// The transient root over the pinned library holding \p dir, when no
    /// registered root covers that library; null otherwise (no library, or
    /// a registered one, which root_for_dir already answers).
    priv fn _pinned_root_for(self, const dir: Path) -> unsafe *SearchRoot {
        var lib = self._library_of(dir.full_path())
        if !lib.found || lib.root != &null {
            return &null
        }

        if self._pinned_roots.contains(kairo::sref(lib.dir)) {
            return self._pinned_roots[kairo::sref(lib.dir)]
        }

        var unsafe *r = kairo::std::create<SearchRoot>(
            Path::from_known(lib.dir, FileType::directory_file),
            u32::MAX,
            self._ext_cfg,
            lib.name,
            lib.name,
        )

        r->discovered                            = true
        self._pinned_roots[kairo::sref(lib.dir)] = r
        return r
    }

    /// \brief the module path a COMMAND-LINE input (or a .k a C++ input
    ///        includes) takes: its canonical_module_path, the one an import
    ///        of it gets, or empty for a file with none.
    ///
    /// \details Empty, too, when the path under an unnamed search dir starts
    ///          with a NAMED root's name or spelling and the file is not in
    ///          that root: `./builtin.k` would be module `builtin`, the
    ///          builtin library's own path. An import of that path reaches
    ///          the library, never this file, so the file is not the module
    ///          there; taking the path would put two modules in one C++
    ///          namespace (and the driver reads a leading `builtin` as the
    ///          prelude). Such a file stays pathless, as one outside every
    ///          root does (CXXSpell::is_entry_tu).
    pub fn input_module_path(self, const file: Path) -> cxx::std::vector<string> {
        var lock = kairo::std::LockGuard(self._mu)
        var segs = self.canonical_module_path(file)
        if segs.size() == 0 {
            return segs
        }

        for var i: usize = 0; i < self._roots.size(); ++i {
            var unsafe *r = self._roots[i]
            if r->name.size() == 0 {
                continue
            }

            if !self._relative_to(file, r->base_path).empty() { // its own library
                continue
            }

            if self._segs_start_with(&segs, &r->name)
                || self._segs_start_with(&segs, &r->spelling) {
                return cxx::std::vector<string>()
            }
        }

        return segs
    }

    priv fn _segs_start_with(self,
                             @inout segs: cxx::std::vector<string>,
                             @inout head: cxx::std::vector<string>) -> bool {
        if head.size() == 0 || head.size() > segs.size() {
            return false
        }

        for var i: usize = 0; i < head.size(); ++i {
            if segs[i] != head[i] {
                return false
            }
        }

        return true
    }

    /// \brief drains module-name collisions found during discovery.
    ///
    /// \details Discovery runs first in the DepScanner, which has no
    ///          DiagEngine, so findings are queued here and drained by the PP
    ///          walk (FileImportIndex), which does. Each directory is swept
    ///          exactly once, so every collision is reported exactly once no
    ///          matter how many imports pass through it.
    pub fn take_collisions(self) -> cxx::std::vector<ModuleNameCollision> {
        var lock = kairo::std::LockGuard(self._mu)
        var out  = self._collisions
        self._collisions.clear()
        return out
    }

    /// \brief drains duplicate-root-name findings from build_index.
    ///
    /// \details Fatal, and reported BEFORE anything is parsed: a module path
    ///          under a duplicated root name means two different files.
    pub fn take_root_collisions(self) -> cxx::std::vector<RootNameCollision> {
        var lock = kairo::std::LockGuard(self._mu)
        var out  = self._root_collisions
        self._root_collisions.clear()
        return out
    }

    /// \brief the deepest registered root that contains \p dir, or null.
    ///
    /// \details "The importing file's own root": what its unqualified imports
    ///          resolve against first, and the root whose name prefixes its
    ///          own module path (Compiler/Spec/Imports.md#path-resolution).
    pub fn root_for_dir(self, const dir: Path) -> unsafe *SearchRoot {
        var lock                         = kairo::std::LockGuard(self._mu)
        var best:     unsafe *SearchRoot = &null
        var best_len: usize              = 0
        for var i: usize = 0; i < self._roots.size(); ++i {
            var unsafe *r = self._roots[i]
            if self._relative_to(dir, r->base_path).size() == 0 {
                // _relative_to returns empty for "not under"; the root dir
                // itself is handled by the full-path equality below.
                if dir.full_path() != r->base_path.full_path() {
                    continue
                }
            }

            var len = r->base_path.full_path().size()
            if best == &null || len > best_len {
                best     = r
                best_len = len
            }
        }

        return best
    }

    /// \brief the module identity a filename claims: `-` folded to `_`.
    ///
    /// \details `foo-bar.k` names module `foo_bar` (Compiler/Spec/Codegen.md#sinks): module path
    ///          segments must be valid identifiers, and `-` is the one
    ///          pragmatic exception rather than an escaping scheme that would
    ///          leak into mangled names forever.
    fn module_ident(self, const name: string) -> string {
        var out = name
        for var i: usize = 0; i < out.size(); ++i {
            if out[i] == ('-' as u8) {
                out[i] = ('_' as u8)
            }
        }

        return out
    }

    /// # relative resolution internals

    struct RootHit {
        var found:    bool = false
        var path:     Path
        var file_dir: bool = false ///< `leaf.k` AND `leaf/module.k` both matched
        var dir_path: Path         ///< the `leaf/module.k`, iff file_dir
    }

    /// One root, one probe. Mirrors resolve_module/resolve_module_dir for a
    /// single root so every place is resolved by identical rules: `foo.k`,
    /// else `foo/module.k`; both present is reported (`file_dir`), the file
    /// still answering so the import does not cascade into "not found".
    /// Sweeps the containing directory for name collisions on the way.
    priv fn _probe_root(self,
                        root:           unsafe *SearchRoot,
                        const segments: cxx::std::vector<string>) -> Self::RootHit {
        var out = Self::RootHit{}
        if root == &null {
            return out
        }

        var unsafe *node = root->root
        for var i: usize = 0; i + 1 < segments.size(); ++i {
            node = node->find_dir(segments[i])
            if node == &null {
                return out
            }
        }

        var last = segments[segments.size() - 1]
        self._sweep_dir(node)

        var        mod_node: unsafe *DirEntry = &null
        var unsafe *dir_node                  = node->find_dir(last)
        if dir_node != &null {
            mod_node = dir_node->find_by_stem_and_category("module", FileCategory::KairoSource)
            if mod_node != &null && !mod_node->file_path? {
                mod_node = &null
            }
        }

        var unsafe *file_node = node->find_by_stem_and_category(last, FileCategory::KairoSource)
        if file_node != &null && file_node->file_path? {
            out.found = true
            out.path     = unwrap!(file_node->file_path)
            out.file_dir = mod_node != &null
            if out.file_dir {
                out.dir_path = unwrap!(mod_node->file_path)
            }

            return out
        }

        if mod_node != &null {
            out.found = true
            out.path  = unwrap!(mod_node->file_path)
        }

        return out
    }

    /// Get-or-create the transient SearchRoot for an importing file's dir.
    priv fn _sibling_root_for(self, dir: Path) -> unsafe *SearchRoot {
        var key = dir.full_path()
        if self._sibling_roots.contains(kairo::sref(key)) {
            return self._sibling_roots[kairo::sref(key)]
        }

        if !dir.exists() || !dir.is_directory() {
            return &null
        }

        // priority u32(-1): never competes with a real root, and is only ever
        // reached through resolve_module_rel.
        var unsafe *r = kairo::std::create<SearchRoot>(dir, u32::MAX, self._ext_cfg)
        self._sibling_roots[kairo::sref(key)] = r
        return r
    }

    priv fn _is_root_dir(self, const dir: Path) -> bool {
        return self._root_at_real(self._real(dir.full_path())) != &null
    }

    /// `file` relative to `base`, or "" when `file` is not under `base`.
    priv fn _relative_to(self, const file: Path, const base: Path) -> string {
        return file.relative_to(base)
    }

    /// # module-name collision sweep (module discovery)

    /// One readdir per directory that actually hosts a resolved module, ever.
    /// Two names claiming one module identity is the same fault as an ambiguous
    /// import, one layer down, so it gets found in the same pass that resolves
    /// the import. Directories nobody imports from are never scanned - the
    /// lazy-probe design survives.
    priv fn _sweep_dir(self, dir: unsafe *DirEntry) {
        if dir == &null || !dir->is_dir {
            return
        }

        if !dir->fs_path? {
            return
        }

        var key = unwrap!(dir->fs_path).full_path()
        if self._swept_dirs.contains(kairo::sref(key)) {
            return
        }

        self._swept_dirs.insert(kairo::sref(key))

        dir->ensure_scanned()

        // Sorted, so a collision is reported with the same pair ordering on
        // every run (children is an unordered_map).
        var names = cxx::std::vector<string>()
        for var it = dir->children.begin(); it != dir->children.end(); ++it {
            var unsafe *child = it->second
            if child == &null {
                continue
            }

            if child->name.size() == 0 {
                continue
            }

            if !child->is_dir && child->category != FileCategory::KairoSource {
                continue
            }

            names.push_back(child->name)
        }

        cxx::std::sort(names.begin(), names.end())

        var seen = llvm::StringMap<string>() // identity -> first claimant; probed only
        for var i: usize = 0; i < names.size(); ++i {
            var raw   = names[i]
            var ident = self._lower(self.module_ident(raw))
            var ins   = seen.try_emplace(kairo::sref(ident), raw)
            if ins.second {
                continue
            }

            var other = ins.first->second
            if other == raw { // a dir and its own module.k, etc.
                continue
            }

            var c = ModuleNameCollision{}
            c.dir       = key
            c.a         = other
            c.b         = raw
            c.ident     = self.module_ident(other)
            c.case_only = self._lower(other) == self._lower(raw)
            self._collisions.push_back(c)
        }
    }

    priv fn _lower(self, const s: string) -> string {
        var out = s
        for var i: usize = 0; i < out.size(); ++i {
            if out[i] >= ('A' as u8) && out[i] <= ('Z' as u8) {
                out[i] = out[i] + 32
            }
        }

        return out
    }

    /// \brief resolves a kairo library (.hlib) by name
    /// \param name library stem without extension
    /// \return the resolved path; panics ResolveError::NotFound when there is none
    fn resolve_library(self, const name: string)
        panic(ResolveError) -> Path {
        self.wait_for_index()

        for var root: *SearchRoot in self._roots {
            var unsafe *node = root->root->find_by_stem_and_category(
                name,
                FileCategory::KairoLibrary,
            )

            if node != &null && node->file_path? {
                return unwrap!(node->file_path)
            }
        }

        panic ResolveError::NotFound
    }

    /// \brief collects all exportable module names under a given path
    /// \param segments path to the directory to scan
    /// \return vector of file stems (excluding "module")
    ///
    /// stops after the first root that yields results.
    fn collect_exports(self, segments: cxx::std::vector<string>) -> cxx::std::vector<string> {
        var result = cxx::std::vector<string>()

        for var root: *SearchRoot in self._roots {
            var unsafe *node = root->traverse(segments)

            if node == &null || !node->is_dir {
                continue
            }

            var files = node->collect_by_category(FileCategory::KairoSource)

            for var f: *DirEntry in files {
                if f->name != "module" {
                    result.push_back(f->name)
                }
            }

            if result.size() > 0 {
                break
            }
        }

        return result
    }

    /// \brief resolves a C++ header by stem
    /// \param name header stem without extension
    /// \return the resolved path; panics ResolveError::NotFound when there is none
    fn resolve_cxx_header(self, const name: string)
        panic(ResolveError) -> Path {
        self.wait_for_index()

        return self.resolve_by_category(name, FileCategory::CxxHeader)
    }

    /// \brief resolves a C++ source file by stem
    /// \param name source stem without extension
    /// \return the resolved path; panics ResolveError::NotFound when there is none
    fn resolve_cxx_source(self, const name: string)
        panic(ResolveError) -> Path {
        self.wait_for_index()

        return self.resolve_by_category(name, FileCategory::CxxSource)
    }

    /// \brief resolves a C header by stem
    /// \param name header stem without extension
    /// \return the resolved path; panics ResolveError::NotFound when there is none
    fn resolve_c_header(self, const name: string)
        panic(ResolveError) -> Path {
        self.wait_for_index()

        return self.resolve_by_category(name, FileCategory::CHeader)
    }

    /// \brief resolves a C source file by stem
    /// \param name source stem without extension
    /// \return the resolved path; panics ResolveError::NotFound when there is none
    fn resolve_c_source(self, const name: string)
        panic(ResolveError) -> Path {
        self.wait_for_index()

        return self.resolve_by_category(name, FileCategory::CSource)
    }

    /// \brief resolves a C/C++ include path as written in `#include` directives
    /// \param include_path the path string, e.g. "foo/bar.h" or "baz"
    /// \return the resolved path; panics ResolveError::NotFound when there is none
    ///
    /// if no extension is provided, tries all known C++ header extensions.
    fn resolve_cxx_include(self, const include_path: string)
        panic(ResolveError) -> Path {
        self.wait_for_index()

        var segments = self.split_path(include_path)

        if segments.size() == 0 {
            panic ResolveError::NotFound
        }

        var last = segments[segments.size() - 1]
        segments.pop_back()

        var dot_pos = last.rfind(".")
        var stem    = last
        var ext     = string()

        if dot_pos != usize::MAX {
            stem = last.subslice(0, dot_pos)
            ext  = last.subslice(dot_pos + 1, last.size())
        }

        for var root: *SearchRoot in self._roots {
            var unsafe *node = root->traverse(segments)

            if node == &null {
                node = root->root
            }

            if ext.size() > 0 {
                var unsafe *file_node = node->find_with_ext(stem, ext)
                if file_node != &null && file_node->file_path? {
                    return unwrap!(file_node->file_path)
                }
            } else {
                var unsafe *header_exts = self._ext_cfg->cxx_header_exts()
                for var hext: string in *header_exts {
                    var unsafe *file_node = node->find_with_ext(stem, hext)
                    if file_node != &null && file_node->file_path? {
                        return unwrap!(file_node->file_path)
                    }
                }
            }
        }

        panic ResolveError::NotFound
    }

    /// \brief resolves a file by category in the root directories (non-recursive)
    /// \param name file stem
    /// \param cat category to match
    /// \return the resolved path; panics ResolveError::NotFound when there is none
    fn resolve_by_category(self, const name: string, cat: FileCategory)
        panic(ResolveError) -> Path {
        self.wait_for_index()

        for var root: *SearchRoot in self._roots {
            var unsafe *node = root->root->find(name)

            if node != &null && node->category == cat {
                return unwrap!(node->file_path)
            }
        }

        panic ResolveError::NotFound
    }

    /// \brief resolves a file by stem and explicit extension
    /// \param name file stem
    /// \param ext extension without leading dot
    /// \return the resolved path; panics ResolveError::NotFound when there is none
    fn resolve_by_ext(self, const name: string, const ext: string)
        panic(ResolveError) -> Path {
        self.wait_for_index()

        for var root: *SearchRoot in self._roots {
            var unsafe *node = root->root->find_with_ext(name, ext)

            if node != &null && node->file_path? {
                return unwrap!(node->file_path)
            }
        }

        panic ResolveError::NotFound
    }

    /// \brief resolves an arbitrary file given path segments
    /// \param segments path components; last element is the filename
    /// \return the resolved path; panics ResolveError::NotFound when there is none
    ///
    /// if the filename has no extension, attempts to match any file with that stem.
    fn resolve_file(self, segments: cxx::std::vector<string>) panic(ResolveError) -> Path {
        self.wait_for_index()

        if segments.size() == 0 {
            panic ResolveError::NotFound
        }

        var dir_segments = segments
        var file_name    = dir_segments[dir_segments.size() - 1]
        dir_segments.pop_back()

        for var root: *SearchRoot in self._roots {
            var unsafe *node = root->root

            if dir_segments.size() > 0 {
                node = root->traverse(dir_segments)
            }

            if node == &null {
                continue
            }

            var unsafe *file_node = node->find(file_name)

            if file_node == &null && file_name.rfind(".") == usize::MAX {
                for var child: *DirEntry in node->sorted_children() {
                    if !child->is_dir && child->name == file_name && child->ext.size() == 0 {
                        file_node = child
                        break
                    }
                }
            }

            if file_node != &null && !file_node->is_dir && file_node->file_path? {
                return unwrap!(file_node->file_path)
            }
        }

        panic ResolveError::NotFound
    }

    /// \brief resolves a relative path from the location of another file
    /// \param rel_path the relative path string
    /// \param from_file the file whose directory is used as the base
    /// \return the resolved path; panics ResolveError::NotFound when there is none
    ///
    /// falls back to searching search roots if not found relative to `from_file`.
    fn resolve_path(self, const rel_path: string, const from_file: Path)
        panic(ResolveError) -> Path {
        self.wait_for_index()

        var candidate = Path::join_str(from_file.parent_path(), rel_path)

        if Path::exists_at(candidate) {
            return Path(candidate, false)
        }

        for var root: *SearchRoot in self._roots {
            candidate = root->base_path.join(rel_path)

            if Path::exists_at(candidate) {
                return Path(candidate, false)
            }
        }

        panic ResolveError::NotFound
    }

    /// \brief checks if a relative path exists under any search root
    /// \param rel_path the relative path to check
    /// \return true if the path exists
    fn path_exists(self, const rel_path: string) -> bool {
        for var root: *SearchRoot in self._roots {
            var candidate = root->base_path.join(rel_path)

            if Path::exists_at(candidate) {
                return true
            }
        }

        return false
    }

    /// \brief collects all files matching a category across all roots (recursive)
    /// \param cat the file category to collect
    /// \return vector of paths; duplicates are filtered by full path string
    fn collect_all_by_category(self, cat: FileCategory) -> cxx::std::vector<Path> {
        var result = cxx::std::vector<Path>()
        var seen   = llvm::StringSet<llvm::MallocAllocator>() // full paths; membership only (result keeps the order)

        for var root: *SearchRoot in self._roots {
            self.collect_recursive(root->root, cat, unsafe &result, unsafe &seen)
        }

        return result
    }

    priv fn collect_recursive(self,
                              node:   unsafe *DirEntry,
                              cat:    FileCategory,
                              result: unsafe *cxx::std::vector<Path>,
                              seen:   unsafe *llvm::StringSet<llvm::MallocAllocator>) {
        var files = node->collect_by_category(cat)

        for var f: unsafe *DirEntry in files {
            var path_str = unwrap!(f->file_path).full_path()
            if seen->insert(kairo::sref(path_str)).second {
                result->push_back(unwrap!(f->file_path))
            }
        }

        for var child: unsafe *DirEntry in node->sorted_children() {
            if child->is_dir {
                self.collect_recursive(child, cat, result, seen)
            }
        }
    }


    /// \brief clears the resolution cache
    fn invalidate_cache(self) {
        self._cache.clear()
    }

    /// \brief rebuilds a single search root by index
    /// \param index the root index in `_roots`
    ///
    /// destroys and recreates the root, then invalidates the cache.
    fn rebuild_root(self, index: usize) {
        if index >= self._roots.size() {
            return
        }

        var unsafe *old     = self._roots[index]
        var        path     = old->base_path
        var        priority = old->priority
        // Everything a root IS, copied BEFORE the destroy. Dropping the name
        // demoted a named root to an unnamed search dir and changed every
        // module path under it; dropping the spelling made std reachable
        // only as `kairo::std`; dropping `discovered` made a pinned
        // library's files importable unqualified (the last-resort probe).
        var name       = old->name
        var spelling   = old->spelling
        var discovered = old->discovered

        kairo::std::destroy(old)
        var unsafe *fresh = kairo::std::create<SearchRoot>(
            path,
            priority,
            self._ext_cfg,
            name,
            spelling,
        )

        fresh->discovered  = discovered
        self._roots[index] = fresh

        self.invalidate_cache()
    }

    /// \brief rebuilds all search roots
    fn rebuild_all(self) {
        for i in (0 as usize)..self._roots.size() {
            self.rebuild_root(i)
        }
    }

    /// \brief returns a human-readable dump of search paths with priorities
    fn dump_search_paths(self) -> string {
        var result = "ImportResolver search paths:\n"

        for i in (0 as usize)..self._roots.size() {
            var unsafe *root = self._roots[i]
            result += f"  [{root->priority}] {root->name_str()} -> {root->base_path.full_path()}\n"
        }

        return result
    }

    /// \brief returns a summary of cache statistics
    fn cache_stats(self) -> string {
        return f"ImportResolver cache: {self._cache.size()} entries"
    }

    /// \brief returns a human-readable dump of all indexed files matching a category
    /// \param cat the category to dump
    fn dump_indexed_files(self, cat: FileCategory) -> string {
        var files  = self.collect_all_by_category(cat)
        var result = f"Indexed files (category {(cat as u32)}):\n"

        for *p in files {
            result += f"  {p->full_path()}\n"
        }

        return result
    }

    /// A root name spelled back for a diagnostic. Mirrors SearchRoot::name_str
    /// but takes the raw segments, which is what the collision record has.
    priv fn _name_str(self, const segs: cxx::std::vector<string>) -> string {
        if segs.size() == 0 {
            return "<entry>"
        }

        var out = string()
        for var i: usize = 0; i < segs.size(); ++i {
            if i > 0 {
                out += "::"
            }

            out += segs[i]
        }

        return out
    }

    priv fn make_cache_key(self,
                           const prefix:   string,
                           const segments: cxx::std::vector<string>) -> string {
        var key = prefix + ":"

        for i in (0 as usize)..segments.size() {
            if i > 0 {
                key += "::"
            }

            key += segments[i]
        }

        return key
    }

    priv fn split_path(self, const path: string) -> cxx::std::vector<string> {
        var result  = cxx::std::vector<string>()
        var current = string()

        for i in (0 as usize)..path.size() {
            var c = path[i]

            if c == ('/' as u8) || c == ('\\' as u8) {
                if current.size() > 0 {
                    result.push_back(current)
                    current = string()
                }
            } else {
                current.push_back(c)
            }
        }

        if current.size() > 0 {
            result.push_back(current)
        }

        return result
    }

    /// \brief returns a complete dump of the entire index structure
    ///
    /// includes all roots, directory trees, and cache entries. useful for debugging.
    fn dump_full_index(self) -> string {
        var result = "Full ImportResolver Index Dump:\n"

        for i in (0 as usize)..self._roots.size() {
            var unsafe *root = self._roots[i]
            result += f"\n[Root {i}] priority={root->priority} name={root->name_str()} path={root->base_path.full_path()}\n"
            result += self.dump_node(root->root, 1)
        }

        result += f"\n=== Cache: {self._cache.size()} entries ===\n"
        for *entry in self._cache {
            result += f"  {entry->first} -> {entry->second.full_path()}\n"
        }

        return result
    }

    priv fn dump_node(self, node: unsafe *DirEntry, depth: usize) -> string {
        var result = string()
        var indent = string()

        for _ in (0 as usize)..depth {
            indent += "  "
        }

        if node->is_dir {
            result += f"{indent}[DIR] {node->name}/\n"
        } else {
            var cat_str  = self.category_to_string(node->category)
            var path_str = "<null>"

            if node->file_path? {
                path_str = unwrap!(node->file_path).full_path()
            }

            if node->ext.size() > 0 {
                result += f"{indent}[FILE] {node->name}.{node->ext} ({cat_str})\n"
            } else {
                result += f"{indent}[FILE] {node->name} ({cat_str})\n"
            }

            result += f"{indent}       -> {path_str}\n"
        }

        for var child: unsafe *DirEntry in node->sorted_children() {
            result += self.dump_node(child, depth + 1)
        }

        return result
    }

    priv fn category_to_string(self, cat: FileCategory) -> string {
        if cat == FileCategory::KairoSource {
            return "KairoSource"
        }

        if cat == FileCategory::KairoLibrary {
            return "KairoLibrary"
        }

        if cat == FileCategory::CxxSource {
            return "CxxSource"
        }

        if cat == FileCategory::CxxHeader {
            return "CxxHeader"
        }

        if cat == FileCategory::CSource {
            return "CSource"
        }

        if cat == FileCategory::CHeader {
            return "CHeader"
        }

        if cat == FileCategory::Other {
            return "Other"
        }

        return "Ignored"
    }
}

pub fn Test() -> i32 {
    io::println("=== ImportResolver Test ===\n")

    // create a temp test directory structure
    var tmp          = Path::temp_dir()
    var test_root    = tmp.join("hlx_import_test")
    var include_root = tmp.join("hlx_include_test")

    // clean up if exists from previous run
    Path::remove_tree(test_root)
    Path::remove_tree(include_root)

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

    Path::make_dirs(Path::join_str(test_root, "std/mem"))
    Path::make_dirs(Path::join_str(test_root, "cpp"))
    Path::make_dirs(Path::join_str(test_root, "Assets"))
    Path::make_dirs(include_root)

    // create dummy files
    var files_to_create = cxx::std::vector<string>()

    // kairo files
    files_to_create.emplace_back(Path::join_str(test_root, "std/io.k"))
    files_to_create.emplace_back(Path::join_str(test_root, "std/net.k"))
    files_to_create.emplace_back(Path::join_str(test_root, "std/mem/module.k"))
    files_to_create.emplace_back(Path::join_str(test_root, "std/mem/alloc.k"))
    files_to_create.emplace_back(Path::join_str(test_root, "mylib.hlib"))
    files_to_create.emplace_back(Path::join_str(test_root, "util.k"))

    // c++ files
    files_to_create.emplace_back(Path::join_str(test_root, "cpp/helper.hpp"))
    files_to_create.emplace_back(Path::join_str(test_root, "cpp/helper.cpp"))
    files_to_create.emplace_back(Path::join_str(test_root, "cpp/legacy.h"))

    // random files (json, txt, no extension)
    files_to_create.emplace_back(Path::join_str(test_root, "Assets/config.json"))
    files_to_create.emplace_back(Path::join_str(test_root, "Assets/data.txt"))
    files_to_create.emplace_back(Path::join_str(test_root, "Assets/README"))
    files_to_create.emplace_back(Path::join_str(test_root, "Makefile"))

    // include path files
    files_to_create.emplace_back(Path::join_str(include_root, "util.k"))
    files_to_create.emplace_back(Path::join_str(include_root, "extra.k"))

    for *p in files_to_create {
        Path::write_file(*p, "")
    }

    var test_path    = Path(test_root, false)
    var include_path = Path(include_root, false)
    var includes     = cxx::std::vector<Path>()
    includes.push_back(include_path)

    var unsafe *pool = kairo::std::create<ThreadPool>(4)

    finally {
        kairo::std::destroy(pool)
    }

    var unsafe *resolver = ImportResolver::Builder().cwd(test_path)->add_includes(
        includes,
    )->create_ptr()

    finally { // cleanup
        kairo::std::destroy(resolver)
        Path::remove_tree(test_root)
        Path::remove_tree(include_root)
    }

    io::println(f"{resolver->dump_full_index()}")

    var failed = 0
    var passed = 0

    var fail_string = "\x1b[31m[FAIL]\x1b[0m"
    var pass_string = "\x1b[32m[PASS]\x1b[0m"

    var suite = Assert("ImportResolver Tests")

    // KAIRO MODULE RESOLUTION

    suite.equal<i32>(
        "resolve_module std::io",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("std")
            segments.push_back("io")
            var result: Path? = null
            try {
                result = resolver->resolve_module(segments)
            } catch { }

            if result? {
                var p? = result
                if p.filename() == "io.k" {
                    return 1
                } else {
                    return 0
                }
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "resolve directory module (std::mem -> std/mem/module.k)",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("std")
            segments.push_back("mem")
            var result: Path? = null
            try {
                result = resolver->resolve_module(segments)
            } catch { }

            if result? {
                var p? = result
                if p.filename() == "module.k" {
                    return 1
                } else {
                    return 0
                }
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "resolve nested module (std::mem::alloc -> std/mem/alloc.k)",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("std")
            segments.push_back("mem")
            segments.push_back("alloc")
            var result: Path? = null
            try {
                result = resolver->resolve_module(segments)
            } catch { }

            if result? {
                var p? = result
                if p.filename() == "alloc.k" {
                    return 1
                } else {
                    return 0
                }
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "resolve library (mylib -> mylib.hlib)",
        1,
        fn () -> i32 {
            var result: Path? = null
            try {
                result = resolver->resolve_library("mylib")
            } catch { }

            if result? {
                var p? = result
                if p.filename() == "mylib.hlib" {
                    return 1
                } else {
                    return 0
                }
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "resolve top-level module (util -> util.k)",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("util")
            var result: Path? = null
            try {
                result = resolver->resolve_module(segments)
            } catch { }

            if result? {
                var p? = result
                if p.filename() == "util.k" {
                    return 1
                } else {
                    return 0
                }
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "resolve_module_dir explicitly",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("std")
            segments.push_back("mem")
            var result: Path? = null
            try {
                result = resolver->resolve_module_dir(segments)
            } catch { }

            if result? && result.filename() == "module.k" {
                return 1
            } else {
                return 0
            }

            // should fail for non-directory module
            var segments2: cxx::std::vector<string>
            segments2.push_back("std")
            segments2.push_back("io")
            var result2: Path? = null
            try {
                result2 = resolver->resolve_module_dir(segments2)
            } catch { }

            if !result2? {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "module not found",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("nonexistent")
            segments.push_back("module")
            var result: Path? = null
            try {
                result = resolver->resolve_module(segments)
            } catch { }

            if !result? {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "collect exports (std::mem::*)",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("std")
            segments.push_back("mem")
            var exports = resolver->collect_exports(segments)

            var found_alloc  = false
            var found_module = false

            for *name in exports {
                if *name == "alloc" {
                    found_alloc = true
                }

                if *name == "module" {
                    found_module = true
                }
            }

            if found_alloc && !found_module {
                return 1
            }

            return 0
        },
        10000,
    )

    // C/C++ RESOLUTION

    suite.equal<i32>(
        "resolve c++ header with extension",
        1,
        fn () -> i32 {
            var result: Path? = null
            try {
                result = resolver->resolve_cxx_include("cpp/helper.hpp")
            } catch { }

            if result? {
                var p? = result
                if p.filename() == "helper.hpp" {
                    return 1
                } else {
                    return 0
                }
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "resolve c++ header without extension",
        1,
        fn () -> i32 {
            var result: Path? = null
            try {
                result = resolver->resolve_cxx_include("cpp/helper")
            } catch { }

            if result? {
                var p? = result
                if p.filename() == "helper.hpp" || p.filename() == "helper.h" {
                    return 1
                } else {
                    return 0
                }
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "resolve c header",
        1,
        fn () -> i32 {
            var result: Path? = null
            try {
                result = resolver->resolve_cxx_include("cpp/legacy.h")
            } catch { }

            if result? {
                var p? = result
                if p.filename() == "legacy.h" {
                    return 1
                } else {
                    return 0
                }
            }

            return 0
        },
        10000,
    )

    // RANDOM FILES / NO EXTENSION

    suite.equal<i32>(
        "resolve json file",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("Assets")
            segments.push_back("config.json")
            var result: Path? = null
            try {
                result = resolver->resolve_file(segments)
            } catch { }

            if result? && result.filename() == "config.json" {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "resolve txt file",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("Assets")
            segments.push_back("data.txt")
            var result: Path? = null
            try {
                result = resolver->resolve_file(segments)
            } catch { }

            if result? && result.filename() == "data.txt" {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "resolve file with no extension (README)",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("Assets")
            segments.push_back("README")
            var result: Path? = null
            try {
                result = resolver->resolve_file(segments)
            } catch { }

            if result? && result.filename() == "README" {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "resolve Makefile (no extension, root level)",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("Makefile")
            var result: Path? = null
            try {
                result = resolver->resolve_file(segments)
            } catch { }

            if result? && result.filename() == "Makefile" {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "resolve_by_ext",
        1,
        fn () -> i32 {
            var result: Path? = null
            try {
                result = resolver->resolve_by_ext("mylib", "hlib")
            } catch { }

            if result? && result.filename() == "mylib.hlib" {
                return 1
            }

            return 0
        },
        10000,
    )

    // PATH RESOLUTION (for embed!, etc)

    suite.equal<i32>(
        "path_exists",
        1,
        fn () -> i32 {
            if resolver->path_exists("std/io.k") {
                return 1
            } else {
                return 0
            }

            if !resolver->path_exists("does/not/exist.k") {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "resolve_path relative to source file",
        1,
        fn () -> i32 {
            var from_file = Path(Path::join_str(test_root, "std/io.k"), false)

            // resolve sibling file
            var result: Path? = null
            try {
                result = resolver->resolve_path("net.k", from_file)
            } catch { }
            if result? && result.filename() == "net.k" {
                return 1
            } else {
                return 0
            }

            // resolve into subdirectory
            var result2: Path? = null
            try {
                result2 = resolver->resolve_path("mem/alloc.k", from_file)
            } catch { }
            if result2? && result2.filename() == "alloc.k" {
                return 1
            } else {
                return 0
            }

            // resolve nonexistent
            var result3: Path? = null
            try {
                result3 = resolver->resolve_path("nope.k", from_file)
            } catch { }
            if !result3? {
                return 1
            }

            return 0
        },
        10000,
    )

    // INCLUDE PATH PRIORITY

    suite.equal<i32>(
        "cwd takes priority over include paths",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("util")
            var result: Path? = null
            try {
                result = resolver->resolve_module(segments)
            } catch { }

            if result? {
                var p = result.full_path()
                // should resolve to cwd version, not include path
                if kairo::std::to_std_string(p).find(r"hlx_import_test") != cxx::std::string::npos {
                    return 1
                } else {
                    return 0
                }
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "fallback to include path for unique modules",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("extra")
            var result: Path? = null
            try {
                result = resolver->resolve_module(segments)
            } catch { }

            if result? && result.filename() == "extra.k" {
                return 1
            }

            return 0
        },
        10000,
    )

    // COLLECT BY CATEGORY

    suite.equal<i32>(
        "collect_all_by_category KairoSource",
        1,
        fn () -> i32 {
            var all_hlx = resolver->collect_all_by_category(FileCategory::KairoSource)

            // cwd: io, net, module, alloc, util = 5
            // include: util (dup), extra = 1 unique
            // total = 6
            if all_hlx.size() == 7 {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "collect_all_by_category CxxSource",
        1,
        fn () -> i32 {
            var all_cpp = resolver->collect_all_by_category(FileCategory::CxxSource)

            if all_cpp.size() == 1 {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "collect_all_by_category CxxHeader",
        1,
        fn () -> i32 {
            var all_hdr = resolver->collect_all_by_category(FileCategory::CxxHeader)

            // helper.hpp, legacy.h = 2
            if all_hdr.size() == 2 {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "collect_all_by_category Other (json, txt, no-ext)",
        1,
        fn () -> i32 {
            var all_other = resolver->collect_all_by_category(FileCategory::Other)

            // config.json, data.txt, README, Makefile = 4
            if all_other.size() == 4 {
                return 1
            }

            return 0
        },
        10000,
    )

    // CACHE BEHAVIOR

    suite.equal<i32>(
        "cache consistency",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("std")
            segments.push_back("io")

            var r1: Path? = null
            try {
                r1 = resolver->resolve_module(segments)
            } catch { }
            var r2: Path? = null
            try {
                r2 = resolver->resolve_module(segments)
            } catch { }

            if r1? && r2? {
                if r1.full_path() == r2.full_path() {
                    return 1
                } else {
                    return 0
                }
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "cache invalidation",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("std")
            segments.push_back("io")

            var r1: Path? = null
            try {
                r1 = resolver->resolve_module(segments)
            } catch { }
            resolver->invalidate_cache()
            var r2: Path? = null
            try {
                r2 = resolver->resolve_module(segments)
            } catch { }

            if r1? && r2? && r1.full_path() == r2.full_path() {
                return 1
            }

            return 0
        },
        10000,
    )

    // REBUILD

    suite.equal<i32>(
        "rebuild picks up new files",
        1,
        fn () -> i32 {
            // add new file after indexing
            var new_file = Path::join_str(test_root, "newmodule.k")
            Path::write_file(new_file, "")

            // should NOT find it yet (stale index)
            var segments: cxx::std::vector<string>
            segments.push_back("newmodule")
            var result: Path? = null
            try {
                result = resolver->resolve_module(segments)
            } catch { }

            if !result? {
                return 1
            } else {
                return 0
            }

            // rebuild and try again
            resolver->rebuild_all()

            var result2: Path? = null
            try {
                result2 = resolver->resolve_module(segments)
            } catch { }
            if result2? && result2.filename() == "newmodule.k" {
                return 1
            } else {
                return 0
            }

            Path::remove_file(new_file)
        },
        10000,
    )

    // EDGE CASES

    suite.equal<i32>(
        "empty segments",
        1,
        fn () -> i32 {
            var empty         = cxx::std::vector<string>()
            var result: Path? = null
            try {
                result = resolver->resolve_module(empty)
            } catch { }

            if !result? {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "single dot path",
        1,
        fn () -> i32 {
            var result: Path? = null
            try {
                result = resolver->resolve_cxx_include(".")
            } catch { }

            if !result? {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "empty string",
        1,
        fn () -> i32 {
            var result: Path? = null
            try {
                result = resolver->resolve_cxx_include("")
            } catch { }

            if !result? {
                return 1
            }

            return 0
        },
        10000,
    )

    suite.equal<i32>(
        "deeply nested path",
        1,
        fn () -> i32 {
            var segments: cxx::std::vector<string>
            segments.push_back("std")
            segments.push_back("mem")
            segments.push_back("module")
            var result: Path? = null
            try {
                result = resolver->resolve_module(segments)
            } catch { }

            // std/mem/module.k exists but as a file, not std/mem/module/module.k
            // this should find it as a direct file
            if result? && result.filename() == "module.k" {
                return 1
            }

            return 0
        },
        10000,
    )

    return failed
}
