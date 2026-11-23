/// --- The Kairo Project ------------------------- Optimize/KairoPass.k --- ///
///
///   What a Kairo pass is: the KairoPass interface every pass meets and the
///   points in LLVM's pipeline a pass can run at. Kept apart from the list
///   of passes (PassRegistry.k), which imports every pass, so a pass can
///   name its point without importing the list that imports it.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/IR/Function.h"
ffi "c++" import "llvm/IR/Module.h"
ffi "c++" import "Native/Types.hh"

/// Where in LLVM's pipeline a pass runs. The values are the ones
/// kairo_register_pass (PassBridge.hh) maps to PassBuilder extension points.
pub enum PassPoint derives u8 {
    /// Module: before the inliner and every simplification.
    PipelineStart,
    /// Function: after each instruction combining of the function
    /// simplification pipeline.
    Peephole,
    /// Function: at the end of the function simplification pipeline.
    ScalarOptimizerLate,
    /// Function: before the loop vectorizer.
    VectorizerStart,
    /// Module: after the whole optimisation pipeline.
    OptimizerLast,
}

/// `p` as --print-kairo-passes writes it.
pub fn pass_point_name(p: PassPoint) -> string {
    if p == PassPoint::PipelineStart {
        return "pipeline-start"
    }

    if p == PassPoint::Peephole {
        return "peephole"
    }

    if p == PassPoint::ScalarOptimizerLate {
        return "scalar-optimizer-late"
    }

    if p == PassPoint::VectorizerStart {
        return "vectorizer-start"
    }

    return "optimizer-last"
}

/// What a Kairo pass provides. A pass is default-constructible: every run
/// builds a fresh one, since TUs are compiled on several threads at once
/// and a pass keeps per-run state in its fields.
pub interface KairoPass {
    /// The name --disable-kairo-pass and --print-kairo-passes use.
    static fn pass_name() -> string
    /// Where in the pipeline the pass runs.
    static fn pass_point() -> PassPoint
    /// Whether the pass runs at -O`opt_level` (0 to 3) with `size_level`
    /// 0 (no size optimisation), 1 (-Os) or 2 (-Oz).
    static fn enabled(opt_level: i32, size_level: i32) -> bool
    /// Runs the pass. At a module point `f` is null; at a function point it
    /// is the function to transform, one of `m`'s. True when the IR changed.
    fn run(self, m: unsafe *llvm::Module, f: unsafe *llvm::Function) -> bool
}
