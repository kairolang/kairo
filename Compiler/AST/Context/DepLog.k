/// --- The Kairo Project ------------------------ AST/Context/DepLog.k --- ///
///
///   The dependency log of one translation unit: what its Sema read of
///   OTHER files, recorded where the read is made
///   (Compiler/Spec/IncrementalSema.md "Dependencies are recorded where they
///   are made").
///
///   Rows are raw: a symbol table's address and the key probed in it, an
///   overlay's address and the key, a declaration's address. Nothing is
///   spelled on the lookup path; Sema/Incremental/DepDump.k turns the rows
///   into (module, scope DeclId, name) at the end of the frontend, while
///   every tree is still alive. The addresses never reach the output.
///
///   One log per TU, written only by the thread running that TU's Sema: the
///   current log is per-thread (Native/KThread.hh sema_dep_log), set by
///   DepLogScope at Sema's entry points. A TU's front runs on a worker and
///   its late part on the driver, never both at once, so no lock.
///
///   Exists only under --dump-deps / --dump-interface. Off, the pointer is
///   null and each chokepoint pays one thread-local load.
///
///   Layer: AST/Context. Imports nothing of the AST, so SymbolTable and
///   ImportOverlay can call it without an import cycle.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "Native/KThread.hh" // sema_dep_log
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import Support::EvalHash::{
    GOLDEN_RATIO_MIX,
    SPLITMIX64_MUL1,
    SPLITMIX64_MUL2,
}

/// \class DepLog
/// \brief One TU's raw reads of other files. See the file header.
pub class DepLog {
    /// The owning TU's address. A probe of one of ITS tables is not a
    /// dependency: an edit to this file re-checks it whatever it read.
    pub var owner: u64 = 0

    /// (table, key) probes of other TUs' symbol tables, hit or miss; the key
    /// is in the table's own TU's space. Insertion-ordered for the dump;
    /// `_seen_*` dedupes. A lookup that misses is a row like any other: the
    /// name staying absent is what the reader depends on.
    pub var  tables:     cxx::std::vector<u64>
    pub var  table_keys: cxx::std::vector<u64>
    priv var _seen_tab:  llvm::DenseSet<u64>

    /// Probes by a spelling the table's TU never interned: provably a miss
    /// today, and the row that makes a later declaration of that name
    /// invalidate this TU. There is no key to store, so the string is kept.
    pub var  spelled_tables: cxx::std::vector<u64>
    pub var  spelled_names:  cxx::std::vector<string>
    priv var _seen_spelled:  llvm::StringMap<u8>

    /// (overlay, key) probes, hit or miss, of any TU's import overlay: this
    /// TU's own for its unqualified names, another's when T reads a node of
    /// an imported file. An overlay is a view of its sources' file scopes;
    /// the dump expands a row to each of them.
    pub var  overlays:     cxx::std::vector<u64>
    pub var  overlay_keys: cxx::std::vector<u64>
    priv var _seen_ov:     llvm::DenseSet<u64>

    /// Declarations whose BODY (or folded initializer) was read: a generic
    /// instantiated, a constant folded through.
    pub var  bodies:     cxx::std::vector<u64>
    priv var _seen_body: llvm::DenseSet<u64>

    fn DepLog(self) { }

    /// A pair has no DenseSet key here, so the dedupe key is a 64-bit mix of
    /// both halves. A collision drops the SECOND row only if both halves
    /// differ and mix alike; `tables` is then missing one row. The mix is
    /// the finalizer of splitmix64 over both words, far past the point where
    /// that is observable, and the alternative is a std::set on every lookup.
    priv static fn _mix(a: u64, b: u64) -> u64 {
        var z = (a ^ (b * GOLDEN_RATIO_MIX)) + GOLDEN_RATIO_MIX
        z = (z ^ z >> 30) * SPLITMIX64_MUL1
        z = (z ^ z >> 27) * SPLITMIX64_MUL2
        var x = z ^ z >> 31
        // DenseSet<u64> reserves ~0 and ~0 - 1.
        if x >= 0xFFFFFFFFFFFFFFFE {
            x = 0
        }

        return x
    }

    pub fn probe(self, root: u64, table: u64, key: u64) {
        if root == self.owner {
            return
        }

        var m = DepLog::_mix(table, key)
        if self._seen_tab.contains(m) {
            return
        }

        self._seen_tab.insert(m)
        self.tables.push_back(table)
        self.table_keys.push_back(key)
    }

    pub fn probe_spelled(self, root: u64, table: u64, const spelling: string) {
        if root == self.owner {
            return
        }

        var k = f"{table}:" + spelling
        if self._seen_spelled.count(kairo::sref(k)) > 0 {
            return
        }

        self._seen_spelled.try_emplace(kairo::sref(k), (1 as u8))
        self.spelled_tables.push_back(table)
        self.spelled_names.push_back(spelling)
    }

    pub fn overlay_probe(self, overlay: u64, key: u64) {
        var m = DepLog::_mix(overlay, key)
        if self._seen_ov.contains(m) {
            return
        }

        self._seen_ov.insert(m)
        self.overlays.push_back(overlay)
        self.overlay_keys.push_back(key)
    }

    pub fn body(self, d: u64) {
        if d == 0 || d >= 0xFFFFFFFFFFFFFFFE {
            return
        }

        if self._seen_body.contains(d) {
            return
        }

        self._seen_body.insert(d)
        self.bodies.push_back(d)
    }
}

/// The log of the TU whose Sema this thread is running, or null.
pub inline fn dep_log_current() -> unsafe *DepLog {
    return unsafe ((*kairo::sema_dep_log()) as unsafe *DepLog)
}

/// \class DepLogScope
/// \brief Makes \p log the thread's current log for the scope, and puts the
///        previous one back: Sema re-enters itself (run() calls run_to()),
///        and the driver runs one TU's stage between another's.
///
/// \note Not copyable in spirit: bind it to a `var` and let it die with the
///       scope, as TimeRegion.
pub class DepLogScope {
    priv var _prev: unsafe *void = &null

    pub fn DepLogScope(self, log: unsafe *DepLog) {
        var unsafe **slot = kairo::sema_dep_log()
        self._prev = *slot
        *slot      = unsafe (log as unsafe *void)
    }

    pub fn op finally(self) {
        var unsafe **slot = kairo::sema_dep_log()
        *slot = self._prev
    }
}
