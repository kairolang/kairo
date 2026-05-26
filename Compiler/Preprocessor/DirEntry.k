/// --- The Kairo Project ----------------------------------- <filename> --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://kairo-lang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Kairo Software Foundation
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Types.hh";

import Path::*;
import FileSystem::*;
import Memory::MappedFileBuffer::*;

import Preprocessor::FileExtensions::*;

class DirEntry {
    pub var name:      string;
    pub var children:  libcxx::unordered_map::<string, *DirEntry>;
    pub var file_path: std::Nullable::<Path>;
    pub var ext:       string;
    pub var category:  FileCategory;
    pub var is_dir:    bool;

    fn DirEntry(self, name: string, is_dir: bool = true) {
        self.name      = name;
        self.children  = libcxx::unordered_map::<string, *DirEntry>();
        self.file_path = null;
        self.ext       = "";
        self.category  = FileCategory::Ignored;
        self.is_dir    = is_dir;
    }

    fn DirEntry(self, name: string, path: Path, ext: string, category: FileCategory) {
        self.name      = name;
        self.children  = libcxx::unordered_map::<string, *DirEntry>();
        self.file_path = path;
        self.ext       = ext;
        self.category  = category;
        self.is_dir    = false;
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
        self.children[name] = child;
        return child;
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
        self.children[key] = child;
    }

    fn find(self, key: string) -> *DirEntry {
        if self.children.contains(key) {
            return self.children[key];
        }
        return &null;
    }

    fn find_with_ext(self, name: string, ext: string) -> *DirEntry {
        var full_name = name + "." + ext;
        return self.find(full_name);
    }

    fn find_dir(self, name: string) -> *DirEntry {
        var node = self.find(name);
        if (node != &null) && node->is_dir {
            return node;
        }
        return &null;
    }

    fn find_by_stem(self, stem: string) -> *DirEntry {
        for entry in self.children {
            var child = entry.second;
            if (!child->is_dir) && (child->name == stem) {
                return child;
            }
        }
        return &null;
    }

    fn find_by_stem_and_category(self, stem: string, cat: FileCategory) -> *DirEntry {
        for entry in self.children {
            var child = entry.second;
            if (!child->is_dir) && (child->name == stem) && (child->category == cat) {
                return child;
            }
        }
        return &null;
    }

    fn collect_by_category(self, cat: FileCategory) -> vec::<*DirEntry> {
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
