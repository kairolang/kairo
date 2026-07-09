/// --- The Kairo Project --------------------- AST/Mixin/Redeclarable.k --- ///
///
///   CRTP mixin for declarations that can be redeclared: forward decl +
///   definition, out-of-line method defs (fn Class::method), reopened
///   modules. Models a circular singly-linked list of redeclarations with
///   a stable canonical (first-seen) decl, mirroring Clang's Redeclarable<T>
///   but with typed *T links so sema avoids *Decl round-trip casts.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// CRTP mixin: concrete decl `T` derives Redeclarable::<T> to gain a
/// redeclaration chain. Links are typed *T.
///
/// Invariants:
///   - A freshly created decl is its own canonical and its own only link:
///     `_redecl_next == self`, `_redecl_canonical == self`.
///   - `_redecl_canonical` always points at the first-seen declaration
///     (the one that owns the "definition wins" merge target).
///   - `_redecl_next` forms a circular list; walking it returns to self.
///   - Exactly one link in a chain may be a definition (has_body / is
///     a completed type). `is_this_definition` marks it.
///
/// The parser/indexer calls `set_prev(existing)` when it parses a decl whose
/// name already resolved to a prior declaration of the same entity.
class <T> Redeclarable {
    priv var _redecl_next:       *T   = &null; ///< circular list; self when alone.
    priv var _redecl_canonical:  *T   = &null; ///< first-seen decl in the chain.
    pub  var is_this_definition: bool = false; ///< true on the one defining link.

    /// Initialize as a standalone chain of one. MUST be called by create().
    fn init_redecl(self) {
        var me = static_cast::<*T>(&self);
        self._redecl_next      = me;
        self._redecl_canonical = me;
    }

    /// The first-seen declaration. Stable identity for the entity; sema keys
    /// merged attributes / lookup results on &self.
    fn canonical_decl(self) -> *T {
        return self._redecl_canonical;
    }

    fn is_canonical(self) -> bool {
        return static_cast::<*T>(&self) == self._redecl_canonical;
    }

    /// The most recently parsed redeclaration. Walks the circular list back
    /// to the link whose next is the canonical.
    fn most_recent_decl(self) -> *T {
        var cur = self._redecl_canonical;
        if cur == &null {
            return static_cast::<*T>(&self);
        }
        while cur->_redecl_next != self._redecl_canonical {
            cur = cur->_redecl_next;
        }
        return cur;
    }

    /// Link `self` as a redeclaration following `prev`. Inherits prev's
    /// canonical and splices into its circular list. `self` must be a
    /// fresh single-element chain (post init_redecl).
    fn set_prev(self, prev: *T) {
        var me = static_cast::<*T>(&self);
        self._redecl_canonical = prev->_redecl_canonical;

        // splice: find prev's tail (the link whose next is canonical),
        // insert self between tail and canonical so most_recent stays correct.
        var tail = prev->_redecl_canonical;
        while tail->_redecl_next != prev->_redecl_canonical {
            tail = tail->_redecl_next;
        }
        
        tail->_redecl_next = me;
        self._redecl_next  = prev->_redecl_canonical;
    }

    /// True if any link in the chain is a definition.
    fn has_definition(self) -> bool {
        var cur = self._redecl_canonical;
        if cur == &null { return self.is_this_definition; }
        var start = cur;
        while true {
            if cur->is_this_definition { return true; }
            cur = cur->_redecl_next;
            if cur == start { break; }
        }
        return false;
    }

    /// The defining link, or null if the entity is only forward-declared.
    fn definition(self) -> *T {
        var cur = self._redecl_canonical;
        if cur == &null { return &null; }
        var start = cur;
        while true {
            if cur->is_this_definition { return cur; }
            cur = cur->_redecl_next;
            if cur == start { break; }
        }
        return &null;
    }

    /// Mark this link as the definition. Asserts no other link already is
    /// (redefinition is a sema error, caught with full context there; here
    /// we only guard the AST invariant in debug).
    fn mark_definition(self) {
        assert((!self.has_definition()) && r"Redeclarable: two definitions in one chain");
        self.is_this_definition = true;
    }
}