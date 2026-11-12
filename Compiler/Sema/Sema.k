/// --- The Kairo Project ---------------------------------- Sema/Sema.k --- ///
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
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "cstdlib"
ffi "c++" import "Native/KShims.hh" // purity_inferred_*

import AST::Context::ASTContext::ASTContext
import AST::Context::DepLog::DepLogScope
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import Driver::TUStage::TUStage
import Sema::Check::AttributeCheck::AttributeCheck
import Sema::Check::BaseInitCheck::BaseInitCheck
import Sema::Check::CallConvCheck::CallConvCheck
import Sema::Check::FfiRefReturnCheck::FfiRefReturnCheck
import Sema::Check::ClassAllocatorCheck::ClassAllocatorCheck
import Sema::Check::ClassLifecycle::ClassLifecycle
import Sema::Check::ClosureCaptures::ClosureCaptures
import Sema::Check::ConformanceChecking::ConformanceChecking
import Sema::Check::ConstraintExtraction::ConstraintExtraction
import Sema::Check::ControlFlowAnalysis::ControlFlowAnalysis
import Sema::Check::CtorInitCheck::CtorInitCheck
import Sema::Check::ArrayIndexCheck::ArrayIndexCheck
import Sema::Check::EvalUsageChecking::EvalUsageChecking
import Sema::Check::FeatureGateCheck::FeatureGateCheck
import Sema::Check::FlagGates::FlagGates
import Sema::Check::FnPurityCheck::FnPurityCheck
import Sema::Check::CRTPHookCheck::CRTPHookCheck
import Sema::Check::ForCopyLint::ForCopyLint
import Sema::Check::InitCheck::InitCheck
import Sema::Check::InterfaceComposition::InterfaceComposition
import Sema::Check::MoveCheck::MoveCheck
import Sema::Check::OperatorSignatureCheck::OperatorSignatureCheck
import Sema::Check::PackChecking::PackChecking
import Sema::Check::PanicEffectChecking::PanicEffectChecking
import Sema::Check::ParamPassInference::ParamPassInference
import Sema::Check::PatternChecking::PatternChecking
import Sema::Check::RangeBindingLint::RangeBindingLint
import Sema::Check::ReturnPathCheck::ReturnPathCheck
import Sema::Check::ScopeEscapeCheck::ScopeEscapeCheck
import Sema::Check::ShadowCheck::ShadowCheck
import Sema::Check::ShorthandLint::ShorthandLint
import Sema::Check::TypeCycleCheck::TypeCycleCheck
import Sema::Check::ValueCategoryPass::ValueCategoryPass
import Sema::Check::WhereGuardCheck::WhereGuardCheck
import Sema::Expand::AllocSugarDesugar::AllocSugarDesugar
import Sema::Expand::EvalIfFolding::EvalIfFolding
import Sema::Expand::PrimitiveLimitDesugar::PrimitiveLimitDesugar
import Sema::Expand::RequiresDesugar::RequiresDesugar
import Sema::Lower::CallLowering::CallLowering
import Sema::Lower::CoalesceLowering::CoalesceLowering
import Sema::Lower::CopyMoveLowering::CopyMoveLowering
import Sema::Lower::CtorInitLowering::CtorInitLowering
import Sema::Lower::EnumLayoutLowering::{
    EnumLayoutLowering,
    EnumLayoutQuery,
}
import Sema::Lower::ExprBodyDesugar::ExprBodyDesugar
import Sema::Lower::ExtensionLowering::ExtensionLowering
import Sema::Lower::FStringLowering::FStringLowering
import Sema::Lower::FieldInitLowering::FieldInitLowering
import Sema::Lower::FinallyLowering::FinallyLowering
import Sema::Lower::IterLowering::IterLowering
import Sema::Lower::LabelLowering::LabelLowering
import Sema::Lower::ListLiteralLowering::ListLiteralLowering
import Sema::Lower::MatchLowering::MatchLowering
import Sema::Lower::NarrowedAccessLowering::NarrowedAccessLowering
import Sema::Lower::NullTestLowering::NullTestLowering
import Sema::Lower::NullableTypeLowering::NullableTypeLowering
import Sema::Lower::OperatorLowering::OperatorLowering
import Sema::Lower::PanicLowering::{
    PanicInstances,
    PanicLowering,
}
import Sema::Lower::PatternCompilation::PatternCompilation
import Sema::Lower::RangeLowering::RangeLowering
import Sema::Lower::ScriptLowering::ScriptLowering
import Sema::Lower::SequenceLowering::{
    SequenceCheck,
    SequenceLowering,
}
import Sema::Lower::StringLowering::StringLowering
import Sema::Lower::TupleLowering::TupleLowering
import Sema::Lower::VariantInitLowering::VariantInitLowering
import Sema::Lower::WhereDispatchLowering::WhereDispatchLowering
import Sema::Resolve::AccessCheck::AccessCheck
import Sema::Resolve::ChainBinding::ChainBinding
import Sema::Resolve::ImportResolution::ImportResolution
import Sema::Resolve::NameResolution::NameResolution
import Sema::Resolve::RedeclMerge::RedeclMerge
import Sema::Resolve::TypeResolve::TypeResolution
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::ExprTyper::ExprTyper
import Sema::Verify::ArmOrderCheck::ArmOrderCheck
import Sema::Verify::CxxNameCheck::CxxNameCheck
import Sema::Verify::JumpLabelCheck::JumpLabelCheck
import Sema::Verify::LoopContextCheck::LoopContextCheck
import Sema::Verify::ModulePinCheck::ModulePinCheck
import Sema::Verify::PatternBindingCheck::PatternBindingCheck
import Support::TimeReport::TimeRegion
import std::io

// Pass imports land here as each pass becomes real, e.g.:
//   import Sema::NameResolution::*;
//   import Sema::TypeChecking::*;
// The driver is the ONLY file that imports passes; passes import
// SemaContext and never this file (import-cycle rule, see SemaContext.k).

/// \enum SemaRun
/// \brief Where a Sema is in the steps a driver runs it in, beside
///        `sc.phase`. The phase names the last stage that finished; these are
///        the facts it cannot hold: a stage done in part on purpose (T's
///        pre-pass for an import cycle's lockstep, the typed checks of a split
///        run, which leave the phase at TypesResolved), and a hard stop, after
///        which the phase still names the stage that stopped.
///
///        Running -> TypesPreDone -> FrontDone, in that order, and any of them
///        -> Stopped, which is final: run_to refuses a Stopped Sema, because a
///        continuation would carry it on past its stop (into T over names N
///        could not bind, which is cascade noise by _hard_stop's policy).
///
///        A plain u8: one thread at a time writes it (a pool worker during
///        the front, SemaSlot::run_front), and the driver reads it after the
///        slot's `done` publish, which orders the two.
pub enum SemaRun derives u8 {
    Running = 0,  ///< none of the below yet.
    TypesPreDone, ///< resolve_types_pre ran; ChainBinding may follow.
    FrontDone,    ///< the typed checks before Conformance ran.
    Stopped,      ///< a stage's hard stop ended a run_to.
}

pub class Sema {
    pub var  sc:   SemaContext
    priv var _run: SemaRun = SemaRun::Running
    /// sc.phase when the run stopped; read only once `_run` is Stopped.
    priv var _stop_phase: SemaPhase = SemaPhase::Parsed
    /// The driver runs a TU's typed checks up to ConformanceChecking on
    /// a pool worker, side by side with the other TUs of its import wave, and
    /// ConformanceChecking itself later on the driver thread, in import
    /// order: Conformance makes instances live and walks their bodies, and
    /// which TU gets there first decides where an instance diagnostic is
    /// reported (`use_at`), so it stays serial. With this set, the typed
    /// checks stage stops before Conformance and leaves the phase at
    /// TypesResolved; the next run_to resumes at Conformance.
    pub var split_conformance: bool = false

    pub fn run_state(self) -> SemaRun {
        return self._run
    }

    /// The typed checks before Conformance have run, so a split run that
    /// stopped at TypesResolved stopped there on purpose and continues; one
    /// that stopped earlier hit a hard stop and must not be continued. A
    /// stop after them (a later stage's, phase Typed or past) leaves them run.
    pub fn checks_front_done(self) -> bool {
        if self._run == SemaRun::Stopped {
            return (self._stop_phase as u8) >= (SemaPhase::Typed as u8)
        }

        return self._run == SemaRun::FrontDone
    }

    /// A stage's hard stop ended a run_to. A driver that continues a TU in
    /// steps asks this, not run_to's result, which is also false for
    /// a TU that merely has errors.
    pub fn stopped(self) -> bool {
        return self._run == SemaRun::Stopped
    }

    /// The hard stop T's own gate would have made, for a run that paused at
    /// the end of T (TypesPreDone at TypesResolved) and was then given
    /// errors of T's that a parallel front deferred to the driver
    /// (FrontendAction::_settle_once): the TU stops after T exactly as a
    /// one-thread run, which reported them inside T, stops it. A run past
    /// T, or one already stopped, is left alone.
    pub fn stop_if_types_errored(self) {
        if self._run == SemaRun::TypesPreDone
            && self.sc.phase == SemaPhase::TypesResolved
            && self._hard_stop() {
            self._stop()
        }
    }

    /// The only way into Stopped.
    priv fn _stop(self) -> bool {
        self._stop_phase = self.sc.phase
        self._run        = SemaRun::Stopped
        return false
    }

    /// The forward transitions, one step each: Running -> TypesPreDone ->
    /// FrontDone. A skipped or repeated step is a driver schedule bug (a
    /// second T pre-pass would re-resolve every type; typed checks before it
    /// read types nothing resolved).
    priv fn _advance_run(self, to: SemaRun) {
        eval if defined!(DEBUG) {
            if (to as u8) != (self._run as u8) + 1 || to == SemaRun::Stopped {
                kairo::std::ice_fail(r"Sema: run state must advance one step at a time, and not past a stop")
            }
        }

        self._run = to
    }

    /// The TU's lifecycle facts. A member, not a stage local: the checks
    /// fill the memo and --print-sema reads it after the run returns.
    /// Sema only runs it; readers reach it through sc.lifecycle
    /// (lifecycle_of), never through this field.
    priv var lifecycle: ClassLifecycle

    /// Mirrors ASTParse's ctor: wire handles, no work. ctx->tu must be a
    /// fully parsed TranslationUnit (dc_symbols frozen, out_of_line
    /// collected) i.e. ASTParse::parse() returned it.
    fn Sema(self, ctx: unsafe *ASTContext, g: unsafe *GlobalDisambigTable) {
        // From here on the tree is no longer the parser's (the serializer's
        // gate, TranslationUnit::stage).
        if ctx != &null && ctx->tu != &null {
            ctx->tu->advance(TUStage::Sema)
        }

        self.sc = SemaContext(ctx, g)
        // Only now: `sc` was assigned from a temporary, and the instance
        // keeps `&self.sc` while `sc` keeps `&self.lifecycle`, so both have
        // to be the members' final addresses.
        self.lifecycle.bind(unsafe &self.sc)
        self.sc.lifecycle = unsafe &self.lifecycle
    }

    /// # Entry points

    /// Full pipeline: I -> N -> T -> checks -> lowerings -> M1 -> M2.
    /// Returns false if a hard gate stopped the run; diagnostics are
    /// already in the sink either way.
    pub fn run(self) -> bool {
        return self.run_to(SemaPhase::Complete)
    }

    /// Run up to and including \p target. Partial runs are for tests and
    /// IDE queries (hover needs N, not codegen lowering). Each stage
    /// advances sc.phase; a re-entrant call continues from the current
    /// phase rather than re-running completed stages.
    /// --print-stats (for measuring): the sum of every TU's ast arena, so a
    /// stage that allocates in another TU (an instance's home) still counts.
    priv fn _arena_total(self) -> usize {
        if !self.sc.opts.print_stats || self.sc.g == &null {
            return 0
        }

        var tot: usize = 0
        var fids       = self.sc.g->all_fids()
        for var i: usize = 0; i < fids.size(); ++i {
            var unsafe *c = self.sc.g->get_context(fids[i])
            if c != &null {
                tot += c->ast_alloc.profile().bytes_allocated
            }
        }

        return tot
    }

    priv fn _arena_note(self, const stage: string, before: usize) {
        if !self.sc.opts.print_stats {
            return
        }

        var after = self._arena_total()
        io::eprintln(f"[stats] sema stage {stage}: ast arena +{after - before} B")
    }

    pub fn run_to(self, target: SemaPhase) -> bool {
        // A stop is final: the phase still names the stage that stopped,
        // so a continuation would run the next stage over its errors.
        if self._run == SemaRun::Stopped {
            eval if defined!(DEBUG) {
                kairo::std::ice_fail(r"Sema: run_to on a run a hard stop ended (ask stopped() first)")
            }

            return false
        }

        // A split run's typed checks end short of Typed (the phase stays
        // TypesResolved until Conformance): asked for more than Typed in the
        // same call, the late checks would run before Conformance.
        eval if defined!(DEBUG) {
            if self.split_conformance && self._run != SemaRun::FrontDone
                && (target as u8) > (SemaPhase::Typed as u8) {
                kairo::std::ice_fail(r"Sema: a split run is taken to Typed first, then continued")
            }
        }

        if self.sc.tu == &null {
            return self._stop()
        }

        // --check-past-syntax-errors: a file with syntax errors, or one that
        // imports such a file, is not checked at all (Driver/CompilerRecovery.k).
        // A hard stop, so no driver path carries it on past this.
        if self.sc.ctx != &null && self.sc.ctx->syntax_skipped {
            return self._stop()
        }

        // Every read a pass makes from here on is this TU's
        // (AST/Context/DepLog.k); null, and a no-op, without the dump flags.
        var _deps = DepLogScope(self.sc.tu->dep_log)

        if !self._gate(SemaPhase::Parsed, target) {
            return self._done()
        }

        var _m_imports = self._arena_total()
        if !self._stage_imports() {
            return self._stop()
        }

        self._arena_note("imports", _m_imports)

        if !self._gate(SemaPhase::ImportsResolved, target) {
            return self._done()
        }

        var _m_expand = self._arena_total()
        if !self._stage_expand() {
            return self._stop()
        }

        self._arena_note("expand", _m_expand)

        if !self._gate(SemaPhase::Expanded, target) {
            return self._done()
        }

        var _m_verify = self._arena_total()
        if !self._stage_verify() {
            return self._stop()
        }

        self._arena_note("verify", _m_verify)

        if !self._gate(SemaPhase::Verified, target) {
            return self._done()
        }

        var _m_name_resolution = self._arena_total()
        if !self._stage_name_resolution() {
            return self._stop()
        }

        self._arena_note("name_resolution", _m_name_resolution)

        if !self._gate(SemaPhase::NamesResolved, target) {
            return self._done()
        }

        var _m_type_resolution = self._arena_total()
        if !self._stage_type_resolution() {
            return self._stop()
        }

        self._arena_note("type_resolution", _m_type_resolution)

        if !self._gate(SemaPhase::TypesResolved, target) {
            return self._done()
        }

        var _m_typed_checks = self._arena_total()
        if !self._stage_typed_checks() {
            return self._stop()
        }

        self._arena_note("typed_checks", _m_typed_checks)

        // The panic-set barrier sits between these two (SemaPhase::Typed):
        // the driver takes every TU of an import cycle to Typed, solves
        // their sets (EffectPropagation), then continues each.
        if !self._gate(SemaPhase::Typed, target) {
            return self._done()
        }

        var _m_checks = self._arena_total()
        if !self._stage_checks() {
            return self._stop()
        }

        self._arena_note("checks", _m_checks)

        if !self._gate(SemaPhase::Checked, target) {
            return self._done()
        }

        var _m_lowerings = self._arena_total()
        if !self._stage_lowerings() {
            return self._stop()
        }

        self._arena_note("lowerings", _m_lowerings)

        if !self._gate(SemaPhase::Lowered, target) {
            return self._done()
        }

        var _m_mono_collect = self._arena_total()
        if !self._stage_mono_collect() {
            return self._stop()
        }

        self._arena_note("mono_collect", _m_mono_collect)

        if !self._gate(SemaPhase::MonoCollected, target) {
            return self._done()
        }

        var _m_mono_instantiate = self._arena_total()
        if !self._stage_mono_instantiate() {
            return self._stop()
        }

        self._arena_note("mono_instantiate", _m_mono_instantiate)

        return self._done()
    }

    /// # Gates

    /// True if the pipeline should continue past \p reached toward \p target.
    priv fn _gate(self, reached: SemaPhase, target: SemaPhase) -> bool {
        // already past this stage (re-entrant run_to continuation)?
        if (self.sc.phase as u8) > (reached as u8) {
            return true
        }

        return (target as u8) > (reached as u8)
    }

    /// True if \p done_phase was already reached: the stage is complete
    /// from a previous run_to and must no-op (re-running a stage would
    /// both redo work and trip advance_phase's monotonicity assert).
    priv fn _already(self, done_phase: SemaPhase) -> bool {
        return (self.sc.phase as u8) >= (done_phase as u8)
    }

    priv fn _done(self) -> bool {
        return !self.sc.errored()
    }

    /// Hard error gate between stages. Resolution stages (I/N/T) stop the
    /// pipeline on errors running lowerings over a tree with unresolved
    /// names produces cascade noise, not information. Check/lowering
    /// stages keep going where they can; poisoned nodes carry the state.
    priv fn _hard_stop(self) -> bool {
        // Contained errors (SemaContext::contained_errors) poison their own
        // uses; only the rest stop the pipeline.
        return self.sc.error_delta() > self.sc.contained_errors
    }

    /// # Stages (schedule only; bodies live in the pass files)
    ///
    /// Each stage: run the pass(es), advance the phase, apply the gate
    /// policy. As passes land, the TODO line becomes:
    ///     ImportResolution(&self.sc).run();

    /// Phase I. PRE: imported TUs parsed + frozen (import-DAG order is the
    /// DRIVER CALLER's job, same begin/finish discipline as
    /// GlobalDisambigTable). POST: tu->import_overlay built; TU self-
    /// contained. Import-existence errors live here, nowhere else.
    priv fn _stage_imports(self) -> bool {
        if self._already(SemaPhase::ImportsResolved) {
            return true
        }

        var _t = TimeRegion("Imports")
        self.sc.require_phase(SemaPhase::Parsed)
        ImportResolution(&self.sc).run()
        self.sc.advance_phase(SemaPhase::ImportsResolved)
        return !self._hard_stop()
    }

    /// Phase E. Surface normalization: pure AST->AST rewrites that must run
    /// before N/T so name/type resolution see canonical syntax. PRE: imports
    /// resolved. POST: inline generic bounds hoisted into requires_clause
    /// (the inline lists are empty; requires_clause is the single source of
    /// truth). These passes need nothing past Parsed structurally; they sit
    /// after I only because the schedule is linear. Macro expansion and eval
    /// lowering land here too when implemented.
    priv fn _stage_expand(self) -> bool {
        if self._already(SemaPhase::Expanded) {
            return true
        }

        var _t = TimeRegion("Expand")
        self.sc.require_phase(SemaPhase::ImportsResolved)
        // `@no_warn(CODE)` scopes, before every pass that can warn: a
        // warning inside the declaration is dropped at the sink whichever
        // pass reports it. The codes are validated by AttributeCheck::run.
        {
            var _p = TimeRegion("NoWarnScopes")
            AttributeCheck(unsafe &self.sc).register_suppressions()
        }

        // First: no later pass may see an untaken `eval if` branch (Compiler/Spec/Eval.md#folding-eval-if).
        // The exception is a declaration-scope one on a type fact: it is
        // deferred, V, N, T and RedeclMerge see all of its branches, and
        // EvalIfLateFolding decides it in the T stage (Compiler/Spec/Eval.md#deferred-conditions).
        // Before it: `eval if i32::MAX > N` folds a literal, as every later
        // pass reads one.
        {
            var _p = TimeRegion("PrimitiveLimits")
            PrimitiveLimitDesugar(&self.sc).run()
        }

        // `@create` / `@destroy` are calls of alloc.k's create / destroy:
        // rewritten before N, so the minted callee binds as a written
        // one does and no later pass meets the attribute.
        {
            var _p = TimeRegion("AllocSugar")
            AllocSugarDesugar(&self.sc).run()
        }

        {
            var _p = TimeRegion("EvalIfFolding")
            EvalIfFolding(unsafe &self.sc).run()
        }

        // TODO(sema): MacroExpansion(&self.sc).run();
        var desugar = RequiresDesugar(self.sc.ctx)
        desugar.run(self.sc.tu)
        self.sc.advance_phase(SemaPhase::Expanded)
        return !self._hard_stop()
    }

    /// Phase V. Structural verification over the expanded tree: rules
    /// that are plainly illegal without names or types (break/continue
    /// context, label sanity). Pure reads; poison-free these checks
    /// are independent, so report all of them and keep going. Errors
    /// here still hard-stop before N: a structurally illegal tree is
    /// not worth resolving.
    priv fn _stage_verify(self) -> bool {
        if self._already(SemaPhase::Verified) {
            return true
        }

        var _t = TimeRegion("Verify")
        self.sc.require_phase(SemaPhase::Expanded)

        // Per pass, not one number for the stage. Five independent full-tree
        // walks (and one look at the TU's pin): the whole question here is which of them is worth fusing.
        // Unreachable code is not here: it needs `!` types (ControlFlowAnalysis, in C).
        {
            var _p = TimeRegion("LoopContext")
            LoopContextCheck(&self.sc).run()
        }

        {
            var _p = TimeRegion("ArmOrder")
            ArmOrderCheck(&self.sc).run()
        }

        {
            var _p = TimeRegion("JumpLabel")
            JumpLabelCheck(unsafe &self.sc).run()
        }

        {
            var _p = TimeRegion("PatternBinding")
            PatternBindingCheck(&self.sc).run()
        }

        {
            var _p = TimeRegion("CxxName")
            CxxNameCheck(&self.sc).run()
        }

        {
            var _p = TimeRegion("ModulePin")
            ModulePinCheck(&self.sc).run()
        }

        // Future Verify passes append here, one visible list.
        self.sc.advance_phase(SemaPhase::Verified)
        return !self._hard_stop()
    }

    /// Phase N, two halves one pass. (a) decl validation over frozen
    /// cells: link Redeclarable chains, validate overload sets, group
    /// specializations, attach tu->out_of_line, populate sc.well_known.
    /// (b) binding: every ident/chain-head/pattern-head gets
    /// resolved_decl. Redefinition + unresolved-ident errors live here.
    priv fn _stage_name_resolution(self) -> bool {
        if self._already(SemaPhase::NamesResolved) {
            return true
        }

        var _t = TimeRegion("Names")
        self.sc.require_phase(SemaPhase::Verified)
        var nr = NameResolution(unsafe &self.sc)
        nr.run()
        // Between N and T, and only in the builtin TU: N has bound the names,
        // and T has not yet resolved `[T;]` in `Vector(items: const [T;])` --
        // which needs the Slice handle this fills. Every other TU's call is a
        // fid compare and a return.
        nr.fill_lang_items()
        self.sc.advance_phase(SemaPhase::NamesResolved)
        // N's errors stop the pipeline AFTER T, not here. N poisons every
        // name it could not bind, so T over the rest of the TU is
        // information, and it is what gives the declarations their types:
        // stopped here, one undeclared name in one method BODY left every
        // signature in the TU unresolved, and each importer's call into it
        // failed "parameter type is unresolved" (self-host: a `std::print`
        // in Command::print_help, 363 SC063E on `cmd->define<FlagKind::X>`).
        // T's own gate counts N's errors, so nothing past T runs.
        return true
    }

    /// Phase T. Every non-dependent Type node -> canonical; dependent
    /// types MARKED, not resolved (hard invariant #5). Then the bound table
    /// is built from the requires clauses, and every chain step decidable
    /// from declared types -- or from a parameter's BOUND -- is bound
    /// (ChainBinding: base-walk PRE is T complete, Compiler/Spec/Generics.md#partial-selection).
    /// Arity / unknown-type-name / no-member errors live here.
    priv fn _stage_type_resolution(self) -> bool {
        if self._already(SemaPhase::TypesResolved) {
            return true
        }

        var _t = TimeRegion("Types")
        self.sc.require_phase(SemaPhase::NamesResolved)
        self.resolve_types_pre()
        {
            var _p = TimeRegion("ChainBinding")
            ChainBinding(unsafe &self.sc).run()
        }

        self.sc.advance_phase(SemaPhase::TypesResolved)
        return !self._hard_stop()
    }

    /// Everything of T before ChainBinding, once. Split out for an import
    /// cycle's lockstep (CompilerInstance::_sema_group): ChainBinding walks
    /// OTHER TUs' records -- a base's members through `derives` edges T
    /// resolves -- so every TU of the group runs this first, then each
    /// binds. Run whole per TU, a TU early in the cycle bound `n->range`
    /// before the TU declaring `LabeledStmt derives Stmt` had resolved that
    /// edge, and the base's members were missing (R025E).
    pub fn resolve_types_pre(self) {
        // Ran already (TypesPreDone, FrontDone), or stopped: a stop before T
        // never reaches here (the lockstep asks first), one in T is after it.
        if self._run != SemaRun::Running {
            eval if defined!(DEBUG) {
                if self._run == SemaRun::Stopped && (self._stop_phase as u8) < (SemaPhase::NamesResolved as u8) {
                    kairo::std::ice_fail(r"Sema: T's pre-pass asked of a run stopped before N")
                }
            }

            return
        }

        self._advance_run(SemaRun::TypesPreDone)
        self.sc.require_phase(SemaPhase::NamesResolved)
        var _deps = DepLogScope(self.sc.tu->dep_log)
        {
            var _p = TimeRegion("TypeResolve")
            TypeResolution(unsafe &self.sc).run()
        }

        {
            var _p = TimeRegion("RedeclMerge")
            RedeclMerge(unsafe &self.sc).run()
        }

        // Compiler/Spec/Eval.md#deferred-conditions: the declaration-scope `eval if`s E deferred on a type
        // fact, decided now that every canonical exists and every function
        // chain is linked (RedeclMerge kept sibling branches apart). Before
        // everything that reads a record's members as final --
        // InterfaceComposition, ConstraintExtraction, ChainBinding here, and
        // TypeCycleCheck, ShadowCheck and the rest in the checks -- so none
        // of them sees a discarded branch, and X, the lowerings and codegen
        // see one branch as if E had folded it.
        {
            var _p = TimeRegion("EvalIfLateFolding")
            EvalIfFolding(unsafe &self.sc).run_late()
        }

        // Algebraic interfaces normalized to regular ones, after their leaves
        // resolve and before ChainBinding reads any interface's members.
        {
            var _p = TimeRegion("InterfaceComposition")
            InterfaceComposition(unsafe &self.sc).run()
        }

        // Constraint partition, BEFORE ChainBinding. Desugar already ran in
        // the Expand phase (pure AST rewrite: inline bounds -> requires as
        // ConstraintExpr conjuncts), so requires_clause is canonical; this
        // sorts each conjunct into conformance constraints vs value
        // predicates and files the result in sc.bounds under its owner decl.
        // ChainBinding is a CONSUMER -- what `x.draw()` on an `x: T` may bind
        // to is exactly what T's declaration promised -- so the table has to
        // exist before it walks.
        {
            var _p = TimeRegion("Constraints")
            ConstraintExtraction(&self.sc).run()
        }
    }

    /// Signature/shape checks: operator signatures, conformance
    /// declarations, const checks, eval usage. These poison nodes rather
    /// than hard-stopping independent errors should all surface in one
    /// compile. The first half, everything typing feeds: X and the checks
    /// on its result, through ConformanceChecking. It ends at Typed, the
    /// panic-set barrier (_stage_checks has the second half).
    priv fn _stage_typed_checks(self) -> bool {
        if self._already(SemaPhase::Typed) {
            return true
        }

        var _t = TimeRegion("Checks")
        self.sc.require_phase(SemaPhase::TypesResolved)
        if self._run != SemaRun::FrontDone {
            self._typed_checks_front()
            self._advance_run(SemaRun::FrontDone)
            // The phase stays TypesResolved: run_to's Typed gate then stops
            // here, and the driver's next run_to comes back for Conformance.
            if self.split_conformance {
                return true
            }
        }

        // The rows of every instance this TU names, from its calls' registered
        // instances (ExprTyper). Before the lowerings: ExtensionLowering's
        // witness calls are emitted against them.
        {
            var _p = TimeRegion("Conformance")
            ConformanceChecking(unsafe &self.sc).run()
        }

        // TODO(sema): ConstChecking(&self.sc).run();
        self.sc.advance_phase(SemaPhase::Typed)
        return true
    }

    /// Every typed check before ConformanceChecking, in schedule order.
    priv fn _typed_checks_front(self) {
        // Every attribute means something where it is written, or is an
        // error (unknown, misplaced, a bad argument, not yet supported).
        // Before X: an error here is reported beside, not after, the
        // diagnostics typing produces, and nothing reads an attribute it
        // has rejected (AttrFacts treats a bad `@align` as absent).
        {
            var _p = TimeRegion("AttributeCheck")
            AttributeCheck(unsafe &self.sc).run()
        }

        // Where `ffi::ref<T>` / `ffi::mref<T>` may stand, and an override's
        // return against the C++ virtual's. Before ExprTyper: a
        // misplaced one is rewritten to its referee, so no call types
        // against a reference that is not there.
        {
            var _p = TimeRegion("FfiRefReturn")
            FfiRefReturnCheck(unsafe &self.sc).run()
        }

        // Layout acyclicity. Runs before anything that needs a size:
        // LayoutPass will not terminate on a recursive type, and EmitPlan's
        // `complete` topological sort asserts on a cycle rather than
        // diagnosing one. This pass is where a by-value loop is reported.
        {
            var _p = TimeRegion("TypeCycle")
            TypeCycleCheck(&self.sc).run()
        }

        // Operator declaration rules, BEFORE X: X's derived operators and
        // compound-assignment pairing assume shapes this pass has already
        // rejected (a compound operator with a result, both halves of a pair).
        {
            var _p = TimeRegion("OperatorSignature")
            OperatorSignatureCheck(unsafe &self.sc).run()
        }

        // `op new` / static `op delete`, a class's own allocator, is
        // rejected (SC149E); the destructor's old `op delete` spelling is
        // S090E outside the builtin / std library.
        {
            var _p = TimeRegion("ClassAllocator")
            ClassAllocatorCheck(unsafe &self.sc).run()
        }

        // Where a type pack, a pack parameter and a pack-expanded variant may
        // appear. Before X: it reads only N's names and T's types, and an
        // enum it rejects is poisoned before any pattern or construction is
        // typed against its expansions.
        {
            var _p = TimeRegion("PackChecking")
            PackChecking(unsafe &self.sc).run()
        }

        // Expression typing. After TypeCycleCheck because it asks for sizes
        // and layouts through the canonical store, and a by-value cycle has
        // to be reported before anything walks one.
        {
            var _p = TimeRegion("ExprTyper")
            ExprTyper(unsafe &self.sc).run()
        }

        // ExprTyper assigns value categories inline (overload resolution
        // needs them mid-typing); this verifies that assignment is total and
        // ICEs on a typed expression without one.
        {
            var _p = TimeRegion("ValueCategory")
            ValueCategoryPass(&self.sc).run()
        }

        // Runs late: it REQUIRES ExprTyper to be complete.

        {
            var _p = TimeRegion("ShadowCheck")
            ShadowCheck(unsafe &self.sc).run()
        }

        // `var x = e` whose inferred type is nullable or a pointer, with no
        // shorthand to say so (Compiler/Spec/Nullables.md#declaration-shorthands). REQUIRES ExprTyper: it
        // reads only inferred slots. Before every lowering, so each decl it
        // sees was written by the user.
        {
            var _p = TimeRegion("ShorthandLint")
            ShorthandLint(unsafe &self.sc).run()
        }

        // A write to a by-value `for` binder that nothing reads afterwards:
        // it was meant for the element (SC275W). REQUIRES ExprTyper: reads
        // resolved uses, binder types and the iterable's IterKind.
        {
            var _p = TimeRegion("ForCopyLint")
            ForCopyLint(unsafe &self.sc).run()
        }

        // `var t = a[i..j]` that took a split subscript's place form and is
        // never written through (SC281W). REQUIRES ExprTyper: reads
        // SubscriptExpr::place_ctx and resolved_op.
        {
            var _p = TimeRegion("RangeBindingLint")
            RangeBindingLint(unsafe &self.sc).run()
        }

        // A derived method with a CRTP hook's name and arity but other
        // parameter types: the base's `self.dyn()->hook(x)` still runs the
        // base's (SC278W). REQUIRES TypeResolve's signatures only; the
        // bodies are read for their dyn calls, not their types.
        {
            var _p = TimeRegion("CRTPHookCheck")
            CRTPHookCheck(unsafe &self.sc).run()
        }

        // Exhaustiveness and dead arms; writes MatchStmt / MatchExpr facts.
        // REQUIRES ExprTyper (pattern types, resolved heads, field slots).
        // Before ReturnPathCheck, which reads is_exhaustive.
        {
            var _p = TimeRegion("PatternChecking")
            PatternChecking(unsafe &self.sc).run()
        }

        // Missing return on some path. REQUIRES ExprTyper: a call is a
        // terminator when its type is `!`. REQUIRES PatternChecking: match
        // coverage is MatchStmt::is_exhaustive.
        {
            var _p = TimeRegion("ReturnPath")
            ReturnPathCheck(unsafe &self.sc).run()
        }

        // `const fn` / `@pure` bodies against their promise. REQUIRES
        // ExprTyper: it reads resolved declarations and operand types.
        // Before every lowering, so a user operator or a lowered call is
        // never mistaken for something the user wrote.
        {
            var _p = TimeRegion("FnPurity")
            FnPurityCheck(unsafe &self.sc).run()
        }

        // Where a calling convention may stand. REQUIRES ExprTyper (X writes
        // is_generator); before every lowering, which mints functions (thunks,
        // a lowered closure's operator) that carry none.
        {
            var _p = TimeRegion("CallConv")
            CallConvCheck(unsafe &self.sc).run()
        }

        // A pointer from an open AllocatorScope that visibly outlives it
        // (SC001W). REQUIRES ExprTyper: resolved callees and the types
        // of initializers. Before every lowering, so `@create` is the call it
        // stands for and nothing minted is mistaken for user code.
        {
            var _p = TimeRegion("ScopeEscape")
            ScopeEscapeCheck(unsafe &self.sc).run()
        }

        // Unreachable code (SC003W), on the same divergence rule as
        // ReturnPath (FallThrough). Same REQUIRES; before every lowering, so
        // it warns only on code the user wrote.
        {
            var _p = TimeRegion("ControlFlow")
            ControlFlowAnalysis(unsafe &self.sc).run()
        }

        // A script's top-level `jump!` that crosses a deferred binding's line
        // (Compiler/Spec/ScriptMode.md#control-flow). JumpLabelCheck's own frame rules ran in Verify;
        // this one asks which initializers are constant, a fact of X's types.
        {
            var _p = TimeRegion("ScriptJumps")
            JumpLabelCheck(unsafe &self.sc).run_script_jumps()
        }

        // `where` dispatch groups (where.mdx): what may be guarded, the
        // fallback, member agreement, unreachable and overlapping guards,
        // and the SC116E gates; files each group it passes for
        // WhereDispatchLowering. REQUIRES ExprTyper: guards are typed, and
        // `is_generator` is X's.
        {
            var _p = TimeRegion("WhereGuard")
            WhereGuardCheck(unsafe &self.sc).run()
        }

        // Per-record lifecycle facts (copyable / movable / trivial) and the
        // rules about the lifecycle itself: one transfer ctor, no user
        // `op =`, base/derived category match, the virtual-destructor rule.
        // After ExprTyper only for schedule linearity; it reads declarations
        // and canonicals, never expression types. The instance is Sema's
        // member: MoveCheck below and the dump read the same memo.
        {
            var _p = TimeRegion("ClassLifecycle")
            self.lifecycle.run()
        }

        // `@move` arguments: movability, and use-after-move over each body.
        // REQUIRES ExprTyper complete (promoted callees, typed arguments) and
        // ClassLifecycle (movability).
        // What each closure captures and how (closures.md, Capture Modes):
        // recorded on the ClosureExpr for MoveCheck, FinallyLowering and
        // EmitIR; a binding a named list or `||` leaves out is an error.
        // REQUIRES ExprTyper (bindings, types) and ClassLifecycle (a MOVE
        // capture is moved in).
        {
            var _p = TimeRegion("ClosureCaptures")
            ClosureCaptures(unsafe &self.sc).run()
        }

        {
            var _p = TimeRegion("MoveCheck")
            MoveCheck(unsafe &self.sc).run()
        }

        // Default member initializers read only fields built before them.
        // REQUIRES N's bindings (a bare sibling in a default is a field).
        // pub/priv/prot on every member reference, constructor and nested
        // type (module-wide: a file's functions see its classes' privates).
        // The emitted C++ is all public, so this is the only check.
        // REQUIRES X's selections (the overload, the constructor).
        {
            var _p = TimeRegion("AccessCheck")
            AccessCheck(unsafe &self.sc).run()
        }

        // `@deprecated`: a warning at every use. REQUIRES X's selections
        // (the overload, the constructor, the operator), as AccessCheck.
        {
            var _p = TimeRegion("DeprecatedUses")
            AttributeCheck(unsafe &self.sc).run_uses()
        }

        {
            var _p = TimeRegion("InitCheck")
            InitCheck(unsafe &self.sc).run()
        }

        // Base initializers (`Base::Base(self, ...)`): where one may be, and
        // that every base needing one gets one. REQUIRES X's callee
        // bindings. Before CtorInitCheck, which skips the statements it
        // admits.
        {
            var _p = TimeRegion("BaseInitCheck")
            BaseInitCheck(unsafe &self.sc).run()
        }

        // A const field is initialized exactly once, in its record's
        // constructor, before `self` is used as a whole; the statement that
        // initializes the last one is where the body is cut (ci_split, for
        // CtorInitLowering). REQUIRES N's bindings and X's types (a `-> !`
        // call ends a path). Before FeatureGate, which stays last.
        {
            var _p = TimeRegion("CtorInitCheck")
            CtorInitCheck(unsafe &self.sc).run()
        }

        // A constant index past a fixed array's extent (SC291E). REQUIRES
        // X's types; after CtorInitCheck, whose SC176E says the same of an
        // element write that builds a field and poisons that subscript.
        {
            var _p = TimeRegion("ArrayIndex")
            ArrayIndexCheck(unsafe &self.sc).run()
        }
    }

    /// The second half of the checks, past the panic-set barrier: every
    /// TU this one reaches through imports is Typed and its sets are solved
    /// (or, with no driver table, this TU's are solved here).
    priv fn _stage_checks(self) -> bool {
        if self._already(SemaPhase::Checked) {
            return true
        }

        var _t = TimeRegion("LateChecks")
        self.sc.require_phase(SemaPhase::Typed)

        // Panic effects (Compiler/Spec/Panic.md#effect-sets, §3.1): unhandled calls, declared sets,
        // `main`, the payload rules, try/catch arms. REQUIRES the solved
        // sets (EffectPropagation, at the barrier) and X's callee bindings.
        // Before FeatureGate, which stays last.
        {
            var _p = TimeRegion("PanicEffect")
            PanicEffectChecking(unsafe &self.sc).run()
        }

        // Last: well-typed constructs the lowerings cannot render yet. An
        // error here keeps the schedule out of the lowerings, which ICE on
        // them, and that matters under --type-check-only too.
        // What an eval context may hold (Compiler/Spec/Eval.md#evalusagechecking): REQUIRES X's callee
        // bindings and iter_kind. Before FeatureGate, which stays last.
        {
            var _p = TimeRegion("EvalUsage")
            EvalUsageChecking(unsafe &self.sc).run()
        }

        {
            var _p = TimeRegion("FeatureGate")
            FeatureGateCheck(unsafe &self.sc).run()
        }

        // --no-unsafe / --no-fp / --no-ffi / --cmax-* and friends: the user's
        // own files only, over the tree as written (before any lowering).
        {
            var _p = TimeRegion("FlagGates")
            FlagGates(unsafe &self.sc).run()
        }

        // Decision trees for every match. Last: it reads PatternChecking's
        // facts and reports (SC116E) the two tests it cannot render, and an
        // error anywhere above keeps the schedule out of the lowerings.
        // --print-sema shows the trees.
        {
            var _p = TimeRegion("PatternCompilation")
            PatternCompilation(unsafe &self.sc).run()
        }

        self.sc.advance_phase(SemaPhase::Checked)
        return true
    }

    /// Desugar/lowering pipeline (ASTWriter passes). Order within this
    /// stage matters pairwise and is owned HERE, in one visible list
    /// not in comments scattered across pass files.
    priv fn _stage_lowerings(self) -> bool {
        if self._already(SemaPhase::Lowered) {
            return true
        }

        // No stage region: the driver opens "Lower" around this, and a
        // nested one would only repeat it (Lower.Lowerings.X).
        self.sc.require_phase(SemaPhase::Checked)

        // The head of the stage is VariantInitLowering, then
        // EnumLayoutLowering, then ExprBodyDesugar, FieldInitLowering,
        // CtorInitLowering and CopyMoveLowering, then ScriptLowering,
        // PanicLowering and FinallyLowering, and the rest after them.
        //
        // First: a variant construction becomes the node EmitIR renders -- a
        // VariantInitExpr, or for a plain enum's `.V` the enumerator's name --
        // from the facts X recorded on the node it was written as. Before any
        // pass rebuilds an initializer or a chain, which would lose them, and
        // so every pass below sees one node kind for it (SequenceLowering
        // orders its payload).
        {
            var _p  = TimeRegion("VariantInitLowering")
            var _ma = self._arena_total()
            VariantInitLowering(unsafe &self.sc).run()
            self._arena_note("L:VariantInitLowering", _ma)
        }

        // Second: every ADT enum gets its layout record, the one a
        // VariantInitExpr is built through (a variant constructor per
        // variant). Before every body rewrite: every later pass and EmitPlan
        // must see the record's members -- MatchLowering and OperatorLowering
        // (an ADT's `==`) read and test values through its query surface,
        // EnumLayoutQuery, which answers from them. The pass touches no body
        // and VariantInitLowering reads nothing it builds, so neither feeds
        // the other; placing it second means every pass from here on sees
        // both the constructions and the record that renders them.
        {
            var _p  = TimeRegion("EnumLayoutLowering")
            var _ma = self._arena_total()
            EnumLayoutLowering(unsafe &self.sc).run()
            self._arena_note("L:EnumLayoutLowering", _ma)
        }

        // Third: `fn f() -> T = e` becomes `{ return e }`, so every pass below
        // sees an ordinary block -- SequenceLowering hoists into statements,
        // and an expression body has no statement position to hoist into.
        {
            var _p  = TimeRegion("ExprBodyDesugar")
            var _ma = self._arena_total()
            ExprBodyDesugar(&self.sc).run()
            self._arena_note("L:ExprBodyDesugar", _ma)
        }

        // Each `where` group becomes one function testing the guards in
        // order and calling its candidates. After ExprBodyDesugar, so every
        // candidate body and the dispatcher are blocks; before every other
        // body rewrite, so each of them meets ordinary functions and the
        // guards as ordinary `if` conditions -- and before CopyMoveLowering,
        // which casts the forwarded MOVE parameters this pass records.
        {
            var _p  = TimeRegion("WhereDispatchLowering")
            var _ma = self._arena_total()
            WhereDispatchLowering(unsafe &self.sc).run()
            self._arena_note("L:WhereDispatchLowering", _ma)
        }

        // Fourth: a field's initializer becomes a constant on the field or the
        // body of a member function its C++ default calls. Clang takes no
        // statement expression at class scope; from here on every pass meets
        // the initializer as an ordinary `return`.
        {
            var _p  = TimeRegion("FieldInitLowering")
            var _ma = self._arena_total()
            FieldInitLowering(unsafe &self.sc).run()
            self._arena_note("L:FieldInitLowering", _ma)
        }

        // A constructor that initializes a const field is cut into its
        // S_pre and S_post blocks at CtorInitCheck's frontier. Here, before
        // any pass inserts a statement: the frontier is a statement COUNT,
        // true of the tree as checked and of nothing a later pass builds.
        {
            var _p  = TimeRegion("CtorInitLowering")
            var _ma = self._arena_total()
            CtorInitLowering(&self.sc).run()
            self._arena_note("L:CtorInitLowering", _ma)
        }

        // Fifth: a MOVE value passed, initialized from, assigned or returned
        // is cast to `T&&` at each site MoveCheck recorded. Before any pass
        // rebuilds an expression, which would drop the node the record names;
        // SequenceLowering leaves the cast in place, a cast of a name being
        // pure.
        {
            var _p  = TimeRegion("CopyMoveLowering")
            var _ma = self._arena_total()
            CopyMoveLowering(unsafe &self.sc).run()
            self._arena_note("L:CopyMoveLowering", _ma)
        }

        // A script's top-level statements become a synthesized `main`, its
        // deferred bindings `T?` storage that main assigns at their lines
        // (Compiler/Spec/ScriptMode.md). After CopyMoveLowering: the `e as T&&` cast it put on
        // a moved initializer moves into main with the initializer. Before
        // FinallyLowering, which lowers the `finally` this pass mints to
        // tear the globals down; before the nullable block, which lowers the
        // `g?` tests and narrowed reads it builds and gives each `T?` it
        // mints its record; before every pass that rebuilds bodies, to which
        // main is then an ordinary function.
        {
            var _p  = TimeRegion("ScriptLowering")
            var _ma = self._arena_total()
            ScriptLowering(unsafe &self.sc, self.sc.script_root).run()
            self._arena_note("L:ScriptLowering", _ma)
        }

        // A panic is a returned value (Compiler/Spec/Panic.md#paniclowering): each panicking
        // function's signature becomes `Panic<T, E...>`, `return` / `panic`
        // build it, a panicking call is held and tested in a statement
        // expression where it sat, and `try` / `catch` become tag compares
        // with label!/jump!. After ScriptLowering, so a script's main is an
        // ordinary body; after CopyMoveLowering, whose `T&&` casts sit in
        // the arguments it holds. Before FinallyLowering, which then meets
        // every jump and return made here as an ordinary exit; before
        // LabelLowering (an arm's `break L` is lowered with every other);
        // before CallLowering and SequenceLowering, which order the held
        // call's arguments like any call's (a panic result is the one
        // record result SequenceLowering sequences).
        {
            var _p  = TimeRegion("PanicLowering")
            var _ma = self._arena_total()
            PanicLowering(unsafe &self.sc).run()
            self._arena_note("L:PanicLowering", _ma)
        }

        // A `finally` becomes a record in the function body whose destructor
        // is its body, and a local of it. After CopyMoveLowering, whose
        // `T&&` cast wraps a node this pass rewrites in place; before every
        // other body rewrite, so each of them meets the body as a method
        // body (tuples, operators, f-strings, calls, receivers, sequencing).
        {
            var _p  = TimeRegion("FinallyLowering")
            var _ma = self._arena_total()
            FinallyLowering(unsafe &self.sc).run()
            self._arena_note("L:FinallyLowering", _ma)
        }

        // A tuple literal becomes its record's initializer, an index step
        // the field it names, a destructuring one local per binder. After
        // CopyMoveLowering, whose `T&&` cast stays on the destructured
        // value; before OperatorLowering, so an operator on `t.0` sees a
        // field path.
        {
            var _p  = TimeRegion("TupleLowering")
            var _ma = self._arena_total()
            TupleLowering(unsafe &self.sc).run()
            self._arena_note("L:TupleLowering", _ma)
        }

        // `x ?? y` -> `if x? => x else y`, `x?.m`, `unwrap!(x)`, `a === b`
        // and a `match` on a `T?` likewise, each read after its test marked
        // narrowed (Compiler/Spec/Nullables.md#lowering-passes step 1). Before MatchLowering, which
        // lowers the match left on the value with PatternCompilation's tree. Before OperatorLowering: `===`'s `==` may be a user
        // `op ==`, recorded by typing and lowered there. Before NullTestLowering and
        // NarrowedAccessLowering, which lower the test and the marked read it
        // builds; after CopyMoveLowering, whose moves it binds as operands.
        {
            var _p  = TimeRegion("CoalesceLowering")
            var _ma = self._arena_total()
            CoalesceLowering(unsafe &self.sc).run()
            self._arena_note("L:CoalesceLowering", _ma)
        }

        // Every null test (`x?`, `x == null` and its spellings) -> a call of
        // the Nullable's `is_null()` (Compiler/Spec/Nullables.md#lowering-passes step 2). After
        // EnumLayoutLowering, which mints `is_null()`; before
        // NullableTypeLowering, so the operand is still a NullableType to
        // classify and a compared `null` is dropped before it becomes a
        // record; before OperatorLowering, which would leave a `x == null`
        // with a record operand for EmitIR to ICE on.
        {
            var _p  = TimeRegion("NullTestLowering")
            var _ma = self._arena_total()
            NullTestLowering(unsafe &self.sc).run()
            self._arena_note("L:NullTestLowering", _ma)
        }

        // Every read the nullness analysis narrowed -> `x.__value()`, the
        // unchecked accessor (Compiler/Spec/Nullables.md#lowering-passes step 3). After CopyMoveLowering:
        // a `x as T&&` it put around a narrowed `x` then moves the VALUE.
        // After EnumLayoutLowering, which mints `__value()`. Before
        // NullableTypeLowering: the receiver it restores is the `T?`, still a
        // NullableType there. Free against NullTestLowering (a test's operand
        // is never narrowed); after it, as §5 lists them.
        {
            var _p  = TimeRegion("NarrowedAccessLowering")
            var _ma = self._arena_total()
            NarrowedAccessLowering(unsafe &self.sc).run()
            self._arena_note("L:NarrowedAccessLowering", _ma)
        }

        // `T?` -> `::builtin::Nullable<T>`, and `null` -> its null (Compiler/Spec/Nullables.md
        // §5). After CopyMoveLowering: a transfer is decided from the value's
        // lifecycle, which ClassLifecycle answers for `T?` from T; the minted
        // record instance has no facts yet. Before OperatorLowering. The last
        // nullable pass: CoalesceLowering, NullTestLowering and
        // NarrowedAccessLowering above it still see NullableType.
        {
            var _p  = TimeRegion("NullableTypeLowering")
            var _ma = self._arena_total()
            NullableTypeLowering(unsafe &self.sc).run()
            self._arena_note("L:NullableTypeLowering", _ma)
        }

        {
            var _p  = TimeRegion("OperatorLowering")
            var _ma = self._arena_total()
            OperatorLowering(unsafe &self.sc).run()
            self._arena_note("L:OperatorLowering", _ma)
        }

        // An f-string becomes one FmtBuf and straight-line puts. After
        // OperatorLowering (a hole may hold a user operator); before
        // StringLowering (a plain `string` literal inside a hole is still a
        // literal here). Everything it mints is pure or single-use, so its
        // position relative to SequenceLowering is free.
        {
            var _p  = TimeRegion("FStringLowering")
            var _ma = self._arena_total()
            FStringLowering(unsafe &self.sc).run()
            self._arena_note("L:FStringLowering", _ma)
        }

        // Defaults and named/packed arguments become one positional list in
        // parameter order. Before SequenceLowering: a default thunk's call is
        // an impure argument, and it is ordered with the rest there.
        {
            var _p  = TimeRegion("CallLowering")
            var _ma = self._arena_total()
            CallLowering(unsafe &self.sc).run()
            self._arena_note("L:CallLowering", _ma)
        }

        // `for x in xs` becomes a `while` over a once-evaluated iterable.
        // Before ExtensionLowering: a user `op in` declared in an extension is
        // called here through a chain, and that pass makes it the free call.
        // Before SequenceLowering and ListLiteralLowering, which order and
        // render what this pass binds.
        {
            var _p  = TimeRegion("IterLowering")
            var _ma = self._arena_total()
            IterLowering(unsafe &self.sc).run()
            self._arena_note("L:IterLowering", _ma)
        }

        // A range used as a value becomes its Range record. After IterLowering,
        // which consumed the ranges written as a loop's iterable; a subscript's
        // range index is a slice and is left for SliceLowering.
        {
            var _p  = TimeRegion("RangeLowering")
            var _ma = self._arena_total()
            RangeLowering(unsafe &self.sc).run()
            self._arena_note("L:RangeLowering", _ma)
        }

        // Every match becomes labels, gotos and switches over a once-
        // evaluated scrutinee, rendering PatternCompilation's tree. After
        // IterLowering and RangeLowering; before SequenceLowering (which
        // orders the scrutinee local this binds) and StringLowering (a
        // string pattern's literal is still a literal here).
        {
            var _p  = TimeRegion("MatchLowering")
            var _ma = self._arena_total()
            MatchLowering(unsafe &self.sc).run()
            self._arena_note("L:MatchLowering", _ma)
        }

        // `break L` / `continue L` become gotos past the loop / to the end
        // of its body. After IterLowering (it keeps labels on the loops it
        // mints) and MatchLowering (an arm's `break L` moves with the arm).
        {
            var _p  = TimeRegion("LabelLowering")
            var _ma = self._arena_total()
            LabelLowering(unsafe &self.sc).run()
            self._arena_note("L:LabelLowering", _ma)
        }

        // An extension member call becomes the free call: the receiver goes in
        // front of the placed arguments. Before SequenceLowering, which orders it.
        {
            var _p  = TimeRegion("ExtensionLowering")
            var _ma = self._arena_total()
            ExtensionLowering(unsafe &self.sc).run()
            self._arena_note("L:ExtensionLowering", _ma)
        }

        // Argument order: after OperatorLowering (operators are calls now),
        // before ListLiteralLowering (a hoisted slice literal is marked
        // Extended here and gets its backing there).
        {
            var _p  = TimeRegion("SequenceLowering")
            var _ma = self._arena_total()
            SequenceLowering(unsafe &self.sc).run()
            self._arena_note("L:SequenceLowering", _ma)
        }

        // The order is in the tree now: no node C++ evaluates in an
        // unspecified order has two effectful operands (an ICE otherwise),
        // and from here a pass that mints one ICEs at the mint
        // (LowerSynth::_mint_check). The passes below mint only calls with
        // at most one effectful operand: ListLiteralLowering's Slice /
        // Vector constructors and StringLowering's string constructor.
        {
            var _p  = TimeRegion("SequenceCheck")
            var _ma = self._arena_total()
            SequenceCheck(unsafe &self.sc).run()
            self._arena_note("L:SequenceCheck", _ma)
        }

        // After OperatorLowering: a list literal can be an operand of a user
        // operator, and this pass builds constructor calls that must not be
        // re-read as operator nodes.
        {
            var _p  = TimeRegion("ListLiteralLowering")
            var _ma = self._arena_total()
            ListLiteralLowering(unsafe &self.sc).run()
            self._arena_note("L:ListLiteralLowering", _ma)
        }

        // Last: a literal is pure until it is a constructor call, and
        // SequenceLowering must not hoist every `"hi"` argument into a local.
        {
            var _p  = TimeRegion("StringLowering")
            var _ma = self._arena_total()
            StringLowering(unsafe &self.sc).run()
            self._arena_note("L:StringLowering", _ma)
        }

        self.sc.end_lowerings()

        // -finfer-purity: const / pure for the functions that keep the
        // promise unwritten, by FnPurityCheck's own rules, as a greatest
        // fixpoint over this TU's call graph (callees in TUs already done
        // count with their verdict). On the lowered tree, so every call a
        // lowering minted is judged; BEFORE ParamPassInference, which must
        // leave an inferred-const function's record parameters by value.
        // Writes FunctionDecl::inferred_purity, read by codegen.
        if self.sc.opts.infer_purity {
            var _p = TimeRegion("PurityInference")
            var pi = FnPurityCheck(unsafe &self.sc)
            pi.infer()
            kairo::purity_inferred_const().fetch_add(pi.n_const as u64)
            kairo::purity_inferred_pure().fetch_add(pi.n_pure as u64)
        }

        // A by-value COPY record parameter the body never mutates is passed
        // as `const T&` and warned to say `const`. After every
        // lowering: the tree it reads is the one EmitIR renders, so a use a
        // lowering mints (a move, an operator's method call) is seen. Writes
        // ParamDecl::inferred_const, which only codegen reads.
        {
            var _p  = TimeRegion("ParamPassInference")
            var _ma = self._arena_total()
            ParamPassInference(unsafe &self.sc).run()
            self._arena_note("L:ParamPassInference", _ma)
        }

        // Every generic ADT instance gets the layout C++ will pick for it,
        // predicted, for codegen to pin with static_asserts. After every
        // lowering: an instance a lowering mints (a `T?`'s record) is in
        // the registry by now.
        {
            var _p  = TimeRegion("EnumLayoutSweep")
            var _ma = self._arena_total()
            EnumLayoutQuery(unsafe &self.sc).sweep()
            self._arena_note("L:EnumLayoutSweep", _ma)
        }

        // `using Base::name;` for merged base overloads C++ would hide is
        // InterfaceEmitter::_base_usings: a property of the class
        // definition, written where it is spelled, so no pass here.
        self.sc.advance_phase(SemaPhase::Lowered)
        return true
    }

    /// M1: instance enumeration (Compiler/Spec/Generics.md#decisions/D4). Creates nothing new of its
    /// own: T, X, the reach, the lang records and the lowerings minted every
    /// instance into the build-wide registry already, each appended to its
    /// worklist. M1 drains that worklist to the fixpoint: every LIVE entry
    /// (one a use needs) whose reach is not walked yet, in mint order, has
    /// its body's uses minted, linked and bound-checked, until a walk makes
    /// nothing new live (ConformanceChecking::discover). Each TU's checks
    /// already ran the same fixpoint before the Typed barrier, where its
    /// diagnostics belong; this drain finds nothing unless something after
    /// them made an instance live, and is what guarantees the invariant
    /// "every live instance's reach is in the registry" past this point.
    ///
    /// Homing needs nothing more from M1: an entry's home is its first
    /// namer (D3, `home_fid`, fixed at mint), and EmitPlan reaches an
    /// instance no tree names through the `reached` edge the walk recorded.
    priv fn _stage_mono_collect(self) -> bool {
        if self._already(SemaPhase::MonoCollected) {
            return true
        }

        var _t = TimeRegion("Collect")
        self.sc.require_phase(SemaPhase::Lowered)
        ConformanceChecking(unsafe &self.sc).discover()
        self.sc.advance_phase(SemaPhase::MonoCollected)
        return !self._hard_stop()
    }

    /// M2: instance facts (Compiler/Spec/Generics.md#decisions). Nothing re-types a generic body per
    /// instance: each enumerated instance's facts come from substituting its
    /// arguments into what its bounds declare, predicted here and pinned or
    /// selected in C++. The ADT layout is EnumLayoutQuery::sweep at the end
    /// of the lowerings; lifecycle and rows are computed where the
    /// instance becomes live. Panic facts are here: each live
    /// instance's result and the panic results its body names, formed at its
    /// arguments (PanicInstances), then swept again so the new results have
    /// their element ids. Not a build-wide sync point: it runs per TU, in
    /// DAG order, and writes only the locked registry, like every other
    /// stage that mints.
    priv fn _stage_mono_instantiate(self) -> bool {
        if self._already(SemaPhase::Complete) {
            return true
        }

        var _t = TimeRegion("Instantiate")
        self.sc.require_phase(SemaPhase::MonoCollected)
        if PanicInstances(unsafe &self.sc).run() {
            EnumLayoutQuery(unsafe &self.sc).sweep()
        }

        self.sc.advance_phase(SemaPhase::Complete)
        return !self._hard_stop()
    }
}
