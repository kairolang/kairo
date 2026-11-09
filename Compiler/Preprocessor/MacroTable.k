/// --- The Kairo Project -------------------- Preprocessor/MacroTable.k --- ///
///
///   MacroTable: the macro registry, pairing each MacroDecl with its tokens.
///
///   The TU-owned MacroDecl node is the authority; each entry pairs it with
///   OWNED expansion storage: one TokenBuffer holding [body tokens][default
///   runs...], edge newlines trimmed.
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "map"
ffi "c++" import "vector"

import AST::Node::Declarations::{
    MacroDecl,
    MacroParamSpec,
}
import Preprocessor::PreprocessorSymbolTable::SymbolID
import Resolution::ModulePath::ModulePath
import Token::TokenBuffer::TokenBuffer
import Token::TokenSpan::TokenSpan

pub class MacroEntry {
    pub var decl:       unsafe *MacroDecl            ///< TU-owned AST node
    pub var storage:    unsafe *TokenBuffer<512>     ///< body + default runs, OWNED
    pub var body_len:   u32                      = 0
    pub var name_sym:   SymbolID                 = 0
    pub var scope:      ModulePath
    pub var source_fid: u32                      = 0
    pub var visibility: u8                       = 3 ///< 1 priv / 2 prot / 3 pub
    pub var order_idx:  u32                      = 0

    fn body_span(self) -> TokenSpan {
        return TokenSpan(self.storage, 0, self.body_len as usize)
    }

    fn default_span(self, p: *MacroParamSpec) -> TokenSpan {
        return TokenSpan(self.storage, p->default_off as usize, (p->default_len as usize))
    }

    fn accepts_params(self) -> bool {
        return self.decl->params_spec.size() > 0 || self.decl->is_variadic
        // NOTE: `macro f!() {}` (empty parens) accepts_params true with zero
        // params. carried on the decl:
    }

    fn MacroEntry(self) = default

    // Move-only: the destructor destroys `storage`, so a copy would destroy it
    // twice. The source is left with no storage.
    @move fn MacroEntry(self, other: Self) {
        self.decl       = other.decl
        self.storage    = other.storage
        self.body_len   = other.body_len
        self.name_sym   = other.name_sym
        self.scope      = other.scope
        self.source_fid = other.source_fid
        self.visibility = other.visibility
        self.order_idx  = other.order_idx
        other.storage   = &null
    }

    fn op finally (self) {
        if self.storage != &null {
            kairo::std::destroy(self.storage)
            self.storage = &null
        }
    }
}

pub class MacroTable {
    priv var _mu: kairo::std::SharedMutex
    /// The outer key stays a std::map: ModulePath is a Kairo record (a vector
    /// of segments), and a DenseMap key would need a DenseMapInfo
    /// specialization (C++). The inner tables and _by_fid are keyed
    /// `sym/fid as u64` (clear of DenseMap's two reserved keys) and are
    /// iterated only to count or free, where hash order cannot show.
    priv var _global: cxx::std::map<ModulePath, llvm::DenseMap<u64, unsafe *MacroEntry>>
    priv var _by_fid: llvm::DenseMap<u64, cxx::std::vector<unsafe *MacroEntry>> ///< owns; each vector in insertion order

    /// register at collection point. false = duplicate (scope, name).
    fn register_macro(self, entry: unsafe *MacroEntry) -> bool {
        var wlock = kairo::std::UniqueLock(self._mu)

        var scope_it = self._global.find(entry->scope)
        if scope_it != self._global.end() {
            if !scope_it->second.try_emplace(entry->name_sym as u64, entry).second {
                kairo::std::destroy(entry)
                return false
            }
        } else {
            var m = llvm::DenseMap<u64, unsafe *MacroEntry>()
            m[entry->name_sym as u64]  = entry
            self._global[entry->scope] = m
        }

        self._by_fid[entry->source_fid as u64].push_back(entry)
        return true
    }

    /// exact (scope, name) lookup. visibility enforcement:
    ///   priv -> requesting_fid must equal source_fid
    ///   prot -> TODO(step 4 + resolver same-library query); treated as priv
    ///          for now CONSERVATIVE, loosens later, never tightens
    ///   pub  -> always visible
    fn find(self,
            const scope:    ModulePath,
            name:           SymbolID,
            requesting_fid: u32) -> unsafe *MacroEntry {
        var rlock = kairo::std::SharedLock(self._mu)

        var scope_it = self._global.find(scope)
        if scope_it == self._global.end() {
            return &null
        }

        var it = scope_it->second.find(name as u64)
        if it == scope_it->second.end() {
            return &null
        }

        var unsafe *e = it->second
        if e->visibility <= 2 && e->source_fid != requesting_fid {
            return &null // priv (and prot-as-priv) blocked cross-file
        }

        return e
    }

    fn find_ignoring_visibility(self,
                                const scope: ModulePath,
                                name:        SymbolID) -> unsafe *MacroEntry {
        var rlock    = kairo::std::SharedLock(self._mu)
        var scope_it = self._global.find(scope)
        if scope_it == self._global.end() {
            return &null
        }

        var it = scope_it->second.find(name as u64)
        if it == scope_it->second.end() {
            return &null
        }

        return it->second
    }

    /// same-fid lookup with no visibility gate (a file always sees its own).
    fn find_same_fid(self,
                     const scope: ModulePath,
                     name:        SymbolID,
                     fid:         u32) -> unsafe *MacroEntry {
        var rlock    = kairo::std::SharedLock(self._mu)
        var scope_it = self._global.find(scope)
        if scope_it == self._global.end() {
            return &null
        }

        var it = scope_it->second.find(name as u64)
        if it == scope_it->second.end() {
            return &null
        }

        if it->second->source_fid != fid {
            return &null
        }

        return it->second
    }

    /// undef! builtin support.
    fn undef(self, const scope: ModulePath, name: SymbolID) -> bool {
        var wlock    = kairo::std::UniqueLock(self._mu)
        var scope_it = self._global.find(scope)
        if scope_it == self._global.end() {
            return false
        }

        return scope_it->second.erase(name as u64)
        // entry stays owned by _by_fid; it just stops resolving.
    }

    /// Total live entries. Grows only if a reparse re-registers without the
    /// matching forget_fid, so a reparse loop can watch it for exactly that.
    fn size(self) -> usize {
        var rlock       = kairo::std::SharedLock(self._mu)
        var n:    usize = 0
        for *fid_entry in self._by_fid {
            n += fid_entry->second.size()
        }

        return n
    }

    /// \brief the entries \p fid defined, in declaration order.
    ///
    /// \details A snapshot of borrowed pointers taken under the read lock, for
    ///          --print-macros. The table keeps ownership, so the caller must
    ///          not hold the result across forget_fid(\p fid).
    pub fn entries_of_fid(self, fid: u32) -> cxx::std::vector<unsafe *MacroEntry> {
        var rlock = kairo::std::SharedLock(self._mu)
        var out   = cxx::std::vector<unsafe *MacroEntry>()
        var it    = self._by_fid.find(fid as u64)
        if it == self._by_fid.end() {
            return out
        }

        for e in it->second {
            if e == &null {
                continue
            }

            out.push_back(e)
        }

        return out
    }

    /// \brief drops every macro defined by \p fid, from both indexes.
    ///
    /// \details MANDATORY before \p fid's ASTContext is destroyed. MacroEntry
    ///          holds \c decl as an obs<MacroDecl> pointing into that context's
    ///          arena, so an entry that outlives the context dangles   and
    ///          register()'s duplicate check would then KEEP the stale entry
    ///          and destroy the freshly-built replacement, so the table
    ///          silently converges on all-dangling decls across reparses.
    ///
    /// \return number of entries dropped.
    fn forget_fid(self, fid: u32) -> usize {
        var wlock = kairo::std::UniqueLock(self._mu)

        var it = self._by_fid.find(fid as u64)
        if it == self._by_fid.end() {
            return 0
        }

        var n: usize = 0
        for e in it->second {
            if e == &null {
                continue
            }

            // Unpublish before destroying   _global holds a borrowed pointer
            // and would otherwise resolve to freed memory.
            var scope_it = self._global.find(e->scope)
            if scope_it != self._global.end() {
                var g = scope_it->second.find(e->name_sym as u64)
                if g != scope_it->second.end() && g->second == e {
                    scope_it->second.erase(g)
                }
            }

            kairo::std::destroy(e)
            n += 1
        }

        self._by_fid.erase(it)
        return n
    }

    fn clear(self) {
        var wlock = kairo::std::UniqueLock(self._mu)
        for *fid_entry in self._by_fid {
            for e in fid_entry->second {
                kairo::std::destroy(e)
            }
        }

        self._by_fid.clear()
        self._global.clear()
    }

    fn op finally (self) {
        self.clear()
    }
}
