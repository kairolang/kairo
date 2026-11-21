/// --- The Kairo Project ------------------------ Resolution/DirEntry.k --- ///
///
///   DirEntry: a lazily scanned directory tree node for import lookup.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/STLExtras.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "llvm/Support/FileSystem.h"
ffi "c++" import "llvm/Support/Path.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "system_error"
ffi "c++" import "vector"
ffi "c++" import "utility"

import Resolution::FileExtensions::{
    FileCategory,
    FileExtensions,
}
import Support::FileIO::FileSystem::FileType
import Support::FileIO::Path::Path

pub class DirEntry {
    pub var name:      string
    pub var children:  llvm::StringMap<unsafe *DirEntry> ///< values are owned pointers: a rehash moves no DirEntry. Walked only via sorted_children (or to free).
    pub var file_path: Path?
    pub var ext:       string
    pub var category:  FileCategory
    pub var is_dir:    bool
    pub var fs_path:   Path? ///< this dir's own fs path; dirs only
    pub var ext_cfg:   unsafe *FileExtensions ///< non-owning; propagated from SearchRoot
    pub var scanned:   bool ///< full readdir done (enumeration path only)

    /// Sets `fs_path` to a copy of `p`. The assignment is spelled here, in
    /// this file's unit: written through a `DirEntry` pointer in another
    /// unit, the `Path?` conversion does not compile on a move-only Path.
    fn set_fs_path(self, const p: Path) {
        self.fs_path = p.copy()
    }

    fn DirEntry(self, name: string, is_dir: bool = true) {
        self.name      = name.copy()
        self.children  = llvm::StringMap<unsafe *DirEntry>()
        self.file_path = null
        self.ext       = ""
        self.category  = FileCategory::Ignored
        self.is_dir    = is_dir
        self.fs_path   = null
        self.ext_cfg   = &null
        self.scanned   = false
    }

    fn DirEntry(self, name: string, path: Path, ext: string, category: FileCategory) {
        self.name      = name.copy()
        self.children  = llvm::StringMap<unsafe *DirEntry>()
        self.file_path = path
        self.ext       = ext.copy()
        self.category  = category
        self.is_dir    = false
        self.fs_path   = null
        self.ext_cfg   = &null
        self.scanned   = false
    }

    fn op finally (self) {
        for *entry in self.children {
            if entry->second != &null {
                @destroy unsafe (entry->second as *DirEntry)
            }
        }

        self.children.clear()
    }


    /// Probe for a subdirectory named `name`. One stat. Memoized.
    fn probe_child_dir(self, name: string) -> unsafe *DirEntry {
        if self.children.contains(kairo::sref(name)) {
            var unsafe *c = self.children[kairo::sref(name)]
            return if c->is_dir => c else => &null
        }

        if !self.fs_path? {
            return &null
        }

        var found            = false
        var child_path: Path
        var cand             = unwrap!(self.fs_path).join(name)
        if llvm::sys::fs::is_directory(llvm::Twine(kairo::sref(cand))) {
            found      = true
            child_path = Path::from_known(cand, FileType::directory_file)
        }

        if !found {
            return &null
        }

        var unsafe *child = unsafe (@create DirEntry(name.copy(), true) as unsafe *DirEntry)
        child->fs_path                   = child_path
        child->ext_cfg                   = self.ext_cfg
        self.children[kairo::sref(name)] = child
        return child
    }

    /// Probe for a file with given stem+ext (ext without leading dot). One stat. Memoized.
    fn probe_file(self, stem: string, ext: string) -> unsafe *DirEntry {
        var key = stem.copy()
        if ext.size() > 0 {
            key = stem.copy() + "." + ext
        }

        if self.children.contains(kairo::sref(key)) {
            var unsafe *c = self.children[kairo::sref(key)]
            return if (!c->is_dir) => c else => &null
        }

        if !self.fs_path? {
            return &null
        }

        var fname           = key.copy()
        var found           = false
        var full_path: Path
        var cand            = unwrap!(self.fs_path).join(fname)
        if llvm::sys::fs::is_regular_file(llvm::Twine(kairo::sref(cand))) {
            found     = true
            full_path = Path::from_known(cand, FileType::regular_file)
        }

        if !found {
            return &null
        }

        var category = self.ext_cfg->categorize(ext)
        var unsafe *child = unsafe (@create DirEntry(
            stem,
            full_path,
            ext,
            category,
        ) as unsafe *DirEntry)

        child->ext_cfg                  = self.ext_cfg
        self.children[kairo::sref(key)] = child
        return child
    }

    /// Full one-level readdir, for module discovery (the collision sweep and
    /// the pinned-library scan). Memoized via `scanned`. The only path that
    /// reads a whole directory: keep it off hot lookups.
    fn ensure_scanned(self) {
        if self.scanned || !self.is_dir {
            return
        }

        self.scanned = true
        if !self.fs_path? {
            return
        }

        // The type comes off the readdir record (Path::type_of_entry), and each
        // child Path is built from it (from_known): one syscall per directory,
        // not two stats per entry. A missing directory just ends the loop.
        var self_path                      = unwrap!(self.fs_path).path_data.copy()
        var ec:       cxx::std::error_code
        var it = llvm::sys::fs::directory_iterator(
            llvm::Twine(kairo::sref(self_path)),
            &ec,
            true,
        )

        var end = llvm::sys::fs::directory_iterator()
        for ; ec.value() == 0 && it != end; it.increment(&ec) {
            var fname = llvm::sys::path::filename(llvm::StringRef(it->path()))
            if fname.starts_with(kairo::sref(r".")) {
                continue
            }

            var name_raw = string::from_bytes_unchecked(
                unsafe ((fname.data() as unsafe *const u8) as *const u8),
                fname.size(),
            )

            var full_raw = Path::join_str(self_path, name_raw.copy())
            var etype    = Path::type_of_entry(*it)

            if etype == FileType::directory_file {
                if self.children.find(kairo::sref(name_raw)) == self.children.end() {
                    var unsafe *c = unsafe (@create DirEntry(
                        name_raw.copy(),
                        true,
                    ) as unsafe *DirEntry)

                    c->fs_path = Path::from_known(full_raw, etype)
                    c->ext_cfg                           = self.ext_cfg
                    self.children[kairo::sref(name_raw)] = c
                }
            } else if etype == FileType::regular_file {
                // No dot: an extensionless file (a built binary beside the
                // sources) has an empty extension, and drop_front(1) on it asserts.
                var ext_ref = llvm::sys::path::extension(fname)
                if !ext_ref.empty() {
                    ext_ref = ext_ref.drop_front(1)
                }

                var ext = string::from_bytes_unchecked(
                    unsafe ((ext_ref.data() as unsafe *const u8) as *const u8),
                    ext_ref.size(),
                )

                if self.ext_cfg->should_index(ext) {
                    var stem_ref = llvm::sys::path::stem(fname)
                    var stem = string::from_bytes_unchecked(
                        unsafe ((stem_ref.data() as unsafe *const u8) as *const u8),
                        stem_ref.size(),
                    )

                    var full = Path::from_known(full_raw, etype)
                    var cat  = self.ext_cfg->categorize(ext)
                    var key  = stem.copy()
                    if !ext.is_empty() {
                        key = stem.copy() + "." + ext
                    }

                    if self.children.find(kairo::sref(key)) == self.children.end() {
                        var unsafe *c = unsafe (@create DirEntry(
                            stem,
                            full,
                            ext,
                            cat,
                        ) as unsafe *DirEntry)

                        c->ext_cfg                      = self.ext_cfg
                        self.children[kairo::sref(key)] = c
                    }
                }
            }
        }
    }

    fn find_dir(self, const name: string) -> unsafe *DirEntry {
        return self.probe_child_dir(name.copy())
    }

    fn find_by_stem_and_category(self, const stem: string, cat: FileCategory) -> unsafe *DirEntry {
        if cat == FileCategory::KairoSource {
            var unsafe *k = self.probe_file(stem.copy(), "k")
            if k != &null && k->category == cat {
                return k
            }

            return &null
        }

        self.ensure_scanned()
        for child in self.sorted_children() {
            if !child->is_dir && child->name == stem && child->category == cat {
                return child
            }
        }

        return &null
    }

    /// the children, sorted by name.
    ///
    /// Every walk over children goes through this. The map's own
    /// order is hash order, and the entries came from readdir, whose
    /// order differs between filesystems (ext4, APFS, NTFS): any
    /// "first match" or collected list taken straight off the map
    /// was platform-dependent. Name is the one order every host
    /// agrees on. Names are the map's keys, so they never tie.
    fn sorted_children(self) -> [unsafe *DirEntry] {
        // Views of the map's own key bytes: stable while the map is not
        // written, which nothing here does.
        var keyed: cxx::std::vector<cxx::std::pair<llvm::StringRef, unsafe *DirEntry>>
        keyed.reserve(self.children.size())
        for var it = self.children.begin(); it != self.children.end(); ++it {
            keyed.push_back(
                cxx::std::pair<llvm::StringRef, unsafe *DirEntry>(
                    it->getKey(),
                    it->second,
                ),
            )
        }

        llvm::sort(keyed.begin(), keyed.end())
        var out: [unsafe *DirEntry]
        out.reserve(keyed.size())
        for var i: usize = 0; i < keyed.size(); ++i {
            out.push(keyed[i].second)
        }

        return out
    }
}
