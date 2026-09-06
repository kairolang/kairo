/// --- The Kairo Project --------------- Sema/Resolve/ResolutionTrace.k --- ///
///
///   \brief An ordered record of every scope, declaration and binding
///          decision NameResolution made, for `--print-sema`.
///
///   \detail
///     The AST records the RESULT of name resolution (`resolved_decl`,
///     `candidate_cell`) but not the REASONING: which lexical frame answered,
///     whether the DC chain or the import overlay did, and above all what a
///     binding HID. Shadowing leaves no trace on the tree at all   the outer
///     decl is simply never consulted   so a reader staring at a surprising
///     `resolved_decl` has no way to see the decl that lost.
///
///     N is the only component that knows: the lexical stack lives inside the
///     pass and is gone the instant it returns. So N writes what it decided
///     here, as it decides it, and SemaDump renders it.
///
///   \par Off by default
///     Recording is gated on `enabled`, set once at SemaContext construction
///     from `--print-sema`. Every push_* is a no-op otherwise, so an ordinary
///     compile pays one predictable branch per name and allocates nothing.
///     NOTHING in the compiler may READ this to make a decision: it is an
///     observation log, and a pass that behaves differently under
///     `--print-sema` is a pass that cannot be debugged with it.
///
///   \par Flat, not nested
///     Rows are a pre-order stream with an explicit depth, the same shape a
///     tree printer wants and the cheapest thing for a hot pass to append to.
///     ScopeOpen/ScopeClose bracket each lexical frame; Declare and Use rows
///     sit at the depth of the frame that owned them.
///
///   Phase: LOWER (component; written by N, read by SemaDump)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::DeclContext::*;
import AST::Node::Base::*;
import Location::SourceLocation::*;

/// \enum MemberOutcome
/// \brief What ChainBinding decided about one chain step. Joined onto N's
///        Member row by SemaDump via the step's location, so the scopes
///        section still reads in source order.
enum MemberOutcome derives u8 {
    None = 0,        ///< ChainBinding did not run (phase stopped before T).
    Bound,           ///< resolved_decl set.
    Candidates,      ///< candidate_cell set; overload resolution picks.
    NeedsInference,  ///< base has no declared type (inferred var, call result).
    Dependent,       ///< base is rooted in a generic param; M2 owns it.
    Errored,         ///< diagnosed here.
    Foreign,         ///< behind an ffi anchor: clang resolves it, not us.
}

/// \class MemberResult
class MemberResult {
    pub var outcome:  MemberOutcome = MemberOutcome::None;
    pub var decl:     *Decl         = &null;   ///< Bound.
    pub var ncand:    usize         = 0;       ///< Candidates.
    pub var found_in: *Decl         = &null;   ///< the type/module that answered.
    fn MemberResult(self) { }
}

/// \enum TraceVia
/// \brief WHICH of N's three lookup sources answered. This is the column a
///        reader checks first when a name bound to the wrong thing.
enum TraceVia derives u8 {
    None = 0,   ///< no lookup happened (a Declare row).
    Local,      ///< a lexical frame: body local, param, generic or binder.
    Scope,      ///< a dc_symbols table on the cur_dc parent chain.
    Overlay,    ///< the TU import overlay (an imported name).
    Miss,       ///< nothing found anywhere; diagnosed as undeclared.
}

/// \enum TraceScopeKind
/// \brief What kind of lexical frame a ScopeOpen row opened. Frames are the
///        construct-level scopes N pushes, NOT DeclContexts   a class body
///        never appears here because it has a table, not a frame.
enum TraceScopeKind derives u8 {
    Function = 0,
    Closure,
    Block,
    ForBody,
    CatchArm,
    MatchArm,
    ContextBinding,
}

/// \enum TraceMemberKind
/// \brief What a deferred chain step named. Steps have no single spelling in
///        common: `.x` is an identifier, `.0` an ordinal, `Foo::op+` a token
///        pair, so the renderer has to be told which one to read.
enum TraceMemberKind derives u8 {
    Name = 0,   ///< `.x`   -- `name` holds the imm.
    Operator,   ///< `op+`  -- no imm; the spelling lives on the AST step.
    TupleIndex, ///< `.0`   -- `index` holds the ordinal.
}

/// \enum TraceSep
/// \brief The access operator that reached a step. Mirrors
///        ChainExpr::AccessKind, duplicated rather than imported so the
///        trace stays a leaf that depends on nothing but Decl and locations.
enum TraceSep derives u8 {
    Dot = 0,        ///< `.`
    Arrow,          ///< `->`
    ColonColon,     ///< `::`
    QuestionDot,    ///< `?.`
    QuestionArrow,  ///< `?->`
}

/// \enum TraceRowKind
enum TraceRowKind derives u8 {
    ScopeOpen = 0,
    ScopeClose,
    Declare,    ///< a name entered a lexical frame.
    Use,        ///< a name use was resolved (or missed).
    Member,     ///< a chain step N deliberately did NOT bind (needs T).
}

///
/// \class TraceRow
/// \brief One recorded decision. A single wide row rather than a variant per
///        kind: the whole structure exists to be printed, the row count is
///        bounded by the size of the TU's bodies, and a tagged union here
///        would buy nothing but ceremony.
///
class TraceRow {
    pub var kind:  TraceRowKind = TraceRowKind::ScopeOpen;
    pub var depth: usize        = 0;      ///< lexical frame depth, for indent.

    // -- ScopeOpen ---------------------------------------------------------
    pub var scope_kind: TraceScopeKind = TraceScopeKind::Block;
    pub var owner:      *Decl          = &null;  ///< fn/closure decl, if any.
    /// The TABLE-owning scope this frame sits in (N's cur_dc). Frames nest
    /// inside DeclContexts without being ones, so a `fn` row needs this to
    /// say which class it belongs to.
    pub var enclosing:  *DeclContext   = &null;

    // -- Declare + Use -----------------------------------------------------
    pub var name: u32         = u32(-1); ///< imm of the spelled name.
    pub var at:   SourceRange;           ///< where it was written.

    /// Declare: the decl that entered the frame.
    /// Use:     the decl the use bound to (null when deferred or missed).
    pub var decl: *Decl = &null;

    /// The binding this row HID, and where that one lived. Null when nothing
    /// was hidden. On a Declare this is the outer decl the new name shadows;
    /// on a Use it is the decl the NEXT source out would have answered with,
    /// which is what makes a surprising binding readable.
    pub var shadowed:          *Decl        = &null;
    pub var shadowed_via:      TraceVia     = TraceVia::None;
    pub var shadowed_found_in: *DeclContext = &null; ///< scope it lived in.

    // -- Member ------------------------------------------------------------
    // A step after the first `.`/`::`. N records it WITHOUT resolving it:
    // picking the member needs the type of the base, which does not exist
    // until T. The row exists so the dump can say "deferred", because the
    // alternative reading of a missing row is "never seen", and those two
    // are the same picture with very different causes.
    pub var member_kind: TraceMemberKind = TraceMemberKind::Name;
    pub var sep:         TraceSep        = TraceSep::Dot;
    pub var index:       u32             = 0;   ///< TupleIndex ordinal.

    // -- Use ---------------------------------------------------------------
    pub var via:       TraceVia     = TraceVia::None;
    pub var found_in:  *DeclContext = &null; ///< the scope that answered (Scope).
    pub var frame:     usize        = 0;     ///< frame index that answered (Local).
    pub var cell_size: usize        = 0;     ///< >0: deferred overload set.
    pub var poisoned:  bool         = false; ///< diagnosed at this use.

    /// Use + Miss: the miss was ALLOWED by the bare-ffi gate rather than
    /// diagnosed (IMPORTS.md §5). Temporary; goes with the gate.
    pub var foreign_gate: bool = false;

    fn TraceRow(self) { }
}

///
/// \class ResolutionTrace
/// \brief The append-only row stream, plus the enable flag.
///
class ResolutionTrace {
    pub var enabled: bool = false;
    pub var rows:    vec::<TraceRow>;
    /// Frame depth as N sees it. Maintained here rather than passed in at
    /// every call so the pass cannot drift from the log.
    priv var _depth: usize = 0;
    /// step location id -> outcome. Written by ChainBinding, read by SemaDump.
    pub var member_results: libcxx::unordered_map::<u32, MemberResult>;

    fn ResolutionTrace(self) { }

    fn depth(self) -> usize { return self._depth; }

    fn open_scope(self, k: TraceScopeKind, owner: *Decl, at: SourceRange,
                  enclosing: *DeclContext) {
        if !self.enabled { return; }
        var r = TraceRow{};
        r.kind       = TraceRowKind::ScopeOpen;
        r.depth      = self._depth;
        r.scope_kind = k;
        r.owner      = owner;
        r.at         = at;
        r.enclosing  = enclosing;
        self.rows.push_back(r);
        self._depth += 1;
    }

    fn close_scope(self) {
        if !self.enabled { return; }
        if self._depth > 0 { self._depth -= 1; }
        var r = TraceRow{};
        r.kind  = TraceRowKind::ScopeClose;
        r.depth = self._depth;
        self.rows.push_back(r);
    }

    fn declare(self, imm: u32, d: *Decl, at: SourceRange,
               shadowed: *Decl, shadowed_via: TraceVia, shadowed_in: *DeclContext) {
        if !self.enabled { return; }
        var r = TraceRow{};
        r.kind              = TraceRowKind::Declare;
        r.depth             = self._depth;
        r.name              = imm;
        r.at                = at;
        r.decl              = d;
        r.shadowed          = shadowed;
        r.shadowed_via      = shadowed_via;
        r.shadowed_found_in = shadowed_in;
        self.rows.push_back(r);
    }

    fn use_site(self, imm: u32, at: SourceRange, bound: *Decl, via: TraceVia,
                found_in: *DeclContext, frame: usize, cell_size: usize,
                poisoned: bool, shadowed: *Decl, shadowed_via: TraceVia,
                shadowed_in: *DeclContext, foreign_gate: bool = false) {
        if !self.enabled { return; }
        var r = TraceRow{};
        r.kind              = TraceRowKind::Use;
        r.depth             = self._depth;
        r.name              = imm;
        r.at                = at;
        r.decl              = bound;
        r.via               = via;
        r.found_in          = found_in;
        r.frame             = frame;
        r.cell_size         = cell_size;
        r.poisoned          = poisoned;
        r.foreign_gate      = foreign_gate;
        r.shadowed          = shadowed;
        r.shadowed_via      = shadowed_via;
        r.shadowed_found_in = shadowed_in;
        self.rows.push_back(r);
    }

    /// Record a chain step N is handing to T. Deliberately takes no decl and
    /// no via: there is no lookup here to report, and a row that carried one
    /// would invite a reader to believe N had an opinion about the member.
    fn member_step(self, imm: u32, at: SourceRange, mk: TraceMemberKind,
                   sep: TraceSep, index: u32) {
        if !self.enabled { return; }
        var r = TraceRow{};
        r.kind        = TraceRowKind::Member;
        r.depth       = self._depth;
        r.name        = imm;
        r.at          = at;
        r.member_kind = mk;
        r.sep         = sep;
        r.index       = index;
        self.rows.push_back(r);
    }

    fn member_result(self, loc_id: u32, outcome: MemberOutcome, decl: *Decl,
                     ncand: usize, found_in: *Decl) {
        if !self.enabled { return; }
        var r = MemberResult{};
        r.outcome  = outcome;
        r.decl     = decl;
        r.ncand    = ncand;
        r.found_in = found_in;
        self.member_results[loc_id] = r;
    }

    fn member_result_for(self, loc_id: u32) -> *MemberResult {
        var it = self.member_results.find(loc_id);
        if it == self.member_results.end() { return &null; }
        return &(it->second);
    }

    fn empty(self) -> bool { return self.rows.empty(); }
}
