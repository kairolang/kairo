/// --- The Kairo Project --------------------------------- Sema/Sema.k --- ///
///
///   \brief The sema DRIVER: entry point, pass schedule, phase gates.
///
///   This class holds STATE AND SCHEDULE ONLY zero semantic logic. Every
///   time a check_* / resolve_* helper wants to land here, it is either a
///   pass (own file, borrows *SemaContext, RAV/ASTWriter for traversal) or
///   a component on SemaContext (like the shared lookup core). That single
///   discipline is what separates this design from Clang's Sema, which
///   grew into a 50k-line method soup nobody can instantiate a piece of.
///
///   Passes communicate ONLY through the AST (resolved links, type_ slots,
///   poison bits, redecl chains) and registries never through each other.
///
///   API shape mirrors ASTParse: construct with the context handles, then
///   one entry call. run() is the parse() analog; run_to() exists for
///   tests and IDE partial runs.
///
///     var sem = Sema(ctx, g_scope);
///     if !sem.run() { /* diags already emitted */ }
///
///   Phase: DRIVER
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::ImportResolution::*;
import AST::Context::ASTContext::*;
import AST::Context::GlobalDisambigTable::*;

// Pass imports land here as each pass becomes real, e.g.:
//   import Sema::NameResolution::*;
//   import Sema::TypeChecking::*;
// The driver is the ONLY file that imports passes; passes import
// SemaContext and never this file (import-cycle rule, see SemaContext.k).

class Sema {
    pub var sc: SemaContext;

    /// Mirrors ASTParse's ctor: wire handles, no work. ctx->tu must be a
    /// fully parsed TranslationUnit (dc_symbols frozen, out_of_line
    /// collected) i.e. ASTParse::parse() returned it.
    fn Sema(self, ctx: *ASTContext, g: *GlobalDisambigTable) {
        self.sc = SemaContext(ctx, g);
    }

    // --- Entry points ---------------------------------------------------------

    /// Full pipeline: I -> N -> T -> checks -> lowerings -> M1 -> M2.
    /// Returns false if a hard gate stopped the run; diagnostics are
    /// already in the sink either way.
    fn run(self) -> bool {
        return self.run_to(SemaPhase::Complete);
    }

    /// Run up to and including \p target. Partial runs are for tests and
    /// IDE queries (hover needs N, not codegen lowering). Each stage
    /// advances sc.phase; a re-entrant call continues from the current
    /// phase rather than re-running completed stages.
    fn run_to(self, target: SemaPhase) -> bool {
        if self.sc.tu == &null { return false; }

        if !self._gate(SemaPhase::Parsed, target) { return self._done(); }
        if !self._stage_imports()                 { return false; }

        if !self._gate(SemaPhase::ImportsResolved, target) { return self._done(); }
        if !self._stage_name_resolution()         { return false; }

        if !self._gate(SemaPhase::NamesResolved, target) { return self._done(); }
        if !self._stage_type_resolution()         { return false; }

        if !self._gate(SemaPhase::TypesResolved, target) { return self._done(); }
        if !self._stage_checks()                  { return false; }

        if !self._gate(SemaPhase::Checked, target) { return self._done(); }
        if !self._stage_lowerings()               { return false; }

        if !self._gate(SemaPhase::Lowered, target) { return self._done(); }
        if !self._stage_mono_collect()            { return false; }

        if !self._gate(SemaPhase::MonoCollected, target) { return self._done(); }
        if !self._stage_mono_instantiate()        { return false; }

        return self._done();
    }

    // --- Gates ----------------------------------------------------------------

    /// True if the pipeline should continue past \p reached toward \p target.
    priv fn _gate(self, reached: SemaPhase, target: SemaPhase) -> bool {
        // already past this stage (re-entrant run_to continuation)?
        if static_cast::<u8>(self.sc.phase) > static_cast::<u8>(reached) { return true; }
        return static_cast::<u8>(target) > static_cast::<u8>(reached);
    }

    /// True if \p done_phase was already reached: the stage is complete
    /// from a previous run_to and must no-op (re-running a stage would
    /// both redo work and trip advance_phase's monotonicity assert).
    priv fn _already(self, done_phase: SemaPhase) -> bool {
        return static_cast::<u8>(self.sc.phase) >= static_cast::<u8>(done_phase);
    }

    priv fn _done(self) -> bool {
        return !self.sc.errored();
    }

    /// Hard error gate between stages. Resolution stages (I/N/T) stop the
    /// pipeline on errors running lowerings over a tree with unresolved
    /// names produces cascade noise, not information. Check/lowering
    /// stages keep going where they can; poisoned nodes carry the state.
    priv fn _hard_stop(self) -> bool {
        return self.sc.errored();
    }

    // --- Stages (schedule only; bodies live in the pass files) ---------------
    //
    // Each stage: run the pass(es), advance the phase, apply the gate
    // policy. As passes land, the TODO line becomes:
    //     ImportResolution(&self.sc).run();

    /// Phase I. PRE: imported TUs parsed + frozen (import-DAG order is the
    /// DRIVER CALLER's job, same begin/finish discipline as
    /// GlobalDisambigTable). POST: tu->import_overlay built; TU self-
    /// contained. Import-existence errors live here, nowhere else.
    priv fn _stage_imports(self) -> bool {
        if self._already(SemaPhase::ImportsResolved) { return true; }
        self.sc.require_phase(SemaPhase::Parsed);
        ImportResolution(&self.sc).run();
        self.sc.advance_phase(SemaPhase::ImportsResolved);
        return !self._hard_stop();
    }

    /// Phase N, two halves one pass. (a) decl validation over frozen
    /// cells: link Redeclarable chains, validate overload sets, group
    /// specializations, attach tu->out_of_line, populate sc.well_known.
    /// (b) binding: every ident/chain-head/pattern-head gets
    /// resolved_decl. Redefinition + unresolved-ident errors live here.
    priv fn _stage_name_resolution(self) -> bool {
        if self._already(SemaPhase::NamesResolved) { return true; }
        self.sc.require_phase(SemaPhase::ImportsResolved);
        // TODO(sema): NameResolution(&self.sc).run();
        self.sc.advance_phase(SemaPhase::NamesResolved);
        return !self._hard_stop();
    }

    /// Phase T. Every non-dependent Type node -> canonical; dependent
    /// types MARKED, not resolved (hard invariant #5). Arity /
    /// unknown-type-name errors live here.
    priv fn _stage_type_resolution(self) -> bool {
        if self._already(SemaPhase::TypesResolved) { return true; }
        self.sc.require_phase(SemaPhase::NamesResolved);
        // TODO(sema): TypeResolution(&self.sc).run();
        self.sc.advance_phase(SemaPhase::TypesResolved);
        return !self._hard_stop();
    }

    /// Signature/shape checks: operator signatures, conformance
    /// declarations, const checks, eval usage. These poison nodes rather
    /// than hard-stopping independent errors should all surface in one
    /// compile.
    priv fn _stage_checks(self) -> bool {
        if self._already(SemaPhase::Checked) { return true; }
        self.sc.require_phase(SemaPhase::TypesResolved);
        // TODO(sema): OperatorSignatureCheck(&self.sc).run();
        // TODO(sema): ConformanceChecking(&self.sc).run();
        // TODO(sema): ConstChecking(&self.sc).run();
        self.sc.advance_phase(SemaPhase::Checked);
        return true;
    }

    /// Desugar/lowering pipeline (ASTWriter passes). Order within this
    /// stage matters pairwise and is owned HERE, in one visible list
    /// not in comments scattered across pass files.
    priv fn _stage_lowerings(self) -> bool {
        if self._already(SemaPhase::Lowered) { return true; }
        self.sc.require_phase(SemaPhase::Checked);
        // TODO(sema): ExtensionLowering(&self.sc).run();     // folds extends
        // TODO(sema): UsingDeclSynthesis(&self.sc).run();    // emits implicit
        //             using Base::name; for merged base overloads C++ would
        //             hide reads type->needs_using written by MemberLookup,
        //             never re-walks bases.
        // TODO(sema): OperatorLowering(&self.sc).run();
        // TODO(sema): MatchLowering(&self.sc).run();
        // TODO(sema): PanicLowering(&self.sc).run();
        // TODO(sema): ...
        self.sc.advance_phase(SemaPhase::Lowered);
        return true;
    }

    /// M1: monomorphization usage collection (parallel-safe).
    priv fn _stage_mono_collect(self) -> bool {
        if self._already(SemaPhase::MonoCollected) { return true; }
        self.sc.require_phase(SemaPhase::Lowered);
        // TODO(sema): Monomorphization::collect(&self.sc);
        self.sc.advance_phase(SemaPhase::MonoCollected);
        return !self._hard_stop();
    }

    /// M2: instantiate + dependent conformance. THE sync point the only
    /// stage allowed to touch cross-TU mutable state.
    priv fn _stage_mono_instantiate(self) -> bool {
        if self._already(SemaPhase::Complete) { return true; }
        self.sc.require_phase(SemaPhase::MonoCollected);
        // TODO(sema): Monomorphization::instantiate(&self.sc);
        // TODO(sema): DependentResolution(&self.sc).run();
        self.sc.advance_phase(SemaPhase::Complete);
        return !self._hard_stop();
    }
}
