/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Preprocessor::MacroDefinition::*;

class MacroSymbolTable {
    var     _mu:   std::SharedMutex;
    pub var table: map::<ModulePath, map::<IdentifierToken, MacroDefinition>>; ///< scope path string -> macro name -> MacroDefinition

    fn insert_macro(self, macro_def: MacroDefinition) -> bool {
        var wlock = std::UniqueLock(self._mu);

        var scope_map_it = self.table.find(macro_def.scope);
        if scope_map_it == self.table.end() {
            // No macros in this scope yet, create new map
            var new_map = map::<IdentifierToken, MacroDefinition>();
            new_map[macro_def.name] = macro_def;
            self.table[macro_def.scope] = new_map;
            return true;
        } else {
            var scope_map = &(scope_map_it->second);
            if scope_map->contains(macro_def.name) {
                return false;
            }

            scope_map->emplace(macro_def.name, macro_def);
            return true;
        }
    }

    fn find_macro(self, scope: ModulePath, name: IdentifierToken) -> *MacroDefinition {
        var rlock = std::SharedLock(self._mu);

        var scope_map_it = self.table.find(scope);
        if scope_map_it != self.table.end() {
            var scope_map = &(scope_map_it->second);
            var macro_it  = scope_map->find(name);
            if  macro_it != scope_map->end() {
                return &(macro_it->second);
            }
        }
        return &null;
    }

    const fn as_string(self, s: *PreprocessorSymbolTable) -> string {
        var repr = "MacroSymbolTable(\n";
        for scope_pair in self.table {
            repr += f"  Scope: '{scope_pair.first.as_string(s)}'\n";
            for macro_pair in scope_pair.second {
                repr += f"    Macro: '{macro_pair.first.as_string(s)}' => {macro_pair.second.as_string(s)}\n";
            }
        }
        repr += ")";
        return repr;
    }
}