/// --- The Kairo Project ---------------------------- Providers/Mingw.k --- ///
///
///   The mingw provider: MinGW-w64 (UCRT) from the shipped input (SysRoot.md
///   4.4, 4.6). Headers are one set for every arch, copied. Import
///   libraries are rebuilt from mingw/def/<arch>/*.def the way the
///   mingw-w64-crt Makefile builds them (dlltool -k), through LLVM's
///   dlltool driver in-process: the release ships no llvm-dlltool and the
///   driver is already in libLLVM. mingw/crt/<arch>/ (crt objects,
///   libmingw*, the mixed import+code archives) goes into lib/ verbatim.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/ArrayRef.h"
ffi "c++" import "llvm/ToolDrivers/llvm-dlltool/DlltoolDriver.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "algorithm"
ffi "c++" import "vector"

import API::FS::LinkFS
import API::Text::LinkText
import Sysroot::Outcome::SysOutcome
import Sysroot::Provider::{
    StageCtx,
    SysrootProvider,
}
import Sysroot::SysRun::SysRun
import std::c_char

pub class MingwProvider derives SysrootProvider {
    pub fn MingwProvider(self) = default

    pub override fn id(self) -> string {
        return "mingw"
    }

    pub override fn headers(self,
                            ctx:        *StageCtx,
                            const dst:  string,
                            @inout out: SysOutcome) -> bool {
        var from = ctx->share_path(ctx->recipe.str("libc", "include"))
        if !LinkFS::is_dir(from) {
            return out.refuse(f"share input {from} missing", "")
        }

        var none = cxx::std::vector<string>()
        if !SysRun::copy_tree(from, dst + "/include", &none) {
            return out.fail(f"cannot copy {from}", "")
        }

        return true
    }

    pub override fn libs(self, ctx: *StageCtx, const dst: string, @inout out: SysOutcome) -> bool {
        var defs    = ctx->share_path(ctx->recipe.str("libc", "defs"))
        var crt     = ctx->share_path(ctx->recipe.str("libc", "crt"))
        var machine = ctx->recipe.expand("{per_arch.dlltool_machine}", &ctx->target)
        if LinkText::contains(machine, "{") {
            return out.refuse(
                f"the mingw recipe has no [per_arch.dlltool_machine] for {ctx->target.arch}",
                "",
            )
        }

        if !LinkFS::is_dir(defs) || !LinkFS::is_dir(crt) {
            return out.refuse(f"share input {defs} or {crt} missing", "")
        }

        var lib  = dst + "/lib"
        var none = cxx::std::vector<string>()
        if !SysRun::copy_tree(crt, lib, &none) {
            return out.fail(f"cannot copy {crt} into {lib}", "")
        }

        var names = LinkFS::list_dir(defs)
        cxx::std::sort(names.begin(), names.end())
        var flags = ctx->recipe.list("libc", "dlltool_flags")
        for var n: string in names {
            if !LinkText::ends_with(n, ".def") {
                continue
            }

            var stem = LinkText::slice(n, 0, n.size() - 4)
            var args = cxx::std::vector<string>()
            args.push_back("llvm-dlltool")
            args.push_back("-m")
            args.push_back(machine)
            for var f: string in flags {
                args.push_back(f)
            }

            args.push_back("-d")
            args.push_back(defs + "/" + n)
            args.push_back("-l")
            args.push_back(lib + "/lib" + stem + ".a")
            if MingwProvider::dlltool(&args) != 0 {
                return out.fail(f"dlltool -d {defs}/{n} failed", "")
            }
        }

        return true
    }

    /// llvm-dlltool's main, in-process, over \p args (args[0] the name).
    pub static fn dlltool(@inout args: cxx::std::vector<string>) -> i32 {
        // Pointers into args' own NUL-terminated bytes; args outlives the call.
        var cargv: cxx::std::vector<kairo::std::ConstPtr<c_char>>
        cargv.reserve(args.size())
        for var i: usize = 0; i < args.size(); ++i {
            cargv.push_back(args[i].c_str())
        }

        return llvm::dlltoolDriverMain(llvm::ArrayRef<kairo::std::ConstPtr<c_char>>(cargv))
    }
}
