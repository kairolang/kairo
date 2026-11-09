/// --- The Kairo Project ---------------------------------- Driver/ksys.k --- ///
///
///   ksys: the sysroot generator, by hand (Compiler/Spec/SysRoot.md).
///
///     ksys probe    <target>
///     ksys ensure   <target> [--glibc=X.Y] [--input DIR]   path on stdout
///     ksys build    <target> [--glibc=X.Y] [--input DIR] --out DIR
///     ksys validate <dir>
///     ksys verify-share
///     ksys ls | gc | rm <name>
///
///   Global options, before or after the command: --share DIR (the input
///   tree; else $KAIRO_SYSROOT_SHARE, else <prefix>/share/kairo/sysroot),
///   --cache DIR (else $KAIRO_SYSROOT_CACHE, else the toolchain cache root's
///   sysroot/), -j N / --jobs N (compiles in flight; else $KSYS_JOBS, else
///   one per hardware thread), -q. And --help, --version,
///   --print-runtimes-revision.
///
///   A thin shell over Linker/Sysroot: kairo's --target hook calls the same
///   library in-process, as it calls the linker library rather than kld.
///
///   Exit: 0 ok, 1 usage, 2 refusal, 3 build or validation failure. Logs and
///   refusals go to stderr in the compiler's basic one-line form, so a
///   refusal reads the same from ksys as from kairo.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/Support/InitLLVM.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "cstring"
ffi "c++" import "vector"

import API::Text::LinkText
import Driver::Runtime::init_runtime
import Sysroot::Generator::SysGen
import Sysroot::Outcome::SysOutcome
import std::c_char
import std::io

fn ksys_usage() -> string {
    var u = ""
    u += "usage: ksys [--share DIR] [--cache DIR] [-j N] [-q] <command>\n"
    u += "  probe <target>                               parse and probe; print the table\n"
    u += "  ensure <target> [--glibc=X.Y] [--input DIR]  the cached sysroot (built if missing); path on stdout\n"
    u += "  build <target> [--glibc=X.Y] [--input DIR] --out DIR\n"
    u += "                                               build into DIR, uncached\n"
    u += "  validate <dir>                               check a sysroot\n"
    u += "  verify-share                                 re-hash every input of the share tree\n"
    u += "  ls                                           cached sysroots by name\n"
    u += "  gc                                           drop unnamed sysroots and stage dirs older than 30 days\n"
    u += "  rm <name>                                    drop a cached sysroot\n"
    u += "  --print-runtimes-revision                    the LLVM runtimes revision this toolchain was built from\n"
    u += "<target> is a sysroot name (x86_64-linux-musl, x86_64-linux-gnu-glibc2.31) or a clang triple.\n"
    u += "exit: 0 ok, 1 usage, 2 refusal, 3 build or validation failure"
    return u
}

/// Prints \p o's refusal or failure the way the compiler's basic error
/// format prints P009E / P010E, and returns its exit status.
fn ksys_report(@inout o: SysOutcome) -> i32 {
    if o.status == 0 {
        return 0
    }

    var code = if (o.status == 3) => ("P010E") else => "P009E"
    io::eprintln(f"ksys: error [{code}]: {o.message}")
    if !o.note.empty() {
        io::eprintln(f"ksys: note [P009N]: {o.note}")
    }

    return o.status
}

fn ksys_usage_error(const what: string) -> i32 {
    io::eprintln(f"ksys: error: {what}")
    io::eprintln("ksys: try `ksys --help`")
    return 1
}

/// `--name=value` or `--name value`; true when argv[i] is that option, with
/// \p i advanced past its value.
fn ksys_opt(@inout args: cxx::std::vector<string>,
            @inout i:    usize,
            const name:  string,
            @inout val:  string) -> bool {
    var a = args[i]
    if LinkText::starts_with(a, name + "=") {
        val = LinkText::slice(a, name.size() + 1, a.size())
        return true
    }

    if a == name && i + 1 < args.size() {
        i += 1
        val = args[i]
        return true
    }

    return false
}

pub fn main(argc: i32, argv: unsafe *(unsafe *c_char)) -> i32 {
    // The probe asks LLVM's TargetRegistry for the backend, so every target
    // must be registered, as in kairo.
    var unsafe *llvm_init = init_runtime(argc, argv)
    finally {
        kairo::std::destroy(llvm_init)
    }

    var args = cxx::std::vector<string>()
    for var i: i32 = 1; i < argc; ++i {
        args.push_back(string(unsafe ((argv[i] as unsafe *const u8) as *const u8)))
    }

    var gen     = SysGen()
    var out_dir = ""
    var words   = cxx::std::vector<string>()
    for var i: usize = 0; i < args.size(); ++i {
        var a = args[i]
        var v = ""
        if a == "--help" || a == "-h" {
            io::println(ksys_usage())
            return 0
        }

        if a == "--version" {
            io::println(f"installed version: {SysGen::tool_version()}")
            io::println(f"runtimes revision: {SysGen::runtimes_revision()}")
            return 0
        }

        if a == "--print-runtimes-revision" {
            io::println(SysGen::runtimes_revision())
            return 0
        }

        if a == "-q" || a == "--quiet" {
            gen.quiet = true
        } else if ksys_opt(&args, &i, "--share", &v) {
            gen.share_flag = v
        } else if ksys_opt(&args, &i, "--cache", &v) {
            gen.cache_root = v
        } else if ksys_opt(&args, &i, "--glibc", &v) {
            gen.glibc = v
        } else if ksys_opt(&args, &i, "--input", &v) {
            gen.input = v
        } else if ksys_opt(&args, &i, "--out", &v) {
            out_dir = v
        } else if ksys_opt(&args, &i, "--jobs", &v)
            || ksys_opt(&args, &i, "-j", &v)
            || LinkText::starts_with(a, "-j") && a.size() > 2 {
            if v.empty() {
                v = LinkText::slice(a, 2, a.size())
            }

            var n: usize = 0
            for var k: usize = 0; k < v.size(); ++k {
                if v[k] < ('0' as u8) || v[k] > ('9' as u8) {
                    return ksys_usage_error(f"-j wants a number of jobs, not {v}")
                }

                n = n * 10 + ((v[k] - ('0' as u8)) as usize)
            }

            if n == 0 {
                return ksys_usage_error("-j wants at least one job")
            }

            gen.jobs = n
        } else if LinkText::starts_with(a, "-") && a.size() > 1 {
            return ksys_usage_error(f"unknown option {a}")
        } else {
            words.push_back(a)
        }
    }

    if words.empty() {
        return ksys_usage_error("no command")
    }

    var cmd   = words[0]
    var o     = SysOutcome()
    var nargs = words.size() - 1
    var want = if (cmd == "probe"
                   || cmd == "ensure"
                   || cmd == "build"
                   || cmd == "validate"
                   || cmd == "rm") => (1)
               else => 0
    if cmd != "probe"
        && cmd != "ensure"
        && cmd != "build"
        && cmd != "validate"
        && cmd != "verify-share"
        && cmd != "ls"
        && cmd != "gc"
        && cmd != "rm" {
        return ksys_usage_error(f"unknown command {cmd}")
    }

    if nargs != (want as usize) {
        return ksys_usage_error(f"{cmd} takes {want} argument(s), got {nargs}")
    }

    if cmd == "probe" {
        gen.probe(words[1], &o)
        return ksys_report(&o)
    }

    if cmd == "ensure" {
        var path = ""
        if gen.ensure(words[1], &path, &o) {
            io::println(path)
        }

        return ksys_report(&o)
    }

    if cmd == "build" {
        if out_dir.empty() {
            return ksys_usage_error("build needs --out DIR")
        }

        gen.build(words[1], out_dir, &o)
        return ksys_report(&o)
    }

    if cmd == "validate" {
        gen.validate(words[1], &o)
        return ksys_report(&o)
    }

    if cmd == "verify-share" {
        gen.verify_share(&o)
        return ksys_report(&o)
    }

    var c = gen.cache()
    if c.root.empty() {
        o.refuse("no cache directory for sysroots", "set KAIRO_SYSROOT_CACHE, or pass --cache DIR")
        return ksys_report(&o)
    }

    if cmd == "ls" {
        for var line: string in c.list() {
            io::println(line)
        }

        return 0
    }

    if cmd == "gc" {
        // 30 days in the filesystem clock's ticks (llvm's TimePoint is
        // nanoseconds on every host).
        var month: u64 = 30 * 24 * 3600 * (1000000000 as u64)
        for var p: string in c.gc(c.now(), month) {
            io::println(f"removed {p}")
        }

        return 0
    }

    if !c.remove_name(words[1]) {
        o.refuse(f"no cached sysroot named {words[1]}", "`ksys ls` lists them")
        return ksys_report(&o)
    }

    return 0
}
