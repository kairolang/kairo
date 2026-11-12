/// --- The Kairo Project --------------------- Codegen/CodegenContext.k --- ///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"

import AST::Context::ASTContext::ASTContext
import AST::Context::InstantiationRegistry::InstantiationRegistry
import AST::Context::TranslationUnit::TranslationUnit
import Codegen::Sink::EmitSink::EmitSink
import Config::Target::ObjectFormat
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable

pub enum CodegenPhase derives u8 {
    Ready = 0, ///< Context wired, nothing emitted.
    Planned,   ///< EmitPlan built. A borrowed plan's context (PlanLease)
    ///< stays here: it fills again, once per stream.
    Emitted, ///< Token stream fully emitted; eof appended.
}

/// Emission switches. Every one is a build-wide decision, never per site.
pub class EmitOptions {
    /// Same-file extension members ALSO declared as inline member wrappers
    /// in the class body. OFF: the class text carries only its `friend
    /// struct` line and an extension member is reached as a static member
    /// of its scope from Kairo and C++ alike. Kept as a switch, not deleted, so the surface can be
    /// reopened without re-deriving where the wrapper would go.
    pub var extension_member_wrappers: bool = false
    /// -funwind: closures and `__kairo_fn`'s call path are not `noexcept`
    /// (a function's own spelling is FunctionDecl::no_unwind, decided in X).
    pub var unwind: bool = false
    /// -Wshift-count-unproven: EmitIR names every shift that pays for its
    /// count mask, on an ARM32 target (the only ones it costs on).
    pub var warn_unproven_shift: bool = false
    /// The triple the C++ is compiled for; "" before the driver resolved it.
    pub var target_triple: string = ""
    /// The objects are linked into an executable here (no --shared, no -c):
    /// every Kairo TU lands in it, so a user `thread` global's offset from
    /// the thread pointer is a link-time constant (CXXSpell::tls_model).
    pub var exe_link: bool = false
    /// The target's objects are ELF, the one format whose TLS models the
    /// tls_model attribute picks between.
    pub var elf: bool = false
    /// --tls-model, "" when not given (CXXSpell::tls_model picks per global).
    pub var tls_model: string = ""
    /// The target is x32 (x86_64 gnux32 / muslx32). lld relaxes an
    /// initial-exec access only in its REX.W movq / addq form, and x32's is a
    /// REX-less movl, so CXXSpell::tls_model never picks initial-exec there.
    pub var x32: bool = false

    fn EmitOptions(self) { }
}

pub class CodegenContext {
    pub var ctx:  unsafe *ASTContext
    pub var tu:   unsafe *TranslationUnit
    pub var sink: unsafe *EmitSink
    /// PP symbol table: `module_base` segments are PP SymbolIDs, and the C++
    /// namespace path is rendered from them (Compiler/Spec/Pipeline.md invariant 20).
    pub var psym: unsafe *PreprocessorSymbolTable
    /// The build's instance registry: tier 3 of the plan, and the args a
    /// shell node does not carry itself.
    pub var instances: unsafe *InstantiationRegistry
    pub var opts:      EmitOptions
    pub var phase:     CodegenPhase                  = CodegenPhase::Ready


    fn CodegenContext(self) {
        self.ctx       = &null
        self.tu        = &null
        self.sink      = &null
        self.psym      = &null
        self.instances = &null
        self.phase     = CodegenPhase::Ready
    }

    pub fn CodegenContext(self,
                          ctx:       unsafe *ASTContext,
                          sink:      unsafe *EmitSink,
                          psym:      unsafe *PreprocessorSymbolTable,
                          instances: unsafe *InstantiationRegistry) {
        self.ctx       = ctx
        self.tu        = ctx->tu
        self.sink      = sink
        self.psym      = psym
        self.instances = instances
        self.phase     = CodegenPhase::Ready
        if sink != &null {
            sink->ice_ctx = ctx
        }

        if ctx->ci != &null && ctx->ci->lang.unwind == 1 {
            self.opts.unwind = true
        }

        if ctx->ci != &null {
            self.opts.warn_unproven_shift = ctx->ci->diag.Wshift_count_unproven
            self.opts.target_triple       = ctx->ci->target.effective_triple
            self.opts.exe_link            = !ctx->ci->linker.shared && !ctx->ci->linker.compile_only
            self.opts.elf                 = ctx->ci->target.object_format_kind == ObjectFormat::Elf
            self.opts.tls_model           = ctx->ci->codegen.tls_model
            var tt = ctx->ci->target.effective_triple
            self.opts.x32 = tt.starts_with("x86_64") && tt.ends_with("x32")
        }
    }

    pub fn require_phase(self, min: CodegenPhase) {
        eval if defined!(DEBUG) {
            if !((self.phase as u8) >= (min as u8)) {
                kairo::std::ice_fail(
                    r"CodegenContext: emitter ran before its precondition phase (driver schedule bug)",
                )
            }
        }
    }

    pub fn advance_phase(self, p: CodegenPhase) {
        eval if defined!(DEBUG) {
            if !((p as u8) > (self.phase as u8)) {
                kairo::std::ice_fail(
                    r"CodegenContext: phase must advance monotonically",
                )
            }
        }

        self.phase = p
    }
}
