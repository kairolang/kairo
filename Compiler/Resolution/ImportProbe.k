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
/// module resolution for the kairo compiler frontend
///
/// Maps qualified import paths (e.g. `Include::FileSystem`) to files through
/// a priority-ordered list of search roots. Each root's directory tree is
/// probed lazily: one stat per segment looked up, and a full readdir only of
/// the directories module discovery sweeps (DirEntry::ensure_scanned).
/// The entry points that read or write the resolver's lazy state take its
/// lock, so the preprocessor may resolve from several threads at once.
///
/// -----------------------------------------------------------------------------

// FIXME(permission-denied): DirEntry::ensure_scanned ends a directory's scan
//      at the first error, and DirEntry::probe_* treat an unreadable entry as
//      absent, so an import into an unreadable directory reports "not found".
//      A denied directory should be recorded so the import site can say the
//      directory exists but cannot be read.

ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/Log.hh"
ffi "c++" import "vector"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "llvm/ADT/StringSet.h"
ffi "c++" import "set"
ffi "c++" import "algorithm"
ffi "c++" import "string"

import Location::SourceManager::SourceManager
import Resolution::DirEntry::DirEntry
import Resolution::FileExtensions::{
    FileCategory,
    FileExtensions,
}
import Resolution::SearchRoot::{
    SearchRoot,
    read_module_pin_in,
    root_name_matches,
    root_names_equal,
    split_module_name,
}
import Support::Ascii::{
    copy_strings,
    rfind_byte,
}
import Support::FileIO::FileSystem::FileType
import Support::FileIO::Path::Path
import Threading::ThreadPool::ThreadPool

/// which candidate set produced a module resolution.
pub enum ModuleOrigin derives u8 {
    Root = 0, ///< found by walking the search roots (cwd + -m/-I dirs).
    Sibling,  ///< found in one directory: `self::`/`module::`'s anchor, or a
    ///  plain import's migration fallback (resolve_module_in).
}

/// the result of a relative-aware module resolution.
///
/// `canonical` is the module's IDENTITY: the path segments from the
/// owning search root down to the file, NOT the segments the import
/// spelled. Two files never share a canonical path, and one file
/// always has exactly one, no matter how it was reached. Codegen
/// derives the C++ namespace path from this (Compiler/Spec/Codegen.md#pipeline: the
/// bijection module-path <-> namespace-path is what makes mangling
/// deterministic and ODR-safe), so it must never depend on the
/// importer's spelling.
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

/// two files in one directory claiming a single module identity.
///
/// Same class of fault as an ambiguous import, one layer down: the
/// module name is derived from the filename, so `Foo.k`/`foo.k` (two
/// files on Linux, ONE on default macOS/Windows) and `foo-bar.k`/
/// `foo_bar.k` (both spell module `foo_bar`) are non-portable or
/// outright ambiguous. Discovered during module discovery, once per
/// directory; reported by the caller that owns a DiagEngine.
pub class ModuleNameCollision {
    pub var dir:       string         ///< absolute directory that holds both.
    pub var a:         string         ///< first name, sorted order.
    pub var b:         string         ///< second name.
    pub var ident:     string         ///< the module identity they both claim.
    pub var case_only: bool   = false ///< true: differ only by case (portability).
}

/// two search roots registered under one module name.
///
/// A root's name is the leading segment of every module under it, so
/// two roots sharing one name make a module path mean two files.
/// A build error, reported before anything is parsed; never
/// first-wins, never a merge (Compiler/Spec/Imports.md#path-resolution).
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

/// two different files that one module path names.
///
/// A module path is a file's identity and its C++ namespace
/// (ModuleResolution::canonical), so it must name ONE file. Two can
/// still land on one path without any root sharing a name: a pin
/// below a root's immediate subdirectories that claims a
/// registered library's name, two inputs reached through two
/// search dirs, two pins naming one library from different places.
/// Each pair is recorded once, at the first resolution (or input)
/// that makes it visible; Compiler/Spec/Imports.md#path-resolution, decision E.
pub class ModuleIdentityCollision {
    pub var ident: string ///< the module path, `::`-joined.
    pub var a:     string ///< the file that claimed it first.
    pub var b:     string ///< the other file.

    fn message(self) -> string {
        return f"'{self.a}' and '{self.b}' are both module '{self.ident}'; a module path names one file, and these two would share one C++ namespace and one object file: rename or move one, or make one part of a library with a pinned module.k"
    }
}

/// resolves qualified module paths and file names against a set of
/// indexed search roots
///
/// the resolver is constructed via the nested `Builder` class, which
/// registers the search roots synchronously; their trees are probed lazily.
///
/// ownership semantics: the search roots and the `FileExtensions` config
/// are heap-allocated and owned by this resolver.
///
/// **Note:** the resolver uses raw pointers (`*T`) rather than managed handles.
/// ensure the resolver outlives any references to returned paths.
pub class ImportResolver {
    priv var _roots:   [unsafe *SearchRoot]   ///< priority-sorted search roots (index 0 = cwd)
    priv var _ext_cfg: unsafe *FileExtensions ///< file extension classification config; owned

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

    /// The source manager that holds a language server's unsaved buffers, or
    /// null: a module.k's pin is read from its buffer there, not from the
    /// disk (SearchRoot.k read_module_pin_in).
    priv var _sm: unsafe *SourceManager = &null

    /// Every module.k whose pin was read (the file's name, as probed): what
    /// a tool that re-checks after an edit must treat as a dependency of the
    /// result, since a changed pin renames a library.
    priv var _pin_files: cxx::std::vector<string>

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

    /// One `-I`-style search directory as the Builder recorded it.
    struct IncludeDir {
        var path:     Path
        var name:     cxx::std::vector<string> ///< explicit root name; empty = the dir's pin, else unnamed.
        var spelling: cxx::std::vector<string> ///< what an import writes; empty = the name.
    }

    /// fluent builder for constructing an `ImportResolver`
    ///
    /// usage:
    ///
    /// ### Example
    /// ```kairo
    /// var resolver = ImportResolver::Builder()
    ///     .cwd(my_cwd)
    ///     ->add_include(some_path)
    ///     ->create_ptr()
    /// ```
    pub class Builder {
        priv var _cwd:      Path?
        priv var _includes: [ImportResolver::IncludeDir]
        priv var _sm:       unsafe *SourceManager        = &null

        /// default constructor; initializes all fields to null/empty
        pub fn Builder(self) {
            self._cwd = null
        }

        /// sets the current working directory as the highest-priority search root
        ///
        /// ### Parameters
        /// - `path`: the directory to use as cwd
        ///
        /// ### Returns
        /// pointer to self for chaining
        pub fn cwd(self, const path: Path) -> unsafe *Self {
            self._cwd = path.copy()
            return unsafe &self
        }

        /// names the source manager whose unsaved buffers a module.k's pin
        /// is read from before the disk
        pub fn sm(self, sm: unsafe *SourceManager) -> unsafe *Self {
            self._sm = sm
            return unsafe &self
        }

        /// appends a single include path to the search list
        ///
        /// ### Parameters
        /// - `path`: the directory to add
        ///
        /// ### Returns
        /// pointer to self for chaining
        ///
        /// ### Parameters
        /// - `name`: the root's MODULE name -- the leading SEGMENTS every
        ///   module under it carries (Compiler/Spec/Imports.md#path-resolution), written as a
        ///   module path (`kairo::std`). Empty means "whatever
        ///   the directory's module.k pins, else an unnamed search
        ///   dir" -- what every `-I dir` is. Only the driver's own
        ///   registrations (builtin, kairo::std) pass a name.
        ///
        /// ### Parameters
        /// - `spelling`: what an import writes to reach the root, when it
        ///   differs from the name (SearchRoot::spelling). Empty
        ///   means "the name".
        ///
        /// The `::` split happens HERE and nowhere else, so the driver's own
        /// registrations and any future caller agree on what a dotted name
        /// means.
        pub fn add_include(self,
                           const path:     Path,
                           const name:     string = "",
                           const spelling: string = "") -> unsafe *Self {
            // Empty stays empty: build_index tells an EXPLICIT name from
            // none by it, because only a nameless dir takes its pinned
            // module.k's name.
            var inc = ImportResolver::IncludeDir{}
            inc.path     = path.copy()
            inc.name     = split_module_name(name)
            inc.spelling = split_module_name(spelling)
            self._includes.push(inc)
            return unsafe &self
        }

        /// constructs the resolver and registers its search roots, on
        /// the calling thread
        ///
        /// ### Parameters
        /// - `pool`: unused: the roots' trees are probed lazily, on first
        ///   lookup, so there is nothing to hand a worker
        ///
        /// ### Returns
        /// heap-allocated resolver; caller assumes ownership
        pub fn create_ptr(self, pool: unsafe *ThreadPool = &null) -> unsafe *ImportResolver {
            var cwd_path = Path::cwd()
            if self._cwd? {
                cwd_path = unwrap!(self._cwd).copy()
            }

            var unsafe *resolver = unsafe (@create ImportResolver() as unsafe *ImportResolver)
            resolver->_sm = self._sm
            resolver->build_index(cwd_path, self._includes)
            return resolver
        }
    }

    /// direct constructor; prefer using `Builder` instead
    fn ImportResolver(self) {
        self._ext_cfg = unsafe (@create FileExtensions() as unsafe *FileExtensions)
    }

    /// registers the search roots
    ///
    /// ### Parameters
    /// - `cwd`: the current working directory (priority 0)
    /// - `includes`: additional include directories (priority 1+)
    fn build_index(self, cwd: Path, const includes: [Self::IncludeDir]) {
        kairo::Logger::info(
            kairo::Logger::Stage::Preprocessor,
            f"ImportResolver::build_index: cwd='{cwd.full_path()}' roots={includes.size() + 1}",
        )

        // Build the root list. Cheap: path checks only. SearchRoot's constructor
        // stamps each root's fs_path and ext_cfg so it can probe lazily on first
        // access; there is no eager directory walk here anymore.
        if cwd.exists() && cwd.is_directory() {
            var unsafe *root = unsafe (@create SearchRoot(
                cwd,
                0,
                self._ext_cfg,
            ) as unsafe *SearchRoot)

            self._roots.push(root)
        }

        var priority: u32 = 1
        for var i: usize = 0; i < includes.size(); ++i {
            var *p = &includes[i].path
            if !p->exists() || !p->is_directory() {
                continue
            }

            var nm = copy_strings(includes[i].name)
            var sp = copy_strings(includes[i].spelling)
            if sp.size() == 0 {
                sp = copy_strings(nm)
            }

            // An explicit name (the driver's builtin and kairo::std; the CLI
            // has no way to give one) is checked against the directory's own
            // pin. The registration wins -- the prelude and the lang items
            // address builtin by it, and std's spelling `std` is not
            // expressible as a pin at all -- so a pin saying something else
            // would be a second, silently ignored name.
            if nm.size() > 0 {
                var own_pin = self._pin_of_dir(p->full_path())
                if own_pin.size() > 0 && !root_names_equal(own_pin, nm) {
                    var c = RootNameCollision{}
                    c.mismatch = true
                    c.name     = self._name_str(nm)
                    c.pin      = self._name_str(own_pin)
                    c.a        = p->full_path()
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
            var unsafe *prior = self._root_at_real(self._real(p->full_path()))
            if prior != &null {
                if nm.size() > 0 {
                    self._check_root_name(*p, nm, sp, false, prior)
                    prior->name       = copy_strings(nm)
                    prior->spelling   = copy_strings(sp)
                    prior->discovered = false
                }

                continue
            }

            // No explicit name: the directory's own pin names it, or it
            // stays an UNNAMED search dir, as the cwd is -- never its
            // basename, which made every `-I .../include` the same root.
            var pinned = false
            if nm.size() == 0 {
                nm     = self._pin_of_dir(p->full_path())
                pinned = nm.size() > 0
                sp     = copy_strings(nm)
            }

            var unsafe *r = self._add_root(*p, priority, nm, sp, pinned)
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
            for child in dir->sorted_children() {
                if child == &null || !child->is_dir || !child->fs_path? {
                    continue
                }

                var cpath = unwrap!(child->fs_path).copy()
                // A directory already registered keeps the registration: the
                // driver's `Lib/std` is an explicit root AND a subdirectory of
                // `Lib`, and must not collide with itself.
                if self._is_root_dir(cpath) {
                    continue
                }

                if child->find_by_stem_and_category(
                    "module",
                    FileCategory::KairoSource,
                ) == &null {
                    continue
                }

                var pin = self._pin_of_dir(cpath.full_path())
                if pin.size() == 0 {
                    continue
                }

                var unsafe *lib = self._add_root(
                    cpath,
                    priority,
                    pin,
                    pin,
                    true,
                )

                lib->discovered = true
                priority += 1
            }
        }

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
                      const p:  Path,
                      priority: u32,
                      const nm: cxx::std::vector<string>,
                      const sp: cxx::std::vector<string>,
                      pinned:   bool) -> unsafe *SearchRoot {
        self._check_root_name(p, nm, sp, pinned, &null)
        var unsafe *root = unsafe (@create SearchRoot(
            p.copy(),
            priority,
            self._ext_cfg,
            copy_strings(nm),
            copy_strings(sp),
        ) as unsafe *SearchRoot)

        self._roots.push(root)
        return root
    }

    /// The R018E half of _add_root, also run when an explicit registration
    /// renames an existing root in place. `skip` is that root itself.
    priv fn _check_root_name(self,
                             const p:  Path,
                             const nm: cxx::std::vector<string>,
                             const sp: cxx::std::vector<string>,
                             pinned:   bool,
                             skip:     unsafe *SearchRoot) {
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

    /// The registered root over the directory whose real path is `real`,
    /// or null.
    priv fn _root_at_real(self, const real: string) -> unsafe *SearchRoot {
        for var i: usize = 0; i < self._roots.size(); ++i {
            if self._roots[i]->real_dir == real {
                return self._roots[i]
            }
        }

        return &null
    }

    /// `p` with its symlinks resolved, cached per spelling.
    priv fn _real(self, const p: string) -> string {
        if self._real_paths.contains(kairo::sref(p)) {
            return self._real_paths[kairo::sref(p)].copy()
        }

        var r = Path::real_path_of(p.copy())
        self._real_paths[kairo::sref(p)] = r.copy()
        return r
    }

    /// The library name `dir`'s module.k pins, or empty. Cached per
    /// directory, hits and misses alike.
    priv fn _pin_of_dir(self, const dir: string) -> cxx::std::vector<string> {
        if self._dir_pins.contains(kairo::sref(dir)) {
            return copy_strings(self._dir_pins[kairo::sref(dir)])
        }

        var pin   = cxx::std::vector<string>()
        var mod_k = Path::join_str(dir, "module.k")
        if Path::exists_at(mod_k) {
            pin = read_module_pin_in(self._sm, mod_k.copy())
            self._pin_files.push_back(mod_k.copy())
        }

        self._dir_pins[kairo::sref(dir)] = copy_strings(pin)
        return pin
    }

    /// destructor; frees the owned search roots and the extension config
    fn op finally (self) {
        for root in self._roots {
            if root != &null {
                @destroy unsafe (root as *SearchRoot)
            }
        }

        self._roots.clear()

        for var it = self._sibling_roots.begin(); it != self._sibling_roots.end(); ++it {
            if it->second != &null {
                @destroy unsafe (it->second as *SearchRoot)
            }
        }

        self._sibling_roots.clear()

        for var it = self._pinned_roots.begin(); it != self._pinned_roots.end(); ++it {
            if it->second != &null {
                @destroy unsafe (it->second as *SearchRoot)
            }
        }

        self._pinned_roots.clear()

        if self._ext_cfg != &null {
            @destroy unsafe (self._ext_cfg as *FileExtensions)
        }
    }

    //  Module resolution (THE home of import path semantics)
    //
    //  Each import form looks in exactly one place
    //  (Compiler/Spec/Imports.md#path-resolution):
    //    `import baz`          the search roots, here (resolve_module_rel);
    //    `import self::baz`    the importing file's directory,
    //    `import module::baz`  its module root -- both resolve_module_in.
    //
    //  The plain form never tries the importing file's directory first.
    //  Sibling-first is Python 2's implicit relative import, which Python
    //  removed because adding `root/baz.k` silently changed what `import baz`
    //  meant three directories away; a collision error would keep that from
    //  being silent but still let a new root file break a build far from it.
    //  Spelling the place in the import removes the question instead.
    //
    //  Module IDENTITY never comes from the spelling - see canonical_module_path.

    /// resolves a PLAIN module path against the search roots.
    ///
    /// ### Parameters
    /// - `segments`: the path as written (e.g. ["baz"] or ["util","fmt"])
    /// - `from_dir`: the IMPORTING file's directory
    /// - `has_from`: false when there is no importing file (entry point)
    ///
    /// ### Returns
    /// a resolution carrying the file and its canonical identity.
    /// The importing file's own directory is NOT a place this form
    /// looks; the callers' migration fallback probes it separately
    /// (resolve_module_in), after every root has missed every prefix.
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
                root_path = h.path.copy()
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
                root_path = h.path.copy()
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
            var cands: [unsafe *SearchRoot]
            for var ni: usize = 0; ni < self._roots.size(); ++ni {
                var unsafe *r = self._roots[ni]
                if r->spelling.size() == 0 {
                    continue
                }

                if !root_name_matches(r->spelling, segments) {
                    continue
                }

                cands.push(r)
            }

            if lib_root != &null && root_name_matches(lib_root->spelling, segments) {
                cands.push(lib_root)
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
                    tail.push_back(segments[ti].copy())
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
                        root_path = unwrap!(smod->file_path).copy()
                    }

                    continue
                }

                var h = self._probe_root(r, tail)
                if h.found {
                    root_hit  = true
                    root_path = h.path.copy()
                    self._take_file_dir(&out, h)
                }
            }
        }

        // A file in a library, registered or found walking up (lib_root):
        // which library holds a file is a property of the file, so whether
        // it may reach into the command line's unnamed dirs must not depend
        // on whether this run happened to register its library.
        var from_library = own_root != &null && own_root->name.size() > 0 || lib_root != &null
        var ri: usize = 0
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
                root_path = h.path.copy()
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

    /// resolves a module path in ONE directory: `import self::x`
    /// (the importing file's directory) or `import module::x` (its
    /// module root). No search root is consulted, so no root file can
    /// change what the import means.
    ///
    /// ### Parameters
    /// - `segments`: the path as written after the anchor
    /// - `dir`: the anchor directory
    pub fn resolve_module_in(self,
                             const segments: cxx::std::vector<string>,
                             const dir:      Path) -> ModuleResolution {
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
        out.path   = h.path.copy()
        out.origin = ModuleOrigin::Sibling
        self._take_file_dir(&out, h)
        return self._finish(out, segments)
    }

    /// The winning probe's `foo.k`-and-`foo/module.k` finding, onto `out`.
    priv fn _take_file_dir(self, out: *ModuleResolution, const h: Self::RootHit) {
        out->file_dir = h.file_dir
        if h.file_dir {
            out->dir_path = h.dir_path.copy()
        }
    }

    /// Identity for a found resolution; shared by both entry points so a
    /// file reached through `self::` and through a root is one module.
    priv fn _finish(self,
                    out:            ModuleResolution,
                    const segments: cxx::std::vector<string>) -> ModuleResolution {
        var res = out
        res.canonical = self.canonical_module_path(res.path)
        self.claim_identity(res.canonical, res.path)
        if res.canonical.size() == 0 {
            // Resolved outside every search root (rare: an absolute -I sibling
            // walk). Fall back to the written spelling rather than handing
            // codegen an empty namespace path.
            res.canonical = copy_strings(segments)
        }

        return res
    }

    /// the module IDENTITY of a file: its path below the library
    /// that holds it, prefixed by that library's name; or, under no
    /// library, its path relative to the deepest search root that
    /// contains it.
    ///
    /// This, not the import spelling, is what a file's module path
    /// means. `root/Foo/baz.k` is `Foo::baz` whether it was reached as
    /// `import Foo::baz` from the root or `import baz` from its
    /// sibling. `root/std/mem/module.k` is `std::mem` - the `module`
    /// leaf names the directory's entry point, not a segment.
    /// `-` maps to `_` per the filename policy (Compiler/Spec/Codegen.md#sinks).
    ///
    ///          The library is found by walking UP from the file
    ///          (_library_of), past every search root if need be: a file's
    ///          module path is a property of the FILE (Compiler/Spec/Imports.md#module-pinning), so `cd geometry/inner && kairo x.k` and `-I
    ///          geometry/inner` give `geo::inner::x` exactly as an importer
    ///          above the library does. Stopping at the deepest root made
    ///          those two runs emit `namespace x`, and a `kcc -c` from inside
    ///          a library defined symbols no importer calls.
    ///
    /// ### Returns
    /// the segments, or empty if no library and no search root
    /// holds the file.
    fn canonical_module_path(self, const file: Path) -> cxx::std::vector<string> {
        var lock = kairo::std::LockGuard(self._mu)
        var out  = cxx::std::vector<string>()

        var best_rel  = ""
        var best_name = cxx::std::vector<string>()
        var lib       = self._library_of(Path::parent_of(file.full_path()))
        if lib.found {
            best_name = lib.name
            best_rel = file.relative_to(
                Path::from_known(lib.dir, FileType::directory_file),
            )
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
                    best_rel = rel.copy()
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
        var leaf    = parts[parts.size() - 1].copy()
        var dot_pos = rfind_byte(leaf, ('.' as u8))
        if dot_pos != leaf.size() {
            leaf = leaf.subslice(0, dot_pos)
        }

        parts[parts.size() - 1] = leaf.copy()

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
            parts.pop()
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

    /// the library holding directory `start`: the nearest directory
    /// at or above it that is a NAMED root, or whose module.k pins a
    /// name.
    ///
    /// A named root is asked before the pin at the same level: the
    /// driver's registration of std and builtin outranks their own
    /// module.k (build_index checks the two agree). Bounded by the
    /// filesystem root and never downward: one stat per directory
    /// walked, cached in _dir_pins, so every file of a build shares
    /// the walk of its ancestors.
    priv fn _library_of(self, const start: string) -> Self::LibraryHit {
        var out  = Self::LibraryHit{}
        var walk = start.copy()
        while walk.size() > 0 {
            for var i: usize = 0; i < self._roots.size(); ++i {
                var unsafe *r = self._roots[i]
                if r->name.size() > 0 && r->base_path.full_path() == walk {
                    out.found = true
                    out.dir   = walk.copy()
                    out.name  = copy_strings(r->name)
                    out.root  = r
                    return out
                }
            }

            var pin = self._pin_of_dir(walk)
            if pin.size() > 0 {
                self._check_pin_dir(walk, pin)
                out.found = true
                out.dir   = walk.copy()
                out.name  = pin
                return out
            }

            // Stop BEFORE an empty parent: joining "" with module.k is a
            // relative path, and the probe would read the cwd's module.k.
            var up = Path::parent_of(walk)
            if up.size() == 0 || up.size() >= walk.size() {
                break
            }

            walk = up.copy()
        }

        return out
    }

    /// `file` lies in a library: under a named root (builtin, std, a
    /// pinned -I dir), or below a module.k that pins a name.
    pub fn in_library(self, const file: Path) -> bool {
        var lock = kairo::std::LockGuard(self._mu)
        return self._library_of(Path::parent_of(file.full_path())).found
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
    priv fn _check_pin_dir(self, const dir: string, const pin: cxx::std::vector<string>) {
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
        if other.is_empty() {
            if !self._lib_pins.contains(kairo::sref(key)) {
                self._lib_pins[kairo::sref(key)]     = real.copy()
                self._lib_pin_dirs[kairo::sref(key)] = dir.copy()
                return
            }

            if self._lib_pins[kairo::sref(key)] == real {
                return
            }

            other      = self._lib_pin_dirs[kairo::sref(key)].copy()
            other_real = self._lib_pins[kairo::sref(key)].copy()
        } else {
            other_real = self._real(other)
        }

        var pair = other_real + "\n" + real
        if self._reported_pairs.contains(kairo::sref(pair)) {
            return
        }

        self._reported_pairs.insert(kairo::sref(pair))
        var c = RootNameCollision{}
        c.name   = key.copy()
        c.a      = other.copy()
        c.b      = dir.copy()
        c.pinned = true
        self._late_collisions.push_back(c.message())
    }

    /// records that `file` holds module path `ident`; a different
    /// file already holding it is a ModuleIdentityCollision.
    ///
    /// Called for every resolution and, by the driver, for every
    /// input before any is compiled, so two inputs that one path
    /// names (`./a.k` and `inc/a.k` under `-I inc`) are rejected
    /// before either writes the object path they share. Files are
    /// compared by real path: one file through a symlink is still
    /// one module.
    pub fn claim_identity(self, const ident: cxx::std::vector<string>, const file: Path) {
        var lock = kairo::std::LockGuard(self._mu)
        if ident.size() == 0 {
            return
        }

        var key  = self._name_str(ident)
        var real = self._real(file.full_path())
        if !self._identities.contains(kairo::sref(key)) {
            self._identities[kairo::sref(key)]     = real.copy()
            self._identity_files[kairo::sref(key)] = file.full_path()
            return
        }

        var first = self._identities[kairo::sref(key)].copy()
        if first == real {
            return
        }

        var pair = first + "\n" + real
        if self._reported_pairs.contains(kairo::sref(pair)) {
            return
        }

        self._reported_pairs.insert(kairo::sref(pair))
        var c = ModuleIdentityCollision{}
        c.ident = key.copy()
        c.a     = self._identity_files[kairo::sref(key)].copy()
        c.b     = file.full_path()
        self._late_collisions.push_back(c.message())
    }

    /// drains the R018E findings made after build_index (a pinned
    /// directory found walking up, two files on one module path), as
    /// messages in the order found, for whoever owns a DiagEngine: the
    /// PP walk after each resolution, the driver after claiming its
    /// inputs.
    pub fn take_late_collisions(self) -> cxx::std::vector<string> {
        var lock = kairo::std::LockGuard(self._mu)
        var out  = cxx::std::move(self._late_collisions)
        self._late_collisions = cxx::std::vector<string>()
        return out
    }

    /// The transient root over the pinned library holding `dir`, when no
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

        var unsafe *r = unsafe (@create SearchRoot(
            Path::from_known(lib.dir, FileType::directory_file),
            u32::MAX,
            self._ext_cfg,
            copy_strings(lib.name),
            copy_strings(lib.name),
        ) as unsafe *SearchRoot)

        r->discovered                            = true
        self._pinned_roots[kairo::sref(lib.dir)] = r
        return r
    }

    /// the module path a COMMAND-LINE input (or a .k a C++ input
    /// includes) takes: its canonical_module_path, the one an import
    /// of it gets, or empty for a file with none.
    ///
    /// Empty, too, when the path under an unnamed search dir starts
    /// with a NAMED root's name or spelling and the file is not in
    /// that root: `./builtin.k` would be module `builtin`, the
    /// builtin library's own path. An import of that path reaches
    /// the library, never this file, so the file is not the module
    /// there; taking the path would put two modules in one C++
    /// namespace (and the driver reads a leading `builtin` as the
    /// prelude). Such a file stays pathless, as one outside every
    /// root does (Speller::is_entry_tu).
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

            if !self._relative_to(file, r->base_path).is_empty() { // its own library
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

    /// drains module-name collisions found during discovery.
    ///
    /// Discovery runs first in the DepScanner, which has no
    /// DiagEngine, so findings are queued here and drained by the PP
    /// walk (FileImportIndex), which does. Each directory is swept
    /// exactly once, so every collision is reported exactly once no
    /// matter how many imports pass through it.
    pub fn take_collisions(self) -> cxx::std::vector<ModuleNameCollision> {
        var lock = kairo::std::LockGuard(self._mu)
        var out  = cxx::std::move(self._collisions)
        self._collisions = cxx::std::vector<ModuleNameCollision>()
        return out
    }

    /// The module.k files whose pins this resolver has read.
    pub fn pin_files(self) -> cxx::std::vector<string> {
        var lock = kairo::std::LockGuard(self._mu)
        return self._pin_files
    }

    /// Whether `path` is a module.k whose pin this resolver has read, by
    /// either spelling of it (as probed, or its real path).
    pub fn reads_pin_of(self, const path: string) -> bool {
        var lock = kairo::std::LockGuard(self._mu)
        var real = self._real(path)
        for var i: usize = 0; i < self._pin_files.size(); ++i {
            if self._pin_files[i] == path || self._real(self._pin_files[i]) == real {
                return true
            }
        }

        return false
    }

    /// drains duplicate-root-name findings from build_index.
    ///
    /// Fatal, and reported BEFORE anything is parsed: a module path
    /// under a duplicated root name means two different files.
    pub fn take_root_collisions(self) -> cxx::std::vector<RootNameCollision> {
        var lock = kairo::std::LockGuard(self._mu)
        var out  = cxx::std::move(self._root_collisions)
        self._root_collisions = cxx::std::vector<RootNameCollision>()
        return out
    }

    /// every search root's directory, in priority order: where
    /// incremental Sema (Driver/ModuleRecords.k) watches for a module
    /// file that would change a resolution with no source edited.
    pub fn root_dirs(self) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        for r in self._roots {
            if r != &null {
                out.push_back(r->base_path.full_path())
            }
        }

        return out
    }

    /// the deepest registered root that contains `dir`, or null.
    ///
    /// "The importing file's own root": what its unqualified imports
    /// resolve against first, and the root whose name prefixes its
    /// own module path (Compiler/Spec/Imports.md#path-resolution).
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

    /// the module identity a filename claims: `-` folded to `_`.
    ///
    /// `foo-bar.k` names module `foo_bar` (Compiler/Spec/Codegen.md#sinks): module path
    /// segments must be valid identifiers, and `-` is the one
    /// pragmatic exception rather than an escaping scheme that would
    /// leak into mangled names forever.
    fn module_ident(self, const name: string) -> string {
        var out        = string()
        var run: usize = 0
        for var i: usize = 0; i < name.size(); ++i {
            if name.data()[i] == ('-' as u8) {
                out += name[run..i]
                out += "_"
                run = i + 1
            }
        }

        out += name[run..]
        return out
    }

    /// # relative resolution internals

    struct RootHit {
        var found:    bool = false
        var path:     Path
        var file_dir: bool = false ///< `leaf.k` AND `leaf/module.k` both matched
        var dir_path: Path         ///< the `leaf/module.k`, iff file_dir
    }

    /// One root, one probe, so every place is resolved by identical rules:
    /// `foo.k`, else `foo/module.k`; both present is reported (`file_dir`),
    /// the file still answering so the import does not cascade into "not
    /// found".
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

        var last = segments[segments.size() - 1].copy()
        self._sweep_dir(node)

        var        mod_node: unsafe *DirEntry = &null
        var unsafe *dir_node                  = node->find_dir(last)
        if dir_node != &null {
            mod_node = dir_node->find_by_stem_and_category(
                "module",
                FileCategory::KairoSource,
            )

            if mod_node != &null && !mod_node->file_path? {
                mod_node = &null
            }
        }

        var unsafe *file_node = node->find_by_stem_and_category(
            last,
            FileCategory::KairoSource,
        )

        if file_node != &null && file_node->file_path? {
            out.found = true
            out.path     = unwrap!(file_node->file_path).copy()
            out.file_dir = mod_node != &null
            if out.file_dir {
                out.dir_path = unwrap!(mod_node->file_path).copy()
            }

            return out
        }

        if mod_node != &null {
            out.found = true
            out.path  = unwrap!(mod_node->file_path).copy()
        }

        return out
    }

    /// Get-or-create the transient SearchRoot for an importing file's dir.
    priv fn _sibling_root_for(self, const dir: Path) -> unsafe *SearchRoot {
        var key = dir.full_path()
        if self._sibling_roots.contains(kairo::sref(key)) {
            return self._sibling_roots[kairo::sref(key)]
        }

        if !dir.exists() || !dir.is_directory() {
            return &null
        }

        // priority u32(-1): never competes with a real root, and is only ever
        // reached through resolve_module_rel.
        var unsafe *r = unsafe (@create SearchRoot(
            dir.copy(),
            u32::MAX,
            self._ext_cfg,
        ) as unsafe *SearchRoot)

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
        var names: [string]
        var dirs            = llvm::StringMap<bool>() // name -> a directory claims it
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

            names.push(child->name.copy())
            if child->is_dir {
                dirs[kairo::sref(child->name)] = true
            }
        }

        names.sort()

        var seen = llvm::StringMap<string>() // identity -> first claimant; probed only
        for var i: usize = 0; i < names.size(); ++i {
            var raw   = names[i].copy()
            var ident = self._lower(self.module_ident(raw))
            var ins   = seen.try_emplace(kairo::sref(ident), raw.copy())
            if ins.second {
                continue
            }

            var other = ins.first->second.copy()
            if other == raw { // a dir and its own module.k, etc.
                continue
            }

            // A directory and a file whose names differ only by case
            // (`Output/` beside `output.k`) are two entries on every
            // filesystem, a case-insensitive one included, and two C++
            // namespaces: the pair is the directory-and-its-file shape
            // above, cased apart. Only two of one kind are one entry on
            // macOS/Windows, which is what P002E says.
            var other_dir = dirs.contains(kairo::sref(other))
            var raw_dir   = dirs.contains(kairo::sref(raw))
            if other_dir != raw_dir && self._lower(other) == self._lower(raw) {
                continue
            }

            var c = ModuleNameCollision{}
            c.dir       = key.copy()
            c.a         = other.copy()
            c.b         = raw.copy()
            c.ident     = self.module_ident(other)
            c.case_only = self._lower(other) == self._lower(raw)
            self._collisions.push_back(c)
        }
    }

    priv fn _lower(self, const s: string) -> string {
        var out        = string()
        var run: usize = 0
        for var i: usize = 0; i < s.size(); ++i {
            var b = s.data()[i]
            if b >= ('A' as u8) && b <= ('Z' as u8) {
                out += s[run..i]
                out.push(b + 32) // ASCII letter
                run = i + 1
            }
        }

        out += s[run..]

        return out
    }

    /// A root name spelled back for a diagnostic, `<entry>` for an unnamed
    /// search dir.
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

    priv fn split_path(self, const path: string) -> [string] {
        var result: [string]
        var current          = string()

        var run: usize = 0
        for i in (0 as usize)..path.size() {
            var c = path.data()[i]

            if c == ('/' as u8) || c == ('\\' as u8) {
                current += path[run..i]
                if current.size() > 0 {
                    result.push(current.copy())
                    current = string()
                }

                run = i + 1
            }
        }

        current += path[run..]

        if current.size() > 0 {
            result.push(current.copy())
        }

        return result
    }
}
