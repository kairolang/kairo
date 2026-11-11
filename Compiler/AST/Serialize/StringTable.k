/// --- The Kairo Project ------------------ AST/Serialize/StringTable.k --- ///
///
///   StringTable: every spelling a serialized AST names (identifiers, module
///   path segments, file names) is stored once and referenced by its index,
///   in first-use order. Index 0 is the empty string.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "Native/Types.hh"

import AST::Serialize::ByteBuffer::{
    ByteReader,
    ByteWriter,
}

pub class StringTable {
    pub var items: [string]

    /// Spelling -> index; the writer's side only (a reader never looks up).
    var index: llvm::StringMap<u32>

    pub fn StringTable(self) {
        self.items.push_back("")
        self.index.try_emplace(kairo::sref(""), 0 as u32)
    }

    pub fn intern(self, const s: string) -> u32 {
        var it = self.index.find(kairo::sref(s))
        if it != self.index.end() {
            return it->second
        }

        var id = self.items.size() as u32
        self.items.push_back(s)
        self.index.try_emplace(kairo::sref(s), id)
        return id
    }

    pub fn size(const self) -> usize {
        return self.items.size()
    }

    /// The spelling at \p id; the empty string for an index the table does
    /// not have (the reader reports that through its own `failed`).
    pub fn get(const self, id: u32) -> string {
        if (id as usize) >= self.items.size() {
            return ""
        }

        return self.items[id as usize]
    }

    pub fn has(const self, id: u32) -> bool {
        return (id as usize) < self.items.size()
    }

    /// count, then (length, bytes) per string. Index 0 is written too, so a
    /// reader's indices line up without a special case.
    pub fn write(const self, @inout w: ByteWriter) {
        w.put_varint(self.items.size() as u64)
        for var i: usize = 0; i < self.items.size(); ++i {
            var n = self.items[i].size()
            w.put_varint(n as u64)
            if n > 0 {
                w.put_bytes(unsafe (self.items[i].raw() as unsafe *const u8), n)
            }
        }
    }

    pub fn read(self, @inout r: ByteReader) {
        self.items.clear()
        var n = r.get_count()
        for var i: usize = 0; i < n; ++i {
            var len = r.get_count()
            var p   = r.get_bytes(len)
            if r.failed {
                return
            }

            if len == 0 {
                self.items.push_back("")
            } else {
                self.items.push_back(string(unsafe (p as *const u8), len))
            }
        }
    }
}
