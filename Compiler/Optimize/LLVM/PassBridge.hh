/* --- The Kairo Project ----------- Compiler/Optimize/LLVM/PassBridge.hh --- */
/*
 *   Puts a Kairo-written LLVM module pass into the optimisation pipeline of
 *   a clang codegen run. clang takes extra passes as PassBuilder callbacks
 *   (CodeGenOptions::PassBuilderCallbacks), and a pass as a type the pass
 *   manager wraps in a template model; neither a std::function with a
 *   reference parameter nor a CRTP base can be spelled in Kairo, so this
 *   header holds that glue and the pass itself stays in Kairo.
 *
 *   `Impl` is a default-constructible Kairo class with
 *   `fn run(self, m: unsafe *llvm::Module) -> bool`, true when it changed
 *   the module.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 */
#pragma once

#include <clang/Basic/CodeGenOptions.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/PassManager.h>
#include <llvm/Passes/OptimizationLevel.h>
#include <llvm/Passes/PassBuilder.h>

template <class Impl>
struct KairoModulePass : llvm::PassInfoMixin<KairoModulePass<Impl>> {
    llvm::PreservedAnalyses run(llvm::Module &M, llvm::ModuleAnalysisManager &) {
        Impl impl;
        return impl.run(&M) ? llvm::PreservedAnalyses::none() : llvm::PreservedAnalyses::all();
    }
};

/// Runs `Impl` at the start of the module pipeline, before the inliner and
/// every simplification, at -O1 and above and not when optimising for size.
template <class Impl>
inline void kairo_add_pipeline_start_pass(clang::CodeGenOptions &Opts) {
    Opts.PassBuilderCallbacks.push_back([](llvm::PassBuilder &PB) {
        PB.registerPipelineStartEPCallback(
            [](llvm::ModulePassManager &MPM, llvm::OptimizationLevel Level) {
                if (Level == llvm::OptimizationLevel::O0 || Level.getSizeLevel() > 0)
                    return;
                MPM.addPass(KairoModulePass<Impl>());
            });
    });
}
