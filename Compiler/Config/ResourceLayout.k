/// --- The Kairo Project ---------------------- Config/ResourceLayout.k --- ///
///
///   ResourceLayout: the toolchain's directory layout, spelled once (the
///   subdirectories of <prefix>, of <prefix>/lib and of a resource
///   directory), and the one answer to "is this file in std?".
///
///   The layout words name directories, not modules: `builtin/` and `std/`
///   share their spelling with the module roots (AST/LangItems.k
///   builtin_root_name, std_root_spelling) by design, and are kept apart so
///   a rename of either is one edit. Linker/API/Toolchain.k derives the
///   prefix on its own (the Linker does not import Config).
///
///   The std test was copied into five passes (VisibilityFacts, SemaDump,
///   FlagGates, ParamPassInference, PanicEffectChecking), each deciding
///   whether a TU is library code the user cannot edit, and only the first
///   resolved symlinks: a std file named through a link was library code to
///   the visibility rule and the user's code to the flag gates, so
///   all five must ask is_std_file.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Config::Invocation::CompilerInvocation
import Support::FileIO::Path::Path

pub class ResourceLayout {
    /// # <prefix>/...

    /// <prefix>/lib: the clang resource dirs, builtin and std (staged tree).
    pub static fn lib_subdir() -> string {
        return "lib"
    }

    /// <prefix>/lib/clang/<version>.
    pub static fn clang_subdir() -> string {
        return "clang"
    }

    /// <prefix>/sysroot/<target>: the bundled sysroots.
    pub static fn sysroot_subdir() -> string {
        return "sysroot"
    }

    /// <prefix>/scripts: the SDK sysroot scripts.
    pub static fn scripts_subdir() -> string {
        return "scripts"
    }

    /// # <prefix>/lib/... or <resource-dir>/...

    pub static fn builtin_subdir() -> string {
        return "builtin"
    }

    pub static fn std_subdir() -> string {
        return "std"
    }

    /// # <runtime root>/... (the builtin root's parent: Lib/ in the tree)

    pub static fn rt_subdir() -> string {
        return "rt"
    }

    pub static fn mimalloc_src_subdir() -> string {
        return "rt/mimalloc/src"
    }

    pub static fn mimalloc_include_subdir() -> string {
        return "rt/mimalloc/include"
    }

    /// # std

    /// \brief the std root the library tests compare against: --std-dir,
    ///        else <resource-dir>/std; "" with neither.
    pub static fn std_root_of(ci: unsafe *CompilerInvocation) -> string {
        if ci == &null {
            return ""
        }

        var root = ci->pp.std_dir
        if root.empty() && !ci->target.resource_dir.empty() {
            root = ci->target.resource_dir + "/" + ResourceLayout::std_subdir()
        }

        return root
    }

    /// \brief \p file is under the std root as spelled, without resolving
    ///        a symlink on either side.
    priv static fn _under_std_as_spelled(ci: unsafe *CompilerInvocation, const file: string) -> bool {
        var root = ResourceLayout::std_root_of(ci)
        if root.empty() {
            return false
        }

        if !root.ends_with("/") {
            root += "/"
        }

        return file.starts_with(root)
    }

    /// \brief \p file is in std: under the root as spelled, or once both
    ///        are resolved (a std file reached through a symlinked tree).
    pub static fn is_std_file(ci: unsafe *CompilerInvocation, const file: string) -> bool {
        if ResourceLayout::_under_std_as_spelled(ci, file) {
            return true
        }

        var root = ResourceLayout::std_root_of(ci)
        if root.empty() {
            return false
        }

        var real_root = Path::real_path_of(root)
        if !real_root.ends_with("/") {
            real_root += "/"
        }

        return Path::real_path_of(file).starts_with(real_root)
    }
}
