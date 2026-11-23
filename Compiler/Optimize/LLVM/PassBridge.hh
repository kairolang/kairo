/* --- The Kairo Project ----------- Compiler/Optimize/LLVM/PassBridge.hh --- */
/*
 *   Puts a Kairo-written LLVM pass into the optimisation pipeline of a
 *   clang codegen run. clang takes extra passes as PassBuilder callbacks
 *   (CodeGenOptions::PassBuilderCallbacks), and a pass as a type the pass
 *   manager wraps in a template model; neither a std::function with a
 *   reference parameter nor a CRTP base can be spelled in Kairo, so this
 *   header holds that glue and the passes themselves stay in Kairo.
 *
 *   A pass reaches this header as its registry entry's run function
 *   (Optimize/PassRegistry.k): a plain function that builds a fresh pass,
 *   runs it, and says whether the IR changed. At a module point it gets
 *   the module and a null function; at a function point, the function's
 *   module and the function. Which passes run, and at which -O, is decided
 *   in Kairo before kairo_register_pass is called: this header registers
 *   what it is given.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 */
#pragma once

#include <clang/Basic/CodeGenOptions.h>
#include <llvm/IR/Function.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/PassManager.h>
#include <llvm/Passes/OptimizationLevel.h>
#include <llvm/Passes/PassBuilder.h>

#include <cstdint>

/// A registry entry's run function (KairoPassInfo::run).
using KairoPassRunFn = bool (*)(llvm::Module *, llvm::Function *);

struct KairoModulePass : llvm::PassInfoMixin<KairoModulePass> {
    KairoPassRunFn Run;

    explicit KairoModulePass(KairoPassRunFn R) : Run(R) {}

    llvm::PreservedAnalyses run(llvm::Module &M, llvm::ModuleAnalysisManager &) {
        return Run(&M, nullptr) ? llvm::PreservedAnalyses::none() : llvm::PreservedAnalyses::all();
    }
};

struct KairoFunctionPass : llvm::PassInfoMixin<KairoFunctionPass> {
    KairoPassRunFn Run;

    explicit KairoFunctionPass(KairoPassRunFn R) : Run(R) {}

    llvm::PreservedAnalyses run(llvm::Function &F, llvm::FunctionAnalysisManager &) {
        return Run(F.getParent(), &F) ? llvm::PreservedAnalyses::none() : llvm::PreservedAnalyses::all();
    }
};

/// Registers `run` at `point`, a PassPoint value (Optimize/PassRegistry.k):
/// 0 pipeline start, 1 peephole, 2 scalar optimizer late, 3 vectorizer
/// start, 4 optimizer last. Each is the PassBuilder extension point of the
/// same name, the same in LLVM 22 and 23.
inline void kairo_register_pass(clang::CodeGenOptions &Opts, std::uint8_t point, KairoPassRunFn run) {
    Opts.PassBuilderCallbacks.push_back([point, run](llvm::PassBuilder &PB) {
        switch (point) {
        case 0:
            PB.registerPipelineStartEPCallback(
                [run](llvm::ModulePassManager &MPM, llvm::OptimizationLevel) {
                    MPM.addPass(KairoModulePass(run));
                });
            return;
        case 1:
            PB.registerPeepholeEPCallback(
                [run](llvm::FunctionPassManager &FPM, llvm::OptimizationLevel) {
                    FPM.addPass(KairoFunctionPass(run));
                });
            return;
        case 2:
            PB.registerScalarOptimizerLateEPCallback(
                [run](llvm::FunctionPassManager &FPM, llvm::OptimizationLevel) {
                    FPM.addPass(KairoFunctionPass(run));
                });
            return;
        case 3:
            PB.registerVectorizerStartEPCallback(
                [run](llvm::FunctionPassManager &FPM, llvm::OptimizationLevel) {
                    FPM.addPass(KairoFunctionPass(run));
                });
            return;
        case 4:
            PB.registerOptimizerLastEPCallback(
                [run](llvm::ModulePassManager &MPM, llvm::OptimizationLevel, llvm::ThinOrFullLTOPhase) {
                    MPM.addPass(KairoModulePass(run));
                });
            return;
        default:
            return;
        }
    });
}
