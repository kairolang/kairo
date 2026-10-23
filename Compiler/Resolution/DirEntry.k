/// --- The Kairo Project ------------------------ Resolution/DirEntry.k --- ///
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

ffi "c++" import "llvm/ADT/STLExtras.h";
ffi "c++" import "Native/Types.hh";
ffi "c++" import "llvm/Support/FileSystem.h";
ffi "c++" import "llvm/Support/Path.h";

import Support::FileIO::Path::*;
import Support::FileIO::FileSystem::*;
import Memory::MappedFileBuffer::*;

import Resolution::FileExtensions::*;

class DirEntry {
    pub var name:      string;
    pub var children:  libcxx::unordered_map::<string, *DirEntry>;
    pub var file_path: std::Nullable::<Path>;
    pub var ext:       string;
    pub var category:  FileCategory;
    pub var is_dir:    bool;
    pub var fs_path:   std::Nullable::<Path>;   ///< this dir's own fs path; dirs only
    pub var ext_cfg:   obs::<FileExtensions>;   ///< non-owning; propagated from SearchRoot
    pub var scanned:   bool;                    ///< full readdir done (enumeration path only)

    fn DirEntry(self, name: string, is_dir: bool = true) {
        self.name      = name;
        self.children  = libcxx::unordered_map::<string, *DirEntry>();
        self.file_path = null;
        self.ext       = "";
        self.category  = FileCategory::Ignored;
        self.is_dir    = is_dir;
        self.fs_path   = null;
        self.ext_cfg   = &null;
        self.scanned   = false;
    }

    fn DirEntry(self, name: string, path: Path, ext: string, category: FileCategory) {
        self.name      = name;
        self.children  = libcxx::unordered_map::<string, *DirEntry>();
        self.file_path = path;
        self.ext       = ext;
        self.category  = category;
        self.is_dir    = false;
        self.fs_path   = null;
        self.ext_cfg   = &null;
        self.scanned   = false;
    }

    fn op delete (self) {
        for entry in self.children {
            if entry.second != &null {
                std::destroy(entry.second);
            }
        }

        self.children.clear();
    }

    fn get_or_create_dir(self, name: string) -> *DirEntry {
        if self.children.contains(name) {
            return self.children[name];
        }

        var child = std::create::<DirEntry>(name, true);
        child->ext_cfg = self.ext_cfg;
        self.children[name] = child;
        return child;
    }


    /// Probe for a subdirectory named `name`. One stat. Memoized.
    fn probe_child_dir(self, name: string) -> *DirEntry {
        if self.children.contains(name) {
            var c = self.children[name];
            return c if c->is_dir else &null;
        }
        if !self.fs_path { return &null; }

        var found = false;
        var child_path: Path;
        var cand = (*self.fs_path).join(name);
        if llvm::sys::fs::is_directory(llvm::Twine(sref(cand))) {
            found = true;
            child_path = Path::from_known(cand, FileType::directory_file);
        }
        if !found { return &null; }

        var child = std::create::<DirEntry>(name, true);
        child->fs_path = child_path;
        child->ext_cfg = self.ext_cfg;
        self.children[name] = child;
        return child;
    }

    /// Probe for a file with given stem+ext (ext without leading dot). One stat. Memoized.
    fn probe_file(self, stem: string, ext: string) -> *DirEntry {
        var key = stem;
        if ext.size() > 0 { key = stem + "." + ext; }

        if self.children.contains(key) {
            var c = self.children[key];
            return c if (!c->is_dir) else &null;
        }
        if !self.fs_path { return &null; }

        var fname = key;
        var found = false;
        var full_path: Path;
        var cand = (*self.fs_path).join(fname);
        if llvm::sys::fs::is_regular_file(llvm::Twine(sref(cand))) {
            found = true;
            full_path = Path::from_known(cand, FileType::regular_file);
        }
        if !found { return &null; }

        var category = self.ext_cfg->categorize(ext);
        var child = std::create::<DirEntry>(stem, full_path, ext, category);
        child->ext_cfg = self.ext_cfg;
        self.children[key] = child;
        return child;
    }

    /// Full one-level readdir. ONLY for enumeration (collect_*). Memoized via `scanned`.
    /// This is the only path that reads a whole directory keep it off hot lookups.
    fn ensure_scanned(self) {
        if self.scanned || !self.is_dir { return; }
        self.scanned = true;
        if !self.fs_path { return; }

        // The type comes off the readdir record (Path::type_of_entry), and each
        // child Path is built from it (from_known): one syscall per directory,
        // not two stats per entry. A missing directory just ends the loop.
        var self_path = (*self.fs_path).path_data;
        var ec: libcxx::error_code;
        var it  = llvm::sys::fs::directory_iterator(llvm::Twine(sref(self_path)), ec, true);
        var end = llvm::sys::fs::directory_iterator();
        for (; (!ec) && (it != end); it.increment(ec)) {
            var fname = llvm::sys::path::filename(it->path());
            if fname.starts_with(r".") { continue; }
            var name_raw = string(fname.data(), fname.size());
            var full_raw = Path::join_str(self_path, name_raw);
            var etype    = Path::type_of_entry(*it);

            if etype == FileType::directory_file {
                if self.children.find(name_raw) == self.children.end() {
                    var c = std::create::<DirEntry>(name_raw, true);
                    c->fs_path = Path::from_known(full_raw, etype);
                    c->ext_cfg = self.ext_cfg;
                    self.children[name_raw] = c;
                }
            } else if etype == FileType::regular_file {
                // No dot: an extensionless file (a built binary beside the
                // sources) has an empty extension, and drop_front(1) on it asserts.
                var ext_ref = llvm::sys::path::extension(fname);
                if !ext_ref.empty() { ext_ref = ext_ref.drop_front(1); }
                var ext     = string(ext_ref.data(), ext_ref.size());
                if self.ext_cfg->should_index(ext) {
                    var stem_ref = llvm::sys::path::stem(fname);
                    var stem = string(stem_ref.data(), stem_ref.size());
                    var full = Path::from_known(full_raw, etype);
                    var cat  = self.ext_cfg->categorize(ext);
                    var key  = stem;
                    if !ext.empty() { key = stem + "." + ext; }
                    if self.children.find(key) == self.children.end() {
                        var c = std::create::<DirEntry>(stem, full, ext, cat);
                        c->ext_cfg = self.ext_cfg;
                        self.children[key] = c;
                    }
                }
            }
        }
    }

    fn insert_file(self, stem: string, path: Path, ext: string, category: FileCategory) {
        var key = stem;
        if ext.size() > 0 {
            key = stem + "." + ext;
        }

        if self.children.contains(key) {
            return;
        }

        var child = std::create::<DirEntry>(stem, path, ext, category);
        child->ext_cfg = self.ext_cfg;
        self.children[key] = child;
    }

    fn find(self, key: string) -> *DirEntry {
        if self.children.contains(key) {
            return self.children[key];
        }
        return &null;
    }

    fn find_with_ext(self, name: string, ext: string) -> *DirEntry {
        return self.probe_file(name, ext);
    }

    fn find_dir(self, name: string) -> *DirEntry {
        return self.probe_child_dir(name);
    }

    fn find_by_stem(self, stem: string) -> *DirEntry {
        var k = self.probe_file(stem, "k");
        if k != &null { return k; }
        self.ensure_scanned();
        for child: *DirEntry in self.sorted_children() {
            if (!child->is_dir) && (child->name == stem) {
                return child;
            }
        }
        return &null;
     }
 
    fn find_by_stem_and_category(self, stem: string, cat: FileCategory) -> *DirEntry {
        if cat == FileCategory::KairoSource {
            var k = self.probe_file(stem, "k");
            if (k != &null) && (k->category == cat) { return k; }
            return &null;
        }
        self.ensure_scanned();
        for child: *DirEntry in self.sorted_children() {
            if (!child->is_dir) && (child->name == stem) && (child->category == cat) {
                return child;
            }
        }
        return &null;
    }

    fn collect_by_category(self, cat: FileCategory) -> vec::<*DirEntry> {
        self.ensure_scanned();
        var result = vec::<*DirEntry>();

        for child: *DirEntry in self.sorted_children() {
            if (!child->is_dir) && (child->category == cat) {
                result.push_back(child);
            }
        }

        return result;
    }

    fn collect_by_ext(self, ext: string) -> vec::<*DirEntry> {
        self.ensure_scanned();
        var result = vec::<*DirEntry>();

        for child: *DirEntry in self.sorted_children() {
            if (!child->is_dir) && (child->ext == ext) {
                result.push_back(child);
            }
        }

        return result;
    }

    ///
    /// \brief the children, sorted by name.
    ///
    /// \details Every walk over children goes through this. The map's own
    ///          order is hash order, and the entries came from readdir, whose
    ///          order differs between filesystems (ext4, APFS, NTFS): any
    ///          "first match" or collected list taken straight off the map
    ///          was platform-dependent. Name is the one order every host
    ///          agrees on. Names are the map's keys, so they never tie.
    ///
    fn sorted_children(self) -> vec::<*DirEntry> {
        var keyed: libcxx::vector::<libcxx::pair::<string, *DirEntry>>;
        keyed.reserve(self.children.size());
        for var it = self.children.begin(); it != self.children.end(); ++it {
            keyed.push_back(libcxx::make_pair(it->first, it->second));
        }
        llvm::sort(keyed.begin(), keyed.end());
        var out = vec::<*DirEntry>();
        out.reserve(keyed.size());
        for var i: usize = 0; i < keyed.size(); ++i { out.push_back(keyed[i].second); }
        return out;
    }

    fn collect_all_files(self) -> vec::<*DirEntry> {
        self.ensure_scanned();
        var result = vec::<*DirEntry>();

        for child: *DirEntry in self.sorted_children() {
            if !child->is_dir {
                result.push_back(child);
            }
        }

        return result;
    }
}
