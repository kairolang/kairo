/// --- The Kairo Project -------------------- Interop/Clang/ClangJobs.k --- ///
///
///   C, C++, Objective-C and LLVM IR inputs, compiled by clang's own driver
///   and frontend, in-process.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
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
///                      CompilerInstance over the backend's shared VFS and
///                      printer + ExecuteCompilerInvocation.
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
///   Driver thread only, like ClangBackend::compile_native.
///

ffi "c++" import "Native/Types.hh";
ffi "c++" import "clang/Basic/Diagnostic.h";
ffi "c++" import "clang/Driver/Compilation.h";
ffi "c++" import "clang/Driver/Driver.h";
ffi "c++" import "clang/Driver/Job.h";
ffi "c++" import "clang/Frontend/CompilerInstance.h";
ffi "c++" import "clang/Frontend/CompilerInvocation.h";
ffi "c++" import "clang/Frontend/TextDiagnosticPrinter.h";
ffi "c++" import "clang/FrontendTool/Utils.h";
ffi "c++" import "llvm/Support/Allocator.h";
ffi "c++" import "llvm/Support/StringSaver.h";

import Interop::Clang::ClangBackend::*;

class ClangJobs {
    priv var _be:        obs::<ClangBackend>;
    /// argv[0] for clang's driver. A NAME, never run: the driver derives its
    /// install dir from it (its resource dir is given explicitly).
    priv var _clang_exe: string;
    /// The cc1 lines of the last plan(), for --print-clang-args.
    pub var planned: vec::<string>;
    /// Why the last run()/plan() failed when clang itself said nothing (an
    /// external tool, an empty plan); "" when clang's own diagnostics,
    /// already printed, are the reason.
    pub var error: string;

    fn ClangJobs(self, be: *ClangBackend, clang_exe: string) {
        self._be        = be;
        self._clang_exe = clang_exe;
    }

    /// \brief compiles one input: \p words is a clang driver command line
    ///        without argv[0] (FlagTranslator::to_driver + the backend's
    ///        roots + the action + `-x <lang> <src> -o <out>`).
    ///
    /// \return false on any failure, with clang's diagnostics printed.
    fn run(self, words: ref!(vec::<string>)) -> bool {
        return self._drive(words, true);
    }

    /// \brief what run() would execute, as `clang -cc1 ...` lines in
    ///        planned, without executing anything (clang's -###).
    fn plan(self, words: ref!(vec::<string>)) -> bool {
        self.planned.clear();
        return self._drive(words, false);
    }

    priv fn _drive(self, words: ref!(vec::<string>), execute: bool) -> bool {
        self.error = "";
        self._be->startup();
        if !self._be->ready() { return false; }

        var owned: llvm::BumpPtrAllocator;   ///< argv bytes; see ClangBackend::_owned
        var argv: libcxx::vector::<std::ConstPtr::<std::Legacy::char>>;
        argv.push_back(llvm::StringSaver(owned).save(sref(self._clang_exe)).data());
        for w: string in words {
            argv.push_back(llvm::StringSaver(owned).save(sref(w)).data());
        }

        var diags = self._be->arg_diags();
        var title = "kairo";
        var drv = clang::driver::Driver(sref(self._clang_exe), sref(self._be->triple()),
                                        *diags, title.std_string(), self._be->vfs());
        // containsError covers argument parsing only; errors the driver
        // reports while planning (a bad -march, an unknown -x) only reach the
        // engine, so its count is the real test.
        var errs_before = diags->getNumErrors();
        var comp = libcxx::unique_ptr::<clang::driver::Compilation>(drv.BuildCompilation(argv));
        if (comp.get() == &null) || comp->containsError() { return false; }
        if diags->getNumErrors() != errs_before { return false; }

        var jobs = &(comp->getJobs().getJobs());
        if jobs->size() == 0 {
            self.error = "clang planned nothing to run for this input";
            return false;
        }
        for var j: usize = 0; j < jobs->size(); ++j {
            var cmd = (*jobs)[j].get();
            // Copied: the job's list is const, and the bytes stay owned by
            // the Compilation, which outlives this loop.
            var cc1: libcxx::vector::<std::ConstPtr::<std::Legacy::char>>;
            var n = cmd->getArguments().size();
            var is_cc1 = (n > 0) && (string(cmd->getArguments()[0]) == "-cc1");
            if !is_cc1 {
                var exe = string(cmd->getExecutable());
                self.error = f"this input needs the external tool '{exe}\x27, which kairo does not run";
                return false;
            }
            for var k: usize = 1; k < n; ++k { cc1.push_back(cmd->getArguments()[k]); }
            if !execute {
                var line = "clang -cc1";
                for var k: usize = 0; k < cc1.size(); ++k { line = line + " " + string(cc1[k]); }
                self.planned.push_back(line);
                continue;
            }
            if !self._cc1(&cc1) { return false; }
        }
        return true;
    }

    /// One `clang -cc1` job, in-process.
    priv fn _cc1(self, cc1: *libcxx::vector::<std::ConstPtr::<std::Legacy::char>>) -> bool {
        var inv = libcxx::make_shared::<clang::CompilerInvocation>();
        if !clang::CompilerInvocation::CreateFromArgs(*(inv.get()), *cc1, *(self._be->arg_diags())) {
            return false;
        }
        // Both copies: CreateFromArgs already copied -disable-free into the
        // codegen options, which would bury every TargetMachine.
        (inv.get()->getFrontendOpts().DisableFree) = false;
        (inv.get()->getCodeGenOpts().DisableFree)  = false;

        var ci = std::create::<clang::CompilerInstance>(inv);
        finally { std::destroy(ci); }
        ci->setVirtualFileSystem(self._be->vfs());
        // Its own printer, owned by the instance: ExecuteAction reports
        // failure from the CLIENT's error count, and a shared client would
        // carry one input's errors into every later input.
        ci->createDiagnostics(&null, true);
        if !ci->hasDiagnostics() { return false; }
        var ok = clang::ExecuteCompilerInvocation(ci);
        return ok && (ci->getDiagnostics().getNumErrors() == 0);
    }
}
