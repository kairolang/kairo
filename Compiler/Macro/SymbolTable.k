/// --- The Kairo Project -------------------------- Macro/SymbolTable.k --- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Macro::Definition::*;
import Memory::ArenaAllocator::*;
import Token::Token::*;
import Token::TokenSpan::*;

class MacroSymbolTable {
    var     _mu:   std::SharedMutex;
    pub var table: map::<ModulePath, map::<IdentifierToken, MacroDefinition>>; ///< scope path string -> macro name -> MacroDefinition

    // --- Owned token storage ----------------------------------------------
    // Definitions arrive from the collector as VIEWS into the lexed token
    // buffers (body span, param default spans, name token pointers). Those
    // buffers get displaced by macro expansion (TCM::replace_tokens), so
    // without a copy they had to leak until shutdown to keep the views
    // alive. insert_macro() deep-copies every alias into this table-owned
    // arena instead: definitions are self-contained, and the TCM can
    // release displaced buffers at end of preprocess
    // (TCM::release_old_buffers).
    priv var _tokens:      ArenaAllocator;
    priv var _tokens_init: bool = false;

    fn op delete (self) {
        if self._tokens_init {
            self._tokens.destroy();
        }
    }

    /// \brief copies a span's tokens into table-owned contiguous storage.
    priv fn _intern_span(self, span: TokenSpan) -> TokenSpan {
        var n = span.size();
        if n == 0 { return TokenSpan(); }

        var mem = reinterpret_cast::<*Token>(
            self._tokens.alloc(sizeof(Token) * n, alignof(Token)));
        for var i: usize = 0; i < n; ++i {
            mem[i] = *(span.get(i));
        }
        return TokenSpan(mem, n); // flat-mode span, stable for table lifetime
    }

    /// \brief copies one token into table-owned storage.
    priv fn _intern_token(self, tok: *Token) -> *Token {
        var mem = reinterpret_cast::<*Token>(
            self._tokens.alloc(sizeof(Token), alignof(Token)));
        (*mem) = (*tok);
        return mem;
    }

    fn insert_macro(self, macro_def: MacroDefinition) -> bool {
        var wlock = std::UniqueLock(self._mu);

        // deep-copy all buffer aliases under the lock (the arena is not
        // thread-safe; phase-1 collectors insert from pool threads).
        if !self._tokens_init {
            self._tokens.init(64 * 1024);
            self._tokens_init = true;
        }

        var def  = macro_def;
        def.body = self._intern_span(def.body);
        if def.name.token != &null {
            def.name.token = self._intern_token(def.name.token);
        }
        for var i: usize = 0; i < def.params.params.size(); ++i {
            var p = &(def.params.params[i]);
            if p->name.token != &null {
                p->name.token = self._intern_token(p->name.token);
            }
            if p->has_default {
                p->default_value = self._intern_span(p->default_value);
            }
        }

        var scope_map_it = self.table.find(def.scope);
        if scope_map_it == self.table.end() {
            // No macros in this scope yet, create new map
            var new_map = map::<IdentifierToken, MacroDefinition>();
            new_map[def.name] = def;
            self.table[def.scope] = new_map;
            return true;
        } else {
            var scope_map = &(scope_map_it->second);
            if scope_map->contains(def.name) {
                // duplicate: the copies interned above are stranded in the
                // arena. acceptable — duplicates are an error path.
                return false;
            }

            scope_map->emplace(def.name, def);
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