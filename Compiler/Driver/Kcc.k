/// --- The Kairo Project --------------------------------- Driver/Kcc.k --- ///
///
///   kcc: the Kairo toolchain's clang/clang++ drop-in. Invoked exactly like
///   clang (`kcc -c x.cc`, `kcc main.cc foo.k -o app`, `kcc x.o y.o`), and
///   run by the same CompilerInstance as `kairo`: the clang command line is
///   translated into kairo's own words (FlagTranslator::from_driver), so the
///   C/C++ inputs, the Kairo inputs, `#include "foo.k"` and the link all
///   behave as they do under `kairo`. The target and sysroot are kairo's,
///   not the host's: kcc is part of the toolchain.
///
///   The translation:
///     - every clang option kairo has a flag for becomes that flag;
///     - every other clang option reaches the C/C++ compiles verbatim
///       (`--cxx-flags`), and nothing else sees it;
///     - `-Xkairo <word>` passes one kairo word through untranslated (what
///       kairo-only settings, and lit's roots, need);
///     - with no `-std=`, C++ defaults to c++23 (the floor an included .k
///       needs is C++20: the hook refuses below it);
///     - `-c`/`-S` write objects for the command line's own files only
///       (--emit-scope=inputs), and a link takes builtin, std and the
///       runtime from the toolchain's cached library (--kairo-lib), so
///       `kcc -c x.cc; kcc -c y.k; kcc x.o y.o` works as with clang.
///   kcc answers `--help` and `--version` itself; clang's own would describe
///   a different compiler. `-###` (print the jobs, run none) is refused
///   until kcc has jobs to print.
///
///   Startup and teardown are Kairo.k's (a build target is one entry file,
///   so this one cannot import that one's main), kept in step by hand.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Driver::CompilerInstance::*;
import Command::FlagTranslator::*;
import Support::FileIO::Path::*;

ffi "c++" import "Native/KLocale.hh";      // init_process_locale
ffi "c++" import "llvm/Support/InitLLVM.h";
ffi "c++" import "llvm/Support/TargetSelect.h";
ffi "c++" import "llvm/Support/raw_ostream.h";

/// Kairo.k's init_runtime: see there for why the guard is returned rather
/// than kept in a static.
fn init_runtime(argc: i32, argv: *(*kairo::std::Legacy::char)) -> *llvm::InitLLVM {
    var init_llvm = std::create::<llvm::InitLLVM>(argc, argv);
    llvm::InitializeAllTargetInfos();
    llvm::InitializeAllTargets();
    llvm::InitializeAllTargetMCs();
    llvm::InitializeAllAsmParsers();
    llvm::InitializeAllAsmPrinters();

    llvm::setBugReportMsg(
        r"PLEASE submit a bug report to https://github.com/kairolang/kairo/issues and include the crash backtrace.\n"
    );

    kairo::init_process_locale();

    libcxx::use_facet::<libcxx::num_put::<std::Legacy::char>>(libcxx::locale());
    libcxx::use_facet::<libcxx::num_get::<std::Legacy::char>>(libcxx::locale());

    { // Force narrow char locale facets used by stringstream/to_string
        var oss: libcxx::ostringstream;
        oss << static_cast::<usize>(1) << 1.0;
        oss.str();
    }

    return init_llvm;
}

fn _kcc_usage() {
    std::print("OVERVIEW: kcc, the Kairo toolchain's C/C++ compiler driver");
    std::print("");
    std::print("USAGE: kcc [clang options] <inputs>");
    std::print("");
    std::print("  Takes clang's options and C, C++, Objective-C(++), Kairo (.k), object and");
    std::print("  archive inputs. A C++ input may #include a .k file; the .k is built and linked");
    std::print("  with it. The target and sysroot are Kairo's.");
    std::print("");
    std::print("  -Xkairo <word>   pass <word> to kairo as is (`-Xkairo --help` lists them)");
}

/// \brief the kairo words for kcc's command line (\p argc / \p argv, argv[0]
///        included). \return false with \p error set when clang's option
///        table rejects a word.
fn _kcc_words(argc: i32, argv: *(*kairo::std::Legacy::char), out: *vec::<string>, error: *string) -> bool {
    var clang = vec::<string>();
    var passed = vec::<string>();
    for var i: i32 = 1; i < argc; ++i {
        var a = string(argv[i], libcxx::strlen(argv[i]));
        if a == "-Xkairo" {
            if i + 1 >= argc {
                (*error) = "argument to '-Xkairo' is missing (expected 1 value)";
                return false;
            }
            passed.push_back(string(argv[i + 1], libcxx::strlen(argv[i + 1])));
            i += 1;
            continue;
        }
        clang.push_back(a);
    }

    var kw = vec::<string>();
    var cw = vec::<string>();
    if !FlagTranslator::from_driver(clang, &kw, &cw, error) { return false; }

    var has_std = false;
    for w: string in kw { if w.starts_with("--cxx-std=") { has_std = true; } }
    for w: string in cw { if w.starts_with("-std=") { has_std = true; } }
    for w: string in passed { if w.starts_with("--cxx-std") { has_std = true; } }
    if !has_std { out->push_back("--cxx-std=c++23"); }

    for w: string in kw { out->push_back(w); }
    // clang's separate compilation: `-c y.k` writes y.o and nothing for what
    // y imports, and a link of such objects takes builtin, std and the
    // runtime from the toolchain's library.
    var compile_only = false;
    for w: string in kw { if (w == "-c") || (w == "-S") { compile_only = true; } }
    if compile_only { out->push_back("--emit-scope=inputs"); }
    out->push_back("--kairo-lib");
    for w: string in cw {
        // kcc's own answer (see the header); clang's would name clang.
        if w == "--version" { out->push_back("--version"); continue; }
        if w == "-###" {
            (*error) = "'-###' is not supported yet";
            return false;
        }
        out->push_back("--cxx-flags=" + w);
    }
    for w: string in passed { out->push_back(w); }
    return true;
}

fn main(argc: i32, argv: *(*kairo::std::Legacy::char)) -> i32 {
    for var i: i32 = 1; i < argc; ++i {
        if (libcxx::strcmp(argv[i], r"--help") == 0) || (libcxx::strcmp(argv[i], r"-help") == 0) {
            _kcc_usage();
            return 0;
        }
        if libcxx::strcmp(argv[i], r"-Xkairo") == 0 { i += 1; }
    }

    Logger::init(Logger::Level::Trace);
    var llvm_init = init_runtime(argc, argv);

    finally {
        Logger::set_dump_path(
            Path::join_str(Path::parent_of(std::get_exe_path()), "kcc.log")
        );
        Logger::dump_to_file();
        Logger::shutdown();
        GlobalRecycler::shutdown_allocator_runtime();
        std::destroy(llvm_init);
    }

    var words = vec::<string>();
    var error = "";
    if !_kcc_words(argc, argv, &words, &error) {
        std::eprintln(f"kcc: error: {error}");
        return 1;
    }

    var ci = std::create::<CompilerInstance>(words);
    finally { std::destroy(ci); }

    if ci->wants_help()    { ci->print_help();    return 0; }
    if ci->wants_version() { ci->print_version(); return 0; }
    if ci->wants_explain() { return ci->run_explain();      }
    if ci->wants_info_query() { return ci->run_info_query(); }

    if !ci->args_ok() {
        ci->flush_errors();
        return 1;
    }
    if !ci->apply_input_options() {
        ci->flush_errors();
        return 1;
    }

    ci->initialize(Path::cwd());
    var result = ci->execute();
    ci->flush_errors();

    if ci->invocation().frontend.verbose {
        std::eprintln(f"compilation: {result.summary()}");
    }
    return 0 if result.ok() else 1;
}
