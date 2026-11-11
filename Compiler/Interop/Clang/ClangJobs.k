/// --- The Kairo Project -------------------- Interop/Clang/ClangJobs.k --- ///
///
///   Compiles C, C++, Objective-C and LLVM IR inputs with clang, in process.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   Why the driver and not a hand-built cc1 line (as kairo's own TUs use):
///   what a C++ or ObjC or OpenCL input needs from cc1 -- the ObjC runtime
///   and ARC defaults, -cl-std and the OpenCL header, the exception and
///   unwind model per language, -main-file-name, the per-input action --
///   is exactly the per-language logic clang's driver owns. A table here
///   would drift from clang; the same reason ClangBackend probes the driver
///   for target defaults instead of tabulating them.
///
///   So: Driver::BuildCompilation on a clang argv FlagTranslator::to_driver
///   built, then every job it plans is run HERE, in this process:
///
///     clang -cc1 ...   CompilerInvocation::CreateFromArgs + a fresh
///                      CompilerInstance over the backend's shared VFS +
///                      execute_with_kairo_includes (ExecuteCompilerInvocation
///                      with the `#include "foo.k"` hook, KairoInclude.k).
///     anything else    an error naming the tool. kairo never spawns one.
///
///   Jobs are read off Compilation::getJobs() and never run through
///   Command::Execute: clang forces out-of-process execution whenever a
///   compilation has more than one job, so "simplifying" to Execute would
///   spawn subprocesses. Every argv carries -c / -S / -E / -fsyntax-only,
///   so the driver never plans a link job: kairo's Link is the only linker.
///
///   -mllvm words are left in: clang's own driver runs its cc1 jobs
///   in-process the same way and re-parses them per job (options take the
///   last value), and some only exist on this line (-masm=intel becomes
///   `-mllvm -x86-asm-syntax=intel`). Like under clang, they stay set for the
///   rest of the process. -disable-free is turned off: the driver asks cc1 to
///   leak its AST and target machine (fine for a process about to exit);
///   this one keeps compiling.
///
///   Diagnostics go through a ClangDiagAdapter into `diags`, so a C/C++
///   input's errors render like Kairo's (snippet, colour, codes); the caller
///   drains it into its engine after each run. The driver's own argument
///   diagnostics still print through the backend's text printer.
///
///   Driver thread only, like ClangBackend::native_invocation.
///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "clang/Basic/Diagnostic.h"
ffi "c++" import "clang/Driver/Compilation.h"
ffi "c++" import "clang/Driver/Driver.h"
ffi "c++" import "clang/Driver/Job.h"
ffi "c++" import "clang/Frontend/CompilerInstance.h"
ffi "c++" import "clang/Frontend/CompilerInvocation.h"
ffi "c++" import "clang/Frontend/TextDiagnosticPrinter.h"
ffi "c++" import "clang/FrontendTool/Utils.h"
ffi "c++" import "llvm/Support/Allocator.h"
ffi "c++" import "llvm/Support/StringSaver.h"
ffi "c++" import "Native/Cc1As.hh"
ffi "c++" import "optional"
ffi "c++" import "string"
ffi "c++" import "vector"
ffi "c++" import "memory"

import API::HostSystem::HostSystem
import Diagnostic::BufferedDiagSink::BufferedDiagSink
import Diagnostic::ClangDiagAdapter::ClangDiagAdapter
import Interop::Clang::ClangBackend::ClangBackend
import Interop::Clang::KairoInclude::{
    KairoIncludeSource,
    execute_with_kairo_includes,
}
import std::c_char

pub class ClangJobs {
    priv var _be: unsafe *ClangBackend
    /// argv[0] for clang's driver. A NAME, never run: the driver derives its
    /// install dir from it (its resource dir is given explicitly).
    priv var _clang_exe: string
    /// The cc1 lines of the last plan(), for --print-clang-args.
    pub var planned: cxx::std::vector<string>
    /// Why the last run()/plan() failed when clang itself said nothing (an
    /// external tool, an empty plan); "" when clang's own diagnostics,
    /// already printed, are the reason.
    pub var error: string
    /// The cc1 jobs' diagnostics, until the caller drains them.
    pub var diags: BufferedDiagSink
    /// Answers `#include "foo.k"` in a C++ input (KairoInclude.k); null
    /// leaves such an include to fail with the reason.
    pub var includes: unsafe *KairoIncludeSource = &null

    pub fn ClangJobs(self, be: unsafe *ClangBackend, const clang_exe: string) {
        self._be        = be
        self._clang_exe = clang_exe
    }

    /// \brief compiles one input: \p words is a clang driver command line
    ///        without argv[0] (FlagTranslator::to_driver + the backend's
    ///        roots + the action + `-x <lang> <src> -o <out>`).
    ///
    /// \return false on any failure, with clang's diagnostics printed.
    pub fn run(self, @inout words: cxx::std::vector<string>) -> bool {
        return self._drive(&words, true)
    }

    /// \brief what run() would execute, as `clang -cc1 ...` lines in
    ///        planned, without executing anything (clang's -###).
    pub fn plan(self, @inout words: cxx::std::vector<string>) -> bool {
        self.planned.clear()
        return self._drive(&words, false)
    }

    /// \brief a driver query (-dumpversion, -print-resource-dir, ...): clang
    ///        prints its answer while the Compilation is built, and plans no
    ///        job, which run() and plan() would report as an error.
    pub fn query(self, @inout words: cxx::std::vector<string>) -> bool {
        return self._drive(&words, false, true)
    }

    priv fn _drive(self, @inout words: cxx::std::vector<string>, execute: bool, query: bool = false) -> bool {
        self.error = ""
        self._be->startup()
        if !self._be->ready() {
            return false
        }

        var owned: llvm::BumpPtrAllocator ///< argv bytes; see ClangBackend::_owned
        var argv:  cxx::std::vector<kairo::std::ConstPtr<c_char>>
        argv.push_back(llvm::StringSaver(&owned).save(kairo::sref(self._clang_exe)).data())
        for *w in words {
            argv.push_back(llvm::StringSaver(&owned).save(kairo::sref(*w)).data())
        }

        var unsafe *diags = self._be->arg_diags()
        var        title  = "kairo"
        // A local: the Driver keeps this StringRef, and a temporary from
        // triple() dangled (a query prints paths built from it, as garbage).
        var        triple = self._be->triple()
        var drv = clang::driver::Driver(
            kairo::sref(self._clang_exe),
            kairo::sref(triple),
            &*diags,
            kairo::std::to_std_string(title),
            self._be->vfs(),
        )

        // containsError covers argument parsing only; errors the driver
        // reports while planning (a bad -march, an unknown -x) only reach the
        // engine, so its count is the real test.
        var errs_before = diags->getNumErrors()
        var comp = cxx::std::unique_ptr<clang::driver::Compilation>(
            drv.BuildCompilation(llvm::ArrayRef<unsafe *const c_char>(argv)),
        )

        if comp.get() == &null || comp->containsError() {
            return false
        }

        if diags->getNumErrors() != errs_before {
            return false
        }

        var *jobs = &comp->getJobs().getJobs()
        if query {
            return true
        }

        if jobs->size() == 0 {
            self.error = "clang planned nothing to run for this input"
            return false
        }

        for var j: usize = 0; j < jobs->size(); ++j {
            var unsafe *cmd = (*jobs)[j].get()
            // Copied: the job's list is const, and the bytes stay owned by
            // the Compilation, which outlives this loop.
            var cc1: cxx::std::vector<kairo::std::ConstPtr<c_char>>
            var n                                                   = cmd->getArguments().size()
            var first = if (n > 0) => (string(
                            unsafe ((cmd->getArguments()[0] as unsafe *const u8) as *const u8),
                        ))
                        else => ""
            var is_cc1   = first == "-cc1"
            var is_cc1as = first == "-cc1as"
            // Anything else is a tool clang itself would spawn (ptxas for CUDA,
            // an external `as` under -fno-integrated-as, ...): kcc is a drop-in
            // clang, so it spawns it too rather than refusing the input.
            if !is_cc1 && !is_cc1as {
                if !execute {
                    var ext = string(
                        unsafe ((cmd->getExecutable() as unsafe *const u8) as *const u8),
                    )

                    for var k: usize = 0; k < n; ++k {
                        ext = ext + " " + string(
                            unsafe ((cmd->getArguments()[k] as unsafe *const u8) as *const u8),
                        )
                    }

                    self.planned.push_back(ext)
                    continue
                }

                if !self._external(cmd) {
                    return false
                }

                continue
            }

            var drop = ClangJobs::_env_drops(cmd, self._be->strip_env())
            for var k: usize = 1; k < n; ++k {
                if drop[k] != 0 {
                    continue
                }

                cc1.push_back(cmd->getArguments()[k])
            }

            if !execute {
                var line = "clang -cc1"
                for var k: usize = 0; k < cc1.size(); ++k {
                    line = line + " " + string(unsafe ((cc1[k] as unsafe *const u8) as *const u8))
                }

                self.planned.push_back(line)
                continue
            }

            if is_cc1as {
                if !self._cc1as(cc1) {
                    return false
                }

                continue
            }

            if !self._cc1(cc1) {
                return false
            }
        }

        return true
    }

    /// One `clang -cc1as` job (an .s, or the assemble step of an .S), in-process
    /// through clang's own cc1as_main (Native/Cc1As.hh). \p args excludes
    /// "-cc1as", as clang's driver passes them. Its diagnostics go to stderr
    /// with the "clang -cc1as" prefix, as clang prints them.
    priv fn _cc1as(self, const args: cxx::std::vector<kairo::std::ConstPtr<c_char>>) -> bool {
        var owned: llvm::BumpPtrAllocator ///< a NUL-terminated argv0
        var unsafe *argv0 = llvm::StringSaver(&owned).save(kairo::sref(self._clang_exe)).data()
        var        rc     = cc1as_main(llvm::ArrayRef<unsafe *const c_char>(args), argv0, &null)
        if rc != 0 {
            self.error = "the assembler (clang -cc1as) failed"
            return false
        }

        return true
    }

    /// A job for a tool outside clang, run as clang's driver runs it.
    priv fn _external(self, cmd: unsafe *clang::driver::Command) -> bool {
        var msg    = cxx::std::string()
        var failed = false
        var none   = llvm::ArrayRef<cxx::std::optional<llvm::StringRef>>()
        var rc     = cmd->Execute(none, unsafe &msg, unsafe &failed)
        if failed || rc != 0 {
            var exe = string(unsafe ((cmd->getExecutable() as unsafe *const u8) as *const u8))
            var why = kairo::std::from_std_string<string>(msg)
            self.error = if (failed) => (f"could not run '{exe}': {why}")
                         else => (f"'{exe}' failed (exit {rc})")
            return false
        }

        return true
    }

    /// Which words of \p cmd's cc1 line came from CPATH, C_INCLUDE_PATH or
    /// CPLUS_INCLUDE_PATH, when \p strip (a hermetic --target build): clang's
    /// driver reads them from the environment itself, and a cross build
    /// must not see the build machine's header dirs. CPATH is clang's
    /// combined -I<dir>, after the command line's own -I, so its LAST match
    /// is the one removed; the others are -c-isystem / -cxx-isystem pairs,
    /// which nothing else in a Kairo line spells.
    priv static fn _env_drops(cmd:   unsafe *clang::driver::Command,
                              strip: bool) -> cxx::std::vector<u8> {
        var n    = cmd->getArguments().size()
        var drop = cxx::std::vector<u8>()
        for var k: usize = 0; k < n; ++k {
            drop.push_back(0)
        }

        if !strip {
            return drop
        }

        var sys = cxx::std::vector<string>()
        for var d: string in HostSystem::env_list("C_INCLUDE_PATH") {
            sys.push_back(d)
        }

        for var d: string in HostSystem::env_list("CPLUS_INCLUDE_PATH") {
            sys.push_back(d)
        }

        for var d: string in HostSystem::env_list("OBJC_INCLUDE_PATH") {
            sys.push_back(d)
        }

        for var k: usize = 1; k < n; ++k {
            var a = string(unsafe ((cmd->getArguments()[k] as unsafe *const u8) as *const u8))
            var pair = a == "-c-isystem"
                || a == "-cxx-isystem"
                || a == "-objc-isystem"
                || a == "-objcxx-isystem"
            if pair && k + 1 < n {
                var v = string(
                    unsafe ((cmd->getArguments()[k + 1] as unsafe *const u8) as *const u8),
                )

                for *d in sys {
                    if *d == v {
                        drop[k]     = 1
                        drop[k + 1] = 1
                    }
                }
            }
        }

        for var d: string in HostSystem::env_list("CPATH") {
            var want       = "-I" + d
            var at:  usize = 0
            for var k: usize = 1; k < n; ++k {
                if string(
                    unsafe ((cmd->getArguments()[k] as unsafe *const u8) as *const u8),
                ) == want {
                    at = k
                }
            }

            if at != 0 {
                drop[at] = 1
            }
        }

        return drop
    }

    /// One `clang -cc1` job, in-process.
    priv fn _cc1(self, const cc1: cxx::std::vector<kairo::std::ConstPtr<c_char>>) -> bool {
        var inv = cxx::std::make_shared<clang::CompilerInvocation>()
        if !clang::CompilerInvocation::CreateFromArgs(
            &*inv.get(),
            llvm::ArrayRef<unsafe *const c_char>(cc1),
            &*self._be->arg_diags(),
        ) {
            return false
        }

        // Both copies: CreateFromArgs already copied -disable-free into the
        // codegen options, which would bury every TargetMachine.
        inv.get()->getFrontendOpts().DisableFree = 0
        inv.get()->getCodeGenOpts().DisableFree  = 0

        // The adapter renders, so clang's "N errors generated." trailer
        // (printed only with carets on) would be a stray second summary.
        inv.get()->getDiagnosticOpts().ShowCarets = 0

        // A fresh adapter per job: ExecuteAction reports failure from the
        // CLIENT's error count, and a shared client would carry one input's
        // errors into every later input. No locmap and no fidmap: it loads
        // each file clang names by path.
        var unsafe *a = kairo::std::create<ClangDiagAdapter>()
        a->sink = unsafe &self.diags
        a->ksm  = self._be->ksm()
        a->kfid = (u32::MAX)
        var unsafe *ci = kairo::std::create<clang::CompilerInstance>(inv)
        // The instance first: its engine borrows the adapter to the end.
        finally {
            kairo::std::destroy(ci)
            a->finish()
            kairo::std::destroy(a)
        }

        ci->setVirtualFileSystem(self._be->vfs())
        ci->createDiagnostics(a, false)
        if !ci->hasDiagnostics() {
            return false
        }

        var ok = execute_with_kairo_includes(ci, self.includes)
        // The CLIENT's count, as ExecuteAction's own verdict: under -verify
        // the client is clang's VerifyDiagnosticConsumer, which keeps the
        // expected errors from counting, while the engine counted them all.
        return ok && ci->getDiagnostics().getClient()->getNumErrors() == 0
    }
}
