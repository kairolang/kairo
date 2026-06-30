/// --- The Kairo Project ------- Preprocessor/PreprocessorSymbolTable.k --- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/CharTable.hh";

type SymbolID = u32;;

class PreprocessorSymbolTable {
    var table:   map::<string, SymbolID>; ///< identifier name -> symbolId
    var symbols: vec::<string>;           ///< symbolId -> identifier name
    var _mu:     std::SharedMutex;      ///< mutex for synchronizing access

    fn intern(self, name: string) -> SymbolID {
        {
            // fast path: check under shared lock
            var rlock = std::SharedLock(self._mu);
            var it = self.table.find(name);
            if it != self.table.end() { return it->second; }
        }

        var wlock = std::UniqueLock(self._mu);

        var it = table.find(name);
        if (it != table.end()) {
            return it->second;
        }

        var id: SymbolID = symbols.size();
        symbols.emplace_back(name);
        table.emplace(symbols.back(), id);

        return id;
    }

    fn resolve(self, id: SymbolID) -> *string {
        var rlock = std::SharedLock(self._mu);

        if id < symbols.size() {
            return &(symbols[id]);
        }

        return &null;
    }

    fn op [](self, id: SymbolID) -> *string {
        return self.resolve(id);
    }

    fn op [](self, name: string) -> SymbolID {
        return self.intern(name);
    }

    fn op as (self) -> string {
        var repr = "PreprocessorSymbolTable(\n";
        for i in usize(0) .. usize(self.symbols.size()) {
            repr += f"  {i}: '{self.symbols[i]}'\n";
        }
        repr += ")";
        return repr;
    }

    fn size(self) -> usize {
        return self.symbols.size();
    }

    fn clear(self) {
        self.table.clear();
        self.symbols.clear();
    }

    fn op delete (self) {
        self.clear();
    }
}