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

ffi "c++" import "llvm/ADT/DenseMap.h";
ffi "c++" import "llvm/ADT/DenseSet.h";
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Context::CanonicalTypes::*;
import AST::Node::Base::*;
import Location::SourceRange::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::LangItems::*;
import AST::DeclFacts::*;
import Sema::Check::ConstraintSet::*;
import Sema::Resolve::NameLookup::*;
import Sema::Resolve::ResolutionTrace::*;
import Sema::Resolve::ResolutionState::*;
import Diagnostic::BufferedDiagSink::*;
import Lexer::Immediate::*;
import Config::Invocation::*;
import Config::CodeGen::*;
import AST::Context::InstantiationRegistry::*;
import Sema::Foreign::ForeignInstantiate::*;
import Sema::Foreign::BuiltinImport::*;
import Sema::Expand::EvalBranches::*;

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
    /// The checks through ConformanceChecking done: X's types and callee
    /// bindings are final. THE barrier for panic sets (PANIC.md §2.2): the
    /// driver takes every TU of an import cycle (just this one when there is
    /// none) here before any of them goes on, and EffectPropagation solves
    /// their sets at once (RESOLUTION.md, "The Typed barrier").
    Typed,
    /// Signature/shape checks done (operator signatures, conformance
    /// declarations verified, const checks).
    Checked,
    /// Desugar/lowering passes done (extends folded+lowered, match/panic/
    /// eval lowerings applied). Tree is codegen-shaped except generics.
    Lowered,
    /// M1 done: every instance minted so far is enumerated (MONO.md D4).
    MonoCollected,
    /// M2 done: this TU's instance facts computed (MONO.md D0). Not a
    /// build-wide sync point: later TUs still mint into the registry.
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
/// \class SemaOptions
/// \brief Sema-relevant toggles, snapshotted from CompilerInvocation at
///        SemaContext construction. Passes read sc->opts, never reach into
///        ci raw flags this gives tests a way to toggle behavior without
///        assembling a full invocation, and gives flags exactly one
///        deserialization point (same rule as LangOptions itself).
///
///        Tri-state convention matches LangOptions: -1 unset (profile
///        default applies), 0 off, 1 on. Resolve through on().
class SemaOptions {
    pub var verify_interfaces: i32 = -1;  ///< check extend..impl bodies against interface.
    pub var const_checks:      i32 = -1;  ///< const-correctness enforcement.
    pub var overflow_checks:   i32 = -1;  ///< arith overflow checking semantics.
    pub var strict_null:       i32 = -1;  ///< nullable strictness.
    pub var implicit_conv:     i32 = -1;  ///< allow implicit conversions.
    pub var rtti:              i32 = -1;  ///< emit RTTI-dependent features.

    /// Longest chain of alias-through-alias expansions T will follow before
    /// giving up (--cmax-type-alias-depth). NOT a tri-state: a positive count,
    /// already defaulted by the flag parser. Separate from the resolution
    /// stack's scope-depth cap because an alias chain is the one structure a
    /// user can make arbitrarily long by accident (a chain of re-exports) and
    /// wants to tune without loosening every other nesting limit.
    pub var max_type_alias_depth: i32 = 64;

    pub var unmatched: UnmatchedPolicy = UnmatchedPolicy::Trap; ///< what a match does with an undeclared value; MatchLowering reads it.
    pub var adt_unmatched: UnmatchedPolicy = UnmatchedPolicy::Unreachable; ///< the same for an ADT tag no variant has (CodeGenOptions::adt_tag_policy).

    // -- language gates and declaration limits (FlagGates reads these) ------
    // Defaults are "off" / unlimited so a hand-built SemaOptions (tests that
    // skip load) never trips a gate; load() applies the real defaults.
    pub var no_unsafe:  bool = false;  ///< --no-unsafe or -fno-unsafe.
    /// The C++ this build compiles has exceptions (LangOptions::cxx_exceptions):
    /// a `catch e: cxx::...` arm needs them (PANIC.md §3.5).
    pub var cxx_exceptions: bool = true;
    pub var unwind_all: bool = false;  ///< -funwind: no Kairo function is spelled noexcept (but @no_unwind).
    /// -fduck-generics: `<T: type>` is the C++-checked regime rather than an
    /// error (FlagGates; MONO.md D1). ON by default until the compiler hosts
    /// itself (USER 2026-10-27): the bootstrap corpus is written in it.
    /// -fno-duck-generics turns it off. A hand-built SemaOptions agrees
    /// with the driver.
    pub var duck_generics: bool = true;
    pub var no_fp:      bool = false;  ///< --no-fp.
    pub var no_ffi:     bool = false;  ///< --no-ffi.
    pub var no_cxx:     bool = false;  ///< --no-cxx.
    pub var no_yield:   bool = false;  ///< --no-yield.
    pub var no_modules: bool = false;  ///< --no-modules.
    pub var max_struct_fields:   i32 = 0;  ///< 0 = unlimited.
    pub var max_function_params: i32 = 0;  ///< 0 = unlimited.
    pub var max_enum_variants:   i32 = 0;  ///< 0 = unlimited.
    pub var max_match_arms:      i32 = 0;  ///< 0 = unlimited.
    pub var max_union_width:     i32 = 0;  ///< 0 = unlimited.
    pub var max_interface_impls: i32 = 0;  ///< 0 = unlimited.
    pub var max_extend_chain:    i32 = 0;  ///< 0 = unlimited.
    /// --cmax-generic-depth: the longest instantiation chain the discovery
    /// fixpoint follows before it reports one (MONO.md D4).
    pub var max_generic_depth:   i32 = 128;
    /// --cmax-generic-backtrace: instantiation-chain notes shown per error
    /// (MONO.md D6: 5, the first 3 and the last 2); 0 shows them all.
    pub var max_generic_backtrace: i32 = 5;
    /// Compiler test hooks for the Panic lang item (PANIC.md §7, P1): source
    /// may name `Panic<...>`, and type ids keep only this many low bits.
    pub var test_panic_type:    bool = false;
    pub var test_panic_id_bits: i32  = 32;
    /// Compiler test hook (EVAL.md 4.2b): EvalIfLateFolding reads every
    /// triviality fact inverted, as a LifecycleFacts bug would, so a test can
    /// show the codegen pin failing the build. No other pass sees it.
    pub var test_fold_lie: bool = false;
    /// The build produces a library (--shared): the `pub` inferred-panic-set
    /// lint is on (PANIC.md §2.2). Off for an executable.
    pub var library_build: bool = false;

    fn SemaOptions(self) { }

    /// Populate from the invocation. The single flag -> option boundary.
    fn load(self, ci: *CompilerInvocation) {
        if ci == &null { return; }
        self.verify_interfaces = ci->lang.verify_interfaces;
        self.const_checks      = ci->lang.const_checks;
        self.overflow_checks   = ci->lang.overflow_checks;
        self.strict_null       = ci->lang.strict_null;
        self.implicit_conv     = ci->lang.implicit_conv;
        self.rtti              = ci->lang.rtti;
        self.max_type_alias_depth = ci->lang.max_type_alias_depth;
        self.unmatched         = ci->codegen.unmatched_policy();
        self.adt_unmatched     = ci->codegen.adt_tag_policy();

        // Language gates and declaration limits. -fno-unsafe is the same
        // switch as --no-unsafe spelled as a feature, so both fold in here
        // rather than making the pass know two spellings.
        self.no_unsafe  = ci->lang.no_unsafe || (ci->lang.unsafe_feature == 0);
        self.unwind_all = (ci->lang.unwind == 1);
        self.duck_generics = (ci->lang.duck_generics != 0);   // unset = on (see above)
        // FlagTranslator's test of a hosted target, on the resolved triple.
        var hosted = !(ci->lang.freestanding || ci->codegen.kernel_mode);
        if ci->target.resolved && (!ci->target.has_os) { hosted = false; }
        self.cxx_exceptions = ci->lang.cxx_exceptions(hosted);
        self.no_fp      = ci->lang.no_fp;
        self.no_ffi     = ci->lang.no_ffi;
        self.no_cxx     = ci->lang.no_cxx;
        self.no_yield   = ci->lang.no_yield;
        self.no_modules = ci->lang.no_modules;
        self.max_struct_fields   = ci->lang.max_struct_fields;
        self.max_function_params = ci->lang.max_function_params;
        self.max_enum_variants   = ci->lang.max_enum_variants;
        self.max_match_arms      = ci->lang.max_match_arms;
        self.max_union_width     = ci->lang.max_union_width;
        self.max_interface_impls = ci->lang.max_interface_impls;
        self.max_extend_chain    = ci->lang.max_extend_chain;
        self.max_generic_depth   = ci->lang.max_generic_depth;
        self.max_generic_backtrace = ci->lang.max_generic_backtrace;
        self.test_panic_type     = ci->lang.test_panic_type;
        self.test_panic_id_bits  = ci->lang.test_panic_id_bits;
        self.test_fold_lie       = ci->lang.test_fold_lie;
        self.library_build       = ci->linker.shared;
    }

    /// Resolve a tri-state against its profile default.
    fn on(self, v: i32, def: bool) -> bool {
        if v == -1 { return def; }
        return v != 0;
    }
}

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
    /// The clang builtins, as the fourth source of unqualified names (N(b),
    /// on a total miss only). Build-wide, owned by CompilerInstance and wired
    /// like `foreign`; null or unready means every builtin misses into R020E.
    pub var builtins:  obs::<BuiltinImport> = &null;

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
    pub var bounds: llvm::DenseMap::<u64, ConstraintSet>;

    /// Demand-driven resolution memo + cycle stack. Per-TU, unsynchronized.
    pub var rstate: ResolutionState;

    /// N's decision log, for `--print-sema`. Recording is enabled once here
    /// and nowhere else; every pass writes to it unconditionally and the
    /// trace itself no-ops when off. READ-ONLY for everyone but SemaDump: a
    /// pass that consults this is a pass whose behavior changes under the flag
    /// meant to explain it.
    pub var trace: ResolutionTrace;

    pub var lifecycle: *void = &null; ///< the Sema-owned ClassLifecycle; one writer: Sema. Untyped because ClassLifecycle imports this file.
    /// The build-wide panic-set table (`*EffectTable`, EffectPropagation.k),
    /// owned by the driver and solved at the Typed barrier, one import
    /// cycle (or one TU) at a time.
    /// Null when nothing set one up: PanicEffectChecking then solves this TU
    /// alone. Untyped for the same import-cycle reason as `lifecycle`.
    pub var effects: *void = &null;

    /// The expressions a transfer moves from (`*Expr` as u64): a MOVE value
    /// passed, initialized from or assigned. One writer, MoveCheck, which
    /// decides it alongside use-after-move; one reader, CopyMoveLowering,
    /// which casts each to `T&&`. So the move C++ performs is exactly the
    /// one the checker counted.
    pub var move_sites: llvm::DenseSet::<u64>;

    /// Every `where` dispatch group of this TU that WhereGuardCheck passed,
    /// flat: one group is a run of members sharing `where_lead`, in
    /// DISPATCH order -- the guarded ones as declared, then the unguarded
    /// fallback, wherever it was declared. A run with no fallback ends in a guarded
    /// member whose guard the earlier ones were proven to leave nothing
    /// for, which is called without being tested. One writer,
    /// WhereGuardCheck; one reader, WhereDispatchLowering.
    pub var where_groups: vec::<*FunctionDecl>;

    /// The range of every function-body `eval if` EvalIfFolding folded (its
    /// taken branch spliced in). A path one of them ends ends only on this
    /// target and configuration, so ControlFlowAnalysis does not call the
    /// code after it dead.
    pub var folded_eval_ifs: vec::<SourceRange>;

    /// Every declaration-scope `eval if` E deferred on a type fact, with the
    /// declarations of each of its branches (EVAL.md 4.2b). One writer,
    /// EvalIfFolding (filed in E, retired by the late fold); readers N(a)
    /// and RedeclMerge (sibling branches never conflict) and the late fold.
    pub var eval_branches: EvalBranchTable;

    /// Each `<T: type>` parameter a member step went through, with the first
    /// such step's range, in the order ChainBinding met them. One writer,
    /// ChainBinding (the `: type` branch of a dependent step); one reader,
    /// FlagGates, whose error for `: type` without -fduck-generics offers to
    /// delete the bound only when nothing here says the body needs it.
    pub var duck_member_params: vec::<*GenericParamDecl>;
    pub var duck_member_at:     vec::<SourceRange>;

    /// This TU is the file a program starts from: a command-line input,
    /// not one reached through an import or a C++ `#include`. Nothing in the
    /// TU says it, so the DRIVER sets it before the run (SCRIPT.md 1.1); a
    /// root with top-level statements and no `fn main` is a script
    /// (ScriptRules::is_script). Every other TU's top-level statement is an
    /// error, since nothing would run it.
    pub var script_root: bool = false;

    /// The first top-level statement of the script ScriptLowering turned
    /// into `main`; invalid when this TU is no script, or lowering never
    /// ran. One writer, ScriptLowering; one reader, the driver, which
    /// rejects two scripts linked into one program by these ranges.
    pub var script_at: SourceRange = SourceRange::invalid();

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
            var i64_long = true;
            var ldb: usize = 0;
            var lda: usize = 0;
            if ctx->ci != &null {
                pbits = ctx->ci->target.pointer_width; i64_long = ctx->ci->target.int64_is_long;
                ldb = ctx->ci->target.long_double_bits; lda = ctx->ci->target.long_double_align;
            }
            if pbits == 0 { pbits = 64; i64_long = true; }
            self.types->init(pbits, i64_long, ldb, lda);
        }

        if ctx->ci != &null {
            self.rstate.set_max_depth(static_cast::<usize>(ctx->ci->frontend.max_scope_depth));
        }

        // Tracing costs one branch per name when off, so it is gated on the
        // only flag that reads it rather than on a build mode.
        // Both dumps read the trace, and --print-lowered runs strictly after
        // --print-sema's cut, so recording has to survive the lowerings.
        if ctx->ci != &null {
            self.trace.enabled = ctx->ci->frontend.print_sema || ctx->ci->frontend.print_lowered;
        }
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

    /// THE canonical for a lang record at \p args. Concrete args go through
    /// the InstantiationRegistry, exactly as TypeResolve::_type_of_decl sends
    /// a written `Foo<i32>`: the instance then has a home TU, and EmitPlan
    /// emits its explicit instantiation and homed bodies there. A dependent
    /// use keeps the primary (a pattern, deferred to M2). TypeResolve and
    /// TypeUtil both build through here, so `[i32;]` written, `[i32;]` taken
    /// by a literal, and `Slice<i32>` spelled out are one identity.
    fn lang_record(self, k: WellKnownType, args: *vec::<*Type>) -> *Type {
        if (self.well_known == &null) || (self.types == &null) { return &null; }
        var d = self.well_known->get(k);
        if d == &null { return &null; }
        var rep = NameLookup::representative(d);
        var gps = decl_generic_params(rep);
        var trimmed = vec::<*Type>();
        var dep = false;
        // A trailing type pack takes every argument from its position on
        // (an instance carries its pack flat, InstanceEntry::args): trimming
        // to the parameter count would drop all but the pack's first.
        var take = gps.size();
        if (take > 0) && (gps[take - 1] != &null) && gps[take - 1]->is_pack { take = args->size(); }
        for var i: usize = 0; (i < take) && (i < args->size()); ++i {
            var a = (*args)[i];
            if a == &null { return &null; }
            if a->is_dependent() || a->is_instantiation_dependent() { dep = true; }
            trimmed.push_back(a);
        }
        var inst = rep;
        if (!dep) && (gps.size() > 0) && (self.instances != &null) && (self.ctx != &null) {
            var e = self.instances->instance_for(rep, &trimmed, self.ctx->fid, NameLookup::ctx_of(rep));
            if e != &null { inst = e->decl; }
        }
        return self.types->record(inst, &trimmed);
    }

    /// The Nullable lang item's pattern, the enum every `T?` lowers to, or
    /// null: no builtin root bound it, or what it bound is no enum (a pass
    /// that needs it ICEs on that, with its own name). By identity, never
    /// by name: a user may declare an enum called Nullable.
    fn nullable_enum(self) -> *EnumDecl {
        if self.well_known == &null { return &null; }
        var nd = self.well_known->get(WellKnownType::Nullable);
        if nd == &null { return &null; }
        return dyn_cast::<EnumDecl>(NameLookup::representative(nd));
    }

    /// The member of the Nullable lang item's layout that plays \p role
    /// (EnumLayoutLowering::_nullable_surface mints them; InterfaceEmitter
    /// writes them in C++), or null when the layout has none. Found by role
    /// on the PATTERN's layout, as MatchLowering finds the tag field: an
    /// instance shares it. The caller has checked the lang item is bound;
    /// \p pass names it in the ICEs for a lang item that is not the enum
    /// Lib/builtin declares, or that EnumLayoutLowering has not laid out.
    fn nullable_member(self, role: AdtRole, pass: string) -> *FunctionDecl {
        var en = self.nullable_enum();
        ICE_IF(en == &null, pass + ": the Nullable lang item is not an enum");
        var lay = dyn_cast::<StructDecl>(en->adt_layout);
        ICE_IF(lay == &null, pass + ": the Nullable lang item has no layout; EnumLayoutLowering runs first");
        var found: *FunctionDecl = &null;
        for var i: usize = 0; i < lay->methods.size(); ++i {
            var m = lay->methods[i];
            if (m != &null) && (m->adt_role == role) { found = m; }
        }
        return found;
    }

    /// The tuple pattern of \p arity (TupleRecords, minted on first use),
    /// or null: no builtin root to home it in, or an arity outside
    /// [2, TUPLE_MAX_ARITY]. The root TU is the DeclContext the record
    /// is scoped in; found through the global table, never this TU's.
    fn tuple_pattern(self, arity: usize) -> *Decl {
        if self.g == &null { return &null; }
        var fid = self.g->builtin_fid();
        if fid == 0 { return &null; }
        var rctx = self.g->get_context(fid);
        if (rctx == &null) || (rctx->tu == &null) { return &null; }
        var rtu = reinterpret_cast::<*TranslationUnit>(rctx->tu);
        return self.g->tuple_pattern(arity, static_cast::<*DeclContext>(rtu));
    }

    /// `(A, B, ..)` as `record(TupleN, [A, B, ..])`: THE canonical builder
    /// for a tuple, the same way lang_record is for a lang item. TypeResolve,
    /// LiteralTyping, StmtTyping and ArgumentDeduction all build through
    /// here, so a written `(i32, f64)`, one a literal takes and one a
    /// substitution produces are one identity with one registry entry
    /// (home TU, explicit instantiation). Null when the pattern is (see
    /// tuple_pattern) or an element is.
    fn tuple_record(self, args: *vec::<*Type>) -> *Type {
        if (args == &null) || (self.types == &null) { return &null; }
        var rep = self.tuple_pattern(args->size());
        if rep == &null { return &null; }
        var trimmed = vec::<*Type>();
        var dep = false;
        for var i: usize = 0; i < args->size(); ++i {
            var a = (*args)[i];
            if a == &null { return &null; }
            if a->is_dependent() || a->is_instantiation_dependent() { dep = true; }
            trimmed.push_back(a);
        }
        var inst = rep;
        if (!dep) && (self.instances != &null) && (self.ctx != &null) {
            var e = self.instances->instance_for(rep, &trimmed, self.ctx->fid, NameLookup::ctx_of(rep));
            if e != &null { inst = e->decl; }
        }
        return self.types->record(inst, &trimmed);
    }

    // === Specialization bodies ================================================
    //
    // `instantiated_from` / pattern_of answer "which template is this an
    // instance of" -- always the primary, which deduction and every
    // lang-item test compare against. These answer the other question,
    // "whose TABLE are this record's members in", which a partial
    // specialization makes different. Only table readers ask it.

    /// The decl whose table holds \p d's members: \p d itself when it has
    /// its own (a primary, a spec, a filled instance), else the partial the
    /// registry selected for it, else its primary.
    fn body_of(self, d: *Decl) -> *Decl {
        if d == &null { return &null; }
        if (!decl_is_instance(d)) || decl_instantiated(d) { return d; }
        if self.instances != &null {
            var e = self.instances->entry_of(d);
            if (e != &null) && (e->pattern != &null) { return e->pattern; }
        }
        var p = decl_instantiated_from(d);
        return (p) if (p != &null) else (d);
    }

    /// The decl whose table holds the members of record type \p t, or null
    /// for a non-record. A DEPENDENT use of a primary (`Store<*P>`: an
    /// extension's receiver, a partial's own Self) has no instance to carry
    /// a selection, so it is matched here, its parameters opaque.
    fn record_body(self, t: *Type) -> *Decl {
        var u = canon_unqual(t);
        if (u == &null) || (!isa::<RecordType>(u)) { return &null; }
        var r = cast::<RecordType>(u);
        var d = r->decl;
        if d == &null { return &null; }
        if decl_is_instance(d) { return self.body_of(d); }
        var binds = vec::<*Type>();
        var sel = self.record_partial(t, &binds);
        return (sel) if (sel != &null) else (d);
    }

    /// The partial \p rec's members come from, with its parameters'
    /// bindings in \p out; null when they come from the primary or an
    /// explicit spec (whose parameters, if any, bind positionally).
    fn record_partial(self, rec: *Type, out: *vec::<*Type>) -> *Decl {
        var u = canon_unqual(rec);
        if (u == &null) || (!isa::<RecordType>(u)) || (self.instances == &null) { return &null; }
        var r = cast::<RecordType>(u);
        var d = r->decl;
        if d == &null { return &null; }
        if decl_is_instance(d) {
            var e = self.instances->entry_of(d);
            if (e == &null) || (e->pattern == &null) { return &null; }
            for var i: usize = 0; i < e->pattern_args.size(); ++i { out->push_back(e->pattern_args[i]); }
            return e->pattern;
        }
        if (r->args.size() == 0) || (decl_spec_kind(d) == SpecKind::Explicit) || (decl_spec_kind(d) == SpecKind::Partial) { return &null; }
        var args = vec::<*Type>();
        for var i: usize = 0; i < r->args.size(); ++i { args.push_back(r->args[i]); }
        return self.instances->select_partial(NameLookup::representative(d), &args, out);
    }

    /// Errors produced since sema began.
    fn error_delta(self) -> u32 {
        return self.diag->error_count() - self.error_count_base;
    }

    fn errored(self) -> bool {
        return self.error_delta() > 0;
    }
}