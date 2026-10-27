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
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Resolve::ImportResolution::*;
import Sema::Resolve::NameResolution::*;
import Sema::Resolve::TypeResolve::*;
import Sema::Resolve::ChainBinding::*;
import Sema::Resolve::RedeclMerge::*;
import Sema::Expand::RequiresDesugar::*;
import Sema::Expand::EvalIfFolding::*;
import Sema::Verify::LoopContextCheck::*;
import Sema::Verify::ArmOrderCheck::*;
import Sema::Verify::JumpLabelCheck::*;
import Sema::Verify::PatternBindingCheck::*;
import Sema::Verify::CxxNameCheck::*;
import Sema::Verify::ModulePinCheck::*;
import Sema::Check::ConstraintExtraction::*;
import Sema::Check::TypeCycleCheck::*;
import Sema::Check::ShadowCheck::*;
import Sema::Check::ShorthandLint::*;
import Sema::Check::ValueCategoryPass::*;
import Sema::Check::ClassLifecycle::*;
import Sema::Check::ClosureCaptures::*;
import Sema::Check::MoveCheck::*;
import Sema::Check::PatternChecking::*;
import Sema::Check::ReturnPathCheck::*;
import Sema::Check::ControlFlowAnalysis::*;
import Sema::Check::WhereGuardCheck::*;
import Sema::Check::OperatorSignatureCheck::*;
import Sema::Check::FeatureGateCheck::*;
import Sema::Check::EvalUsageChecking::*;
import Sema::Check::FlagGates::*;
import Sema::Check::InitCheck::*;
import Sema::Check::CtorInitCheck::*;
import Sema::Check::ConformanceChecking::*;
import Sema::Check::InterfaceComposition::*;
import Sema::Type::ExprTyper::*;
import Sema::Lower::VariantInitLowering::*;
import Sema::Lower::EnumLayoutLowering::*;
import Sema::Lower::ExprBodyDesugar::*;
import Sema::Lower::WhereDispatchLowering::*;
import Sema::Lower::FieldInitLowering::*;
import Sema::Lower::CtorInitLowering::*;
import Sema::Lower::CopyMoveLowering::*;
import Sema::Lower::ScriptLowering::*;
import Sema::Lower::FinallyLowering::*;
import Sema::Lower::TupleLowering::*;
import Sema::Lower::CoalesceLowering::*;
import Sema::Lower::NullTestLowering::*;
import Sema::Lower::NarrowedAccessLowering::*;
import Sema::Lower::NullableTypeLowering::*;
import Sema::Lower::OperatorLowering::*;
import Sema::Lower::CallLowering::*;
import Sema::Lower::IterLowering::*;
import Sema::Lower::RangeLowering::*;
import Sema::Lower::ExtensionLowering::*;
import Sema::Lower::ListLiteralLowering::*;
import Sema::Lower::SequenceLowering::*;
import Sema::Lower::FStringLowering::*;
import Sema::Lower::StringLowering::*;
import Sema::Lower::PatternCompilation::*;
import Sema::Lower::MatchLowering::*;
import Sema::Lower::LabelLowering::*;
import AST::Context::ASTContext::*;
import AST::Context::GlobalDisambigTable::*;
import Support::TimeReport::*;

// Pass imports land here as each pass becomes real, e.g.:
//   import Sema::NameResolution::*;
//   import Sema::TypeChecking::*;
// The driver is the ONLY file that imports passes; passes import
// SemaContext and never this file (import-cycle rule, see SemaContext.k).

class Sema {
    pub var sc: SemaContext;

    /// The TU's lifecycle facts. A member, not a stage local: the checks
    /// fill the memo and --print-sema reads it after the run returns.
    /// Sema only runs it; readers reach it through sc.lifecycle
    /// (lifecycle_of), never through this field.
    priv var lifecycle: ClassLifecycle;

    /// Mirrors ASTParse's ctor: wire handles, no work. ctx->tu must be a
    /// fully parsed TranslationUnit (dc_symbols frozen, out_of_line
    /// collected) i.e. ASTParse::parse() returned it.
    fn Sema(self, ctx: *ASTContext, g: *GlobalDisambigTable) {
        self.sc = SemaContext(ctx, g);
        // Only now: `sc` was assigned from a temporary, and the instance
        // keeps `&self.sc` while `sc` keeps `&self.lifecycle`, so both have
        // to be the members' final addresses.
        self.lifecycle.bind(&self.sc);
        self.sc.lifecycle = &self.lifecycle;
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
        if !self._stage_expand()                  { return false; }

        if !self._gate(SemaPhase::Expanded, target) { return self._done(); }
        if !self._stage_verify()                  { return false; }

        if !self._gate(SemaPhase::Verified, target) { return self._done(); }
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
        var _t = TimeRegion("Imports");
        self.sc.require_phase(SemaPhase::Parsed);
        ImportResolution(&self.sc).run();
        self.sc.advance_phase(SemaPhase::ImportsResolved);
        return !self._hard_stop();
    }

    /// Phase E. Surface normalization: pure AST->AST rewrites that must run
    /// before N/T so name/type resolution see canonical syntax. PRE: imports
    /// resolved. POST: inline generic bounds hoisted into requires_clause
    /// (the inline lists are empty; requires_clause is the single source of
    /// truth). These passes need nothing past Parsed structurally; they sit
    /// after I only because the schedule is linear. Macro expansion and eval
    /// lowering land here too when implemented.
    priv fn _stage_expand(self) -> bool {
        if self._already(SemaPhase::Expanded) { return true; }
        var _t = TimeRegion("Expand");
        self.sc.require_phase(SemaPhase::ImportsResolved);
        // First: no later pass may see an untaken `eval if` branch (EVAL.md §4).
        { var _p = TimeRegion("EvalIfFolding"); EvalIfFolding(&self.sc).run(); }
        // TODO(sema): MacroExpansion(&self.sc).run();
        var desugar = RequiresDesugar(self.sc.ctx);
        desugar.run(self.sc.tu);
        self.sc.advance_phase(SemaPhase::Expanded);
        return !self._hard_stop();
    }

    /// Phase V. Structural verification over the expanded tree: rules
    /// that are plainly illegal without names or types (break/continue
    /// context, label sanity). Pure reads; poison-free these checks
    /// are independent, so report all of them and keep going. Errors
    /// here still hard-stop before N: a structurally illegal tree is
    /// not worth resolving.
    priv fn _stage_verify(self) -> bool {
        if self._already(SemaPhase::Verified) { return true; }
        var _t = TimeRegion("Verify");
        self.sc.require_phase(SemaPhase::Expanded);

        // Per pass, not one number for the stage. Five independent full-tree
        // walks (and one look at the TU's pin): the whole question here is which of them is worth fusing.
        // Unreachable code is not here: it needs `!` types (ControlFlowAnalysis, in C).
        { var _p = TimeRegion("LoopContext");     LoopContextCheck(&self.sc).run();     }
        { var _p = TimeRegion("ArmOrder");        ArmOrderCheck(&self.sc).run();        }
        { var _p = TimeRegion("JumpLabel");       JumpLabelCheck(&self.sc).run();       }
        { var _p = TimeRegion("PatternBinding");  PatternBindingCheck(&self.sc).run();  }
        { var _p = TimeRegion("CxxName");         CxxNameCheck(&self.sc).run();         }
        { var _p = TimeRegion("ModulePin");       ModulePinCheck(&self.sc).run();       }
        // Future Verify passes append here, one visible list.
        self.sc.advance_phase(SemaPhase::Verified);
        return !self._hard_stop();
    }

    /// Phase N, two halves one pass. (a) decl validation over frozen
    /// cells: link Redeclarable chains, validate overload sets, group
    /// specializations, attach tu->out_of_line, populate sc.well_known.
    /// (b) binding: every ident/chain-head/pattern-head gets
    /// resolved_decl. Redefinition + unresolved-ident errors live here.
    priv fn _stage_name_resolution(self) -> bool {
        if self._already(SemaPhase::NamesResolved) { return true; }
        var _t = TimeRegion("Names");
        self.sc.require_phase(SemaPhase::Verified);
        var nr = NameResolution(&self.sc);
        nr.run();
        // Between N and T, and only in the builtin TU: N has bound the names,
        // and T has not yet resolved `[T;]` in `Vector(items: const [T;])` --
        // which needs the Slice handle this fills. Every other TU's call is a
        // fid compare and a return.
        nr.fill_lang_items();
        self.sc.advance_phase(SemaPhase::NamesResolved);
        return !self._hard_stop();
    }

    /// Phase T. Every non-dependent Type node -> canonical; dependent
    /// types MARKED, not resolved (hard invariant #5). Then the bound table
    /// is built from the requires clauses, and every chain step decidable
    /// from declared types -- or from a parameter's BOUND -- is bound
    /// (ChainBinding: base-walk PRE is T complete, RESOLUTION.md §2b).
    /// Arity / unknown-type-name / no-member errors live here.
    priv fn _stage_type_resolution(self) -> bool {
        if self._already(SemaPhase::TypesResolved) { return true; }
        var _t = TimeRegion("Types");
        self.sc.require_phase(SemaPhase::NamesResolved);
        { var _p = TimeRegion("TypeResolve");  TypeResolution(&self.sc).run(); }
        { var _p = TimeRegion("RedeclMerge");  RedeclMerge(&self.sc).run();    }
        // Algebraic interfaces normalized to regular ones, after their leaves
        // resolve and before ChainBinding reads any interface's members.
        { var _p = TimeRegion("InterfaceComposition"); InterfaceComposition(&self.sc).run(); }

        // Constraint partition, BEFORE ChainBinding. Desugar already ran in
        // the Expand phase (pure AST rewrite: inline bounds -> requires as
        // ConstraintExpr conjuncts), so requires_clause is canonical; this
        // sorts each conjunct into conformance constraints vs value
        // predicates and files the result in sc.bounds under its owner decl.
        // ChainBinding is a CONSUMER -- what `x.draw()` on an `x: T` may bind
        // to is exactly what T's declaration promised -- so the table has to
        // exist before it walks.
        { var _p = TimeRegion("Constraints"); ConstraintExtraction(&self.sc).run(); }

        { var _p = TimeRegion("ChainBinding"); ChainBinding(&self.sc).run();   }
        self.sc.advance_phase(SemaPhase::TypesResolved);
        return !self._hard_stop();
    }

    /// Signature/shape checks: operator signatures, conformance
    /// declarations, const checks, eval usage. These poison nodes rather
    /// than hard-stopping independent errors should all surface in one
    /// compile.
    priv fn _stage_checks(self) -> bool {
        if self._already(SemaPhase::Checked) { return true; }
        var _t = TimeRegion("Checks");
        self.sc.require_phase(SemaPhase::TypesResolved);

        // Layout acyclicity. Runs before anything that needs a size:
        // LayoutPass will not terminate on a recursive type, and EmitPlan's
        // `complete` topological sort asserts on a cycle rather than
        // diagnosing one. This pass is where a by-value loop is reported.
        { var _p = TimeRegion("TypeCycle"); TypeCycleCheck(&self.sc).run(); }

        // Operator declaration rules, BEFORE X: X's derived operators and
        // compound-assignment pairing assume shapes this pass has already
        // rejected (a compound operator with a result, both halves of a pair).
        { var _p = TimeRegion("OperatorSignature"); OperatorSignatureCheck(&self.sc).run(); }

        // Expression typing. After TypeCycleCheck because it asks for sizes
        // and layouts through the canonical store, and a by-value cycle has
        // to be reported before anything walks one.
        { var _p = TimeRegion("ExprTyper"); ExprTyper(&self.sc).run(); }

        // ExprTyper assigns value categories inline (overload resolution
        // needs them mid-typing); this verifies that assignment is total and
        // ICEs on a typed expression without one.
        { var _p = TimeRegion("ValueCategory"); ValueCategoryPass(&self.sc).run(); }

        // Runs late: it REQUIRES ExprTyper to be complete.

        { var _p = TimeRegion("ShadowCheck"); ShadowCheck(&self.sc).run(); }

        // `var x = e` whose inferred type is nullable or a pointer, with no
        // shorthand to say so (NULLABLE.md 1.8). REQUIRES ExprTyper: it
        // reads only inferred slots. Before every lowering, so each decl it
        // sees was written by the user.
        { var _p = TimeRegion("ShorthandLint"); ShorthandLint(&self.sc).run(); }

        // Exhaustiveness and dead arms; writes MatchStmt / MatchExpr facts.
        // REQUIRES ExprTyper (pattern types, resolved heads, field slots).
        // Before ReturnPathCheck, which reads is_exhaustive.
        { var _p = TimeRegion("PatternChecking"); PatternChecking(&self.sc).run(); }

        // Missing return on some path. REQUIRES ExprTyper: a call is a
        // terminator when its type is `!`. REQUIRES PatternChecking: match
        // coverage is MatchStmt::is_exhaustive.
        { var _p = TimeRegion("ReturnPath"); ReturnPathCheck(&self.sc).run(); }

        // Unreachable code (SC003W), on the same divergence rule as
        // ReturnPath (FallThrough). Same REQUIRES; before every lowering, so
        // it warns only on code the user wrote.
        { var _p = TimeRegion("ControlFlow"); ControlFlowAnalysis(&self.sc).run(); }

        // A script's top-level `jump!` that crosses a deferred binding's line
        // (SCRIPT.md 2.7). JumpLabelCheck's own frame rules ran in Verify;
        // this one asks which initializers are constant, a fact of X's types.
        { var _p = TimeRegion("ScriptJumps"); JumpLabelCheck(&self.sc).run_script_jumps(); }

        // `where` dispatch groups (where.mdx): what may be guarded, the
        // fallback, member agreement, unreachable and overlapping guards,
        // and the SC116E gates; files each group it passes for
        // WhereDispatchLowering. REQUIRES ExprTyper: guards are typed, and
        // `is_generator` is X's.
        { var _p = TimeRegion("WhereGuard"); WhereGuardCheck(&self.sc).run(); }

        // Per-record lifecycle facts (copyable / movable / trivial) and the
        // rules about the lifecycle itself: one transfer ctor, no user
        // `op =`, base/derived category match, the virtual-destructor rule.
        // After ExprTyper only for schedule linearity; it reads declarations
        // and canonicals, never expression types. The instance is Sema's
        // member: MoveCheck below and the dump read the same memo.
        { var _p = TimeRegion("ClassLifecycle"); self.lifecycle.run(); }

        // `@move` arguments: movability, and use-after-move over each body.
        // REQUIRES ExprTyper complete (promoted callees, typed arguments) and
        // ClassLifecycle (movability).
        // What each closure captures and how (closures.md, Capture Modes):
        // recorded on the ClosureExpr for MoveCheck, FinallyLowering and
        // EmitIR; a binding a named list or `||` leaves out is an error.
        // REQUIRES ExprTyper (bindings, types) and ClassLifecycle (a MOVE
        // capture is moved in).
        { var _p = TimeRegion("ClosureCaptures"); ClosureCaptures(&self.sc).run(); }

        { var _p = TimeRegion("MoveCheck"); MoveCheck(&self.sc).run(); }

        // Default member initializers read only fields built before them.
        // REQUIRES N's bindings (a bare sibling in a default is a field).
        { var _p = TimeRegion("InitCheck"); InitCheck(&self.sc).run(); }

        // A const field is initialized exactly once, in its record's
        // constructor, before `self` is used as a whole; the statement that
        // initializes the last one is where the body is cut (ci_split, for
        // CtorInitLowering). REQUIRES N's bindings and X's types (a `-> !`
        // call ends a path). Before FeatureGate, which stays last.
        { var _p = TimeRegion("CtorInitCheck"); CtorInitCheck(&self.sc).run(); }

        // The rows of every instance this TU names, from its calls' registered
        // instances (ExprTyper). Before the lowerings: ExtensionLowering's
        // witness calls are emitted against them.
        { var _p = TimeRegion("Conformance"); ConformanceChecking(&self.sc).run(); }
        // TODO(sema): ConstChecking(&self.sc).run();

        // Last: well-typed constructs the lowerings cannot render yet. An
        // error here keeps the schedule out of the lowerings, which ICE on
        // them, and that matters under --type-check-only too.
        // What an eval context may hold (EVAL.md §6): REQUIRES X's callee
        // bindings and iter_kind. Before FeatureGate, which stays last.
        { var _p = TimeRegion("EvalUsage"); EvalUsageChecking(&self.sc).run(); }
        { var _p = TimeRegion("FeatureGate"); FeatureGateCheck(&self.sc).run(); }
        // --no-unsafe / --no-fp / --no-ffi / --cmax-* and friends: the user's
        // own files only, over the tree as written (before any lowering).
        { var _p = TimeRegion("FlagGates"); FlagGates(&self.sc).run(); }
        // Decision trees for every match. Last: it reads PatternChecking's
        // facts and reports (SC116E) the two tests it cannot render, and an
        // error anywhere above keeps the schedule out of the lowerings.
        // --print-sema shows the trees.
        { var _p = TimeRegion("PatternCompilation"); PatternCompilation(&self.sc).run(); }
        self.sc.advance_phase(SemaPhase::Checked);
        return true;
    }

    /// Desugar/lowering pipeline (ASTWriter passes). Order within this
    /// stage matters pairwise and is owned HERE, in one visible list
    /// not in comments scattered across pass files.
    priv fn _stage_lowerings(self) -> bool {
        if self._already(SemaPhase::Lowered) { return true; }
        // No stage region: the driver opens "Lower" around this, and a
        // nested one would only repeat it (Lower.Lowerings.X).
        self.sc.require_phase(SemaPhase::Checked);

        // The head of the stage is VariantInitLowering, then
        // EnumLayoutLowering, then ExprBodyDesugar, FieldInitLowering,
        // CtorInitLowering and CopyMoveLowering, then ScriptLowering and
        // FinallyLowering, and the rest after them.
        //
        // First: a variant construction becomes the node EmitIR renders -- a
        // VariantInitExpr, or for a plain enum's `.V` the enumerator's name --
        // from the facts X recorded on the node it was written as. Before any
        // pass rebuilds an initializer or a chain, which would lose them, and
        // so every pass below sees one node kind for it (SequenceLowering
        // orders its payload).
        { var _p = TimeRegion("VariantInitLowering"); VariantInitLowering(&self.sc).run(); }
        // Second: every ADT enum gets its layout record, the one a
        // VariantInitExpr is built through (a variant constructor per
        // variant). Before every body rewrite: every later pass and EmitPlan
        // must see the record's members -- MatchLowering and OperatorLowering
        // (an ADT's `==`) read and test values through its query surface,
        // EnumLayoutQuery, which answers from them. The pass touches no body
        // and VariantInitLowering reads nothing it builds, so neither feeds
        // the other; placing it second means every pass from here on sees
        // both the constructions and the record that renders them.
        { var _p = TimeRegion("EnumLayoutLowering"); EnumLayoutLowering(&self.sc).run(); }
        // Third: `fn f() -> T = e` becomes `{ return e }`, so every pass below
        // sees an ordinary block -- SequenceLowering hoists into statements,
        // and an expression body has no statement position to hoist into.
        { var _p = TimeRegion("ExprBodyDesugar"); ExprBodyDesugar(&self.sc).run(); }
        // Each `where` group becomes one function testing the guards in
        // order and calling its candidates. After ExprBodyDesugar, so every
        // candidate body and the dispatcher are blocks; before every other
        // body rewrite, so each of them meets ordinary functions and the
        // guards as ordinary `if` conditions -- and before CopyMoveLowering,
        // which casts the forwarded MOVE parameters this pass records.
        { var _p = TimeRegion("WhereDispatchLowering"); WhereDispatchLowering(&self.sc).run(); }
        // Fourth: a field's initializer becomes a constant on the field or the
        // body of a member function its C++ default calls. Clang takes no
        // statement expression at class scope; from here on every pass meets
        // the initializer as an ordinary `return`.
        { var _p = TimeRegion("FieldInitLowering"); FieldInitLowering(&self.sc).run(); }
        // A constructor that initializes a const field is cut into its
        // S_pre and S_post blocks at CtorInitCheck's frontier. Here, before
        // any pass inserts a statement: the frontier is a statement COUNT,
        // true of the tree as checked and of nothing a later pass builds.
        { var _p = TimeRegion("CtorInitLowering"); CtorInitLowering(&self.sc).run(); }
        // Fifth: a MOVE value passed, initialized from, assigned or returned
        // is cast to `T&&` at each site MoveCheck recorded. Before any pass
        // rebuilds an expression, which would drop the node the record names;
        // SequenceLowering leaves the cast in place, a cast of a name being
        // pure.
        { var _p = TimeRegion("CopyMoveLowering"); CopyMoveLowering(&self.sc).run(); }
        // A script's top-level statements become a synthesized `main`, its
        // deferred bindings `T?` storage that main assigns at their lines
        // (SCRIPT.md). After CopyMoveLowering: the `e as T&&` cast it put on
        // a moved initializer moves into main with the initializer. Before
        // FinallyLowering, which lowers the `finally` this pass mints to
        // tear the globals down; before the nullable block, which lowers the
        // `g?` tests and narrowed reads it builds and gives each `T?` it
        // mints its record; before every pass that rebuilds bodies, to which
        // main is then an ordinary function.
        { var _p = TimeRegion("ScriptLowering"); ScriptLowering(&self.sc, self.sc.script_root).run(); }
        // A `finally` becomes a record in the function body whose destructor
        // is its body, and a local of it. After CopyMoveLowering, whose
        // `T&&` cast wraps a node this pass rewrites in place; before every
        // other body rewrite, so each of them meets the body as a method
        // body (tuples, operators, f-strings, calls, receivers, sequencing).
        { var _p = TimeRegion("FinallyLowering"); FinallyLowering(&self.sc).run(); }
        // A tuple literal becomes its record's initializer, an index step
        // the field it names, a destructuring one local per binder. After
        // CopyMoveLowering, whose `T&&` cast stays on the destructured
        // value; before OperatorLowering, so an operator on `t.0` sees a
        // field path.
        { var _p = TimeRegion("TupleLowering"); TupleLowering(&self.sc).run(); }
        // `x ?? y` -> `if x? => x else y`, `x?.m`, `unwrap!(x)`, `a === b`
        // and a `match` on a `T?` likewise, each read after its test marked
        // narrowed (NULLABLE.md §5 step 1). Before MatchLowering, which
        // lowers the match left on the value with PatternCompilation's tree. Before OperatorLowering: `===`'s `==` may be a user
        // `op ==`, recorded by typing and lowered there. Before NullTestLowering and
        // NarrowedAccessLowering, which lower the test and the marked read it
        // builds; after CopyMoveLowering, whose moves it binds as operands.
        { var _p = TimeRegion("CoalesceLowering"); CoalesceLowering(&self.sc).run(); }
        // Every null test (`x?`, `x == null` and its spellings) -> a call of
        // the Nullable's `is_null()` (NULLABLE.md §5 step 2). After
        // EnumLayoutLowering, which mints `is_null()`; before
        // NullableTypeLowering, so the operand is still a NullableType to
        // classify and a compared `null` is dropped before it becomes a
        // record; before OperatorLowering, which would leave a `x == null`
        // with a record operand for EmitIR to ICE on.
        { var _p = TimeRegion("NullTestLowering"); NullTestLowering(&self.sc).run(); }
        // Every read the nullness analysis narrowed -> `x.__value()`, the
        // unchecked accessor (NULLABLE.md §5 step 3). After CopyMoveLowering:
        // a `x as T&&` it put around a narrowed `x` then moves the VALUE.
        // After EnumLayoutLowering, which mints `__value()`. Before
        // NullableTypeLowering: the receiver it restores is the `T?`, still a
        // NullableType there. Free against NullTestLowering (a test's operand
        // is never narrowed); after it, as §5 lists them.
        { var _p = TimeRegion("NarrowedAccessLowering"); NarrowedAccessLowering(&self.sc).run(); }
        // `T?` -> `::builtin::Nullable<T>`, and `null` -> its null (NULLABLE.md
        // §5). After CopyMoveLowering: a transfer is decided from the value's
        // lifecycle, which ClassLifecycle answers for `T?` from T; the minted
        // record instance has no facts yet. Before OperatorLowering. The last
        // nullable pass: CoalesceLowering, NullTestLowering and
        // NarrowedAccessLowering above it still see NullableType.
        { var _p = TimeRegion("NullableTypeLowering"); NullableTypeLowering(&self.sc).run(); }
        { var _p = TimeRegion("OperatorLowering"); OperatorLowering(&self.sc).run(); }
        // An f-string becomes one FmtBuf and straight-line puts. After
        // OperatorLowering (a hole may hold a user operator); before
        // StringLowering (a plain `string` literal inside a hole is still a
        // literal here). Everything it mints is pure or single-use, so its
        // position relative to SequenceLowering is free.
        { var _p = TimeRegion("FStringLowering"); FStringLowering(&self.sc).run(); }
        // Defaults and named/packed arguments become one positional list in
        // parameter order. Before SequenceLowering: a default thunk's call is
        // an impure argument, and it is ordered with the rest there.
        { var _p = TimeRegion("CallLowering"); CallLowering(&self.sc).run(); }
        // `for x in xs` becomes a `while` over a once-evaluated iterable.
        // Before ExtensionLowering: a user `op in` declared in an extension is
        // called here through a chain, and that pass makes it the free call.
        // Before SequenceLowering and ListLiteralLowering, which order and
        // render what this pass binds.
        { var _p = TimeRegion("IterLowering"); IterLowering(&self.sc).run(); }
        // A range used as a value becomes its Range record. After IterLowering,
        // which consumed the ranges written as a loop's iterable; a subscript's
        // range index is a slice and is left for SliceLowering.
        { var _p = TimeRegion("RangeLowering"); RangeLowering(&self.sc).run(); }
        // Every match becomes labels, gotos and switches over a once-
        // evaluated scrutinee, rendering PatternCompilation's tree. After
        // IterLowering and RangeLowering; before SequenceLowering (which
        // orders the scrutinee local this binds) and StringLowering (a
        // string pattern's literal is still a literal here).
        { var _p = TimeRegion("MatchLowering"); MatchLowering(&self.sc).run(); }
        // `break L` / `continue L` become gotos past the loop / to the end
        // of its body. After IterLowering (it keeps labels on the loops it
        // mints) and MatchLowering (an arm's `break L` moves with the arm).
        { var _p = TimeRegion("LabelLowering"); LabelLowering(&self.sc).run(); }
        // An extension member call becomes the free call: the receiver goes in
        // front of the placed arguments. Before SequenceLowering, which orders it.
        { var _p = TimeRegion("ExtensionLowering"); ExtensionLowering(&self.sc).run(); }
        // Argument order: after OperatorLowering (operators are calls now),
        // before ListLiteralLowering (a hoisted slice literal is marked
        // Extended here and gets its backing there).
        { var _p = TimeRegion("SequenceLowering"); SequenceLowering(&self.sc).run(); }
        // After OperatorLowering: a list literal can be an operand of a user
        // operator, and this pass builds constructor calls that must not be
        // re-read as operator nodes.
        { var _p = TimeRegion("ListLiteralLowering"); ListLiteralLowering(&self.sc).run(); }
        // Last: a literal is pure until it is a constructor call, and
        // SequenceLowering must not hoist every `"hi"` argument into a local.
        { var _p = TimeRegion("StringLowering"); StringLowering(&self.sc).run(); }
        // TODO(sema): UsingDeclSynthesis(&self.sc).run();    // emits implicit
        //             using Base::name; for merged base overloads C++ would
        //             hide reads type->needs_using written by MemberLookup,
        //             never re-walks bases.
        // TODO(sema): PanicLowering(&self.sc).run();
        // TODO(sema): ...
        self.sc.advance_phase(SemaPhase::Lowered);
        return true;
    }

    /// M1: monomorphization usage collection (parallel-safe).
    priv fn _stage_mono_collect(self) -> bool {
        if self._already(SemaPhase::MonoCollected) { return true; }
        var _t = TimeRegion("Collect");
        self.sc.require_phase(SemaPhase::Lowered);
        // TODO(sema): Monomorphization::collect(&self.sc);
        self.sc.advance_phase(SemaPhase::MonoCollected);
        return !self._hard_stop();
    }

    /// M2: instantiate + dependent conformance. THE sync point the only
    /// stage allowed to touch cross-TU mutable state.
    priv fn _stage_mono_instantiate(self) -> bool {
        if self._already(SemaPhase::Complete) { return true; }
        var _t = TimeRegion("Instantiate");
        self.sc.require_phase(SemaPhase::MonoCollected);
        // TODO(sema): Monomorphization::instantiate(&self.sc);
        // TODO(sema): DependentResolution(&self.sc).run();
        self.sc.advance_phase(SemaPhase::Complete);
        return !self._hard_stop();
    }
}
