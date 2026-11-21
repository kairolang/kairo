/// --- The Kairo Project --------------- Sema/Resolve/ResolutionState.k --- ///
///
/// Per-node resolution state and cycle detection for demand-driven
/// resolution. A component on SemaContext, not a pass.
///
///   \detail
///     Compiler/Spec/Pipeline.md#sema-pass-order orders N before T. That ordering is right as a contract
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::DeclFacts::tu_of
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::VisibilityFacts::is_library_tu
import Location::SourceRange::SourceRange

/// Where one node is in its own resolution.
///
///        `InProgress` is the load-bearing one: seeing it means the resolver
///        re-entered a node it is already inside, which is a cycle in the
///        USER's program, not a bug in the resolver. A two-state
///        (done/not-done) table cannot tell that apart from "not started" and
///        would recurse forever on `type A = B; type B = A`.
pub enum ResolveState derives u8 {
    Unresolved = 0, ///< never entered.
    InProgress,     ///< currently on the resolution stack -- re-entry is a cycle.
    Resolved,       ///< finished successfully; the node's own slots are filled.
    Errored,        ///< finished with a diagnosis. Never retried, never re-reported.
}

/// One entry of the active resolution stack, kept so a cycle can be
/// REPORTED rather than merely detected. Without the frames the best
/// possible message is "circular dependency"; with them the pass can
/// name every edge, which is the difference between a usable diagnostic
/// and a shrug.
pub class ResolveFrame {
    pub var decl: unsafe *Decl = &null ///< the decl being resolved.
    pub var at:   SourceRange ///< where resolution was demanded FROM.
    pub var lib:  bool         = false ///< `decl` is builtin or std: not counted against the user's cap.

    fn ResolveFrame(self) { }
}

/// The memo table + the active stack.
pub class ResolutionState {
    priv var _decls: llvm::DenseMap<u64, u8> ///< by address: never a reserved key.
    priv var _types: llvm::DenseMap<u64, u8>

    /// The active chain, innermost last. Depth is bounded by the caps below, not by
    /// the C++ stack: deeply chained aliases recurse hard, and a segfault is a
    /// worse answer than a diagnostic.
    pub var stack: cxx::std::vector<ResolveFrame>

    /// The user's cap (--cmax-scope-depth) bounds the frames of user
    /// declarations; the library's cap bounds the whole stack. A user file
    /// demanding a deep chain inside builtin or std is not refused for the
    /// library's depth, and the stack stays bounded either way.
    priv var _max_depth:   usize = 256
    priv var _lib_depth:   usize = 256
    priv var _user_frames: usize = 0

    fn ResolutionState(self) {
        self._decls.reserve(64)
        self._types.reserve(256)
        self.stack.reserve(16)
    }

    /// `user` caps the user's frames, `lib` the whole stack; a `lib` below
    /// `user` is raised to it.
    fn set_max_depth(self, user: usize, lib: usize) {
        if user > 0 {
            self._max_depth = user
        }

        self._lib_depth = if (lib > self._max_depth) => (lib) else => self._max_depth
    }

    /// The cap that refuses `d`: the library's for a builtin or std
    /// declaration, the user's otherwise.
    fn max_depth_for(self, d: unsafe *Decl) -> usize {
        return if (self._is_lib(d)) => (self._lib_depth) else => self._max_depth
    }

    /// Asked only while the two caps differ, so a build at the default
    /// cap never walks a declaration's scope chain here.
    priv fn _is_lib(self, d: unsafe *Decl) -> bool {
        if d == &null || self._lib_depth == self._max_depth {
            return false
        }

        var unsafe *dc = d->lexical_dc
        if dc == &null {
            dc = d->semantic_dc
        }

        return is_library_tu(tu_of(dc))
    }

    priv fn _refuses(self, lib: bool) -> bool {
        if self.stack.size() >= self._lib_depth {
            return true
        }

        return (!lib) && self._user_frames >= self._max_depth
    }

    /// # Decl state

    fn decl_state(self, d: unsafe *Decl) -> ResolveState {
        if d == &null {
            return ResolveState::Errored
        }

        var it = self._decls.find(self._key(unsafe (d as unsafe *void)))
        if it == self._decls.end() {
            return ResolveState::Unresolved
        }

        return it->second as ResolveState
    }

    /// Private: every move of a decl's state is one of the transitions
    /// below (begin / finish / settle / fail), so Errored stays permanent and
    /// the stack stays paired with InProgress.
    priv fn _set_decl_state(self, d: unsafe *Decl, s: ResolveState) {
        if d == &null {
            return
        }

        self._decls[self._key(unsafe (d as unsafe *void))] = (s as u8)
    }

    /// The only way into Errored outside finish_decl: a demand that
    /// diagnosed `d` without owning its frame (re-entry, a cap, a
    /// cycle closed by someone further up). The frame, if any, stays
    /// its owner's to pop.
    fn fail_decl(self, d: unsafe *Decl) {
        self._set_decl_state(d, ResolveState::Errored)
    }

    /// Claim `d` for resolution, pushing a frame.
    ///
    /// ### Returns
    /// true when the caller owns the resolution and MUST call
    /// finish_decl exactly once. False means one of: already done
    /// (caller reads the node's slots), already errored (caller stays
    /// silent -- one error, one home), a cycle, or the depth cap. The
    /// caller distinguishes those by asking decl_state / cycle_index
    /// BEFORE calling this.
    fn begin_decl(self, d: unsafe *Decl, at: SourceRange) -> bool {
        if d == &null {
            return false
        }

        var st = self.decl_state(d)
        if st != ResolveState::Unresolved {
            return false
        }

        var lib = self._is_lib(d)
        if self._refuses(lib) {
            return false
        }

        self._set_decl_state(d, ResolveState::InProgress)
        var f = ResolveFrame()
        f.decl = d
        f.at   = at
        f.lib  = lib
        self.stack.push_back(f)
        if !lib {
            ++self._user_frames
        }

        return true
    }

    /// Release `d`. `ok == false` records Errored, which is permanent:
    /// a decl whose resolution was diagnosed is never re-attempted and
    /// never re-reported, so a bad alias used fifty times yields one
    /// error, not fifty.
    ///
    ///        Only the frame begin_decl pushed for `d` is popped: a caller
    ///        that finished a decl it never began would otherwise pop its
    ///        CALLER's frame, and every depth and cycle question after that
    ///        is asked of the wrong stack.
    fn finish_decl(self, d: unsafe *Decl, ok: bool) {
        if d == &null {
            return
        }

        eval if defined!(DEBUG) {
            if self.stack.empty() || self.stack.back().decl != d {
                kairo::std::ice_fail(
                    r"ResolutionState: finish_decl without its begin_decl frame on top",
                )
            }
        }

        self.settle_decl(d, ok)
        if (!self.stack.empty()) && self.stack.back().decl == d {
            if !self.stack.back().lib {
                --self._user_frames
            }

            self.stack.pop_back()
        }
    }

    /// Record `d`'s outcome without touching the stack: for a decl
    /// resolved with no frame of its own, because begin_decl refused
    /// it at the depth cap. Leaving it Unresolved instead would let a
    /// later demand resolve, and report, it a second time.
    ///
    ///        Never lowers Errored: a cycle closed below `d`'s frame
    ///        (SC043E on re-entry, every alias of an R035E loop) fails it
    ///        while the outer resolution is still running, and that outer
    ///        resolution's own `ok` must not resurrect it.
    fn settle_decl(self, d: unsafe *Decl, ok: bool) {
        if d == &null || self.decl_state(d) == ResolveState::Errored {
            return
        }

        self._set_decl_state(
            d,
            if (ok) => (ResolveState::Resolved) else => ResolveState::Errored,
        )
    }

    /// Index of `d` in the active stack, or usize(-1) if absent.
    /// A hit IS the cycle, and the slice from here to the top is the
    /// edge list the diagnostic should name.
    fn cycle_index(self, d: unsafe *Decl) -> usize {
        if d == &null {
            return usize::MAX
        }

        for var i: usize = 0; i < self.stack.size(); ++i {
            if self.stack[i].decl == d {
                return i
            }
        }

        return usize::MAX
    }

    fn in_progress(self, d: unsafe *Decl) -> bool {
        return self.decl_state(d) == ResolveState::InProgress
    }

    fn depth(self) -> usize {
        return self.stack.size()
    }

    /// begin_decl(d) would be refused for depth.
    fn at_depth_limit(self, d: unsafe *Decl) -> bool {
        return self._refuses(self._is_lib(d))
    }

    /// # Type-node state
    ///
    /// Separate from decls because a Type node's "done" is cheap to read off the
    /// node itself (canonical != null) for the SUCCESS case, but not for the
    /// dependent case: a dependent type is legitimately finished with a null
    /// canonical (hard invariant #5), and without a state bit the resolver would
    /// re-walk it on every reference.

    fn type_state(self, t: unsafe *Type) -> ResolveState {
        if t == &null {
            return ResolveState::Errored
        }

        var it = self._types.find(self._key(unsafe (t as unsafe *void)))
        if it == self._types.end() {
            return ResolveState::Unresolved
        }

        return it->second as ResolveState
    }

    fn set_type_state(self, t: unsafe *Type, s: ResolveState) {
        if t == &null {
            return
        }

        self._types[self._key(unsafe (t as unsafe *void))] = (s as u8)
    }

    fn type_done(self, t: unsafe *Type) -> bool {
        var s = self.type_state(t)
        return s == ResolveState::Resolved || s == ResolveState::Errored
    }

    priv fn _key(self, p: unsafe *void) -> u64 {
        return p as usize as u64
    }
}
