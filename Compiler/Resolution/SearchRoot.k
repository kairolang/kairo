/// --- The Kairo Project ---------------------- Resolution/SearchRoot.k --- ///
///
///   SearchRoot: one import root, with its module name and directory index.
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

import Memory::MappedFileBuffer::MappedFileBuffer
import Resolution::DirEntry::DirEntry
import Resolution::FileExtensions::FileExtensions
import Support::FileIO::Path::Path
import Threading::ThreadPool::ThreadPool

pub class SearchRoot {
    pub var base_path: Path
    pub var ext_cfg:   unsafe *FileExtensions
    pub var root:      unsafe *DirEntry
    pub var priority:  u32

    /// The root's MODULE name: the leading SEGMENTS every module under it
    /// carries (Compiler/Spec/Imports.md#path-resolution). `-I ~/foo` over a `~/foo/module.k` pinning
    /// `module foo` is a root named `foo`, so `~/foo/a.k` is `foo::a` from
    /// every importer. Empty for an unnamed
    /// search dir (the cwd, an unpinned -I): its files are importable by
    /// their bare path under it, with no prefix.
    ///
    /// Multi-segment because a root's name is a module PATH, not an
    /// identifier: Kairo's own standard library registers under `kairo::std`
    /// so that `Lib/std/vec.k` is `kairo::std::vec` and emits into
    /// `::kairo::std`, which can never collide with C++'s own `std`.
    pub var name: cxx::std::vector<string>

    /// The leading segments an IMPORT writes to reach this root. Equal to
    /// `name` unless the root registered a shorter spelling: the std root is
    /// NAMED `kairo::std` (its identity and namespace) but SPELLED `std`, so
    /// source writes `import std::io` and still gets `kairo::std::io`.
    /// resolve_module_rel matches on this; canonical_module_path never reads
    /// it, which is what keeps the emitted namespace independent of it.
    pub var spelling: cxx::std::vector<string>

    /// A library named by its pinned module.k (`module foo`): found in an
    /// immediate subdirectory of another root, or an -I dir whose own
    /// module.k pins it -- anything but the driver's explicitly named roots
    /// (builtin, kairo::std). Reached by its NAME only: resolve_module_rel's
    /// last-resort probe of every root with the path as written skips it, so
    /// a pinned library never makes its files importable unqualified from
    /// the whole build.
    pub var discovered: bool = false

    /// `base_path` with its symlinks resolved, for asking whether two roots
    /// are ONE directory: a vendored `b/geolink -> a/geometry` and an `-I
    /// a/geometry` must be one library, not an R018E between two spellings
    /// of it. Never printed; diagnostics quote base_path, what was typed.
    pub var real_dir: string

    fn SearchRoot(self,
                  const path: Path,
                  priority:   u32,
                  ext_cfg:    unsafe *FileExtensions,
                  name:       cxx::std::vector<string> = cxx::std::vector<string>(),
                  spelling:   cxx::std::vector<string> = cxx::std::vector<string>()) {
        self.base_path     = path
        self.real_dir      = Path::real_path_of(path.full_path())
        self.priority      = priority
        self.name          = name
        self.spelling      = if (spelling.size() > 0) => (spelling) else => name
        self.ext_cfg       = ext_cfg
        self.root          = kairo::std::create<DirEntry>(path.filename(), true)
        self.root->fs_path = path
        self.root->ext_cfg = ext_cfg
    }

    /// \deprecated Does nothing: the tree is scanned lazily.
    fn build_index(self, pool: *ThreadPool? = &null) {
        // Lazy: nothing to walk. Root is stamped at construction; children are
        // materialised on demand via DirEntry::probe_* / ensure_scanned.
        // `pool` retained only for signature compatibility.
    }

    // Move-only: the destructor destroys `root`, so a copy would destroy it
    // twice. The source is left with no root.
    @move fn SearchRoot(self, other: Self) {
        self.base_path  = other.base_path
        self.ext_cfg    = other.ext_cfg
        self.root       = other.root
        self.priority   = other.priority
        self.name       = cxx::std::move(other.name)
        self.spelling   = cxx::std::move(other.spelling)
        self.discovered = other.discovered
        self.real_dir   = cxx::std::move(other.real_dir)
        other.root      = &null
    }

    fn op finally (self) {
        if self.root != &null {
            kairo::std::destroy(self.root)
        }
    }

    /// The name as written, for dumps and diagnostics. `<entry>` for an
    /// unnamed search dir (the cwd, an unpinned -I), so a reader never sees a
    /// blank column.
    fn name_str(self) -> string {
        if self.name.size() == 0 {
            return "<entry>"
        }

        var out = string()
        for var i: usize = 0; i < self.name.size(); ++i {
            if i > 0 {
                out += "::"
            }

            out += self.name[i]
        }

        return out
    }

    fn traverse(self, const segments: cxx::std::vector<string>) -> unsafe *DirEntry {
        var unsafe *current = self.root
        for i in (0 as usize)..segments.size() {
            var seg     = segments[i]
            var is_last = i == segments.size() - 1
            if is_last {
                var unsafe *child = current->find_dir(seg)
                if child != &null {
                    return child
                }

                return current->find_by_stem(seg)
            } else {
                current = current->find_dir(seg)
                if current == &null {
                    return &null
                }
            }
        }

        return current
    }
}

/// Split a root name written as a module path (`kairo::std`) into its
/// segments. One home for the split so a module.k pin, the driver's own
/// registrations and any future caller agree on what a dotted name means.
/// An empty or all-separator name yields an empty vec -- an unnamed search dir.
pub fn split_module_name(const name: string) -> cxx::std::vector<string> {
    var out     = cxx::std::vector<string>()
    var current = string()

    var i: usize = 0
    while i < name.size() {
        if i + 1 < name.size() && name[i] == (':' as u8) && name[i + 1] == (':' as u8) {
            if current.size() > 0 {
                out.push_back(current)
                current = string()
            }

            i += 2
            continue
        }

        current.push_back(name[i])
        i += 1
    }

    if current.size() > 0 {
        out.push_back(current)
    }

    return out
}

/// The MODULE ROOT of a file in directory \p dir: the nearest directory at
/// or above it that holds a `module.k` (pinned or not), or "" when none
/// does. One walk for both of its readers, so `import module::x` resolves
/// from exactly the directory whose files share `prot` (AST/VisibilityFacts.k):
/// a module is one thing to the import and to the access check. Walked on
/// the real path, so a symlinked tree and its target agree, and bounded by
/// the filesystem root.
pub fn module_dir_at_or_above(const dir: string) -> string {
    if dir.empty() || dir.starts_with("<") {
        return ""
    }

    var cur = Path::real_path_of(dir)
    while cur.size() > 0 {
        if Path::exists_at(Path::join_str(cur, "module.k")) {
            return cur
        }

        // Stop BEFORE an empty parent: joining "" with module.k is a
        // relative path, and the probe would read the cwd's module.k.
        var up = Path::parent_of(cur)
        if up.size() == 0 || up.size() >= cur.size() {
            break
        }

        cur = up
    }

    return ""
}

/// Two roots claiming ONE name is a build error (Compiler/Spec/Imports.md#path-resolution); two roots
/// where one name is a PREFIX of the other is not, because longest-first
/// matching in resolve_module_rel decides between them unambiguously.
pub fn root_names_equal(const a: cxx::std::vector<string>,
                        const b: cxx::std::vector<string>) -> bool {
    if a.size() != b.size() {
        return false
    }

    for var i: usize = 0; i < a.size(); ++i {
        if a[i] != b[i] {
            return false
        }
    }

    return true
}

/// True when \p name is a leading-segment prefix of \p segments. The empty
/// name (an unnamed search dir) is a prefix of everything, so callers that must not
/// match it check `name.size() > 0` first.
pub fn root_name_matches(const name:     cxx::std::vector<string>,
                         const segments: cxx::std::vector<string>) -> bool {
    if name.size() > segments.size() {
        return false
    }

    for var i: usize = 0; i < name.size(); ++i {
        if name[i] != segments[i] {
            return false
        }
    }

    return true
}

/// Reads the pin of a module.k: the path of its bare `module a::b` declaration
/// when that is the file's FIRST declaration, else nothing.
///
/// A byte scan, not a lex: the resolver decides library names at index time,
/// before there is a SourceManager fid for the file, and it may look at a
/// module.k in every immediate subdirectory of every search root, so the cost
/// has to be one map and a few bytes, never a tokenization. It agrees with
/// the parser's `_is_module_pin` on what a pin is: comments are trivia, the
/// path is `ident (:: ident)*`, and it ends at `;`, EOF or a newline that is
/// not followed by `{` (`module foo` NEWLINE `{` is the block form).
pub class ModulePinScanner {
    pub var d: kairo::std::ConstPtr<u8> = &null
    pub var n: usize                    = 0
    pub var i: usize                    = 0

    fn at(self, k: usize) -> u8 {
        return if (k < self.n) => (self.d[k]) else => (0)
    }

    /// Spaces, tabs, `//` to end of line and NESTED `/* */` (the lexer nests
    /// them); newlines too when \p nl is set.
    fn skip(self, nl: bool) {
        while self.i < self.n {
            var c = self.at(self.i)
            if c == (' ' as u8) || c == ('\t' as u8) || c == ('\r' as u8) {
                self.i += 1
                continue
            }

            if c == ('\n' as u8) && nl {
                self.i += 1
                continue
            }

            if c == ('/' as u8) && self.at(self.i + 1) == ('/' as u8) {
                while self.i < self.n && self.at(self.i) != ('\n' as u8) {
                    self.i += 1
                }

                continue
            }

            if c == ('/' as u8) && self.at(self.i + 1) == ('*' as u8) {
                var depth: usize = 1
                self.i += 2
                while self.i < self.n && depth > 0 {
                    if self.at(self.i) == ('*' as u8) && self.at(self.i + 1) == ('/' as u8) {
                        depth -= 1
                        self.i += 2
                        continue
                    }

                    if self.at(self.i) == ('/' as u8) && self.at(self.i + 1) == ('*' as u8) {
                        depth += 1
                        self.i += 2
                        continue
                    }

                    self.i += 1
                }

                continue
            }

            return
        }
    }

    fn is_ident_char(self, c: u8, first: bool) -> bool {
        if c >= ('a' as u8) && c <= ('z' as u8)
            || c >= ('A' as u8) && c <= ('Z' as u8)
            || c == ('_' as u8) {
            return true
        }

        if first {
            return false
        }

        return c >= ('0' as u8) && c <= ('9' as u8)
    }

    /// The identifier at the cursor, consumed, or "" with the cursor unmoved.
    fn ident(self) -> string {
        var out = string()
        if !self.is_ident_char(self.at(self.i), true) {
            return out
        }

        while self.i < self.n && self.is_ident_char(self.at(self.i), false) {
            out.push_back((self.at(self.i)))
            self.i += 1
        }

        return out
    }

    fn scan(self) -> cxx::std::vector<string> {
        var none = cxx::std::vector<string>()
        // A UTF-8 BOM is not a declaration.
        if self.at(0) == 0xEF && self.at(1) == 0xBB && self.at(2) == 0xBF {
            self.i = 3
        }

        self.skip(true)
        if self.ident() != "module" {
            return none
        }

        var segs = cxx::std::vector<string>()
        while true {
            self.skip(false)
            var seg = self.ident()
            if seg.size() == 0 {
                return none
            }

            segs.push_back(seg)
            self.skip(false)
            if self.at(self.i) == (':' as u8) && self.at(self.i + 1) == (':' as u8) {
                self.i += 2
                continue
            }

            break
        }

        if self.i >= self.n {
            return segs
        }

        var c = self.at(self.i)
        if c == (';' as u8) {
            return segs
        }

        if c != ('\n' as u8) {
            return none
        }

        self.skip(true)
        if self.i < self.n && self.at(self.i) == ('{' as u8) {
            return none
        }

        return segs
    }
}

pub fn read_module_pin(file: string) -> cxx::std::vector<string> {
    var buf = MappedFileBuffer()
    buf.load(unsafe &file)
    if !buf.is_valid() {
        return cxx::std::vector<string>()
    }

    var mem = buf.bytes()
    var sc  = ModulePinScanner{}
    sc.d = mem.data()
    sc.n = mem.size()
    return sc.scan()
}
