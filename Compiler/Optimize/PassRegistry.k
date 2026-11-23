/// --- The Kairo Project ---------------------- Optimize/PassRegistry.k --- ///
///
///   The one list of every Kairo pass LLVM runs on each Kairo TU's IR
///   (each a KairoPass, Optimize/KairoPass.k). The passes are compiled into
///   the compiler with the list; no plugin is loaded. CodegenBackend::run
///   hands each entry that runs at the TU's level to
///   Optimize/LLVM/PassBridge.hh, which registers it with clang's
///   PassBuilder; --print-kairo-passes lists them and --disable-kairo-pass
///   turns one off by name.
///
///   A new pass is a class meeting KairoPass under Optimize/LLVM/ and one
///   info_of<P>() entry in kairo_passes().
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
ffi "c++" import "vector"

import Optimize::KairoPass::{
    KairoPass,
    PassPoint,
}
import Optimize::LLVM::SpecDevirt::SpecDevirt

/// One pass as the registry lists it: a KairoPass's static answers, and
/// the plain function PassBridge.hh calls to run it.
pub struct KairoPassInfo {
    pub var name: string
    pub var point: PassPoint = PassPoint::PipelineStart
    pub var enabled: unsafe fn(i32, i32) -> bool
    pub var run:     unsafe fn(unsafe *llvm::Module, unsafe *llvm::Function) -> bool
}

/// Runs a fresh `P` once.
fn <P impl KairoPass> run_fresh(m: unsafe *llvm::Module, f: unsafe *llvm::Function) -> bool {
    var p = P()
    return p.run(m, f)
}

/// `P`'s registry entry.
fn <P impl KairoPass> info_of() -> KairoPassInfo {
    return KairoPassInfo {
        name:    P::pass_name(),
        point:   P::pass_point(),
        enabled: P::enabled,
        run:     run_fresh<P>,
    }
}

/// Every Kairo pass. Passes at one point run in this order.
pub fn kairo_passes() -> [KairoPassInfo] {
    return [info_of<SpecDevirt>()]
}

/// Whether some pass is named `name`.
pub fn kairo_pass_known(const name: string) -> bool {
    var passes = kairo_passes()
    for *p in passes {
        if (*p).name == name {
            return true
        }
    }

    return false
}

/// Every pass's name, comma separated, for a message.
pub fn kairo_pass_names() -> string {
    var passes = kairo_passes()
    var out    = ""
    for *p in passes {
        if !out.is_empty() {
            out += ", "
        }

        out += (*p).name
    }

    return out
}

/// Whether `p` runs at -O`opt_level` / `size_level` (KairoPass::enabled)
/// when the passes named in `off` are turned off.
pub fn kairo_pass_runs(const p:    KairoPassInfo,
                       opt_level:  i32,
                       size_level: i32,
                       const off:  cxx::std::vector<string>) -> bool {
    for *s in off {
        if *s == p.name {
            return false
        }
    }

    return p.enabled(opt_level, size_level)
}
