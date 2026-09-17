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
    /// carries (IMPORTS.md §2.1). `-I ~/foo` registers a root named `foo`, so
    /// `~/foo/a.k` is `foo::a` from every importer. Empty for the ENTRY root,
    /// the one and only unnamed root and therefore the only one whose files
    /// are importable with a bare first segment.
    ///
    /// Multi-segment because a root's name is a module PATH, not an
    /// identifier: Kairo's own standard library registers under `kairo::std`
    /// so that `Lib/std/vec.k` is `kairo::std::vec` and bare `std` can be a
    /// prelude alias rather than a root name anyone could collide with.
    pub var name: vec::<string>;

    fn SearchRoot(self, path: Path, priority: u32, ext_cfg: *FileExtensions,
                  name: vec::<string> = vec::<string>()) {
        self.base_path     = path;
        self.priority      = priority;
        self.name          = name;
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

    /// The name as written, for dumps and diagnostics. `<entry>` for the
    /// unnamed entry root, so a reader never sees a blank column.
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
/// segments. One home for the split so `-I name=path`, the driver's own
/// registrations and any future caller agree on what a dotted name means.
/// An empty or all-separator name yields an empty vec -- the entry root.
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
/// name (the entry root) is a prefix of everything, so callers that must not
/// match it check `name.size() > 0` first.
fn root_name_matches(name: vec::<string>, segments: vec::<string>) -> bool {
    if name.size() > segments.size() { return false; }
    for var i: usize = 0; i < name.size(); ++i {
        if name[i] != segments[i] { return false; }
    }
    return true;
}
