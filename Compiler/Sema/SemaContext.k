/// --- The Kairo Project -------------------------- Sema/SemaContext.k --- ///
///
///   \brief Durable shared state for all sema passes. Passes borrow a
///          *SemaContext; only the Sema driver (Sema.k) constructs one.
///
///   Structural rule (why this exists as a separate class): the driver must
///   import every pass to schedule them. If passes took *Sema, every pass
///   would import the driver and the driver imports every pass an import
///   cycle hub at the worst possible place. Passes import THIS file and
///   never see the driver.
///
///   Composition, not wrapping: SemaContext HOLDS obs<ASTContext>; it does
///   not forward its API. Reach through sc->ctx for AST services. The only
///   conveniences duplicated here are the ones every pass touches on every
///   node (diag, imm lookups, phase asserts).
///
///   Phase: LOWER (shared by all)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Context::CanonicalTypes::*;
import AST::Node::Base::*;
import AST::Node::CanonicalNodes::*;
import AST::LangItems::*;
import Sema::Check::ConstraintSet::*;
import Sema::Resolve::NameLookup::*;
import Sema::Resolve::ResolutionTrace::*;
import Sema::Resolve::ResolutionState::*;
import Diagnostic::BufferedDiagSink::*;
import Lexer::Immediate::*;
import Config::Invocation::*;
import AST::Context::InstantiationRegistry::*;
import Sema::Foreign::ForeignInstantiate::*;

/// \enum SemaPhase
/// \brief Where the TU is in the RESOLUTION.md pipeline. Monotonically
///        advanced by the driver; passes ASSERT their preconditions against
///        it instead of trusting the schedule ("one error, one home" only
///        works if phase order is enforced, not hoped for).
///
///        P -> I -> E -> V -> N -> T -> checks -> lowerings -> M1 -> M2
enum SemaPhase derives u8 {
    /// Parse done: AST built, dc_symbols frozen, out_of_line collected.
    Parsed = 0,
    /// Phase I done: import_overlay built; TU is self-contained.
    ImportsResolved,
    /// Phase E done: surface normalization applied (requires-desugar; later
    /// macro expansion + eval). Pure AST->AST; runs before N/T so name and
    /// type resolution see canonical syntax. Needs nothing past Parsed.
    Expanded,
    /// Phase V done: structural verification over the expanded tree
    /// (break/continue context, label sanity things that are plainly
    /// illegal without needing names or types). Pure reads, no rewrites.
    Verified,
    /// Phase N done: redecl chains linked, out_of_line attached, every
    /// non-dependent ident bound (resolved_decl set).
    NamesResolved,
    /// Phase T done: every non-dependent Type node canonical.
    TypesResolved,
    /// Signature/shape checks done (operator signatures, conformance
    /// declarations verified, const checks).
    Checked,
    /// Desugar/lowering passes done (extends folded+lowered, match/panic/
    /// eval lowerings applied). Tree is codegen-shaped except generics.
    Lowered,
    /// M1 done: monomorphization usage collection complete.
    MonoCollected,
    /// M2 done: instantiation + dependent conformance. THE sync point;
    /// nothing cross-TU mutates after this.
    Complete,
}

/// \class SemaContext
/// \brief The state every pass borrows. One per TU per sema run.
///
/// \par What lives here vs elsewhere
///   here:        phase, options, diag handle, lang items, resolution state.
///   ASTContext:  arenas, interner, tokens, source mgmt (AST-domain).
///   GlobalDisambig: the canonical type store   BUILD-wide, not TU-wide,
///                because type identity is a pointer comparison and pointers
///                only compare inside one uniquing domain.
///   nodes:       ALL inter-pass results (resolved_decl links, canonical
///                slots, poison bits, redecl chains). Passes communicate
///                through the AST and registries, NEVER through each other.
class SemaContext {
    pub var ctx:       obs::<ASTContext>;
    pub var tu:        obs::<TranslationUnit>;
    pub var g:         obs::<GlobalDisambigTable>;   ///< cross-TU context access (fid -> ctx).
    pub var diag:      obs::<BufferedDiagSink>;
    pub var opts:      SemaOptions;
    pub var phase:     SemaPhase = SemaPhase::Parsed;
    pub var instances: obs::<InstantiationRegistry> = &null;
    /// Fills instances of IMPORTED class templates from clang (MemberLookup's
    /// trigger). Build-wide, owned by CompilerInstance and wired by the driver
    /// after construction; null when nothing imports C++ -- every reader
    /// treats null as "cannot fill", which leaves lookup on the pattern.
    pub var foreign:   obs::<ForeignInstantiate> = &null;

    /// The build's lang items, OWNED by GlobalDisambigTable and observed here.
    /// Per-TU storage was the bug: every TU re-bound them by unqualified name
    /// from its own root, so a file that never mentioned `Vector` had no handle
    /// and one that declared its own shadowed the real one. Filled once, by the
    /// builtin TU between its N and T.
    pub var well_known: obs::<WellKnownDecls> = &null;

    /// THE shared lookup core (N and T both stand on it; see NameLookup.k
    /// for the four primitives and the LookupResult lifetime law).
    pub var lookup: NameLookup;

    /// THE canonical type store. Borrowed from GlobalDisambigTable, NOT owned:
    /// canonical identity is build-wide (see CanonicalTypes.k header).
    pub var types: obs::<CanonicalTypeStore> = &null;

    /// THE bound table: requires-clause conformance constraints keyed by the
    /// OWNER decl (function / type / extension), as
    /// `reinterpret_cast::<u64>(decl)`. Written once by ConstraintExtraction
    /// in the T stage; read by ChainBinding's dependent path (what a `T` in a
    /// body is allowed to see) and, later, by ConformanceChecking.
    ///
    /// Keyed by decl rather than by param because that is the granularity the
    /// clause is written at: one requires clause belongs to one declaration,
    /// and which param each conjunct names is a property of the conjunct.
    pub var bounds: libcxx::unordered_map::<u64, ConstraintSet>;

    /// Demand-driven resolution memo + cycle stack. Per-TU, unsynchronized.
    pub var rstate: ResolutionState;

    /// N's decision log, for `--print-sema`. Recording is enabled once here
    /// and nowhere else; every pass writes to it unconditionally and the
    /// trace itself no-ops when off. READ-ONLY for everyone but SemaDump: a
    /// pass that consults this is a pass whose behavior changes under the flag
    /// meant to explain it.
    pub var trace: ResolutionTrace;

    /// diag->error_count() at construction; errored() reports only errors
    /// sema itself produced (parse errors already gated the run).
    pub var error_count_base: u32 = 0;

    /// Default ctor: leaves the context UNWIRED (null handles, Parsed phase).
    /// Exists so a by-value SemaContext member (e.g. Sema::sc) can be
    /// default-constructed and then assigned the wired form below. A pass must
    /// never run against a default-constructed context the driver always
    /// assigns SemaContext(ctx, g) before scheduling any stage.
    fn SemaContext(self) {
        self.ctx        = &null;
        self.g          = &null;
        self.tu         = &null;
        self.diag       = &null;
        self.types      = &null;
        self.instances  = &null;
        self.well_known = &null;
        self.phase     = SemaPhase::Parsed;
        self.error_count_base = 0;
    }

    fn SemaContext(self, ctx: *ASTContext, g: *GlobalDisambigTable) {
        self.ctx   = ctx;
        self.g     = g;
        self.tu    = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        self.diag  = &(ctx->diag_sink);
        self.phase = SemaPhase::Parsed;
        self.opts.load(ctx->ci);
        self.lookup.init(self.tu);

        // The store is build-wide and idempotently initialized, so every TU
        // may ask; the first caller wins and the rest are a locked bool read.
        // Pointer width comes from the target, which is the only thing about a
        // builtin that is not fixed by its own name.
        if g != &null {
            self.instances  = g->instances();
            self.types      = g->types();
            self.well_known = g->well_known();
            var pbits: usize = 64;
            if ctx->ci != &null { pbits = ctx->ci->target.pointer_width; }
            if pbits == 0 { pbits = 64; }
            self.types->init(pbits);
        }

        if ctx->ci != &null {
            self.rstate.set_max_depth(static_cast::<usize>(ctx->ci->frontend.max_scope_depth));
        }

        // Tracing costs one branch per name when off, so it is gated on the
        // only flag that reads it rather than on a build mode.
        if ctx->ci != &null { self.trace.enabled = ctx->ci->frontend.print_sema; }
        self.error_count_base = self.diag->error_count();
    }

    // --- Phase discipline -----------------------------------------------------

    /// Passes call this first thing in run(). Firing it means the driver
    /// schedule and the pass's precondition disagree a bug in Sema.k,
    /// never in the pass.
    fn require_phase(self, min: SemaPhase) {
        assert((static_cast::<u8>(self.phase) >= static_cast::<u8>(min))
               && r"SemaContext: pass ran before its precondition phase (driver schedule bug)");
    }

    /// Driver-only. Monotonic.
    fn advance_phase(self, p: SemaPhase) {
        assert((static_cast::<u8>(p) > static_cast::<u8>(self.phase))
               && r"SemaContext: phase must advance monotonically");
        self.phase = p;
    }

    // --- Conveniences (the every-node-hot ones only) --------------------------

    fn imm_table(self) -> *ImmediateTable {
        return self.ctx->get_imm_table();
    }

    /// Shorthand for the single most-requested canonical.
    fn builtin(self, b: BuiltinKind) -> *Type {
        if self.types == &null { return &null; }
        return self.types->builtin(b);
    }

    /// Errors produced since sema began.
    fn error_delta(self) -> u32 {
        return self.diag->error_count() - self.error_count_base;
    }

    fn errored(self) -> bool {
        return self.error_delta() > 0;
    }
}