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
import AST::Node::Base::*;
import Sema::NameLookup::*;
import Diagnostic::BufferedDiagSink::*;
import Lexer::Immediate::*;
import Config::Invocation::*;

/// \enum SemaPhase
/// \brief Where the TU is in the RESOLUTION.md pipeline. Monotonically
///        advanced by the driver; passes ASSERT their preconditions against
///        it instead of trusting the schedule ("one error, one home" only
///        works if phase order is enforced, not hoped for).
///
///        P -> I -> N -> T -> checks -> lowerings -> M1 -> M2
enum SemaPhase derives u8 {
    /// Parse done: AST built, dc_symbols frozen, out_of_line collected.
    Parsed = 0,
    /// Phase I done: import_overlay built; TU is self-contained.
    ImportsResolved,
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
    }

    /// Resolve a tri-state against its profile default.
    fn on(self, v: i32, def: bool) -> bool {
        if v == -1 { return def; }
        return v != 0;
    }
}

/// \enum WellKnownType
/// \brief Compiler-known LIBRARY types (lang items, Rust-style). These are
///        ordinary decls that arrive through ordinary imports and sit in
///        ordinary symbol tables sema just needs a direct handle for
///        desugaring. Their names are NEVER special-cased in lookup.
///
///        Builtin VALUE types (i32, bool, f64 ...) are a different problem
///        and do not belong here or in any symbol table: they are universal
///        entities, to be modeled as singleton Type nodes owned by
///        ASTContext (Clang's IntTy model) once a BuiltinType TypeKind
///        exists. Today builtins ride through ChainType; TypeResolution
///        resolves them by keyword, not by table lookup.
enum WellKnownType derives u8 {
    Future = 0,    ///< async effect desugar target: Future<T>.
    Generator,     ///< yield effect desugar target: Generator<T>.
    Ordering,      ///< <=> result type.
    Steppable,     ///< range operator interface (.. / ..=).
    PanicPayload,  ///< panic effect tagged-union payload.

    COUNT,         ///< keep last.
}

/// \class WellKnownDecls
/// \brief Lang-item registry: WellKnownType -> canonical *Decl. Populated
///        once during NameResolution by qualified lookup of the canonical
///        std paths; read by the lowering passes. A missing entry is only
///        an error at USE (e.g. `async` used but Future unresolvable), and
///        that diagnosis belongs to the pass that needs it.
class WellKnownDecls {
    priv var _decls: vec::<*Decl>;   ///< indexed by WellKnownType; COUNT slots.

    fn WellKnownDecls(self) {
        for var i: usize = 0; i < static_cast::<usize>(WellKnownType::COUNT); ++i {
            self._decls.push_back(&null);
        }
    }

    fn set(self, k: WellKnownType, d: *Decl) {
        self._decls[static_cast::<usize>(k)] = d;
    }

    /// Canonical decl for the lang item, or null if not (yet) resolved.
    fn get(self, k: WellKnownType) -> *Decl {
        return self._decls[static_cast::<usize>(k)];
    }

    fn has(self, k: WellKnownType) -> bool {
        return self._decls[static_cast::<usize>(k)] != &null;
    }
}

/// \class SemaContext
/// \brief The state every pass borrows. One per TU per sema run.
///
/// \par What lives here vs elsewhere
///   here:        phase, options, diag handle, lang items, error budget.
///   ASTContext:  arenas, interner, tokens, source mgmt (AST-domain).
///   nodes:       ALL inter-pass results (resolved_decl links, type_ slots,
///                poison bits, redecl chains). Passes communicate through
///                the AST and registries, NEVER through each other.
///   later:       NameLookup (the shared N/T lookup core) and the global
///                cross-TU tables (conformance registry, instantiation
///                cache) land here as fields when those components are
///                built import_overlay consumption and the M2 sync point
///                are their gatekeepers.
class SemaContext {
    pub var ctx:   obs::<ASTContext>;
    pub var tu:    obs::<TranslationUnit>;
    pub var g:     obs::<GlobalDisambigTable>;   ///< cross-TU context access (fid -> ctx).
    pub var diag:  obs::<BufferedDiagSink>;
    pub var opts:  SemaOptions;
    pub var phase: SemaPhase = SemaPhase::Parsed;

    pub var well_known: WellKnownDecls;

    /// THE shared lookup core (N and T both stand on it; see NameLookup.k
    /// for the four primitives and the LookupResult lifetime law).
    pub var lookup: NameLookup;

    /// diag->error_count() at construction; errored() reports only errors
    /// sema itself produced (parse errors already gated the run).
    pub var error_count_base: u32 = 0;

    /// Default ctor: leaves the context UNWIRED (null handles, Parsed phase).
    /// Exists so a by-value SemaContext member (e.g. Sema::sc) can be
    /// default-constructed and then assigned the wired form below. A pass must
    /// never run against a default-constructed context the driver always
    /// assigns SemaContext(ctx, g) before scheduling any stage.
    fn SemaContext(self) {
        self.ctx   = &null;
        self.g     = &null;
        self.tu    = &null;
        self.diag  = &null;
        self.phase = SemaPhase::Parsed;
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

    /// Errors produced since sema began.
    fn error_delta(self) -> u32 {
        return self.diag->error_count() - self.error_count_base;
    }

    fn errored(self) -> bool {
        return self.error_delta() > 0;
    }
}
