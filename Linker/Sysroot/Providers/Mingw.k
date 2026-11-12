/// --- The Kairo Project ---------------------------- Providers/Mingw.k --- ///
///
///   The mingw provider: MinGW-w64 (UCRT) from the shipped input (SysRoot.md
///   4.4, 4.6). Headers are one set for every arch, copied.
///
///   With the mingw-crt input (the default share), the whole mingw-w64-crt
///   of the root is built from source, the way Zig does it: mingw-crt/<arch>
///   .toml (FORMAT.md "mingw-crt") replays the crt's own Makefile (every
///   .def.in through cpp, every source compiled, every archive made in the
///   Makefile's order) with no make or shell. Import libraries come from
///   LLVM's dlltool driver in-process (the release ships no llvm-dlltool and
///   the driver is already in libLLVM); merging members into an archive is
///   llvm-ar's (`qc`, and `qcL` for the Makefile's MRI ADDLIB). What
///   mingw-w64-crt does not build (winpthreads, libssp, winstorecompat,
///   windowsappcompat, libomp's import lib) comes verbatim from
///   mingw/crt/<arch>.
///
///   Without it (an older share), import libraries are rebuilt from
///   mingw/def/<arch>/*.def and mingw/crt/<arch> is the rest of lib/.
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
import Sysroot::CrtTable::{
    CrtArchive,
    CrtEnv,
    CrtPair,
    SysCrt,
    SysCrtTable,
}
import Sysroot::Outcome::SysOutcome
import Sysroot::Provider::{
    StageCtx,
    SysrootProvider,
}
import Sysroot::Runtimes::SysRuntimes
import Sysroot::SysRun::{
    SysJobs,
    SysRun,
}
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

        if !ctx->materialise(from, dst + "/include", &out) {
            return false
        }

        return true
    }

    pub override fn libs(self, ctx: *StageCtx, const dst: string, @inout out: SysOutcome) -> bool {
        var tables = ctx->input_dir("mingw-crt")
        if !tables.empty() {
            return MingwProvider::_from_source(ctx, tables, dst, &out)
        }

        var defs = ctx->share_path(ctx->recipe.str("libc", "defs"))
        var crt  = ctx->share_path(ctx->recipe.str("libc", "crt"))
        var machine = ctx->recipe.expand(
            "{per_arch.dlltool_machine}",
            &ctx->target,
        )

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

    /// lib/ from mingw-crt/<arch>.toml (FORMAT.md "mingw-crt", steps 1-4;
    /// Scripts/build_mingw_crt_direct.py is the reference runner).
    priv static fn _from_source(ctx:          *StageCtx,
                                const tables: string,
                                const dst:    string,
                                @inout out:   SysOutcome) -> bool {
        var tpath = f"{tables}/{ctx->target.arch}.toml"
        if !LinkFS::is_file(tpath) {
            return out.refuse(
                f"share input mingw-crt has no table for {ctx->target.arch} ({tpath})",
                "",
            )
        }

        var t = SysCrtTable()
        if !t.load(tpath) {
            return out.refuse(t.error, "")
        }

        // The tables carry configure's per-arch verdicts under this triple.
        if t.clang_triple != ctx->target.clang_triple {
            return out.refuse(
                f"{tpath} was derived for {t.clang_triple}, and this target compiles as {ctx->target.clang_triple}",
                "",
            )
        }

        var work = ctx->stage + "/crt"
        var env  = CrtEnv()
        env.src     = tables + "/src"
        env.build   = work + "/build"
        env.sysroot = work + "/sysroot"
        env.src_tag = "mingw-w64-crt"
        LinkFS::remove_tree(work)
        if !LinkFS::make_dirs(env.build) {
            return out.fail(f"cannot create {env.build}", "")
        }

        // mingw/include as include/ plus the rendered SYSROOT.toml, no c++/:
        // the root the runtimes stage compiles against.
        var toml = ctx->recipe.render_toml(&ctx->target)
        if !SysRuntimes::header_root(ctx, toml, env.sysroot, &out) {
            return false
        }

        var err = ""
        for var f: CrtPair in t.files {
            if !SysCrt::put_ref(
                f.val,
                env.src,
                tables + "/gen",
                env.build + "/" + f.key,
                false,
                &err,
            ) {
                return out.refuse(f"{tpath}: [files] {f.key}: {err}", "")
            }
        }

        if !SysCrt::compile(ctx, &t, &env, &out) {
            return false
        }

        if !MingwProvider::_archives(ctx, &t, &env, &out) {
            return false
        }

        // The prebuilt remainder first: what [install] builds wins where an
        // older share's crt/ still carries a copy of it.
        var lib   = dst + "/lib"
        var extra = ctx->share_path(ctx->recipe.str("libc", "crt"))
        if LinkFS::is_dir(extra) && !ctx->materialise(extra, lib, &out) {
            return false
        }

        for var i: CrtPair in t.install {
            var from = env.build + "/" + i.val
            if !LinkFS::is_file(from) {
                return out.fail(
                    f"{tpath}: [install] {i.key}: nothing built {i.val}",
                    "",
                )
            }

            if !SysRun::put_file(from, dst + "/" + i.key, true) {
                return out.fail(f"cannot install {from} as {dst}/{i.key}", "")
            }
        }

        LinkFS::remove_tree(work)
        return true
    }

    /// Step 3, in table order (later archives merge earlier ones): every
    /// import library through dlltool, then the objects appended to the
    /// archives that name members, then the ADDLIB merges, which read only
    /// archives of the first two kinds or earlier merges. llvm-ar's `qc`
    /// and `qcL` give the bytes the runner's `qc` and `-M` ADDLIB do, and
    /// its symbol table; a def that exports nothing and no members is
    /// still an (empty) archive.
    priv static fn _archives(ctx:        *StageCtx,
                             t:          *SysCrtTable,
                             env:        *CrtEnv,
                             @inout out: SysOutcome) -> bool {
        if ctx->ar.empty() {
            return out.refuse(
                "llvm-ar not found beside the toolchain or on PATH",
                "",
            )
        }

        for var a: CrtArchive in t->archives {
            var o = env->build + "/" + a.out
            LinkFS::make_dirs(LinkFS::parent(o))
            LinkFS::remove(o)
            if a.def.empty() {
                continue
            }

            var args = cxx::std::vector<string>()
            args.push_back("llvm-dlltool")
            args.push_back("-m")
            args.push_back(t->dlltool_machine)
            for var f: string in t->dlltool_flags {
                args.push_back(f)
            }

            args.push_back("-d")
            args.push_back(SysCrt::expand(env, a.def))
            args.push_back("-l")
            args.push_back(o)
            if MingwProvider::dlltool(&args) != 0 {
                return out.fail(
                    f"dlltool -d {SysCrt::expand(env, a.def)} failed",
                    "",
                )
            }
        }

        var logs = ctx->log_dir + "/ar"
        LinkFS::make_dirs(logs)
        var jobs       = SysJobs()
        var n:   usize = 0
        jobs.limit(ctx->jobs)
        for var a: CrtArchive in t->archives {
            if a.members.empty() {
                continue
            }

            var argv = cxx::std::vector<string>()
            argv.push_back(ctx->ar)
            argv.push_back("qc")
            argv.push_back(env->build + "/" + a.out)
            for var m: string in a.members {
                argv.push_back(env->build + "/" + m)
            }

            if !jobs.add(&argv, f"{logs}/{n}.log") {
                break
            }

            n += 1
        }

        if !jobs.wait_all() {
            var text = ""
            LinkFS::read(jobs.failed_log, &text)
            return out.fail(
                f"llvm-ar qc failed: {SysCrt::first_error(text)}",
                f"log: {jobs.failed_log}",
            )
        }

        for var a: CrtArchive in t->archives {
            var o = env->build + "/" + a.out
            if !a.addlib.empty() {
                var argv = cxx::std::vector<string>()
                argv.push_back(ctx->ar)
                argv.push_back("qcL")
                argv.push_back(o)
                for var m: string in a.addlib {
                    argv.push_back(env->build + "/" + m)
                }

                var log = f"{logs}/addlib-{n}.log"
                n += 1
                if SysRun::run(&argv, log) != 0 {
                    var text = ""
                    LinkFS::read(log, &text)
                    return out.fail(
                        f"llvm-ar qcL {a.out} failed: {SysCrt::first_error(text)}",
                        f"log: {log}",
                    )
                }
            }

            if !LinkFS::is_file(o) && !SysCrt::write_empty_archive(o) {
                return out.fail(f"cannot write {o}", "")
            }
        }

        LinkFS::remove_tree(logs)
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

        return llvm::dlltoolDriverMain(
            llvm::ArrayRef<kairo::std::ConstPtr<c_char>>(cargv),
        )
    }
}
