/// --- The Kairo Project ------------------ AST/Context/ImportOverlay.k --- ///
///
///   The TU-level import overlay: this-TU-keyed map of imported names to
///   multi-target entries. Built by Sema/ImportResolution (phase I), read
///   LAST in unqualified lookup (Sema/NameLookup primitive 2), after the DC
///   parent chain so a local decl always shadows an imported one.
///
///   Ownership: a this-TU arena structure that REFERENCES source cells/decls,
///   never copies and never owns foreign cells (all arenas stay alive under
///   GlobalDisambigTable). See Sema/RESOLUTION.md §2 "I ImportResolution"
///   (overlay cells are thin and MULTI-TARGET) and hard invariant #2.
///
///   Layer: AST/Context. Imports AST only never Sema (cycle rule, mirrors
///   SymbolTable / NameLookup direction).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/MapVector.h";
ffi "c++" import "llvm/Support/Allocator.h";
import AST::Node::Base::*;
import AST::Context::SymbolTable::*;

/// \enum OverlayVisibility
/// \brief The visibility FACT carried on an overlay target the fact I records
///        and N reads to emit "exists but priv/prot" access errors. I never
///        filters by this; it writes presence + the fact, N writes the
///        diagnostic (RESOLUTION.md §2 "import EVERYTHING, carry the fact").
enum OverlayVisibility derives u8 {
    Public = 0,   ///< pub decl / pub edge surface, freely usable.
    Protected,    ///< prot: usable by siblings in the same library; N enforces.
    Private,      ///< priv decl name folded for the "exists but priv" error.
}

/// \enum OverlayTargetKind
/// \brief What an overlay target points at. Function-set targets union into an
///        overload set at resolution; two or more NON-function targets under
///        one key are an ambiguous import (diagnosed in I, never here).
enum OverlayTargetKind derives u8 {
    FunctionSet = 0, ///< target is a source OverloadCell of functions (unionable).
    Type,            ///< a single non-function type/module/etc. decl target.
    ModuleHandle,    ///< a module handle: a Kairo file's ModuleDecl, or one C++ header's under an ffi alias.
}

/// \class OverlayTarget
/// \brief One reference an overlay entry holds. Points into a SOURCE TU's
///        frozen arena (cell) or at a decl; carries the originating import for
///        diagnostics + edge visibility, and the visibility fact N reads.
class OverlayTarget {
    pub var kind:    OverlayTargetKind = OverlayTargetKind::Type;
    pub var cell:    obs::<OverloadCell> = &null;  ///< set iff kind == FunctionSet.
    pub var decl:    obs::<Decl>         = &null;  ///< set for Type/ModuleHandle.
    pub var origin:  obs::<Decl>         = &null;  ///< the source *ImportDecl (typed *Decl to dodge cycle).
    pub var vis:     OverlayVisibility   = OverlayVisibility::Public;
    pub var src_fid: u32                 = 0;      ///< source module fid (for dumps/diagnostics).
    /// A C/C++ tag hidden by an imported ordinary name under the same key
    /// (`struct timezone` beside `extern long timezone`). Kept for dumps,
    /// left out of `merged` and of the ambiguity count. One writer: I.
    pub var hidden:  bool                = false;
}

/// \class OverlayEntry
/// \brief All targets folded under one THIS-TU imm key. Most entries carry a
///        single target; multi-target arises from (a) two imports of the same
///        name, (b) module extension across TUs, (c) a function-set union.
///
/// \details `merged` is a this-TU OverloadCell that ImportResolution fills with
///          the union of every FunctionSet target's decls, so the lookup path
///          (NameLookup primitive 2) can return ONE *OverloadCell unchanged.
///          For a single non-function target `merged` holds that one decl too,
///          keeping every lookup cell-shaped. It is a VIEW built at fold time;
///          the source cells it references are never mutated.
class OverlayEntry {
    pub var targets: vec::<OverlayTarget>;
    pub var merged:  OverloadCell;        ///< unioned candidate view; what lookup returns.
    /// Ambiguous, and every entity in the collision came from a header: C++
    /// reports such a collision only where the name is USED, so I records it
    /// here and N / T emit R016E at the use (IMPORTS.md §5.1). A collision
    /// any Kairo import takes part in is reported by I, at the import.
    pub var lazy:     bool = false;
    pub var reported: bool = false;       ///< I already emitted the eager R016E for this key.

    fn OverlayEntry(self) { }

    fn add_target(self, t: OverlayTarget) {
        self.targets.push_back(t);
    }

    /// Number of DISTINCT non-function entities held. Two or more is the
    /// ambiguous-import condition (diagnosed in I). Used by I to decide, and
    /// by dumps.
    ///
    /// Distinct by decl identity, not target count: `import foo::MyClass`
    /// alongside `import foo::*` folds the same ClassDecl twice, and naming
    /// one entity by two routes is not an ambiguity -- there is nothing for a
    /// reader to choose between.
    fn non_function_count(self) -> usize {
        var seen = vec::<obs::<Decl>>();
        for var i: usize = 0; i < self.targets.size(); ++i {
            // A module handle names a SCOPE, not an entity: two files
            // reopening `module util` are one namespace, and the N headers of
            // one `ffi import ... as h` closure are one foreign scope. Neither
            // is an ambiguity (IMPORTS.md §4.3).
            var k = self.targets[i].kind;
            if (k == OverlayTargetKind::FunctionSet) || (k == OverlayTargetKind::ModuleHandle) { continue; }
            if self.targets[i].hidden { continue; }
            var d = self.targets[i].decl;
            if d == &null { continue; }
            var dup = false;
            for var j: usize = 0; j < seen.size(); ++j {
                if seen[j] == d { dup = true; break; }
            }
            if !dup { seen.push_back(d); }
        }
        return seen.size();
    }

    fn is_ambiguous(self) -> bool { return self.non_function_count() >= 2; }
}

/// \class ImportOverlay
/// \brief THIS-TU imm-keyed map of imported names -> OverlayEntry.
///
/// \details Keyed by the IMPORTING TU's imm indices (hard invariant #2): I
///          re-interns each imported spelling into this TU's imm space once,
///          at fold time, and every subsequent lookup is an integer probe.
///          Read LAST in unqualified lookup so TU-local decls shadow imports.
///          Frozen after I completes (I is the sole writer).
class ImportOverlay {
    /// MapVector: collect_rows walks entries in the order imports folded
    /// them in, and that walk decides which pair the R016 collision names
    /// (_fold_reexports) and the --print-imports order. Insertion order is
    /// the defined rule; bucket order was an accident.
    ///
    /// The key is the u32 imm WIDENED to u64: lookups arrive unguarded, and
    /// u32(-1) is both "no ident" and DenseMap<u32>'s empty key, which
    /// asserts even on a find. Entries live in _arena; entry_for() hands
    /// out pointers that _fold_reexports holds across later entry_for()s.
    priv var _entries: llvm::MapVector::<u64, *OverlayEntry>;
    priv var _arena:   llvm::SpecificBumpPtrAllocator::<OverlayEntry>;
    priv var _frozen:  bool = false;

    fn ImportOverlay(self) {
        self._frozen = false;
    }

    /// Get-or-create the entry for this-TU imm \p key. Write path (I only).
    fn entry_for(self, key: u32) -> *OverlayEntry {
        assert((!self._frozen) && r"ImportOverlay::entry_for after freeze (I is the sole writer)");
        var slot = &(self._entries[static_cast::<u64>(key)]);
        if (*slot) == &null {
            var e = self._arena.Allocate(1);
            libcxx::construct_at(e);
            (*slot) = e;
        }
        return *slot;
    }

    fn has(self, key: u32) -> bool { return self._entries.count(static_cast::<u64>(key)) > 0; }

    fn freeze(self)           { self._frozen = true; }
    /// Writable again, for the one sanctioned late writer: the re-export
    /// fixpoint of an import cycle (ImportResolution::refold_reexports),
    /// which runs while every TU of the cycle is still in phase I.
    fn thaw(self)             { self._frozen = false; }

    /// Targets across every entry: what the fixpoint watches grow.
    fn target_count(self) -> usize {
        var n: usize = 0;
        for var it = self._entries.begin(); it != self._entries.end(); ++it { n += it->second->targets.size(); }
        return n;
    }
    fn is_frozen(self) -> bool { return self._frozen; }

    fn size(self) -> usize { return self._entries.size(); }

    // --- Lookup (read path: NameLookup primitive 2) --------------------------

    /// The unioned candidate cell for this-TU imm \p key, or null if the name
    /// was never imported. Returns the entry's `merged` view so the caller
    /// stays cell-shaped; ambiguity was already diagnosed in I.
    fn lookup_ident(self, key: u32) -> *OverloadCell {
        var it = self._entries.find(static_cast::<u64>(key));
        if it == self._entries.end() { return &null; }
        return &(it->second->merged);
    }

    /// The full entry (targets + visibility facts) for a key, or null. N reads
    /// this for access diagnostics; dumps read it for --print-imports.
    fn entry(self, key: u32) -> *OverlayEntry {
        var it = self._entries.find(static_cast::<u64>(key));
        if it == self._entries.end() { return &null; }
        return it->second;
    }

    // --- Dump support --------------------------------------------------------

    class Row {
        pub var key:   u32;
        pub var entry: obs::<OverlayEntry>;
    }

    fn collect_rows(self, out: ref!(vec::<Row>)) {
        for var it = self._entries.begin(); it != self._entries.end(); ++it {
            var r = Row{};
            r.key   = static_cast::<u32>(it->first);
            r.entry = it->second;
            out.push_back(r);
        }
    }
}
