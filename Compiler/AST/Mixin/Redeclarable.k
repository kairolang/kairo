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

ffi "c++" import "Native/Types.hh";

/// CRTP mixin: concrete decl `T` derives Redeclarable::<T> to gain a
/// redeclaration chain. Links are typed *T.
///
/// Invariants:
///   - A freshly created decl is its own canonical and its own only link:
///     `_redecl_next == self`, `_redecl_canonical == self`, `_redecl_first
///     == self`.
///   - `_redecl_first` always points at the FIRST-SEEN declaration. It is
///     the ring head and is never repointed after linking; `most_recent_decl`
///     is defined against it, so ring order stays insertion order.
///   - `_redecl_canonical` is the POLICY pointer: "the declaration that
///     represents this entity". It starts as the first-seen decl and is
///     repointed to the definition by NameResolution N(a) via
///     `retarget_canonical` once the whole chain is known. Sema keys merged
///     attributes / lookup results on it.
///   - `_redecl_next` forms a circular list; walking it returns to self.
///   - Exactly one link in a chain may be a definition (has_body / is
///     a completed type). `is_this_definition` marks it.
///
/// The parser/indexer calls `set_prev(existing)` when it parses a decl whose
/// name already resolved to a prior declaration of the same entity.
class <T> Redeclarable {
    priv var _redecl_next:       *T   = &null; ///< circular list; self when alone.
    priv var _redecl_canonical:  *T   = &null; ///< the entity's representative decl.
    priv var _redecl_first:      *T   = &null; ///< first-seen decl; the ring head.
    pub  var is_this_definition: bool = false; ///< true on the one defining link.

    /// Initialize as a standalone chain of one. MUST be called by create().
    fn init_redecl(self) {
        var me = static_cast::<*T>(&self);
        self._redecl_next      = me;
        self._redecl_canonical = me;
        self._redecl_first     = me;
    }

    /// The first-seen declaration. Stable identity for the entity; sema keys
    /// merged attributes / lookup results on &self.
    fn canonical_decl(self) -> *T {
        return self._redecl_canonical;
    }

    fn is_canonical(self) -> bool {
        return static_cast::<*T>(&self) == self._redecl_canonical;
    }

    /// The first-seen declaration and the ring head. Unlike
    /// `canonical_decl()` this NEVER moves, so iteration order over the
    /// chain is stable insertion order for the life of the AST.
    fn first_decl(self) -> *T {
        if self._redecl_first == &null { return static_cast::<*T>(&self); }
        return self._redecl_first;
    }

    /// The most recently parsed redeclaration. Walks the circular list back
    /// to the link whose next is the ring head (the first-seen decl).
    fn most_recent_decl(self) -> *T {
        var head = self._redecl_first;
        if head == &null {
            return static_cast::<*T>(&self);
        }
        var cur = head;
        while cur->_redecl_next != head {
            cur = cur->_redecl_next;
        }
        return cur;
    }

    /// Link `self` as a redeclaration following `prev`. Inherits prev's
    /// chain identity and splices into its circular list. `self` must be a
    /// fresh single-element chain (post init_redecl).
    fn set_prev(self, prev: *T) {
        var me = static_cast::<*T>(&self);
        self._redecl_canonical = prev->_redecl_canonical;
        self._redecl_first     = prev->_redecl_first;

        // splice: find the ring tail (the link whose next is the head),
        // insert self between tail and head so most_recent stays correct.
        var head = prev->_redecl_first;
        var tail = head;
        while tail->_redecl_next != head {
            tail = tail->_redecl_next;
        }

        tail->_redecl_next = me;
        self._redecl_next  = head;
    }

    /// Repoint EVERY link's canonical at \p c. NameResolution N(a) calls this
    /// once per chain, after linking, to make the definition the canonical
    /// decl ("definition if one exists, else first decl"). The ring itself is
    /// untouched, so `first_decl` / `most_recent_decl` keep their meaning.
    ///
    /// Idempotent: re-running N over the same AST recomputes the same target.
    fn retarget_canonical(self, c: *T) {
        if c == &null { return; }
        var head = self._redecl_first;
        if head == &null { return; }
        var cur = head;
        while true {
            cur->_redecl_canonical = c;
            cur = cur->_redecl_next;
            if cur == head { break; }
        }
    }

    /// True if any link in the chain is a definition.
    fn has_definition(self) -> bool {
        var cur = self._redecl_first;
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
        var cur = self._redecl_first;
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
        ICE_IF(self.has_definition(), "Redeclarable: two definitions in one chain");
        self.is_this_definition = true;
    }
}