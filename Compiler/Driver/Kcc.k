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
///   a different compiler. `-###` prints the jobs without running them:
///   each cc1 line, then the link (kairo's --print-jobs). The probes
///   `-dumpversion`, `-dumpmachine`, `-print-resource-dir`,
///   `--print-libgcc-file-name`, `-print-target-triple`,
///   `-print-effective-triple`, `-print-multiarch`, `-print-search-dirs`,
///   `-print-prog-name=X` and `-print-file-name=X` are answered by clang's driver for kairo's target (--print-clang-query),
///   so a build system can configure with kcc as its compiler.
///
///   Startup is Driver/Runtime.k's init_runtime, shared with Kairo.k.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/KLocale.hh" // init_process_locale
ffi "c++" import "llvm/Support/InitLLVM.h"
ffi "c++" import "llvm/Support/TargetSelect.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/GlobalRecycler.hh"
ffi "c++" import "locale"
ffi "c++" import "sstream"
ffi "c++" import "vector"
ffi "c++" import "cstring"

import AST::LangItems::LowerTargets
import Command::FlagTranslator::FlagTranslator
import Driver::CompilerInfo
import Driver::CompilerInstance::CompilerInstance
import Driver::Runtime::init_runtime
import Support::ExitCodes::{
    EXIT_FAILURE,
    EXIT_OK,
}
import Support::FileIO::Path::Path
import std::c_char
import std::env
import std::io


pub fn _kcc_usage() {
    io::println("OVERVIEW: kcc, the Kairo toolchain's C/C++ compiler driver")
    io::println("")
    io::println("USAGE: kcc [clang options] <inputs>")
    io::println("")
    io::println("  Takes clang's options and C, C++, Objective-C(++), Kairo (.k), object and")
    io::println("  archive inputs. A C++ input may #include a .k file; the .k is built and linked")
    io::println("  with it. The target and sysroot are Kairo's.")
    io::println("")
    io::println("  -Xkairo <word>   pass <word> to kairo as is (`-Xkairo --help` lists them)")
    io::println("  -###             print the compile and link jobs, run nothing")
}

/// \brief the kairo words for kcc's command line (\p argc / \p argv, argv[0]
///        included). \return false with \p error set when clang's option
///        table rejects a word.
pub fn _kcc_words(argc:       i32,
                  argv:       unsafe *(unsafe *c_char),
                  @inout out: cxx::std::vector<string>,
                  error:      unsafe *string) -> bool {
    var clang  = cxx::std::vector<string>()
    var passed = cxx::std::vector<string>()
    for var i: i32 = 1; i < argc; ++i {
        var a = string(
            unsafe ((argv[i] as unsafe *const u8) as *const u8),
            cxx::std::strlen(argv[i]),
        )

        if a == "-Xkairo" {
            if i + 1 >= argc {
                *error = "argument to '-Xkairo' is missing (expected 1 value)"
                return false
            }

            passed.push_back(
                string(
                    unsafe ((argv[i + 1] as unsafe *const u8) as *const u8),
                    cxx::std::strlen(argv[i + 1]),
                ),
            )

            i += 1
            continue
        }

        clang.push_back(a)
    }

    var kw = cxx::std::vector<string>()
    var cw = cxx::std::vector<string>()
    if !FlagTranslator::from_driver(&clang, &kw, &cw, &*error) {
        return false
    }

    // -emit-llvm is clang's modifier on -S / -c: IR text or bitcode
    // instead of assembly or an object, which kairo spells --emit.
    var emit_llvm = false
    var kept      = cxx::std::vector<string>()
    for *w in cw {
        if *w == "-emit-llvm" {
            emit_llvm = true
        } else {
            kept.push_back(*w)
        }
    }

    cw = kept
    if emit_llvm {
        var asm_ = false
        var obj  = false
        var rest = cxx::std::vector<string>()
        for *w in kw {
            if *w == "-S" {
                asm_ = true
                continue
            }

            if *w == "-c" {
                obj = true
                continue
            }

            rest.push_back(*w)
        }

        kw = rest
        if asm_ {
            kw.push_back("--emit=llvm-ir")
        } else if obj {
            kw.push_back("--emit=llvm-bc")
        } else {
            *error = "-emit-llvm needs -S or -c"
            return false
        }
    }

    var has_std = false
    for *w in kw {
        if w->starts_with("--cxx-std=") {
            has_std = true
        }
    }

    for *w in cw {
        if w->starts_with("-std=") {
            has_std = true
        }
    }

    for *w in passed {
        if w->starts_with("--cxx-std") {
            has_std = true
        }
    }

    if !has_std {
        out.push_back("--cxx-std=c++23")
    }

    for *w in kw {
        out.push_back(*w)
    }

    // clang's -D is a C/C++ macro (--cxx-define); this one is the Kairo
    // files' as well: the program sets its global allocator, which every
    // Kairo TU must know (--global-allocator-set; CompilerInstance::
    // _settle_global_allocator). Also reachable as -Xkairo --global-allocator-set.
    var gdef = "--cxx-define=" + LowerTargets::global_alloc_set_macro()
    for *w in kw {
        if *w == gdef || w->starts_with(gdef + "=") {
            out.push_back("--global-allocator-set")
            break
        }
    }

    // clang's separate compilation: `-c y.k` writes y.o and nothing for what
    // y imports, and a link of such objects takes builtin, std and the
    // runtime from the toolchain's library.
    var compile_only = false
    for *w in kw {
        if *w == "-c" || *w == "-S" || w->starts_with("--emit=") {
            compile_only = true
        }
    }

    if compile_only {
        out.push_back("--emit-scope=inputs")
    }

    out.push_back("--kairo-lib")
    for *w in cw {
        // kcc's own answer (see the header); clang's would name clang.
        if *w == "--version" {
            out.push_back("--version")
            continue
        }

        // Probes (CMake and friends ask the compiler for these): answered by
        // clang's driver itself, with no input (--print-clang-query).
        if _kcc_is_clang_query(*w) {
            out.push_back("--print-clang-query")
        }

        // The jobs, not run: each cc1 line and the link (--print-jobs).
        if *w == "-###" {
            out.push_back("--print-jobs")
            continue
        }

        out.push_back("--cxx-flags=" + *w)
    }

    for *w in passed {
        out.push_back(*w)
    }

    return true
}

/// \brief whether \p w is a driver probe clang answers with no input (its
///        HandleImmediateArgs): -dumpversion and the -print-* family.
/// \details compiler-rt's configure asks for -print-target-triple to
///          normalise its triple; the rest are what CMake, autoconf
///          and libtool send. Both clang spellings of each (`-x` and `--x`)
///          are accepted, as clang accepts them.
fn _kcc_is_clang_query(w: string) -> bool {
    if w == "-dumpversion" || w == "-dumpmachine" {
        return true
    }

    var n = w
    if w.starts_with("--") {
        n = w.subslice(1, w.length() - 1)
    }

    if n == "-print-libgcc-file-name" || n == "-print-resource-dir"
        || n == "-print-target-triple" || n == "-print-effective-triple"
        || n == "-print-multiarch" || n == "-print-search-dirs" {
        return true
    }

    return n.starts_with("-print-prog-name=") || n.starts_with("-print-file-name=")
}

pub fn main(argc: i32, argv: unsafe *(unsafe *c_char)) -> i32 {
    for var i: i32 = 1; i < argc; ++i {
        if cxx::std::strcmp(argv[i], r"--help") == 0 || cxx::std::strcmp(argv[i], r"-help") == 0 {
            _kcc_usage()
            return EXIT_OK
        }

        if cxx::std::strcmp(argv[i], r"-Xkairo") == 0 {
            i += 1
        }
    }

    kairo::Logger::init(kairo::Logger::Level::Trace)
    var unsafe *llvm_init = init_runtime(argc, argv)

    finally {
        kairo::Logger::set_dump_path(Path::join_str(Path::parent_of(env::exe_path()), "kcc.log"))
        kairo::Logger::dump_to_file()
        kairo::Logger::shutdown()
        kairo::GlobalRecycler::shutdown_allocator_runtime()
        kairo::std::destroy(llvm_init)
    }

    var words = cxx::std::vector<string>()
    var error = ""
    if !_kcc_words(argc, argv, &words, unsafe &error) {
        io::eprintln(f"kcc: error: {error}")
        return EXIT_FAILURE
    }

    var unsafe *ci = kairo::std::create<CompilerInstance>(words)
    finally {
        kairo::std::destroy(ci)
    }

    if ci->wants_help() {
        ci->print_help()
        return EXIT_OK
    }

    if ci->wants_version() {
        ci->print_version()
        return EXIT_OK
    }

    if ci->wants_explain() {
        return ci->run_explain()
    }

    if ci->wants_info_query() {
        return ci->run_info_query()
    }

    if !ci->args_ok() {
        ci->flush_errors()
        return EXIT_FAILURE
    }

    if !ci->apply_input_options() {
        ci->flush_errors()
        return EXIT_FAILURE
    }

    ci->initialize(Path::cwd())
    var result = ci->execute()
    ci->flush_errors()

    if ci->invocation()->frontend.verbose {
        io::eprintln(f"compilation: {result.summary()}")
    }

    return if result.ok() => EXIT_OK else => EXIT_FAILURE
}
