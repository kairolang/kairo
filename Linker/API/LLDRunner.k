/// --- The Kairo Project ------------------------------ API/LLDRunner.k --- ///
///
///   Runs an lld argv in process or through kld and captures its output.
///
///   \par In process
///     lld::lldMain runs on a global CommonLinkerContext and destroys it on
///     return, so links are serialized on a process-wide mutex. One link at
///     a time, which costs nothing: lld parallelizes internally (--threads).
///
///     CrashRecoveryContext is enabled before the first link and never
///     disabled. Without it, lld's fatal() ends in exitLld ->
///     llvm_shutdown() -> Process::Exit(NoCleanup), and one corrupt input
///     object kills the compiler mid-build with nothing flushed. With it,
///     RunSafely longjmps back and lldMain returns. Outside a recovery
///     context its signal handler disables itself and re-raises, so
///     InitLLVM's stack-trace handler still runs on a real compiler crash.
///
///   \par Poisoning
///     canRunAgain == false (a fatal() or a crash unwound out of lld, or the
///     context teardown failed) means lld's globals are not trustworthy. The
///     flag latches: every later link in this process goes through kld.
///     The failed link itself is never retried; its errors were printed.
///
///   \par Always out of process
///     -mllvm and --plugin-opt=-<x> reach cl::ParseCommandLineOptions and
///     rewrite the compiler's own global cl state, so any argv carrying
///     them runs through kld. So does a job that forces it.
///
///   \par What stays uncaught
///     A crash on one of lld's own worker threads has no recovery context
///     there and still takes the process down. Only out-of-process isolates
///     that.
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
ffi "c++" import "lld/Common/Driver.h"
ffi "c++" import "llvm/ADT/ArrayRef.h"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/Support/CrashRecoveryContext.h"
ffi "c++" import "llvm/Support/Program.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "Include/kld_drivers.hh"
ffi "c++" import "vector"
ffi "c++" import "string"
ffi "c++" import "optional"

import API::FS::LinkFS
import API::Text::LinkText
import std::c_char

pub struct LLDRun {
    var ret:          i32    = 1
    var in_process:   bool   = true
    var poisoned_now: bool   = false ///< this run latched the poison flag
    var stdout_text:  string
    var stderr_text:  string
    var spawn_error:  string         ///< set only when nothing ran
}

pub class LLDRunner {
    /// \p argv[0] carries the flavor: ld.lld, ld64.lld, lld-link, wasm-ld.
    static fn run(@inout argv:    cxx::std::vector<string>,
                  const kld_path: string,
                  force_process:  bool) -> LLDRun {
        if force_process || LLDRunner::poisoned() || LLDRunner::needs_process(&argv) {
            return LLDRunner::_spawn(&argv, kld_path)
        }

        return LLDRunner::_in_process(&argv)
    }

    static fn poisoned() -> bool {
        return LLDRunner::_poison()->load()
    }

    static fn needs_process(@inout argv: cxx::std::vector<string>) -> bool {
        for var a: string in argv {
            if a == "-mllvm" || a == "--mllvm" {
                return true
            }

            if LinkText::starts_with(a, "-mllvm=") || LinkText::starts_with(a, "--mllvm=") {
                return true
            }

            if LinkText::starts_with(a, "-plugin-opt=-")
                || LinkText::starts_with(a, "--plugin-opt=-") {
                return true
            }
        }

        return false
    }

    static fn flavor_of(const argv0: string) -> string {
        if argv0 == "ld64.lld" {
            return "darwin"
        }

        if argv0 == "lld-link" {
            return "link"
        }

        if argv0 == "wasm-ld" {
            return "wasm"
        }

        return "gnu"
    }

    /// # in process

    priv static fn _mu() -> unsafe *kairo::std::Mutex {
        static mu: kairo::std::Mutex
        return unsafe &mu
    }

    priv static fn _poison() -> unsafe *kairo::std::Atomic<bool> {
        static p: kairo::std::Atomic<bool> = kairo::std::Atomic<bool>(false)
        return unsafe &p
    }

    priv static fn _in_process(@inout argv: cxx::std::vector<string>) -> LLDRun {
        var res  = LLDRun{}
        var lock = kairo::std::LockGuard(*LLDRunner::_mu())

        llvm::CrashRecoveryContext::Enable()

        // Pointers straight into argv's own (NUL-terminated) bytes: lld keeps
        // them for the whole link, and argv is the caller's and outlives it.
        // Indexed, not `for a in`: a by-value loop variable would hand lld a
        // pointer into a copy that dies at the end of each iteration.
        var cargv: cxx::std::vector<kairo::std::ConstPtr<c_char>>
        cargv.reserve(argv.size())
        for var i: usize = 0; i < argv.size(); ++i {
            cargv.push_back(argv[i].c_str())
        }

        var out_buf: cxx::std::string
        var err_buf: cxx::std::string
        var out_os                    = llvm::raw_string_ostream(&out_buf)
        var err_os                    = llvm::raw_string_ostream(&err_buf)

        var r = lld::lldMain(
            llvm::ArrayRef<kairo::std::ConstPtr<c_char>>(cargv),
            &out_os,
            &err_os,
            kld_driver_list(),
        )

        out_os.flush()
        err_os.flush()

        res.ret = r.retCode
        res.stdout_text = string(
            unsafe ((out_buf.data() as unsafe *const u8) as *const u8),
            out_buf.size(),
        )

        res.stderr_text = string(
            unsafe ((err_buf.data() as unsafe *const u8) as *const u8),
            err_buf.size(),
        )

        if !r.canRunAgain {
            LLDRunner::_poison()->store(true)
            res.poisoned_now = true
        }

        return res
    }

    /// # out of process

    priv static fn _spawn(@inout argv: cxx::std::vector<string>, kld_path: string) -> LLDRun {
        var res = LLDRun{}
        res.in_process = false

        if kld_path.empty() || !LinkFS::is_file(kld_path) {
            var _where = if (kld_path.empty()) => ("<unset>") else => kld_path
            res.spawn_error = f"this link has to run out of process, and kld was not found at {_where}"
            return res
        }

        // kld is a generic lld: the flavor goes in as -flavor at argv[1],
        // which lld reads before any response file is expanded.
        var flavor = LLDRunner::flavor_of(argv[0])
        var rest   = cxx::std::vector<string>()
        for var i: usize = 1; i < argv.size(); ++i {
            rest.push_back(argv[i])
        }

        var out_path = LinkFS::temp_file("kld-out", "txt")
        var err_path = LinkFS::temp_file("kld-err", "txt")
        var rsp_path = ""
        finally {
            if !out_path.empty() {
                LinkFS::remove(out_path)
            }

            if !err_path.empty() {
                LinkFS::remove(err_path)
            }

            if !rsp_path.empty() {
                LinkFS::remove(rsp_path)
            }
        }

        var args = cxx::std::vector<string>()
        args.push_back(kld_path)
        args.push_back("-flavor")
        args.push_back(flavor)
        for var a: string in rest {
            args.push_back(a)
        }

        if !LLDRunner::_fits(&args) {
            rsp_path = LinkFS::temp_file("kld", "rsp")
            var text = ""
            for var a: string in rest {
                text += LinkText::quote_rsp(a)
                text += "\n"
            }

            if rsp_path.empty() || !LinkFS::write(rsp_path, text) {
                res.spawn_error = "cannot write the linker response file"
                return res
            }

            args.clear()
            args.push_back(kld_path)
            args.push_back("-flavor")
            args.push_back(flavor)
            // quote_rsp escapes backslashes GNU-style. lld-link defaults to
            // Windows tokenization, which would keep both of them.
            if flavor == "gnu" || flavor == "wasm" || flavor == "link" {
                args.push_back("--rsp-quoting=posix")
            }

            args.push_back(f"@{rsp_path}")
        }

        // Views of args' own bytes; args is not touched again while refs lives.
        var refs: cxx::std::vector<llvm::StringRef>
        refs.reserve(args.size())
        for var i: usize = 0; i < args.size(); ++i {
            refs.push_back(kairo::sref(args[i]))
        }

        var nout = kairo::std::to_std_string(out_path)
        var nerr = kairo::std::to_std_string(err_path)
        var redir: cxx::std::vector<cxx::std::optional<llvm::StringRef>>
        redir.push_back(cxx::std::optional<llvm::StringRef>(cxx::std::nullopt))
        if nout.empty() {
            redir.push_back(
                cxx::std::optional<llvm::StringRef>(cxx::std::nullopt),
            )
        } else {
            redir.push_back(
                cxx::std::optional<llvm::StringRef>(llvm::StringRef(nout)),
            )
        }

        if nerr.empty() {
            redir.push_back(
                cxx::std::optional<llvm::StringRef>(cxx::std::nullopt),
            )
        } else {
            redir.push_back(
                cxx::std::optional<llvm::StringRef>(llvm::StringRef(nerr)),
            )
        }

        var emsg:  cxx::std::string
        var failed                  = false
        var rc = llvm::sys::ExecuteAndWait(
            refs[0],
            llvm::ArrayRef<llvm::StringRef>(refs),
            cxx::std::optional<llvm::ArrayRef<llvm::StringRef>>(
                cxx::std::nullopt,
            ),
            llvm::ArrayRef<cxx::std::optional<llvm::StringRef>>(redir),
            0,
            0,
            unsafe &emsg,
            unsafe &failed,
        )

        if failed {
            res.spawn_error = f"cannot run {kld_path}: {string(unsafe ((emsg.data() as unsafe *const u8) as *const u8), emsg.size())}"
            return res
        }

        res.ret = rc
        var t = ""
        if !out_path.empty() && LinkFS::read(out_path, &t) {
            res.stdout_text = t
        }

        t = ""
        if !err_path.empty() && LinkFS::read(err_path, &t) {
            res.stderr_text = t
        }

        return res
    }

    priv static fn _fits(@inout args: cxx::std::vector<string>) -> bool {
        // Views of args' own bytes; args is not touched again while refs lives.
        var refs: cxx::std::vector<llvm::StringRef>
        refs.reserve(args.size())
        for var i: usize = 0; i < args.size(); ++i {
            refs.push_back(kairo::sref(args[i]))
        }

        return llvm::sys::commandLineFitsWithinSystemLimits(
            refs[0],
            llvm::ArrayRef<llvm::StringRef>(refs),
        )
    }
}
