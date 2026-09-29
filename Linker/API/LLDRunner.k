/// --- The Kairo Project --------------------- Linker/API/LLDRunner.k ----- ///
///
///   \brief Runs an lld argv, in process or through kld, and captures what
///          it printed. The only file in the compiler that touches lld.
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "lld/Common/Driver.h";
ffi "c++" import "llvm/ADT/ArrayRef.h";
ffi "c++" import "llvm/ADT/StringRef.h";
ffi "c++" import "llvm/Support/CrashRecoveryContext.h";
ffi "c++" import "llvm/Support/Program.h";
ffi "c++" import "llvm/Support/raw_ostream.h";
ffi "c++" import "Include/kld_drivers.hh";

import Linker::API::Text::*;
import Linker::API::FS::*;

struct LLDRun {
    var ret:          i32  = 1;
    var in_process:   bool = true;
    var poisoned_now: bool = false;   ///< this run latched the poison flag
    var stdout_text:  string;
    var stderr_text:  string;
    var spawn_error:  string;         ///< set only when nothing ran
}

class LLDRunner {
    /// \p argv[0] carries the flavor: ld.lld, ld64.lld, lld-link, wasm-ld.
    static fn run(argv: ref!(vec::<string>), kld_path: string, force_process: bool) -> LLDRun {
        if force_process || LLDRunner::poisoned() || LLDRunner::needs_process(argv) {
            return LLDRunner::_spawn(argv, kld_path);
        }
        return LLDRunner::_in_process(argv);
    }

    static fn poisoned() -> bool { return LLDRunner::_poison()->load(); }

    static fn needs_process(argv: ref!(vec::<string>)) -> bool {
        for a: string in argv {
            if (a == "-mllvm") || (a == "--mllvm") { return true; }
            if LinkText::starts_with(a, "-mllvm=") || LinkText::starts_with(a, "--mllvm=") { return true; }
            if LinkText::starts_with(a, "-plugin-opt=-") || LinkText::starts_with(a, "--plugin-opt=-") { return true; }
        }
        return false;
    }

    static fn flavor_of(argv0: string) -> string {
        if argv0 == "ld64.lld" { return "darwin"; }
        if argv0 == "lld-link" { return "link";   }
        if argv0 == "wasm-ld"  { return "wasm";   }
        return "gnu";
    }

    // --- in process -----------------------------------------------------------

    priv static fn _mu() -> *std::Mutex {
        static var mu: std::Mutex;
        return &mu;
    }

    priv static fn _poison() -> *std::Atomic::<bool> {
        static var p: std::Atomic::<bool> = false;
        return &p;
    }

    priv static fn _in_process(argv: ref!(vec::<string>)) -> LLDRun {
        var res  = LLDRun{};
        var lock = std::LockGuard(*(LLDRunner::_mu()));

        llvm::CrashRecoveryContext::Enable();

        // Narrow copies with stable addresses: lld keeps the char pointers
        // for the whole link.
        var owned: libcxx::deque::<libcxx::string>;
        var cargv: libcxx::vector::<std::ConstPtr::<std::Legacy::char>>;
        for a: string in argv {
            owned.push_back(libcxx::string(std::string_to_nstring(a).raw_string()));
            cargv.push_back(owned.back().c_str());
        }

        var out_buf: libcxx::string;
        var err_buf: libcxx::string;
        var out_os = llvm::raw_string_ostream(out_buf);
        var err_os = llvm::raw_string_ostream(err_buf);

        var r = lld::lldMain(
            llvm::ArrayRef::<std::ConstPtr::<std::Legacy::char>>(cargv),
            out_os, err_os, kld_drivers);
        out_os.flush();
        err_os.flush();

        res.ret         = r.retCode;
        res.stdout_text = std::nstring_to_string(out_buf);
        res.stderr_text = std::nstring_to_string(err_buf);
        if !r.canRunAgain {
            LLDRunner::_poison()->store(true);
            res.poisoned_now = true;
        }
        return res;
    }

    // --- out of process ----------------------------------------------------

    priv static fn _spawn(argv: ref!(vec::<string>), kld_path: string) -> LLDRun {
        var res = LLDRun{};
        res.in_process = false;

        if kld_path.empty() || (!LinkFS::is_file(kld_path)) {
            var _where = ("<unset>") if (kld_path.empty()) else (kld_path);
            res.spawn_error = f"this link has to run out of process, and kld was not found at {_where}";
            return res;
        }

        // kld is a generic lld: the flavor goes in as -flavor at argv[1],
        // which lld reads before any response file is expanded.
        var flavor = LLDRunner::flavor_of(argv[0]);
        var rest   = vec::<string>();
        for var i: usize = 1; i < argv.size(); ++i { rest.push_back(argv[i]); }

        var out_path = LinkFS::temp_file("kld-out", "txt");
        var err_path = LinkFS::temp_file("kld-err", "txt");
        var rsp_path = "";
        finally {
            if !out_path.empty() { LinkFS::remove(out_path); }
            if !err_path.empty() { LinkFS::remove(err_path); }
            if !rsp_path.empty() { LinkFS::remove(rsp_path); }
        }

        var args = vec::<string>();
        args.push_back(kld_path);
        args.push_back("-flavor");
        args.push_back(flavor);
        for a: string in rest { args.push_back(a); }

        if !LLDRunner::_fits(args) {
            rsp_path = LinkFS::temp_file("kld", "rsp");
            var text = "";
            for a: string in rest {
                text += LinkText::quote_rsp(a);
                text += "\n";
            }
            if rsp_path.empty() || (!LinkFS::write(rsp_path, text)) {
                res.spawn_error = "cannot write the linker response file";
                return res;
            }
            args.clear();
            args.push_back(kld_path);
            args.push_back("-flavor");
            args.push_back(flavor);
            if (flavor == "gnu") || (flavor == "wasm") { args.push_back("--rsp-quoting=posix"); }
            args.push_back(f"@{rsp_path}");
        }

        var owned: libcxx::deque::<libcxx::string>;
        var refs:  libcxx::vector::<llvm::StringRef>;
        for a: string in args {
            owned.push_back(libcxx::string(std::string_to_nstring(a).raw_string()));
            refs.push_back(llvm::StringRef(owned.back()));
        }

        var nout = libcxx::string(std::string_to_nstring(out_path).raw_string());
        var nerr = libcxx::string(std::string_to_nstring(err_path).raw_string());
        var redir: libcxx::vector::<libcxx::optional::<llvm::StringRef>>;
        redir.push_back(libcxx::nullopt);
        if nout.empty() { redir.push_back(libcxx::nullopt); }
        else            { redir.push_back(libcxx::optional::<llvm::StringRef>(llvm::StringRef(nout))); }
        if nerr.empty() { redir.push_back(libcxx::nullopt); }
        else            { redir.push_back(libcxx::optional::<llvm::StringRef>(llvm::StringRef(nerr))); }

        var emsg: libcxx::string;
        var failed = false;
        var rc = llvm::sys::ExecuteAndWait(
            refs[0],
            llvm::ArrayRef::<llvm::StringRef>(refs),
            libcxx::nullopt,
            llvm::ArrayRef::<libcxx::optional::<llvm::StringRef>>(redir),
            0, 0, &emsg, &failed);

        if failed {
            res.spawn_error = f"cannot run {kld_path}: {std::nstring_to_string(emsg)}";
            return res;
        }

        res.ret = rc;
        var t = "";
        if (!out_path.empty()) && LinkFS::read(out_path, t) { res.stdout_text = t; }
        t = "";
        if (!err_path.empty()) && LinkFS::read(err_path, t) { res.stderr_text = t; }
        return res;
    }

    priv static fn _fits(args: ref!(vec::<string>)) -> bool {
        var owned: libcxx::deque::<libcxx::string>;
        var refs:  libcxx::vector::<llvm::StringRef>;
        for a: string in args {
            owned.push_back(libcxx::string(std::string_to_nstring(a).raw_string()));
            refs.push_back(llvm::StringRef(owned.back()));
        }
        return llvm::sys::commandLineFitsWithinSystemLimits(refs[0], llvm::ArrayRef::<llvm::StringRef>(refs));
    }
}