/// --- The Kairo Project ------------------------------ Sysroot/KccArgv.k --- ///
///
///   The words every kcc that ksys spawns carries after its program name
///   (and a --driver-mode, where one is given): the target, the stage's own
///   sysroot, and --sysroot-exact. Five call sites (Provider::kcc, the
///   generator's probe, validation and type probes, the SDK validation)
///   built the same block by hand, each with the same comment.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

pub class KccArgv {
    /// \brief appends `--target=<triple> --sysroot=<sysroot> -Xkairo
    ///        --sysroot-exact` to \p argv.
    ///
    /// \details Always --sysroot, so kcc's own sysroot hook never re-enters
    ///          ksys for the target being built, and --sysroot-exact, so a
    ///          root bundled beside kcc for the same triple never replaces
    ///          the stage's own headers. kcc takes kairo-only words
    ///          through -Xkairo.
    pub static fn push_target(@inout argv:   cxx::std::vector<string>,
                              const triple:  string,
                              const sysroot: string) {
        argv.push_back("--target=" + triple)
        argv.push_back("--sysroot=" + sysroot)
        argv.push_back("-Xkairo")
        argv.push_back("--sysroot-exact")
    }
}
