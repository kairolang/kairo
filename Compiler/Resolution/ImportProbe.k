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
//      on the calling thread. this was forced by libcxx::filesystem, which
//      touched locale state on first use and threw on worker threads; the walk
//      is on llvm::sys::fs now, so that constraint is gone and async indexing
//      can be revisited. rn in kairo/ the
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
///          root module, or (`cross_root`) two different files through two
///          unnamed search dirs: a hard error at the import site (R017E).
///          The winner is still returned so resolution does not cascade into
///          a second "not found" for the same import.
class ModuleResolution {
    pub var found:      bool         = false;
    pub var path:       Path;                        ///< the resolved file.
    pub var canonical:  vec::<string>;               ///< identity segments from the search root.
    pub var origin:     ModuleOrigin = ModuleOrigin::Root;
    pub var ambiguous:  bool         = false;        ///< sibling AND root both matched.
    pub var other_path: Path;                        ///< the losing (root) candidate, iff ambiguous.
    pub var cross_root: bool         = false;        ///< ambiguous between two unnamed search dirs, not sibling/root.
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

/// \class RootNameCollision
/// \brief two search roots registered under one module name.
///
/// \details A root's name is the leading segment of every module under it, so
///          two roots sharing one name make a module path mean two files.
///          A build error, reported before anything is parsed; never
///          first-wins, never a merge (IMPORTS.md §2.1).
class RootNameCollision {
    pub var name:   string;
    pub var a:      string;   ///< the root already registered.
    pub var b:      string;   ///< the one that collided with it.
    pub var pinned: bool = false;   ///< `b` took its name from a pinned module.k, not -I.

    /// Not two roots: ONE directory the driver registers under `name` while
    /// its module.k pins `pin`. The registration wins (it is what the
    /// driver's own lookups -- the prelude, lang items -- address), so the
    /// pin would be a second, silently ignored answer to "what is this
    /// library called". `a` is the directory.
    pub var mismatch: bool = false;
    pub var pin:      string;

    /// The diagnostic text, one home for the driver (registration time) and
    /// the PP walk (a pin found later, by canonical_module_path's walk up).
    fn message(self) -> string {
        if self.mismatch {
            return f"'{self.a}/module.k' pins `module {self.pin}`, but this directory is registered as library '{self.name}', and the registration wins; make the pin `module {self.name}` or remove it";
        }
        // Only the driver's own registrations (builtin, kairo::std) name a
        // root without a pin, so either way the fix is a pin.
        if self.pinned {
            return f"duplicate module root '{self.name}': '{self.a}' and '{self.b}' both claim it; rename one library\x27s `module` declaration in its module.k";
        }
        return f"duplicate module root '{self.name}': '{self.a}' and '{self.b}' both claim it; rename the library\x27s `module` declaration in its module.k";
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
///          that makes it visible; IMPORTS.md §2.1, decision E.
class ModuleIdentityCollision {
    pub var ident: string;   ///< the module path, `::`-joined.
    pub var a:     string;   ///< the file that claimed it first.
    pub var b:     string;   ///< the other file.

    fn message(self) -> string {
        return f"'{self.a}' and '{self.b}' are both module '{self.ident}'; a module path names one file, and these two would share one C++ namespace and one object file: rename or move one, or make one part of a library with a pinned module.k";
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

    /// Duplicate root names found at build_index time. Same deferral reason as
    /// _collisions: the resolver has no DiagEngine.
    priv var _root_collisions:  vec::<RootNameCollision>;

    /// Per-directory answer to "does this directory's module.k pin a library
    /// name?", keyed by absolute dir; an empty vec is a cached NO. Written by
    /// index-time discovery and by canonical_module_path's walk up, so each
    /// module.k is read at most once per build.
    priv var _dir_pins:         map::<string, vec::<string>>;

    /// Module identity -> the REAL path of the file that holds it, and the
    /// pairs already reported (ModuleIdentityCollision). Written by every
    /// resolution and by the driver for each input (claim_identity).
    priv var _identities:       map::<string, string>;
    priv var _identity_files:   map::<string, string>;   ///< the same file as first spelled, for messages.
    priv var _reported_pairs:   set::<string>;

    /// R018E findings made AFTER build_index -- a pinned directory the walk
    /// up found colliding (_check_pin_dir), two files on one module path
    /// (claim_identity) -- as their messages, in the order they were found.
    /// ONE queue, drained whole: the PP walks files on several threads, and
    /// two queues let two threads each drain one, so the same build printed
    /// the pair in either order.
    priv var _late_collisions:  vec::<string>;

    /// Every entry point that reads or writes the maps above (and the lazy
    /// caches beside them) holds this: the PP resolves imports from every
    /// file of a wave at once (WaveExecutor). Recursive, because the entry
    /// points call one another (resolve_module_rel -> canonical_module_path
    /// -> _library_of).
    priv var _mu:               std::RecursiveMutex;

    /// A pinned directory no root registered, by the library name it pins
    /// -> its real path: the first such directory seen to claim the name.
    /// A second directory pinning one name, or a registered library's, is
    /// the R018E two named roots would be (_check_pin_dir).
    priv var _lib_pins:         map::<string, string>;
    priv var _lib_pin_dirs:     map::<string, string>;   ///< the same directory as first spelled.

    /// Transient roots over pinned directories that no root registered,
    /// keyed by directory: what a file inside such a library resolves its
    /// own imports against (resolve_module_rel, step 2a'). Owned, like
    /// _sibling_roots.
    priv var _pinned_roots:     map::<string, own::<SearchRoot>>;

    /// Symlink-resolved spellings, cached: identity comparisons ask the same
    /// directories again and again.
    priv var _real_paths:       map::<string, string>;

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
        priv var _include_names: vec::<vec::<string>>;  ///< parallel to _include_paths.
        priv var _include_spellings: vec::<vec::<string>>;  ///< parallel; empty = the name.
        priv var _ext_cfg:       *FileExtensions;
        priv var _pool:          *ThreadPool;

        /// \brief default constructor; initializes all fields to null/empty
        fn Builder(self) {
            self._cwd           = null;
            self._include_paths = vec::<Path>();
            self._include_names = vec::<vec::<string>>();
            self._include_spellings = vec::<vec::<string>>();
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
        /// \param name the root's MODULE name -- the leading SEGMENTS every
        ///             module under it carries (IMPORTS.md §2.1), written as a
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
        fn add_include(self, path: Path, name: string = "", spelling: string = "") -> ref!(Builder) {
            self._include_paths.push_back(path);
            // Empty stays empty: build_index tells an EXPLICIT name from
            // none by it, because only a nameless dir takes its pinned
            // module.k's name.
            self._include_names.push_back(split_module_name(name));
            self._include_spellings.push_back(split_module_name(spelling));
            return self;
        }

        /// \brief appends multiple include paths to the search list
        /// \param paths vector of directories to add
        /// \return pointer to self for chaining
        fn add_includes(self, paths: vec::<Path>) -> ref!(Builder) {
            for p: Path in paths {
                self.add_include(p, "");
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
            var cwd_path = self._cwd.value_or(Path::cwd());
            var resolver = std::create::<ImportResolver>(self._ext_cfg);

            // Always index synchronously on the calling (main) thread. (The
            // original reason, libcxx::filesystem throwing on worker threads,
            // left with the move to llvm::sys::fs.) Async indexing bought nothing since
            // CompilationBatch::run() calls wait_for_index() before dispatching
            // any TU tasks - the spin was immediate and free-threaded for zero gain.
            resolver->build_index(cwd_path, self._include_paths, &null,
                                  self._include_names, self._include_spellings);
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
    fn build_index(self, cwd: Path, include_paths: vec::<Path>, pool: *ThreadPool = &null,
                   include_names: vec::<vec::<string>> = vec::<vec::<string>>(),
                   include_spellings: vec::<vec::<string>> = vec::<vec::<string>>()) {
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
        for var i: usize = 0; i < include_paths.size(); ++i {
            var p = include_paths[i];
            if (!p.exists()) || (!p.is_directory()) { continue; }
            var nm = (include_names[i]) if (i < include_names.size()) else (vec::<string>());
            var sp = (include_spellings[i]) if (i < include_spellings.size()) else (vec::<string>());
            if sp.size() == 0 { sp = nm; }

            // An explicit name (the driver's builtin and kairo::std; the CLI
            // has no way to give one) is checked against the directory's own
            // pin. The registration wins -- the prelude and the lang items
            // address builtin by it, and std's spelling `std` is not
            // expressible as a pin at all -- so a pin saying something else
            // would be a second, silently ignored name.
            if nm.size() > 0 {
                var own_pin = self._pin_of_dir(p.full_path());
                if (own_pin.size() > 0) && (!root_names_equal(own_pin, nm)) {
                    var c = RootNameCollision{};
                    c.mismatch = true;
                    c.name     = self._name_str(nm);
                    c.pin      = self._name_str(own_pin);
                    c.a        = p.full_path();
                    self._root_collisions.push_back(c);
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
            var prior = self._root_at_real(self._real(p.full_path()));
            if prior != &null {
                if nm.size() > 0 {
                    self._check_root_name(p, nm, sp, false, prior);
                    prior->name       = nm;
                    prior->spelling   = sp;
                    prior->discovered = false;
                }
                continue;
            }

            // No explicit name: the directory's own pin names it, or it
            // stays an UNNAMED search dir, as the cwd is -- never its
            // basename, which made every `-I .../include` the same root
            // (TICKETS.TXT:210).
            var pinned = false;
            if nm.size() == 0 {
                nm = self._pin_of_dir(p.full_path());
                pinned = nm.size() > 0;
                sp = nm;
            }
            var r = self._add_root(p, priority, nm, sp, pinned);
            // A pinned -I dir is a library like a pinned subdirectory, and
            // reached the same way: by its declared name only. Left
            // undiscovered, the last-resort probe of every root found its
            // files by their bare paths too, so `-I geometry` with a
            // `module geo` made `import vec` reach `geo::vec`. The
            // driver's builtin and kairo::std are explicit names, not
            // pins, and keep that probe.
            if pinned { r->discovered = true; }
            priority += 1;
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
        var registered = self._roots.size();
        for var ri: usize = 0; ri < registered; ++ri {
            var dir = self._roots[ri]->root;
            if dir == &null { continue; }
            dir->ensure_scanned();
            for child: *DirEntry in dir->sorted_children() {
                if (child == &null) || (!child->is_dir) || (!child->fs_path) { continue; }
                var cpath = *(child->fs_path);
                // A directory already registered keeps the registration: the
                // driver's `Lib/std` is an explicit root AND a subdirectory of
                // `Lib`, and must not collide with itself.
                if self._is_root_dir(cpath) { continue; }
                if child->find_by_stem_and_category("module", FileCategory::KairoSource) == &null { continue; }
                var pin = self._pin_of_dir(cpath.full_path());
                if pin.size() == 0 { continue; }
                var lib = self._add_root(cpath, priority, pin, pin, true);
                lib->discovered = true;
                priority += 1;
            }
        }

        // `pool` retained for signature compatibility; lazy resolution needs no
        // worker dispatch. Resolution methods probe on demand; wait_for_index() is
        // a no-op.
        Logger::info(Logger::Stage::Preprocessor,
            f"ImportResolver::build_index: registered roots={self._roots.size()}");
    }

    /// Registers one root, checking it against every root before it. Two
    /// roots claiming one name is a build error, never first-wins and never
    /// a merge (IMPORTS.md §2.1). EQUAL names only: one name being a PREFIX
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
    priv fn _add_root(self, p: Path, priority: u32, nm: vec::<string>, sp: vec::<string>,
                      pinned: bool) -> *SearchRoot {
        self._check_root_name(p, nm, sp, pinned, &null);
        var root = std::create::<SearchRoot>(p, priority, self._ext_cfg, nm, sp);
        self._roots.push_back(root);
        return root;
    }

    /// The R018E half of _add_root, also run when an explicit registration
    /// renames an existing root in place. \p skip is that root itself.
    priv fn _check_root_name(self, p: Path, nm: vec::<string>, sp: vec::<string>,
                             pinned: bool, skip: *SearchRoot) {
        var real = self._real(p.full_path());
        for var k: usize = 0; (nm.size() > 0) && (k < self._roots.size()); ++k {
            var r = self._roots[k];
            if (r == skip) || (r->name.size() == 0) { continue; }
            // One directory under two spellings is one library.
            if r->real_dir == real { continue; }
            if (!root_names_equal(r->name, nm))
            && (!root_names_equal(r->spelling, sp)) { continue; }
            var c = RootNameCollision{};
            c.name   = (self._name_str(nm)) if (root_names_equal(r->name, nm)) else (self._name_str(sp));
            c.a      = r->base_path.full_path();
            c.b      = p.full_path();
            c.pinned = pinned;
            self._root_collisions.push_back(c);
        }
    }

    /// The registered root over the directory whose real path is \p real,
    /// or null.
    priv fn _root_at_real(self, real: string) -> *SearchRoot {
        for var i: usize = 0; i < self._roots.size(); ++i {
            if self._roots[i]->real_dir == real { return self._roots[i]; }
        }
        return &null;
    }

    /// \p p with its symlinks resolved, cached per spelling.
    priv fn _real(self, p: string) -> string {
        if self._real_paths.contains(p) { return self._real_paths[p]; }
        var r = Path::real_path_of(p);
        self._real_paths[p] = r;
        return r;
    }

    /// The library name \p dir's module.k pins, or empty. Cached per
    /// directory, hits and misses alike.
    priv fn _pin_of_dir(self, dir: string) -> vec::<string> {
        if self._dir_pins.contains(dir) { return self._dir_pins[dir]; }
        var pin = vec::<string>();
        var mod_k = Path::join_str(dir, "module.k");
        if Path::exists_at(mod_k) { pin = read_module_pin(mod_k); }
        self._dir_pins[dir] = pin;
        return pin;
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

        for var it = self._pinned_roots.begin(); it != self._pinned_roots.end(); ++it {
            if it->second != &null {
                std::destroy(it->second);
            }
        }
        self._pinned_roots.clear();

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
        var lock = std::LockGuard(self._mu);
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

        // 2. root candidates, in the order IMPORTS.md §2.1 fixes:
        //      a. the importing file's OWN root, with the path as written
        //      b. any root whose NAME is the leading segment, with the rest
        //      c. every other root with the path as written -- except that a
        //         file under a NAMED root never falls back into an unnamed
        //         search dir (the cwd, an unpinned -I): a library cannot
        //         depend on what happens to sit on one build's command line.
        var own_root: *SearchRoot = &null;
        if has_from { own_root = self.root_for_dir(from_dir); }

        var root_hit  = false;
        var root_path: Path;
        var hit_root: *SearchRoot = &null;   // the root that answered, for the search-dir check

        if own_root != &null {
            var h = self._probe_root(own_root, segments, is_module);
            if h.found {
                root_hit  = true;
                root_path = h.path;
                hit_root  = own_root;
                if !sib_hit { out.file_dir = h.file_dir; }
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
        var lib_root: *SearchRoot = &null;
        if has_from { lib_root = self._pinned_root_for(from_dir); }
        if (!root_hit) && (lib_root != &null) {
            var h = self._probe_root(lib_root, segments, is_module);
            if h.found {
                root_hit  = true;
                root_path = h.path;
                hit_root  = lib_root;
                if !sib_hit { out.file_dir = h.file_dir; }
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
            var cands = vec::<*SearchRoot>();
            for var ni: usize = 0; ni < self._roots.size(); ++ni {
                var r = self._roots[ni];
                if r->spelling.size() == 0 { continue; }
                if !root_name_matches(r->spelling, segments) { continue; }
                cands.push_back(r);
            }
            if (lib_root != &null) && root_name_matches(lib_root->spelling, segments) {
                cands.push_back(lib_root);
            }
            // Insertion sort, descending by name length. The candidate set is
            // the roots whose name prefixes ONE import path: one or two in
            // every real build.
            for var a: usize = 1; a < cands.size(); ++a {
                var c = cands[a];
                var b = a;
                while (b > 0) && (cands[b - 1]->spelling.size() < c->spelling.size()) {
                    cands[b] = cands[b - 1];
                    b -= 1;
                }
                cands[b] = c;
            }

            var ci: usize = 0;
            while (ci < cands.size()) && (!root_hit) {
                var r = cands[ci];
                ci += 1;

                var tail = vec::<string>();
                for var ti: usize = r->spelling.size(); ti < segments.size(); ++ti {
                    tail.push_back(segments[ti]);
                }

                if tail.size() == 0 {
                    var snode = r->root;
                    if snode == &null { continue; }
                    self._sweep_dir(snode);
                    var smod = snode->find_by_stem_and_category("module", FileCategory::KairoSource);
                    if (smod != &null) && (smod->file_path) {
                        root_hit  = true;
                        root_path = *(smod->file_path);
                    }
                    continue;
                }

                var h = self._probe_root(r, tail, is_module);
                if h.found {
                    root_hit  = true;
                    root_path = h.path;
                    if !sib_hit { out.file_dir = h.file_dir; }
                }
            }
        }

        // A file in a library, registered or found walking up (lib_root):
        // which library holds a file is a property of the file, so whether
        // it may reach into the command line's unnamed dirs must not depend
        // on whether this run happened to register its library.
        var from_library = ((own_root != &null) && (own_root->name.size() > 0)) || (lib_root != &null);
        var ri: usize = 0;
        while (ri < self._roots.size()) && (!root_hit) {
            var r = self._roots[ri];
            ri += 1;
            if r == own_root { continue; }                       // already tried
            if from_library && (r->name.size() == 0) { continue; } // library -> unnamed search dir
            if r->discovered { continue; }                       // a pinned library: by name only
            var h = self._probe_root(r, segments, is_module);
            if h.found {
                root_hit  = true;
                root_path = h.path;
                hit_root  = r;
                if !sib_hit { out.file_dir = h.file_dir; }
            }
        }

        // 4. Two unnamed search dirs answering one path with two files. Both
        //    are that path's module -- an unnamed dir adds no prefix -- so
        //    they would be one module identity and one C++ namespace, and
        //    the first-searched would win silently: the day `inc/a.k`
        //    appears beside `./a.k`, an `import a` elsewhere changes meaning.
        //    Same fault as rule 3, one level out, and the same error
        //    (IMPORTS.md §2.1, decision E). Every unnamed dir is probed,
        //    not just those after the winner: the importer's own dir wins
        //    the search but must not hide a twin. A library never searches
        //    unnamed dirs, and a sibling collision is already reported.
        var other_hit = false;
        var other_path: Path;
        if root_hit && (!sib_hit) && (hit_root != &null) && (hit_root->name.size() == 0) {
            var oi: usize = 0;
            while (oi < self._roots.size()) && (!other_hit) {
                var r = self._roots[oi];
                oi += 1;
                if (r == hit_root) || (r->name.size() > 0) || r->discovered { continue; }
                var h = self._probe_root(r, segments, is_module);
                if h.found && (h.path.full_path() != root_path.full_path()) {
                    other_hit  = true;
                    other_path = h.path;
                }
            }
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
            if other_hit {
                out.ambiguous  = true;
                out.cross_root = true;
                out.other_path = other_path;
            }
        }

        out.canonical = self.canonical_module_path(out.path);
        self.claim_identity(out.canonical, out.path);
        if out.canonical.size() == 0 {
            // Resolved outside every search root (rare: an absolute -I sibling
            // walk). Fall back to the written spelling rather than handing
            // codegen an empty namespace path.
            out.canonical = segments;
        }
        return out;
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
    ///          `-` maps to `_` per the filename policy (CODEGEN.md 2).
    ///
    ///          The library is found by walking UP from the file
    ///          (_library_of), past every search root if need be: a file's
    ///          module path is a property of the FILE (PLAN-module-pinning
    ///          §2.1), so `cd geometry/inner && kairo x.k` and `-I
    ///          geometry/inner` give `geo::inner::x` exactly as an importer
    ///          above the library does. Stopping at the deepest root made
    ///          those two runs emit `namespace x`, and a `kcc -c` from inside
    ///          a library defined symbols no importer calls.
    /// \return the segments, or empty if no library and no search root
    ///         holds the file.
    fn canonical_module_path(self, file: Path) -> vec::<string> {
        var lock = std::LockGuard(self._mu);
        var out = vec::<string>();

        var best_rel  = "";
        var best_name = vec::<string>();
        var lib = self._library_of(Path::parent_of(file.full_path()));
        if lib.found {
            best_name = lib.name;
            best_rel  = file.relative_to(Path::from_known(lib.dir, FileType::directory_file));
        } else {
            // No library above the file: the deepest search root holding it
            // (necessarily unnamed -- the walk stops at every named root).
            // Deepest, so a nested -I dir is not shadowed by an outer one
            // into a longer, wrong identity.
            var best_len: usize = 0;
            for var i: usize = 0; i < self._roots.size(); ++i {
                var root = self._roots[i];
                var rel  = self._relative_to(file, root->base_path);
                if rel.size() == 0 { continue; }
                var base_len = root->base_path.full_path().size();
                if (best_rel.size() == 0) || (base_len > best_len) {
                    best_rel = rel;
                    best_len = base_len;
                }
            }
        }
        if best_rel.size() == 0 { return out; }

        // The library's name is the leading SEGMENTS: `~/foo/a.k` under a
        // `~/foo/module.k` pinning `foo` is `foo::a` from EVERY importer, and
        // `Lib/std/vec.k` under the driver's `kairo::std` root is
        // `kairo::std::vec`. That is what makes a file's identity -- and
        // therefore its C++ namespace -- independent of who imported it. An
        // unnamed search dir (the cwd, an unpinned -I) contributes no prefix.
        for var bi: usize = 0; bi < best_name.size(); ++bi {
            out.push_back(self.module_ident(best_name[bi]));
        }

        var parts = self.split_path(best_rel);
        if parts.size() == 0 { return out; }

        // strip the extension off the leaf
        var leaf     = parts[parts.size() - 1];
        var dot_pos  = leaf.rfind(".");
        if dot_pos != null { leaf = leaf.subslice(0, (*dot_pos)); }
        parts[parts.size() - 1] = leaf;

        // `Foo/module.k` IS module `Foo`; the leaf names the directory entry.
        // At a library's TOP level the directory is the library itself, so
        // its NAME is already the whole path and the leaf drops there too.
        // Without the second clause `Lib/std/module.k` under `kairo::std`
        // would be `kairo::std::module`, its synthetic module_self would be
        // named `module`, and every decl in it would emit one C++ namespace
        // too deep. (Same latent bug for `Lib/builtin/module.k`, which was
        // `builtin::module`; unexercised only because the prelude folds it as
        // a wildcard and never binds its handle.)
        if (leaf == "module") && ((parts.size() > 1) || (out.size() > 0)) { parts.pop_back(); }
        // The module.k at the top of an unnamed, unpinned dir names that dir,
        // which has no name: the file has no module path (it is outside every
        // library), not the path `module`.
        if (leaf == "module") && (parts.size() == 1) && (out.size() == 0) { return out; }

        for var i: usize = 0; i < parts.size(); ++i {
            out.push_back(self.module_ident(parts[i]));
        }
        return out;
    }

    struct LibraryHit {
        var found: bool = false;
        var dir:   string;              ///< the library's directory, as walked.
        var name:  vec::<string>;       ///< its name: the root's, or the pin's.
        var root:  *SearchRoot = &null; ///< the registered root, when it is one.
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
    priv fn _library_of(self, start: string) -> LibraryHit {
        var out  = LibraryHit{};
        var walk = start;
        while walk.size() > 0 {
            for var i: usize = 0; i < self._roots.size(); ++i {
                var r = self._roots[i];
                if (r->name.size() > 0) && (r->base_path.full_path() == walk) {
                    out.found = true;
                    out.dir   = walk;
                    out.name  = r->name;
                    out.root  = r;
                    return out;
                }
            }
            var pin = self._pin_of_dir(walk);
            if pin.size() > 0 {
                self._check_pin_dir(walk, pin);
                out.found = true;
                out.dir   = walk;
                out.name  = pin;
                return out;
            }
            // Stop BEFORE an empty parent: joining "" with module.k is a
            // relative path, and the probe would read the cwd's module.k.
            var up = Path::parent_of(walk);
            if (up.size() == 0) || (up.size() >= walk.size()) { break; }
            walk = up;
        }
        return out;
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
    priv fn _check_pin_dir(self, dir: string, pin: vec::<string>) {
        var real = self._real(dir);
        // A registered library reached through another spelling (a symlink)
        // is that library, already checked when it was registered. An
        // UNNAMED root that pins -- the cwd inside a library -- is not, and
        // falls through.
        var at = self._root_at_real(real);
        if (at != &null) && (at->name.size() > 0) { return; }

        var key   = self._name_str(pin);
        var other = string();
        for var k: usize = 0; k < self._roots.size(); ++k {
            var r = self._roots[k];
            if (r->name.size() == 0) || (r->real_dir == real) { continue; }
            if root_names_equal(r->name, pin) || root_names_equal(r->spelling, pin) {
                other = r->base_path.full_path();
                break;
            }
        }
        var other_real = string();
        if other.empty() {
            if !self._lib_pins.contains(key) {
                self._lib_pins[key]     = real;
                self._lib_pin_dirs[key] = dir;
                return;
            }
            if self._lib_pins[key] == real { return; }
            other      = self._lib_pin_dirs[key];
            other_real = self._lib_pins[key];
        } else {
            other_real = self._real(other);
        }
        var pair = other_real + "\n" + real;
        if self._reported_pairs.contains(pair) { return; }
        self._reported_pairs.insert(pair);
        var c = RootNameCollision{};
        c.name   = key;
        c.a      = other;
        c.b      = dir;
        c.pinned = true;
        self._late_collisions.push_back(c.message());
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
    fn claim_identity(self, ident: vec::<string>, file: Path) {
        var lock = std::LockGuard(self._mu);
        if ident.size() == 0 { return; }
        var key  = self._name_str(ident);
        var real = self._real(file.full_path());
        if !self._identities.contains(key) {
            self._identities[key]     = real;
            self._identity_files[key] = file.full_path();
            return;
        }
        var first = self._identities[key];
        if first == real { return; }
        var pair = first + "\n" + real;
        if self._reported_pairs.contains(pair) { return; }
        self._reported_pairs.insert(pair);
        var c = ModuleIdentityCollision{};
        c.ident = key;
        c.a     = self._identity_files[key];
        c.b     = file.full_path();
        self._late_collisions.push_back(c.message());
    }

    /// \brief drains the R018E findings made after build_index (a pinned
    ///        directory found walking up, two files on one module path), as
    ///        messages in the order found, for whoever owns a DiagEngine: the
    ///        PP walk after each resolution, the driver after claiming its
    ///        inputs.
    fn take_late_collisions(self) -> vec::<string> {
        var lock = std::LockGuard(self._mu);
        var out = self._late_collisions;
        self._late_collisions.clear();
        return out;
    }

    /// The transient root over the pinned library holding \p dir, when no
    /// registered root covers that library; null otherwise (no library, or
    /// a registered one, which root_for_dir already answers).
    priv fn _pinned_root_for(self, dir: Path) -> *SearchRoot {
        var lib = self._library_of(dir.full_path());
        if (!lib.found) || (lib.root != &null) { return &null; }
        if self._pinned_roots.contains(lib.dir) { return self._pinned_roots[lib.dir]; }
        var r = std::create::<SearchRoot>(Path::from_known(lib.dir, FileType::directory_file),
                                          u32(-1), self._ext_cfg, lib.name, lib.name);
        r->discovered = true;
        self._pinned_roots[lib.dir] = r;
        return r;
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
    fn input_module_path(self, file: Path) -> vec::<string> {
        var lock = std::LockGuard(self._mu);
        var segs = self.canonical_module_path(file);
        if segs.size() == 0 { return segs; }
        for var i: usize = 0; i < self._roots.size(); ++i {
            var r = self._roots[i];
            if r->name.size() == 0 { continue; }
            if !(self._relative_to(file, r->base_path).empty()) { continue; }   // its own library
            if self._segs_start_with(segs, r->name) || self._segs_start_with(segs, r->spelling) {
                return vec::<string>();
            }
        }
        return segs;
    }

    priv fn _segs_start_with(self, segs: ref!(vec::<string>), head: ref!(vec::<string>)) -> bool {
        if (head.size() == 0) || (head.size() > segs.size()) { return false; }
        for var i: usize = 0; i < head.size(); ++i {
            if segs[i] != head[i] { return false; }
        }
        return true;
    }

    /// \brief drains module-name collisions found during discovery.
    ///
    /// \details Discovery runs first in the DepScanner, which has no
    ///          DiagEngine, so findings are queued here and drained by the PP
    ///          walk (FileImportIndex), which does. Each directory is swept
    ///          exactly once, so every collision is reported exactly once no
    ///          matter how many imports pass through it.
    fn take_collisions(self) -> vec::<ModuleNameCollision> {
        var lock = std::LockGuard(self._mu);
        var out = self._collisions;
        self._collisions.clear();
        return out;
    }

    /// \brief drains duplicate-root-name findings from build_index.
    ///
    /// \details Fatal, and reported BEFORE anything is parsed: a module path
    ///          under a duplicated root name means two different files.
    fn take_root_collisions(self) -> vec::<RootNameCollision> {
        var lock = std::LockGuard(self._mu);
        var out = self._root_collisions;
        self._root_collisions.clear();
        return out;
    }

    /// \brief the deepest registered root that contains \p dir, or null.
    ///
    /// \details "The importing file's own root": what its unqualified imports
    ///          resolve against first, and the root whose name prefixes its
    ///          own module path (IMPORTS.md §2.1).
    fn root_for_dir(self, dir: Path) -> *SearchRoot {
        var lock = std::LockGuard(self._mu);
        var best: *SearchRoot = &null;
        var best_len: usize = 0;
        for var i: usize = 0; i < self._roots.size(); ++i {
            var r = self._roots[i];
            if self._relative_to(dir, r->base_path).size() == 0 {
                // _relative_to returns empty for "not under"; the root dir
                // itself is handled by the full-path equality below.
                if dir.full_path() != r->base_path.full_path() { continue; }
            }
            var len = r->base_path.full_path().size();
            if (best == &null) || (len > best_len) { best = r; best_len = len; }
        }
        return best;
    }

    /// \brief the module identity a filename claims: `-` folded to `_`.
    ///
    /// \details `foo-bar.k` names module `foo_bar` (CODEGEN.md 2): module path
    ///          segments must be valid identifiers, and `-` is the one
    ///          pragmatic exception rather than an escaping scheme that would
    ///          leak into mangled names forever.
    fn module_ident(self, name: string) -> string {
        var out = name;
        for var i: usize = 0; i < out.size(); ++i {
            if out[i] == '-' { out[i] = '_'; }
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
        return self._root_at_real(self._real(dir.full_path())) != &null;
    }

    /// `file` relative to `base`, or "" when `file` is not under `base`.
    priv fn _relative_to(self, file: Path, base: Path) -> string {
        return file.relative_to(base);
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
        for var i: usize = 0; i < out.size(); ++i {
            if (out[i] >= 'A') && (out[i] <= 'Z') {
                out[i] = static_cast::<char>(out[i] + 32);
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
            stem = last.subslice(0, (*dot_pos));
            ext  = last.subslice((*dot_pos) + 1, last.size());
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
                for child: *DirEntry in node->sorted_children() {
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

        var candidate = Path::join_str(from_file.parent_path(), rel_path);

        if Path::exists_at(candidate) {
            return (
                Path(candidate, false)
            );
        }

        for root: *SearchRoot in self._roots {
            candidate = root->base_path.join(rel_path);

            if Path::exists_at(candidate) {
                return (
                    Path(candidate, false)
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
            var candidate = root->base_path.join(rel_path);

            if Path::exists_at(candidate) {
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

        for child: *DirEntry in node->sorted_children() {
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

        var old        = self._roots[index];
        var path       = old->base_path;
        var priority   = old->priority;
        // Everything a root IS, copied BEFORE the destroy. Dropping the name
        // demoted a named root to an unnamed search dir and changed every
        // module path under it; dropping the spelling made std reachable
        // only as `kairo::std`; dropping `discovered` made a pinned
        // library's files importable unqualified (the last-resort probe).
        var name       = old->name;
        var spelling   = old->spelling;
        var discovered = old->discovered;

        std::destroy(old);
        var fresh = std::create::<SearchRoot>(path, priority, self._ext_cfg, name, spelling);
        fresh->discovered = discovered;
        self._roots[index] = fresh;

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
            result += f"  [{root->priority}] {root->name_str()} -> {root->base_path.full_path()}\n";
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

    /// A root name spelled back for a diagnostic. Mirrors SearchRoot::name_str
    /// but takes the raw segments, which is what the collision record has.
    priv fn _name_str(self, segs: vec::<string>) -> string {
        if segs.size() == 0 { return "<entry>"; }
        var out = string();
        for var i: usize = 0; i < segs.size(); ++i {
            if i > 0 { out += "::"; }
            out += segs[i];
        }
        return out;
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
            result += f"\n[Root {i}] priority={root->priority} name={root->name_str()} path={root->base_path.full_path()}\n";
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

        for child: *DirEntry in node->sorted_children() {
            result += self.dump_node(child, depth + 1);
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
    var tmp          = Path::temp_dir();
    var test_root    = tmp.join("hlx_import_test");
    var include_root = tmp.join("hlx_include_test");

    // clean up if exists from previous run
    Path::remove_tree(test_root);
    Path::remove_tree(include_root);

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

    Path::make_dirs(Path::join_str(test_root, "std/mem"));
    Path::make_dirs(Path::join_str(test_root, "cpp"));
    Path::make_dirs(Path::join_str(test_root, "Assets"));
    Path::make_dirs(include_root);

    // create dummy files
    var files_to_create = vec::<string>();

    // kairo files
    files_to_create.emplace_back(Path::join_str(test_root, "std/io.k"));
    files_to_create.emplace_back(Path::join_str(test_root, "std/net.k"));
    files_to_create.emplace_back(Path::join_str(test_root, "std/mem/module.k"));
    files_to_create.emplace_back(Path::join_str(test_root, "std/mem/alloc.k"));
    files_to_create.emplace_back(Path::join_str(test_root, "mylib.hlib"));
    files_to_create.emplace_back(Path::join_str(test_root, "util.k"));

    // c++ files
    files_to_create.emplace_back(Path::join_str(test_root, "cpp/helper.hpp"));
    files_to_create.emplace_back(Path::join_str(test_root, "cpp/helper.cpp"));
    files_to_create.emplace_back(Path::join_str(test_root, "cpp/legacy.h"));

    // random files (json, txt, no extension)
    files_to_create.emplace_back(Path::join_str(test_root, "Assets/config.json"));
    files_to_create.emplace_back(Path::join_str(test_root, "Assets/data.txt"));
    files_to_create.emplace_back(Path::join_str(test_root, "Assets/README"));
    files_to_create.emplace_back(Path::join_str(test_root, "Makefile"));

    // include path files
    files_to_create.emplace_back(Path::join_str(include_root, "util.k"));
    files_to_create.emplace_back(Path::join_str(include_root, "extra.k"));

    for p: string in files_to_create {
        Path::write_file(p, "");
    }

    var test_path = Path(test_root, false);
    var include_path = Path(include_root, false);
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
        Path::remove_tree(test_root);
        Path::remove_tree(include_root);
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
        var from_file = Path(Path::join_str(test_root, "std/io.k"), false);

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
            if p.view().find(r"hlx_import_test") != string::npos {
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
        var new_file = Path::join_str(test_root, "newmodule.k");
        Path::write_file(new_file, "");

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

        Path::remove_file(new_file);
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
