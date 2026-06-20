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

import Support::FileIO::Path::*;
import Support::FileIO::FileSystem::*;
import Support::Memory::MappedFileBuffer::*;

import Preprocessor::FileExtensions::*;
import Preprocessor::DirEntry::*;
import Support::Threading::ThreadPool::*;

class SearchRoot {
    pub var base_path: Path;
    pub var ext_cfg:   obs::<FileExtensions>;
    pub var root:      own::<DirEntry>;
    pub var priority:  u32;

    fn SearchRoot(self, path: Path, priority: u32, ext_cfg: *FileExtensions) {
        self.base_path     = path;
        self.priority      = priority;
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