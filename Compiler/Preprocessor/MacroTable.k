/// --- The Kairo Project ------------------- Preprocessor/MacroTable.k --- ///
///
///   Runtime macro registry, v2. Pairs the TU-owned MacroDecl node
///   (the authority) with OWNED expansion storage: one TokenBuffer per
///   entry holding [body tokens][default runs...], edge newlines trimmed.
///   Kills the "leak original buffers" retention in TCM at step 4.
///
///   order_idx recorded now; order-gated lookup lands with the step-4 walk
///   (the two-phase driver can't honor decl order known, accepted).
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Declarations::*;
import Resolution::ModulePath::*;
import Token::TokenBuffer::*;
import Token::TokenSpan::*;
import Preprocessor::PreprocessorSymbolTable::*;

class MacroEntry {
    pub var decl:       obs::<MacroDecl>;           ///< TU-owned AST node
    pub var storage:    own::<TokenBuffer::<512>>;  ///< body + default runs, OWNED
    pub var body_len:   u32 = 0;
    pub var name_sym:   SymbolID = 0;
    pub var scope:      ModulePath;
    pub var source_fid: u32 = 0;
    pub var visibility: u8  = 3;                    ///< 1 priv / 2 prot / 3 pub
    pub var order_idx:  u32 = 0;

    fn body_span(self) -> TokenSpan {
        return TokenSpan(self.storage, 0, usize(self.body_len));
    }

    fn default_span(self, p: *MacroParamSpec) -> TokenSpan {
        return TokenSpan(self.storage, usize(p->default_off), usize(p->default_len));
    }

    fn accepts_params(self) -> bool {
        return self.decl->params_spec.size() > 0 || self.decl->is_variadic;
        // NOTE: `macro f!() {}` (empty parens) accepts_params true with zero
        // params. carried on the decl:
    }

    fn op delete (self) {
        if self.storage != &null { std::destroy(self.storage); self.storage = &null; }
    }
}

class MacroTable {
    priv var _mu:     std::SharedMutex;
    priv var _global: map::<ModulePath, map::<SymbolID, *MacroEntry>>;
    priv var _by_fid: map::<u32, vec::<*MacroEntry>>;  ///< owns; insertion order

    /// register at collection point. false = duplicate (scope, name).
    fn register(self, entry: *MacroEntry) -> bool {
        var wlock = std::UniqueLock(self._mu);

        var scope_it = self._global.find(entry->scope);
        if scope_it != self._global.end() {
            if scope_it->second.contains(entry->name_sym) {
                std::destroy(entry);
                return false;
            }
            scope_it->second[entry->name_sym] = entry;
        } else {
            var m = map::<SymbolID, *MacroEntry>();
            m[entry->name_sym] = entry;
            self._global[entry->scope] = m;
        }

        self._by_fid[entry->source_fid].push_back(entry);
        return true;
    }

    /// exact (scope, name) lookup. visibility enforcement:
    ///   priv -> requesting_fid must equal source_fid
    ///   prot -> TODO(step 4 + resolver same-library query); treated as priv
    ///          for now CONSERVATIVE, loosens later, never tightens
    ///   pub  -> always visible
    fn find(self, scope: ModulePath, name: SymbolID, requesting_fid: u32) -> *MacroEntry {
        var rlock = std::SharedLock(self._mu);

        var scope_it = self._global.find(scope);
        if scope_it == self._global.end() { return &null; }
        var it = scope_it->second.find(name);
        if it == scope_it->second.end() { return &null; }

        var e = it->second;
        if (e->visibility <= 2) && (e->source_fid != requesting_fid) {
            return &null; // priv (and prot-as-priv) blocked cross-file
        }
        return e;
    }

    fn find_ignoring_visibility(self, scope: ModulePath, name: SymbolID) -> *MacroEntry {
        var rlock = std::SharedLock(self._mu);
        var scope_it = self._global.find(scope);
        if scope_it == self._global.end() { return &null; }
        var it = scope_it->second.find(name);
        if it == scope_it->second.end() { return &null; }
        return it->second;
    }

    /// same-fid lookup with no visibility gate (a file always sees its own).
    fn find_same_fid(self, scope: ModulePath, name: SymbolID, fid: u32) -> *MacroEntry {
        var rlock = std::SharedLock(self._mu);
        var scope_it = self._global.find(scope);
        if scope_it == self._global.end() { return &null; }
        var it = scope_it->second.find(name);
        if it == scope_it->second.end() { return &null; }
        if it->second->source_fid != fid { return &null; }
        return it->second;
    }

    /// undef! builtin support.
    fn undef(self, scope: ModulePath, name: SymbolID) -> bool {
        var wlock = std::UniqueLock(self._mu);
        var scope_it = self._global.find(scope);
        if scope_it == self._global.end() { return false; }
        return scope_it->second.erase(name) > 0;
        // entry stays owned by _by_fid; it just stops resolving.
    }

    /// Total live entries. Grows only if a reparse re-registers without the
    /// matching forget_fid, so a reparse loop can watch it for exactly that.
    fn size(self) -> usize {
        var rlock = std::SharedLock(self._mu);
        var n: usize = 0;
        for fid_entry in self._by_fid { n += fid_entry.second.size(); }
        return n;
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
        var wlock = std::UniqueLock(self._mu);

        var it = self._by_fid.find(fid);
        if it == self._by_fid.end() { return 0; }

        var n: usize = 0;
        for e in it->second {
            if e == &null { continue; }

            // Unpublish before destroying   _global holds a borrowed pointer
            // and would otherwise resolve to freed memory.
            var scope_it = self._global.find(e->scope);
            if scope_it != self._global.end() {
                var g = scope_it->second.find(e->name_sym);
                if (g != scope_it->second.end()) && (g->second == e) {
                    scope_it->second.erase(e->name_sym);
                }
            }

            std::destroy(e);
            n += 1;
        }

        self._by_fid.erase(it);
        return n;
    }

    fn clear(self) {
        var wlock = std::UniqueLock(self._mu);
        for fid_entry in self._by_fid {
            for e in fid_entry.second { std::destroy(e); }
        }
        self._by_fid.clear();
        self._global.clear();
    }

    fn op delete (self) { self.clear(); }
}