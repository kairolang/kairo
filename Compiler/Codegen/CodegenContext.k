/// --- The Kairo Project ------------------- Codegen/CodegenContext.k ----- ///
///
///   \brief Durable shared state for all emitters. Emitters borrow a
///          *CodegenContext; only the Backend driver constructs one.
///
///   Structural rule (identical to SemaContext.k, same reason): the driver
///   imports every emitter; emitters import THIS file and never the driver.
///
///   Composition, not wrapping: handles only, zero logic, zero forwarding.
///   Reach through cg->ctx for AST services and cg->sink to emit.
///
///   Import law: no clang headers here. The sink is an opaque Kairo type.
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
import AST::Context::InstantiationRegistry::*;
import AST::Node::Base::*;
import Preprocessor::PreprocessorSymbolTable::*;
import Codegen::EmitSink::*;

enum CodegenPhase derives u8 {
    Ready = 0,   ///< Context wired, nothing emitted.
    Planned,     ///< EmitPlan built.
    Emitted,     ///< Token stream fully emitted; eof appended.
}

/// Emission switches. Every one is a build-wide decision, never per site.
class EmitOptions {
    /// Same-file extension members ALSO declared as inline member wrappers
    /// in the class body. OFF: the class text carries only `friend` lines
    /// and an extension member is reached as a free function from Kairo
    /// and C++ alike. Kept as a switch, not deleted, so the surface can be
    /// reopened without re-deriving where the wrapper would go.
    pub var extension_member_wrappers: bool = false;

    fn EmitOptions(self) { }
}

class CodegenContext {
    pub var ctx:       obs::<ASTContext>;
    pub var tu:        obs::<TranslationUnit>;
    pub var sink:      obs::<EmitSink>;
    /// PP symbol table: `module_base` segments are PP SymbolIDs, and the C++
    /// namespace path is rendered from them (IMPORTS.md invariant 9).
    pub var psym:      obs::<PreprocessorSymbolTable>;
    /// The build's instance registry: tier 3 of the plan, and the args a
    /// shell node does not carry itself.
    pub var instances: obs::<InstantiationRegistry>;
    pub var opts:      EmitOptions;
    pub var phase:     CodegenPhase = CodegenPhase::Ready;


    fn CodegenContext(self) {
        self.ctx       = &null;
        self.tu        = &null;
        self.sink      = &null;
        self.psym      = &null;
        self.instances = &null;
        self.phase     = CodegenPhase::Ready;
    }

    fn CodegenContext(self, ctx: *ASTContext, sink: *EmitSink,
                      psym: *PreprocessorSymbolTable, instances: *InstantiationRegistry) {
        self.ctx       = ctx;
        self.tu        = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        self.sink      = sink;
        self.psym      = psym;
        self.instances = instances;
        self.phase     = CodegenPhase::Ready;
    }

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