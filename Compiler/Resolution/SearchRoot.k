/// --- The Kairo Project ---------------------- Resolution/SearchRoot.k --- ///
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

import Support::FileIO::Path::*;
import Support::FileIO::FileSystem::*;
import Memory::MappedFileBuffer::*;

import Resolution::FileExtensions::*;
import Resolution::DirEntry::*;
import Threading::ThreadPool::*;

class SearchRoot {
    pub var base_path: Path;
    pub var ext_cfg:   obs::<FileExtensions>;
    pub var root:      own::<DirEntry>;
    pub var priority:  u32;

    /// The root's MODULE name: the leading SEGMENTS every module under it
    /// carries (IMPORTS.md §2.1). `-I ~/foo` over a `~/foo/module.k` pinning
    /// `module foo` is a root named `foo`, so `~/foo/a.k` is `foo::a` from
    /// every importer. Empty for an unnamed
    /// search dir (the cwd, an unpinned -I): its files are importable by
    /// their bare path under it, with no prefix.
    ///
    /// Multi-segment because a root's name is a module PATH, not an
    /// identifier: Kairo's own standard library registers under `kairo::std`
    /// so that `Lib/std/vec.k` is `kairo::std::vec` and emits into
    /// `::kairo::std`, which can never collide with C++'s own `std`.
    pub var name: vec::<string>;

    /// The leading segments an IMPORT writes to reach this root. Equal to
    /// `name` unless the root registered a shorter spelling: the std root is
    /// NAMED `kairo::std` (its identity and namespace) but SPELLED `std`, so
    /// source writes `import std::io` and still gets `kairo::std::io`.
    /// resolve_module_rel matches on this; canonical_module_path never reads
    /// it, which is what keeps the emitted namespace independent of it.
    pub var spelling: vec::<string>;

    /// A library named by its pinned module.k (`module foo`): found in an
    /// immediate subdirectory of another root, or an -I dir whose own
    /// module.k pins it -- anything but the driver's explicitly named roots
    /// (builtin, kairo::std). Reached by its NAME only: resolve_module_rel's
    /// last-resort probe of every root with the path as written skips it, so
    /// a pinned library never makes its files importable unqualified from
    /// the whole build.
    pub var discovered: bool = false;

    fn SearchRoot(self, path: Path, priority: u32, ext_cfg: *FileExtensions,
                  name: vec::<string> = vec::<string>(),
                  spelling: vec::<string> = vec::<string>()) {
        self.base_path     = path;
        self.priority      = priority;
        self.name          = name;
        self.spelling      = (spelling) if (spelling.size() > 0) else (name);
        self.ext_cfg       = ext_cfg;
        self.root          = std::create::<DirEntry>(path.filename(), true);
        self.root->fs_path = path;
        self.root->ext_cfg = ext_cfg;
    }

    /// \deprecated Do not use this function.
    fn build_index(self, pool: *ThreadPool = &null) {
        // Lazy: nothing to walk. Root is stamped at construction; children are
        // materialised on demand via DirEntry::probe_* / ensure_scanned.
        // `pool` retained only for signature compatibility.

        // DEPRECATED NO-OP: This function is no longer used
    }

    fn op delete (self) {
        if self.root != &null {
            std::destroy(self.root);
        }
    }

    /// The name as written, for dumps and diagnostics. `<entry>` for an
    /// unnamed search dir (the cwd, an unpinned -I), so a reader never sees a
    /// blank column.
    fn name_str(self) -> string {
        if self.name.size() == 0 { return "<entry>"; }
        var out = string();
        for var i: usize = 0; i < self.name.size(); ++i {
            if i > 0 { out += "::"; }
            out += self.name[i];
        }
        return out;
    }

    fn traverse(self, segments: vec::<string>) -> *DirEntry {
        var current = self.root;
        for i in range::<usize>(0, segments.size()) {
            var seg     = segments[i];
            var is_last = (i == segments.size() - 1);
            if is_last {
                var child = current->find_dir(seg);
                if child != &null { return child; }
                return current->find_by_stem(seg);
            } else {
                current = current->find_dir(seg);
                if current == &null { return &null; }
            }
        }
        return current;
    }
}

/// Split a root name written as a module path (`kairo::std`) into its
/// segments. One home for the split so a module.k pin, the driver's own
/// registrations and any future caller agree on what a dotted name means.
/// An empty or all-separator name yields an empty vec -- an unnamed search dir.
fn split_module_name(name: string) -> vec::<string> {
    var out     = vec::<string>();
    var current = string();

    var i: usize = 0;
    while i < name.size() {
        if ((i + 1) < name.size()) && (name[i] == ':') && (name[i + 1] == ':') {
            if current.size() > 0 { out.push_back(current); current = string(); }
            i += 2;
            continue;
        }
        current += name[i];
        i += 1;
    }
    if current.size() > 0 { out.push_back(current); }
    return out;
}

/// Two roots claiming ONE name is a build error (IMPORTS.md §2.1); two roots
/// where one name is a PREFIX of the other is not, because longest-first
/// matching in resolve_module_rel decides between them unambiguously.
fn root_names_equal(a: vec::<string>, b: vec::<string>) -> bool {
    if a.size() != b.size() { return false; }
    for var i: usize = 0; i < a.size(); ++i {
        if a[i] != b[i] { return false; }
    }
    return true;
}

/// True when \p name is a leading-segment prefix of \p segments. The empty
/// name (an unnamed search dir) is a prefix of everything, so callers that must not
/// match it check `name.size() > 0` first.
fn root_name_matches(name: vec::<string>, segments: vec::<string>) -> bool {
    if name.size() > segments.size() { return false; }
    for var i: usize = 0; i < name.size(); ++i {
        if name[i] != segments[i] { return false; }
    }
    return true;
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
class ModulePinScanner {
    pub var d: std::ConstPtr::<u8> = &null;
    pub var n: usize = 0;
    pub var i: usize = 0;

    fn at(self, k: usize) -> u8 {
        return (self.d[k]) if (k < self.n) else (0 as u8);
    }

    /// Spaces, tabs, `//` to end of line and NESTED `/* */` (the lexer nests
    /// them); newlines too when \p nl is set.
    fn skip(self, nl: bool) {
        while self.i < self.n {
            var c = self.at(self.i);
            if (c == ' ') || (c == '\t') || (c == '\r') { self.i += 1; continue; }
            if (c == '\n') && nl { self.i += 1; continue; }
            if (c == '/') && (self.at(self.i + 1) == '/') {
                while (self.i < self.n) && (self.at(self.i) != '\n') { self.i += 1; }
                continue;
            }
            if (c == '/') && (self.at(self.i + 1) == '*') {
                var depth: usize = 1;
                self.i += 2;
                while (self.i < self.n) && (depth > 0) {
                    if (self.at(self.i) == '*') && (self.at(self.i + 1) == '/') { depth -= 1; self.i += 2; continue; }
                    if (self.at(self.i) == '/') && (self.at(self.i + 1) == '*') { depth += 1; self.i += 2; continue; }
                    self.i += 1;
                }
                continue;
            }
            return;
        }
    }

    fn is_ident_char(self, c: u8, first: bool) -> bool {
        if ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || (c == '_') { return true; }
        if first { return false; }
        return (c >= '0') && (c <= '9');
    }

    /// The identifier at the cursor, consumed, or "" with the cursor unmoved.
    fn ident(self) -> string {
        var out = string();
        if !self.is_ident_char(self.at(self.i), true) { return out; }
        while (self.i < self.n) && self.is_ident_char(self.at(self.i), false) {
            out += static_cast::<char>(self.at(self.i));
            self.i += 1;
        }
        return out;
    }

    fn scan(self) -> vec::<string> {
        var none = vec::<string>();
        // A UTF-8 BOM is not a declaration.
        if (self.at(0) == 0xEF) && (self.at(1) == 0xBB) && (self.at(2) == 0xBF) { self.i = 3; }

        self.skip(true);
        if self.ident() != "module" { return none; }

        var segs = vec::<string>();
        while true {
            self.skip(false);
            var seg = self.ident();
            if seg.size() == 0 { return none; }
            segs.push_back(seg);
            self.skip(false);
            if (self.at(self.i) == ':') && (self.at(self.i + 1) == ':') {
                self.i += 2;
                continue;
            }
            break;
        }

        if self.i >= self.n { return segs; }
        var c = self.at(self.i);
        if c == ';' { return segs; }
        if c != '\n' { return none; }
        self.skip(true);
        if (self.i < self.n) && (self.at(self.i) == '{') { return none; }
        return segs;
    }
}

fn read_module_pin(file: string) -> vec::<string> {
    var buf = MappedFileBuffer{};
    buf.load(&file);
    if !buf.is_valid() { return vec::<string>(); }
    var mem = buf.bytes();
    var sc  = ModulePinScanner{};
    sc.d = mem.data();
    sc.n = mem.size();
    return sc.scan();
}
