/// --- The Kairo Project --------------- Sema/Resolve/ResolutionState.k --- ///
///
///   \brief Per-node resolution state and cycle detection for demand-driven
///          resolution. A component on SemaContext, not a pass.
///
///   \detail
///     RESOLUTION.md §2 orders N before T. That ordering is right as a contract
///     between their JOBS and wrong as a hard pass boundary, because the
///     dependency between a name and a type is a genuine CYCLE, not a sortable
///     edge:
///
///         Outer::Inner::make   -- stepping `Inner` needs Outer's KIND.
///         type A = B; B::m     -- stepping `m` needs A EXPANDED, which is T.
///         type A = B; type B = A  -- neither can go first, and that is an
///                                    ERROR the user must be told about.
///
///     So T resolves ON DEMAND: `resolve(node)` recurses into whatever it
///     needs. This class is the memo table that makes that terminate, and the
///     stack that makes a real cycle a diagnostic instead of a hang.
///
///   \par This component DIAGNOSES NOTHING
///     It reports THAT a cycle exists and hands back the stack that formed it.
///     Only the pass knows whether the right message is "circular type alias"
///     or "type contains itself", so the pass owns the diagnostic. That is also
///     why the imports here are AST + Location only -- the same leaf rule
///     NameLookup.k and ResolutionTrace.k follow (see SemaContext.k, cycle
///     rule).
///
///   \par Why a side table and not a field on Decl
///     Three reasons, all specific to this codebase. (1) ast_alloc is reset per
///     stage; a field on Decl survives into stages that must not see it, a map
///     in SemaContext dies with the context. (2) SemaContext is per-TU per-run,
///     so an LSP re-run starts clean without touching the AST. (3) Decl already
///     carries `poisoned`, and a second "already done" bit on the node is a
///     second source of truth that can disagree with the first.
///
///   \par Threading
///     One instance per SemaContext, i.e. per TU, and UNSYNCHRONIZED. Correct
///     today: P/N/T are per-TU parallel and each owns its own SemaContext
///     (hard invariant #4). Bolting on intra-TU parallelism means giving this a
///     lock, which is why it is a component with an API rather than two raw
///     maps inlined into the pass.
///
///   Phase: LOWER (component; used from N onward)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Base::*;
import Location::SourceRange::*;

/// \enum ResolveState
/// \brief Where one node is in its own resolution.
///
///        `InProgress` is the load-bearing one: seeing it means the resolver
///        re-entered a node it is already inside, which is a cycle in the
///        USER's program, not a bug in the resolver. A two-state
///        (done/not-done) table cannot tell that apart from "not started" and
///        would recurse forever on `type A = B; type B = A`.
enum ResolveState derives u8 {
    Unresolved = 0, ///< never entered.
    InProgress,     ///< currently on the resolution stack -- re-entry is a cycle.
    Resolved,       ///< finished successfully; the node's own slots are filled.
    Errored,        ///< finished with a diagnosis. Never retried, never re-reported.
}

/// \class ResolveFrame
/// \brief One entry of the active resolution stack, kept so a cycle can be
///        REPORTED rather than merely detected. Without the frames the best
///        possible message is "circular dependency"; with them the pass can
///        name every edge, which is the difference between a usable diagnostic
///        and a shrug.
class ResolveFrame {
    pub var decl: *Decl = &null;        ///< the decl being resolved.
    pub var at:   SourceRange;          ///< where resolution was demanded FROM.

    fn ResolveFrame(self) { }
}

///
/// \class ResolutionState
/// \brief The memo table + the active stack.
///
class ResolutionState {
    priv var _decls: libcxx::unordered_map::<u64, u8>;
    priv var _types: libcxx::unordered_map::<u64, u8>;

    /// The active chain, innermost last. Depth is bounded by _max_depth, not by
    /// the C++ stack: deeply chained aliases recurse hard, and a segfault is a
    /// worse answer than a diagnostic.
    pub var stack: vec::<ResolveFrame>;

    priv var _max_depth: usize = 256;

    fn ResolutionState(self) {
        self._decls.reserve(64);
        self._types.reserve(256);
        self.stack.reserve(16);
    }

    fn set_max_depth(self, d: usize) {
        if d > 0 { self._max_depth = d; }
    }

    fn max_depth(self) -> usize { return self._max_depth; }

    // --- Decl state -----------------------------------------------------------

    fn decl_state(self, d: *Decl) -> ResolveState {
        if d == &null { return ResolveState::Errored; }
        var it = self._decls.find(self._key(reinterpret_cast::<*void>(d)));
        if it == self._decls.end() { return ResolveState::Unresolved; }
        return static_cast::<ResolveState>(it->second);
    }

    fn set_decl_state(self, d: *Decl, s: ResolveState) {
        if d == &null { return; }
        self._decls[self._key(reinterpret_cast::<*void>(d))] = static_cast::<u8>(s);
    }

    /// \brief Claim \p d for resolution, pushing a frame.
    ///
    /// \return true when the caller owns the resolution and MUST call
    ///         finish_decl exactly once. False means one of: already done
    ///         (caller reads the node's slots), already errored (caller stays
    ///         silent -- one error, one home), a cycle, or the depth cap. The
    ///         caller distinguishes those by asking decl_state / cycle_index
    ///         BEFORE calling this.
    fn begin_decl(self, d: *Decl, at: SourceRange) -> bool {
        if d == &null { return false; }
        var st = self.decl_state(d);
        if st != ResolveState::Unresolved { return false; }
        if self.stack.size() >= self._max_depth { return false; }

        self.set_decl_state(d, ResolveState::InProgress);
        var f = ResolveFrame{};
        f.decl = d;
        f.at   = at;
        self.stack.push_back(f);
        return true;
    }

    /// \brief Release \p d. `ok == false` records Errored, which is permanent:
    ///        a decl whose resolution was diagnosed is never re-attempted and
    ///        never re-reported, so a bad alias used fifty times yields one
    ///        error, not fifty.
    fn finish_decl(self, d: *Decl, ok: bool) {
        if d == &null { return; }
        self.set_decl_state(d, (ResolveState::Resolved) if (ok) else (ResolveState::Errored));
        if !self.stack.empty() { self.stack.pop_back(); }
    }

    /// \brief Index of \p d in the active stack, or usize(-1) if absent.
    ///        A hit IS the cycle, and the slice from here to the top is the
    ///        edge list the diagnostic should name.
    fn cycle_index(self, d: *Decl) -> usize {
        if d == &null { return usize(-1); }
        for var i: usize = 0; i < self.stack.size(); ++i {
            if self.stack[i].decl == d { return i; }
        }
        return usize(-1);
    }

    fn in_progress(self, d: *Decl) -> bool {
        return self.decl_state(d) == ResolveState::InProgress;
    }

    fn depth(self) -> usize { return self.stack.size(); }

    fn at_depth_limit(self) -> bool {
        return self.stack.size() >= self._max_depth;
    }

    // --- Type-node state ------------------------------------------------------
    //
    // Separate from decls because a Type node's "done" is cheap to read off the
    // node itself (canonical != null) for the SUCCESS case, but not for the
    // dependent case: a dependent type is legitimately finished with a null
    // canonical (hard invariant #5), and without a state bit the resolver would
    // re-walk it on every reference.

    fn type_state(self, t: *Type) -> ResolveState {
        if t == &null { return ResolveState::Errored; }
        var it = self._types.find(self._key(reinterpret_cast::<*void>(t)));
        if it == self._types.end() { return ResolveState::Unresolved; }
        return static_cast::<ResolveState>(it->second);
    }

    fn set_type_state(self, t: *Type, s: ResolveState) {
        if t == &null { return; }
        self._types[self._key(reinterpret_cast::<*void>(t))] = static_cast::<u8>(s);
    }

    fn type_done(self, t: *Type) -> bool {
        var s = self.type_state(t);
        return (s == ResolveState::Resolved) || (s == ResolveState::Errored);
    }

    priv fn _key(self, p: *void) -> u64 {
        return reinterpret_cast::<u64>(p);
    }
}