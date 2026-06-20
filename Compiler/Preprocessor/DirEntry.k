/// --- The Kairo Project ----------------------------------- <filename> --- ///
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

ffi "c++" import "Include/Types.hh";

import Support::FileIO::Path::*;
import Support::FileIO::FileSystem::*;
import Support::Memory::MappedFileBuffer::*;

import Preprocessor::FileExtensions::*;

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
        inline "c++" {
            auto cand = (*fs_path).path_data /
                        ::std::filesystem::path(name.raw_string());
            ::std::error_code ec;
            if (::std::filesystem::is_directory(cand, ec)) {
                found = true;
                child_path = Path(cand.generic_wstring(), false);
            }
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
        inline "c++" {
            auto cand = (*fs_path).path_data /
                        ::std::filesystem::path(fname.raw_string());
            ::std::error_code ec;
            if (::std::filesystem::is_regular_file(cand, ec)) {
                found = true;
                full_path = Path(cand.generic_wstring(), false);
            }
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

        inline "c++" {
            ::std::error_code ec;
            if (!::std::filesystem::is_directory((*fs_path).path_data, ec)) return;
            ::std::filesystem::directory_iterator it((*fs_path).path_data, ec), end;
            for (; !ec && it != end; it.increment(ec)) {
                auto& entry = *it;
                auto name_raw = entry.path().filename().generic_wstring();
                if (name_raw.starts_with(WIDE_STR('.'))) continue;

                ::std::error_code ec2;
                if (entry.is_directory(ec2)) {
                    if (children.find(name_raw) == children.end()) {
                        auto* c = std::create<DirEntry>(name_raw, true);
                        c->fs_path = Path(entry.path().generic_wstring(), false);
                        c->ext_cfg = ext_cfg;
                        children[name_raw] = c;
                    }
                } else if (entry.is_regular_file(ec2)) {
                    auto ext_raw = entry.path().extension().generic_wstring();
                    auto ext     = ext_raw.empty() ? ext_raw :
                                   (ext_raw[0] == WIDE_STR('.')? ext_raw.substr(1) : ext_raw);
                    if (ext_cfg->should_index(ext)) {
                        auto stem = entry.path().stem().generic_wstring();
                        auto full = Path(entry.path().generic_wstring(), false);
                        auto cat  = ext_cfg->categorize(ext);
                        auto key  = ext.empty() ? stem : (stem + WIDE_STR(".") + ext);
                        if (children.find(key) == children.end()) {
                            auto* c = std::create<DirEntry>(stem, full, ext, cat);
                            c->ext_cfg = ext_cfg;
                            children[key] = c;
                        }
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
        for entry in self.children {
            var child = entry.second;
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
        for entry in self.children {
            var child = entry.second;
            if (!child->is_dir) && (child->name == stem) && (child->category == cat) {
                return child;
            }
        }
        return &null;
    }

    fn collect_by_category(self, cat: FileCategory) -> vec::<*DirEntry> {
        self.ensure_scanned();
        var result = vec::<*DirEntry>();

        for entry in self.children {
            var child = entry.second;
            if (!child->is_dir) && (child->category == cat) {
                result.push_back(child);
            }
        }

        return result;
    }

    fn collect_by_ext(self, ext: string) -> vec::<*DirEntry> {
        self.ensure_scanned();
        var result = vec::<*DirEntry>();

        for entry in self.children {
            var child = entry.second;
            if (!child->is_dir) && (child->ext == ext) {
                result.push_back(child);
            }
        }

        return result;
    }

    fn collect_all_files(self) -> vec::<*DirEntry> {
        self.ensure_scanned();
        var result = vec::<*DirEntry>();

        for entry in self.children {
            var child = entry.second;
            if !child->is_dir {
                result.push_back(child);
            }
        }

        return result;
    }
}
