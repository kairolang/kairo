/// --- The Kairo Project ------------------- Codegen/CodegenContext.k ----- ///
///
///   \brief Durable shared state for all emitters. Emitters borrow a
///          *CodegenContext; only the Backend driver constructs one.
///
///   Structural rule (identical to SemaContext.k, same reason): the driver
///   must import every emitter to schedule them. If emitters took *Backend,
///   every emitter would import the driver and the driver imports every
///   emitter   an import cycle hub at the worst possible place. Emitters
///   import THIS file and never see the driver.
///
///   Composition, not wrapping: CodegenContext HOLDS obs<ASTContext> and
///   obs<TokenSink>; it does not forward either one's API. Reach through
///   cg->ctx for AST services and cg->sink to emit.
///
///   \par ZERO LOGIC   and now zero forwarding either
///     This class used to carry a token-shaped wrapper per emission
///     (emit_ident, emit_punct, emit_synth_semi, ...) plus the global ->
///     file-relative offset conversion. All of it moved onto TokenSink, which
///     takes Kairo Tokens and SourceRanges directly and owns the location
///     arithmetic in one place. The wrappers were pure forwarding once that
///     happened, so they are gone.
///
///     What remains is what the header always claimed: handles and phase.
///     Every time an emit_* helper wants to land back here, it belongs on the
///     sink (if it constructs a token) or in an emitter under Emit/ (if it
///     decides a shape). That single discipline is what keeps codegen from
///     becoming what it became in Stage 0.
///
///   \par Import law
///     This file imports NO clang headers. It sees TokenSink as an opaque
///     Kairo type. Only Backend.k, CodegenAction.k, TokenSink.k, and
///     Printer/TokenStreamPrinter.k may touch clang.
///
///   Phase: CODEGEN (shared by all emitters)
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
import AST::Node::Base::*;
import Codegen::TokenSink::*;

/// \enum CodegenPhase
/// \brief Where the TU is in the emit schedule. Monotonically advanced by
///        the Backend driver; emitters ASSERT their preconditions against it
///        instead of trusting the schedule.
enum CodegenPhase derives u8 {
    /// Context wired, nothing emitted.
    Ready = 0,
    /// EmitPlan built (decl order + fwd-decl set). M3   at M2 the plan is
    /// the identity transform and this phase is entered trivially.
    Planned,
    /// Token stream fully emitted; eof appended.
    Emitted,
}

/// \class CodegenContext
/// \brief The state every emitter borrows. One per TU per codegen run.
///
/// \par What lives here vs elsewhere
///   here:        AST handles, the sink handle, phase.
///   ASTContext:  arenas, interner, tokens, source mgmt (AST-domain).
///   TokenSink:   the token stream, the literal arena, and ALL location
///                arithmetic.
///   nowhere:     intermediate representation. Codegen owns NO IR. Sema's
///                Lower/ stage produces the codegen-shaped tree.
class CodegenContext {
    pub var ctx:   obs::<ASTContext>;
    pub var tu:    obs::<TranslationUnit>;
    pub var sink:  obs::<TokenSink>;
    pub var phase: CodegenPhase = CodegenPhase::Ready;

    /// Default ctor: leaves the context UNWIRED. Exists so a by-value member
    /// can be default-constructed then assigned. An emitter must never run
    /// against a default-constructed context.
    fn CodegenContext(self) {
        self.ctx   = &null;
        self.tu    = &null;
        self.sink  = &null;
        self.phase = CodegenPhase::Ready;
    }

    fn CodegenContext(self, ctx: *ASTContext, sink: *TokenSink) {
        self.ctx   = ctx;
        self.tu    = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        self.sink  = sink;
        self.phase = CodegenPhase::Ready;
    }

    // --- Phase discipline -----------------------------------------------------

    fn require_phase(self, min: CodegenPhase) {
        assert((static_cast::<u8>(self.phase) >= static_cast::<u8>(min))
               && r"CodegenContext: emitter ran before its precondition phase (driver schedule bug)");
    }

    fn advance_phase(self, p: CodegenPhase) {
        assert((static_cast::<u8>(p) > static_cast::<u8>(self.phase))
               && r"CodegenContext: phase must advance monotonically");
        self.phase = p;
    }
}
