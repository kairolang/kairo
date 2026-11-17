/// --- The Kairo Project ---------------- Interop/Clang/ClangInstance.k --- ///
///
///   The steps every hand-built clang::CompilerInstance here takes, in the
///   order clang's own ExecuteAction takes them, and the -mllvm parse.
///
///     setup_diagnostics  file system, then the diagnostics engine
///     setup_target       target from the invocation, adjusted to its LangOpts
///     begin_and_execute  BeginSourceFile + Execute, the llvm::Error consumed
///
///   The steps are separate calls because callers do work between them: a
///   header set routes the engine to its own client before the target
///   exists, so a target diagnostic reaches that client; a builtin oracle
///   stops after the target and runs no action. Each caller keeps its own
///   failure handling, its error count and its EndSourceFile.
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
ffi "c++" import "clang/Basic/Diagnostic.h"
ffi "c++" import "clang/Basic/TargetInfo.h"
ffi "c++" import "clang/Frontend/CompilerInstance.h"
ffi "c++" import "clang/Frontend/FrontendAction.h"
ffi "c++" import "clang/Frontend/FrontendOptions.h"
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h"
ffi "c++" import "llvm/Support/CommandLine.h"
ffi "c++" import "llvm/Support/Error.h"
ffi "c++" import "llvm/Support/VirtualFileSystem.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "vector"
ffi "c++" import "string"
ffi "c++" import "utility"

import std::c_char

/// Gives `ci` the file system `vfs`, then a diagnostics engine reporting to
/// `client`, which the engine owns when `owns`. The file system comes
/// first: createDiagnostics reads through it. False when no engine was made.
pub fn setup_diagnostics(ci:     unsafe *clang::CompilerInstance,
                         vfs:    llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>,
                         client: unsafe *clang::DiagnosticConsumer,
                         owns:   bool) -> bool {
    ci->setVirtualFileSystem(vfs)
    ci->createDiagnostics(client, owns)
    return ci->hasDiagnostics()
}

/// Creates `ci`'s target from its invocation's TargetOptions and adjusts it
/// to the LangOptions, with no auxiliary target. Needs the engine
/// (setup_diagnostics): an unknown triple is reported through it. False when
/// the triple names no target.
pub fn setup_target(ci: unsafe *clang::CompilerInstance) -> bool {
    ci->setTarget(
        clang::TargetInfo::CreateTargetInfo(
            &ci->getDiagnostics(),
            &ci->getInvocation().getTargetOpts(),
        ),
    )

    if !ci->hasTarget() {
        return false
    }

    ci->getTarget().adjust(&ci->getDiagnostics(), &ci->getLangOpts(), &null)
    return true
}

/// Begins `act` on `input` in `ci` and, when that succeeds, executes it.
/// `began` is set to whether BeginSourceFile succeeded: from then on the
/// action is the caller's to end (or to keep alive). Execute's llvm::Error
/// is consumed here, since an unconsumed one asserts on destruction. True
/// when both steps succeeded; the diagnostics' error count is the caller's
/// to read.
pub fn begin_and_execute(@inout act:   clang::FrontendAction,
                         ci:           unsafe *clang::CompilerInstance,
                         input:        clang::FrontendInputFile,
                         @inout began: bool) -> bool {
    began = act.BeginSourceFile(&*ci, input)
    if !began {
        return false
    }

    // bool(err) is TRUE ON FAILURE.
    var err    = act.Execute()
    var failed = err as bool
    if failed {
        llvm::consumeError(cxx::std::move(err))
    }

    return !failed
}

/// Hands `words` (a FrontendOptions::LLVMArgs) to LLVM's option parser
/// behind `argv0`, as clang's cc1 does with its -mllvm words; the options
/// are process-wide. `overview` is what LLVM prints for `-help`; LLVM
/// keeps the view for the life of the process, so it must be static text.
/// With `errs` null a rejected word makes LLVM print to stderr and exit, as
/// under cc1; with a stream it is printed there and the call returns false.
/// `vfs` reads response files (null: the real file system). An empty
/// `words` is a no-op that returns true.
pub fn parse_llvm_args(const words: cxx::std::vector<cxx::std::string>,
                       const argv0: string,
                       overview:    llvm::StringRef,
                       errs:        unsafe *llvm::raw_ostream,
                       vfs:         unsafe *llvm::vfs::FileSystem) -> bool {
    if words.empty() {
        return true
    }

    // The argv lives only for the parse, as under cc1: LLVM copies the
    // program name, and each option parses its value into its own storage.
    var a0 = kairo::std::to_std_string(argv0)
    var argv: cxx::std::vector<kairo::std::ConstPtr<c_char>>
    argv.push_back(a0.c_str())
    for var i: usize = 0; i < words.size(); ++i {
        argv.push_back(words[i].c_str())
    }

    argv.push_back(&null) // argv[argc], as main's own.
    return llvm::cl::ParseCommandLineOptions(
        (argv.size() - 1) as i32,
        argv.data(),
        overview,
        errs,
        vfs,
    )
}
