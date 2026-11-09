/// --- The Kairo Project ------- Preprocessor/PreprocessorSymbolTable.k --- ///
///
///   PreprocessorSymbolTable: interns identifier names to SymbolIDs.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/CharTable.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "vector"

pub type SymbolID = u32

pub class PreprocessorSymbolTable {
    /// identifier name -> symbolId. StringMap: probed with the name's own
    /// bytes (no tree walk of string compares), never iterated.
    var table: llvm::StringMap<SymbolID>
    /// symbolId -> identifier name. Each name lives in its own allocation:
    /// resolve() hands out a pointer and drops the lock, and the wave tasks
    /// intern concurrently, so a `vec::<string>` regrowing under a writer
    /// moved the string out from under a reader mid-copy (the fuzzer's
    /// bad_alloc in _walk_one: a garbage length read from a freed slot).
    var symbols: cxx::std::vector<unsafe *string>
    var _mu:     kairo::std::SharedMutex          ///< mutex for synchronizing access

    pub fn intern(self, name: string) -> SymbolID {
        {
            // fast path: check under shared lock
            var rlock = kairo::std::SharedLock(self._mu)
            var it    = self.table.find(kairo::sref(name))
            if it != self.table.end() {
                return it->second
            }
        }

        var wlock = kairo::std::UniqueLock(self._mu)

        var it = self.table.find(kairo::sref(name))
        if it != self.table.end() {
            return it->second
        }

        var id: SymbolID = (self.symbols.size() as u32)
        self.symbols.push_back(kairo::std::create<string>(name))
        self.table.try_emplace(kairo::sref(name), id)

        return id
    }

    pub fn resolve(self, id: SymbolID) -> unsafe *string {
        var rlock = kairo::std::SharedLock(self._mu)

        if (id as usize) < self.symbols.size() {
            return self.symbols[id]
        }

        return &null
    }

    fn op [](self, id: SymbolID) -> *string {
        unsafe {
            return self.resolve(id) as *string
        }
    }

    fn op [](self, const name: string) -> SymbolID {
        return self.intern(name)
    }

    fn op as (self) -> string {
        var repr = "PreprocessorSymbolTable(\n"
        for i in (0 as usize) .. (self.symbols.size()) {
            var nm = *self.symbols[i]
            repr += f"  {i}: '{nm}'\n"
        }

        repr += ")"
        return repr
    }

    fn size(self) -> usize {
        return self.symbols.size()
    }

    fn clear(self) {
        self.table.clear()
        for var i: usize = 0; i < self.symbols.size(); ++i {
            kairo::std::destroy(self.symbols[i])
        }

        self.symbols.clear()
    }

    fn op finally (self) {
        self.clear()
    }
}
