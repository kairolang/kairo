/// --- The Kairo Project ----------------------- Command/FlagRegistry.k --- ///
///
///   Defines every kairo flag and its choice lists on a Command, plus the tests.
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
ffi "c++" import "vector"
ffi "c++" import "utility"

import Command::Command::Command
import Command::FlagUtils::{
    FlagDef,
    FlagKind,
}
import Diagnostic::Engine::DiagEngine
import Support::Assert::Assert
import std::io

/// The values -O accepts after the `O`. `g` is clang's -Og, which it treats
/// as -O1; CodeGenOptions::from_args does the mapping.
pub fn _opt_level_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("0")
    c.push_back("1")
    c.push_back("2")
    c.push_back("3")
    c.push_back("s")
    c.push_back("z")
    c.push_back("g")
    return c
}

/// c++17 is deliberately absent: Lib/builtin needs __builtin_coro_*, so every
/// compile at that level dies in R020E. gnu++ spellings stay for libc++ headers
/// that want the GNU extensions.
pub fn _cxx_std_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("c++20")
    c.push_back("c++23")
    c.push_back("c++26")
    c.push_back("gnu++20")
    c.push_back("gnu++23")
    c.push_back("gnu++26")
    return c
}

pub fn _c_std_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("c89")
    c.push_back("c99")
    c.push_back("c11")
    c.push_back("c17")
    c.push_back("c23")
    c.push_back("gnu89")
    c.push_back("gnu99")
    c.push_back("gnu11")
    c.push_back("gnu17")
    c.push_back("gnu23")
    return c
}

pub fn _lto_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("off")
    c.push_back("thin")
    c.push_back("full")
    return c
}

pub fn _interface_pch_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("auto")
    c.push_back("on")
    c.push_back("off")
    return c
}

pub fn _profile_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("debug")
    c.push_back("release")
    c.push_back("min-size")
    return c
}

pub fn _fp_model_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("precise")
    c.push_back("strict")
    c.push_back("fast")
    return c
}

pub fn _fp_contract_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("off")
    c.push_back("on")
    c.push_back("fast")
    return c
}

pub fn _tls_model_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("global-dynamic")
    c.push_back("local-dynamic")
    c.push_back("initial-exec")
    c.push_back("local-exec")
    return c
}

pub fn _visibility_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("default")
    c.push_back("hidden")
    c.push_back("protected")
    return c
}

pub fn _stack_protector_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("none")
    c.push_back("basic")
    c.push_back("strong")
    c.push_back("all")
    return c
}

pub fn _cf_protection_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("none")
    c.push_back("branch")
    c.push_back("return")
    c.push_back("full")
    return c
}

pub fn _auto_var_init_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("uninitialized")
    c.push_back("zero")
    c.push_back("pattern")
    return c
}

pub fn _mcmodel_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("tiny")
    c.push_back("small")
    c.push_back("kernel")
    c.push_back("medium")
    c.push_back("large")
    return c
}

pub fn _zero_call_used_regs_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("skip")
    c.push_back("used-gpr-arg")
    c.push_back("used-gpr")
    c.push_back("used-arg")
    c.push_back("used")
    c.push_back("all-gpr-arg")
    c.push_back("all-gpr")
    c.push_back("all-arg")
    c.push_back("all")
    return c
}

pub fn _thread_model_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("posix")
    c.push_back("single")
    return c
}

pub fn _default_visibility_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("spec")
    c.push_back("pub")
    return c
}

pub fn _unwind_tables_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("none")
    c.push_back("sync")
    c.push_back("async")
    return c
}

pub fn _hardening_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("enum-tags")
    return c
}

pub fn _unmatched_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("trap")
    c.push_back("unreachable")
    return c
}

/// A String flag restricted to \p choices that still takes its value as the
/// next argument. str_c is built for `-O`, whose bare form means `-O1`; it sets
/// has_bare, and a flag with a bare form never consumes the following word, so
/// `--edition 2026` would have left `2026` behind as an input file.
pub fn _choice_flag(const key:  string,
                    const help: string,
                    const dfl:  string,
                    choices:    cxx::std::vector<string>) -> FlagDef {
    var d = FlagDef::str_c(key, "", key, help, dfl, choices, "")
    d.has_bare = false
    return d
}

pub fn _edition_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("2025")
    c.push_back("2026")
    return c
}

pub fn _borrow_check_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("warn")
    c.push_back("error")
    c.push_back("off")
    return c
}

pub fn _amt_mode_choices() -> cxx::std::vector<string> {
    var c: cxx::std::vector<string>
    c.push_back("warn")
    c.push_back("error")
    c.push_back("silent")
    return c
}

pub fn register_kairo_flags(cmd: unsafe *Command) {
    //  IDENTITY

    cmd->define<FlagKind::Bool>("help", "h", "help", "show this help message and exit", false)
    cmd->define<FlagKind::Bool>(
        "help-hidden",
        "",
        "help-hidden",
        "list the internal and the not-yet-implemented flags and exit",
        false,
    )

    cmd->define<FlagKind::Bool>("version", "V", "version", "print compiler version and exit", false)
    cmd->define<FlagKind::String>(
        "explain",
        "",
        "explain",
        "print detailed explanation for a diagnostic code (e.g. --explain R049E)",
        "",
    )

    cmd->define<FlagKind::Bool>(
        "print-targets",
        "",
        "print-targets",
        "list the LLVM target architectures (not triples) and exit",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-cpus",
        "",
        "print-cpus",
        "list supported CPUs for the current or specified --target",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-cfg",
        "",
        "print-cfg",
        "print the --cfg values given on this command line and exit",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-runtimes-revision",
        "",
        "print-runtimes-revision",
        "print the LLVM runtimes revision this compiler was built from (share/kairo/runtimes/REVISION must match) and exit",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-dirs",
        "",
        "print-dirs",
        "print the toolchain/sysroot directories and exit",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-clang-args",
        "",
        "print-clang-args",
        "print the exact clang invocation and exit (does not compile)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-jobs",
        "",
        "print-jobs",
        "print the clang invocations and the planned link, and exit (kcc's -###)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-from-clang",
        "",
        "print-from-clang",
        "print what the clang command line after -- means to kairo (kairo flags, and the clang-only words) and exit",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-ld-args",
        "",
        "print-ld-args",
        "print the exact ld.lld/ld64.lld/lld-link/wasm-ld invocation instead of linking",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-target-info",
        "",
        "print-target-info",
        "print target ABI, pointer width, endianness for --target and exit",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-pass-pipeline",
        "",
        "print-pass-pipeline",
        "print the full LLVM pass pipeline that would be applied and exit",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-stats",
        "",
        "print-stats",
        "print per-phase compilation statistics after compilation",
        false,
    )

    cmd->define<FlagKind::String>(
        "stats-file",
        "",
        "stats-file",
        "write compilation statistics to this file instead of stderr",
        "",
    )

    //  INPUT

    cmd->define<FlagKind::PathList>("files", "run --help to see usage")
    // -x applies to the inputs that FOLLOW it, so the parser tags each input
    // with the value in force when it is seen (ParsedArgs::file_langs).
    cmd->define<FlagKind::String>(
        "language",
        "x",
        "language",
        "treat the following inputs as <lang>: kairo, or a clang type (c, c++, objective-c, objective-c++, ir, c-header, c++-header, ...); none = by extension",
        "",
    )

    cmd->tag_positionals_with("language")
    cmd->define<FlagKind::StringList>(
        "include-dirs",
        "I",
        "include",
        "search dir for .k imports AND a clang -I for C/C++ inputs and ffi headers (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "ffi-include",
        "",
        "ffi-include",
        "adds -I for clang only, not a .k search dir; identical to --cxx-include (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "cxx-include",
        "",
        "cxx-include",
        "adds -I for clang only, not a .k search dir; identical to --ffi-include (repeatable)",
    )

    // kairo -D and -U are Kairo macros; these are clang's, for C/C++ inputs
    // and the ffi headers. What kcc makes of a clang -D/-U.
    cmd->define<FlagKind::StringList>(
        "cxx-define",
        "",
        "cxx-define",
        "define a macro for clang (C/C++ inputs and ffi headers): NAME or NAME=VALUE (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "cxx-undefine",
        "",
        "cxx-undefine",
        "undefine a macro for clang (C/C++ inputs and ffi headers) (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "macro-search-path",
        "",
        "macro-search-path",
        "search dir for .k imports like -I, but not passed to clang (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "force-include",
        "",
        "force-include",
        "import <file>::* into the main file (adds to the prelude; repeatable)",
    )

    cmd->define<FlagKind::String>(
        "sysroot",
        "",
        "sysroot",
        "system root for headers and linking; a --target with a bundled <prefix>/sysroot/<target> uses that instead",
        "",
    )

    cmd->define<FlagKind::Bool>(
        "sysroot-exact",
        "",
        "sysroot-exact",
        "use --sysroot exactly as given: never substitute a bundled or cached sysroot for the target",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-sysroot-build",
        "",
        "no-sysroot-build",
        "a --target with no installed or cached sysroot is refused (exit 2) instead of built by ksys",
        false,
    )

    cmd->define<FlagKind::String>(
        "resource-dir",
        "",
        "resource-dir",
        "clang resource directory for C++ interop; its include/ holds the builtin headers",
        "",
    )

    cmd->define<FlagKind::String>(
        "builtins-dir",
        "",
        "builtins-dir",
        "builtin module tree, overrides <resource-dir>/builtin; its parent becomes the runtime root",
        "",
    )

    cmd->define<FlagKind::String>(
        "std-dir",
        "",
        "std-dir",
        "directory holding Kairo's standard library tree; overrides <resource-dir>/std",
        "",
    )

    cmd->define<FlagKind::String>(
        "prelude",
        "",
        "prelude",
        "file imported as <file>::* into the main file, REPLACING the default builtin prelude",
        "",
    )

    cmd->define<FlagKind::String>(
        "working-dir",
        "",
        "working-dir",
        "override working directory for all relative path resolution",
        "",
    )

    cmd->define<FlagKind::String>(
        "input-encoding",
        "",
        "input-encoding",
        "source file encoding: only utf-8 is supported (default: utf-8)",
        "utf-8",
    )

    cmd->define<FlagKind::Bool>(
        "no-prelude",
        "",
        "no-prelude",
        "no implicit prelude and builtin is not linked (--no-builtins only skips the import)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-builtins",
        "",
        "no-builtins",
        "skip the implicit 'import builtin::*' only; builtin is still compiled and linked",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-stdlib",
        "",
        "no-stdlib",
        "do not import the std root; the link line is unchanged (see --no-default-libs)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-default-libs",
        "",
        "no-default-libs",
        "do not link libc++, libc++abi, libm, the unwinder, compiler-rt builtins or libc",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-crt",
        "",
        "no-crt",
        "do not link CRT startup objects; the binary needs its own _start (-e main is injected)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "freestanding",
        "",
        "freestanding",
        "freestanding: implies --no-stdlib --no-crt --no-prelude --no-default-libs and -e main",
        false,
    )

    //  OUTPUT

    cmd->define<FlagKind::String>(
        "output",
        "o",
        "output",
        "write the output to this file: the executable or library, or with -c the one object",
        "",
    )

    cmd->define<FlagKind::String>(
        "cache-dir",
        "",
        "cache-dir",
        "directory for object files, kept, and the incremental object cache (default: a temp dir removed after linking; . with -c)",
        "",
    )

    cmd->define<FlagKind::String>(
        "emit",
        "",
        "emit",
        "comma-separated output types: obj,asm,llvm-ir,llvm-bc (any other value is an error)",
        "obj",
    )

    cmd->define<FlagKind::String>(
        "entry",
        "",
        "entry",
        "entry symbol; only applies when no CRT is linked (--no-crt/--freestanding) (default: main)",
        "main",
    )

    cmd->define<FlagKind::Bool>(
        "compile-only",
        "c",
        "compile-only",
        "compile only, do not link",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "emit-asm",
        "S",
        "emit-asm",
        "emit assembly output (sugar for --emit asm)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "preprocess",
        "",
        "preprocess",
        "run preprocessor only, then exit (no extra output)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "dump-preprocessed",
        "",
        "dump-preprocessed",
        "run preprocessor only and print the expanded tokens (space-joined) to stdout",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "syntax-only",
        "",
        "syntax-only",
        "stop after parsing and report only syntax errors, no sema or codegen",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "type-check-only",
        "",
        "type-check-only",
        "stop after type checking, no codegen or linking",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "shared",
        "",
        "shared",
        "produce a shared library (.so / .dylib / .dll); not available on static-only sysroots (musl)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "static",
        "",
        "static",
        "produce a statically linked binary or archive",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-entry",
        "",
        "no-entry",
        "no entry point: library / kernel / raw binary output",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "save-temps",
        "",
        "save-temps",
        "keep the object files, under <out>.kobj/ (only without --cache-dir)",
        false,
    )

    cmd->define<FlagKind::String>(
        "emit-scope",
        "",
        "emit-scope",
        "which Kairo files a run writes objects for: graph (every one it reaches; the default) or inputs (the command line's own, as clang -c; kcc's -c)",
        "graph",
    )

    cmd->define<FlagKind::Bool>(
        "global-allocator-set",
        "",
        "global-allocator-set",
        "some file of the program sets the global allocator (@set_global_allocator): define __KAIRO_GLOBAL_ALLOCATOR_SET for every Kairo file, as a graph build does by itself; for builds the driver cannot see whole (--emit-scope=inputs, kcc -c)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "kairo-lib",
        "",
        "kairo-lib",
        "link builtin, std and the runtime lazily from the toolchain's cache, built on first use (kcc sets it when it links)",
        false,
    )

    //  TARGET

    cmd->define<FlagKind::String>(
        "target",
        "",
        "target",
        "target triple: arch-vendor-os-abi (e.g. x86_64-unknown-linux-gnu)",
        "",
    )

    cmd->define<FlagKind::String>("host", "", "host", "host triple (defaults to native)", "")
    cmd->define<FlagKind::String>(
        "march",
        "",
        "march",
        "target architecture (e.g. armv8-a, x86-64-v3)",
        "",
    )

    cmd->define<FlagKind::String>(
        "mcpu",
        "",
        "mcpu",
        "target CPU (e.g. apple-m1, znver3, cortex-a72); wins over --march. use --print-cpus to list",
        "",
    )

    cmd->define<FlagKind::String>(
        "mtune",
        "",
        "mtune",
        "tune codegen for this CPU without restricting ISA",
        "",
    )

    cmd->define<FlagKind::String>("mabi", "", "mabi", "target ABI (e.g. lp64d, ilp32, eabihf)", "")
    cmd->define<FlagKind::String>(
        "mfeatures",
        "",
        "mfeatures",
        "enable/disable target features: +avx2,+bmi2,-sse4.1",
        "",
    )

    cmd->define<FlagKind::Bool>(
        "m32",
        "",
        "m32",
        "force 32-bit code generation: --target becomes its 32-bit variant (x86_64 -> i386)",
        false,
    )

    cmd->define<FlagKind::Bool>("m64", "", "m64", "force 64-bit code generation", false)
    cmd->define<FlagKind::Bool>(
        "native",
        "",
        "native",
        "build against this machine's own C library, headers and libraries (clang's native search order), with the bundled libc++ and compiler-rt; cannot be combined with --target",
        false,
    )

    cmd->define<FlagKind::StringList>(
        "pkg-config",
        "",
        "pkg-config",
        "run pkg-config --cflags --libs <name> and apply it: -I/-isystem/-D/-U to clang, -L/-l/-Wl to the link (repeatable); with --target only when PKG_CONFIG_SYSROOT_DIR or PKG_CONFIG_LIBDIR is set",
    )

    cmd->define(
        FlagDef::str_c(
            "cxx-std",
            "",
            "cxx-std",
            "C++ standard for interop: c++20|c++23|c++26, or the gnu++ spelling of each (default: c++23)",
            "c++23",
            _cxx_std_choices(),
            "c++23",
        ),
    )

    cmd->define(
        FlagDef::str_c(
            "c-std",
            "",
            "c-std",
            "C standard for C inputs: c89|c99|c11|c17|c23, or the gnu spelling of each (default: c17)",
            "c17",
            _c_std_choices(),
            "c17",
        ),
    )

    cmd->define<FlagKind::String>(
        "cxx-abi",
        "",
        "cxx-abi",
        "C++ ABI for interop: itanium|msvc (default: itanium)",
        "itanium",
    )

    //  BUILD MODE

    cmd->define(
        FlagDef::str_c(
            "profile",
            "",
            "profile",
            "build profile: debug (-O0 -g), release (-O2), min-size (-Os); an explicit -O or -g wins",
            "debug",
            _profile_choices(),
            "debug",
        ),
    )

    cmd->define(
        _choice_flag(
            "borrow-check",
            "borrow checker severity: warn|error|off (default: warn in debug, error in release)",
            "",
            _borrow_check_choices(),
        ),
    )

    cmd->define(
        _choice_flag(
            "amt-mode",
            "AMT violation reporting independent of --borrow-check: warn|error|silent",
            "",
            _amt_mode_choices(),
        ),
    )

    cmd->define<FlagKind::String>(
        "amt-report-file",
        "",
        "amt-report-file",
        "write all AMT decisions and rewrites to this file for auditing",
        "",
    )

    cmd->define(
        FlagDef::str_c(
            "lto",
            "",
            "lto",
            "link-time optimization: off|thin|full (default: off)",
            "off",
            _lto_choices(),
            "off",
        ),
    )

    cmd->define<FlagKind::String>(
        "panic-handler",
        "",
        "panic-handler",
        "symbol name of a custom panic handler (for --no-stdlib targets)",
        "",
    )

    //  OPTIMISATION

    // ONE key for every -O spelling, so the last one given wins: -O2 -Os is
    // -Os, as in clang. -Ofast is rejected, not mapped -- it changes
    // floating-point semantics and is a separate decision.
    cmd->define(
        FlagDef::str_c(
            "opt",
            "O",
            "",
            "optimization level: -O0 (default), -O1, -O2, -O3, -Os, -Oz; -O and -Og are -O1",
            "0",
            _opt_level_choices(),
            "1",
        ),
    )

    cmd->define<FlagKind::Bool>(
        "debug-info",
        "g",
        "",
        "emit debug information: DWARF, or CodeView on MSVC targets",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-debug-info",
        "",
        "g0",
        "explicitly disable debug info emission",
        false,
    )

    cmd->define<FlagKind::I32>(
        "dwarf-version",
        "",
        "dwarf-version",
        "DWARF version to emit: 2|3|4|5 (default: 5); needs -g",
        5i32,
        2i32,
        5i32,
    )

    cmd->define<FlagKind::Bool>(
        "split-dwarf",
        "",
        "split-dwarf",
        "emit DWARF into separate .dwo files (reduces link-time memory usage)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "strip",
        "",
        "strip",
        "strip all symbols from output; wins over --strip-debug",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "strip-debug",
        "",
        "strip-debug",
        "strip only debug symbols, keep exports",
        false,
    )

    cmd->define<FlagKind::StringList>(
        "pass-plugin",
        "",
        "pass-plugin",
        "load a custom LLVM pass plugin .so/.dylib (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "disable-llvm-pass",
        "",
        "disable-llvm-pass",
        "disable a specific LLVM pass by name (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "mllvm",
        "",
        "mllvm",
        "forward flags directly to LLVM's option processor (repeatable)",
    )

    //  REPRODUCIBLE BUILDS

    cmd->define<FlagKind::String>(
        "source-date-epoch",
        "",
        "source-date-epoch",
        "clamp all embedded timestamps to this Unix epoch value for reproducible output",
        "",
    )

    cmd->define<FlagKind::StringList>(
        "remap-path-prefix",
        "",
        "remap-path-prefix",
        "old=new path prefix remapping for debug info, coverage mappings and __FILE__-style macros (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "debug-prefix-map",
        "",
        "debug-prefix-map",
        "old=new path remapping applied only to DWARF debug info (repeatable)",
    )

    cmd->define<FlagKind::Bool>(
        "no-timestamps",
        "",
        "no-timestamps",
        "strip all timestamps from output (implies --source-date-epoch=0)",
        false,
    )

    //  LANGUAGE SEMANTICS  (hard on/off switches)

    cmd->define(
        _choice_flag(
            "edition",
            "language edition: 2025|2026 (checked, otherwise unused) (default: 2026)",
            "2026",
            _edition_choices(),
        ),
    )

    cmd->define<FlagKind::Bool>(
        "no-assert",
        "",
        "no-assert",
        "disable assert{} block codegen",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-finally",
        "",
        "no-finally",
        "disable finally{} codegen (freestanding / embedded targets)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-exceptions",
        "",
        "no-exceptions",
        "disable exception handling codegen",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-ffi",
        "",
        "no-ffi",
        "error on any ffi\"...\" import or ffi block (C and C++) in the program's own files",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-cxx",
        "",
        "no-cxx",
        "error on any ffi \"c++\" import or block; ffi \"c\" stays allowed (see --no-ffi)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-unsafe",
        "",
        "no-unsafe",
        "treat any unsafe{} block or expression as a compile error (same as -fno-unsafe)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-overflow",
        "",
        "no-overflow",
        "trap on integer overflow in all modes (overrides profile default)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "strict-const",
        "",
        "strict-const",
        "error when a const/eval expression cannot be fully reduced at compile time",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-eval",
        "",
        "no-eval",
        "disable eval compile-time expansion (C++ template pass-through mode)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-yield",
        "",
        "no-yield",
        "error on yield, await, async fns and -> yield T generators",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-modules",
        "",
        "no-modules",
        "error on any import of a Kairo module (ffi imports are governed by --no-ffi)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-generics",
        "",
        "no-generics",
        "disable generic instantiation (useful for analysing uninstantiated IR)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-fp",
        "",
        "no-fp",
        "error on any floating-point literal or float-typed expression in the program's own files",
        false,
    )

    //  LANGUAGE FEATURE TOGGLES  (-f{name} / -fno-{name})
    //  query: args.get_feature("name") -> -1 unset, 0 disabled, 1 enabled
    //  items marked (on) default to enabled when unset; driver must check -1 as on

    // language correctness (on by default)
    cmd->define<FlagKind::Feature>(
        "verify-interfaces",
        "verify all interface impl T declarations are fully satisfied (on)",
    )

    cmd->define<FlagKind::Feature>("const-checks", "strict const correctness enforcement (on)")
    cmd->define<FlagKind::Feature>(
        "overflow-checks",
        "integer overflow checking - on in debug, off in release by default",
    )

    cmd->define<FlagKind::Feature>(
        "strict-null",
        "treat nullable pointer dereference as a hard error",
    )

    cmd->define<FlagKind::Feature>("implicit-conv", "allow implicit type conversions (on)")
    cmd->define<FlagKind::Feature>("rtti", "runtime type information (on)")
    cmd->define<FlagKind::Feature>(
        "union-inference",
        "union type inference: x = 1; x = \"s\" -> x: i32|string",
    )

    cmd->define<FlagKind::Feature>("exceptions", "C++ style exception handling")
    cmd->define<FlagKind::Feature>(
        "unwind",
        "let C++ exceptions pass through Kairo frames: no Kairo function is noexcept (off: each is noexcept unless @unwind)",
    )

    cmd->define<FlagKind::Feature>(
        "unsafe",
        "permit unsafe{} blocks (-fno-unsafe makes them an error)",
    )

    // Compiler/Spec/Generics.md#duck-regime: the transitional C++-checked regime. Off, `<T: type>` is an
    // error; on, its body is typed as written and clang checks each instance.
    // INTERNAL (decided 2026-11-08): off by default, so user code gets real
    // bounds; build.py passes -fduck-generics for the compiler's own targets,
    // whose source still has `: type` sites. Hidden from --help (below).
    cmd->define<FlagKind::Feature>(
        "duck-generics",
        "internal, for the compiler's own build: accept `<T: type>`, whose body C++ checks per instance (off by default)",
    )

    cmd->mark_hidden("duck-generics")
    // What a declaration with no visibility keyword is (classes.mdx,
    // modules.mdx; decided 2026-11-08): `spec` is the language's rule, `priv`
    // to its file or `prot` to its module when a module.k is above it;
    // `pub` is the rule before it (everything public but a class's
    // variables). INTERNAL: build.py passes `pub` for the compiler's own
    // targets, whose source was written under the old rule. The long name
    // carries the `f` so `-fdefault-visibility=pub` matches it exactly.
    cmd->define(
        FlagDef::str_c(
            "default-visibility",
            "",
            "fdefault-visibility",
            "internal: what an unmarked declaration is: spec (priv, or prot under a module.k) | pub (the old rule)",
            "spec",
            _default_visibility_choices(),
            "spec",
        ),
    )

    cmd->mark_hidden("default-visibility")
    // Import cycles compile, with a warning (R001W) on each, as
    // documented (modules.mdx, Circular Dependencies). -fno-import-cycles makes each one
    // an error (R001E) and stops the build after parse.
    cmd->define<FlagKind::Feature>(
        "import-cycles",
        "allow import cycles, each with a warning (on); -fno-import-cycles makes an import cycle an error",
    )

    // codegen / optimization (off by default unless noted) -----------------
    cmd->define<FlagKind::Feature>("inline", "function inlining (on)")
    cmd->define<FlagKind::Feature>("force-inline", "honour @force_inline() directives (on)")
    cmd->define<FlagKind::Feature>("tail-call", "tail call optimization")
    cmd->define<FlagKind::Feature>("dead-code-elim", "dead code elimination (on)")
    cmd->define<FlagKind::Feature>(
        "vectorize",
        "auto-vectorisation (loop + SLP); on at every level above -O0",
    )

    cmd->define<FlagKind::Feature>("unroll-loops", "loop unrolling")
    cmd->define<FlagKind::Feature>("merge-functions", "merge identical functions (ICF)")
    cmd->define<FlagKind::Feature>("function-sections", "place each function in its own section")
    cmd->define<FlagKind::Feature>("data-sections", "place each variable in its own section")
    cmd->define<FlagKind::Feature>("omit-frame-pointer", "omit frame pointer in leaf functions")
    cmd->define<FlagKind::Feature>(
        "fast-math",
        "aggressive floating-point optimisations (may break IEEE754 compliance)",
    )

    cmd->define<FlagKind::Feature>("export-all", "export all top-level symbols by default")
    cmd->define<FlagKind::Feature>(
        "shared-header-set",
        "parse the build's C++ header lists once, as one union, instead of once per list (on)",
    )

    cmd->define<FlagKind::Feature>(
        "infer-purity",
        "infer `fn f() const` / `@pure` for functions that keep the promise without saying so, and emit __attribute__((const)) / __attribute__((pure)) for them (on; -fno-infer-purity turns it off)",
    )

    // hardening
    cmd->define<FlagKind::Feature>("stack-protector", "stack canary insertion")
    cmd->define<FlagKind::Feature>("pic", "position-independent code")
    cmd->define<FlagKind::Feature>(
        "pie",
        "position-independent executable (a link-time choice; code generation is unchanged)",
    )

    cmd->define<FlagKind::Feature>("split-stack", "segmented stack (for green-thread runtimes)")
    cmd->define<FlagKind::Feature>(
        "trap-unreachable",
        "lower unreachable to a hardware trap instruction rather than UB",
    )

    cmd->define<FlagKind::Feature>(
        "soft-float",
        "software floating point ABI (for targets without FPU)",
    )

    cmd->define<FlagKind::Feature>(
        "plt",
        "call external functions through the PLT (on); -fno-plt loads their address from the GOT",
    )

    cmd->define<FlagKind::Feature>(
        "red-zone",
        "use the stack red zone below the stack pointer (on where the ABI has one)",
    )

    cmd->define<FlagKind::Feature>(
        "delete-null-pointer-checks",
        "let the optimizer drop null checks after a dereference (on)",
    )

    cmd->define<FlagKind::Feature>(
        "visibility-inlines-hidden",
        "give inline C++ functions hidden visibility",
    )

    // instrumentation
    cmd->define<FlagKind::Feature>("coverage", "source-level coverage instrumentation")
    cmd->define<FlagKind::Feature>(
        "profile-generate",
        "PGO instrumentation pass (generates .profraw)",
    )

    cmd->define<FlagKind::Feature>("sanitize-address", "AddressSanitizer")
    cmd->define<FlagKind::Feature>("sanitize-thread", "ThreadSanitizer")
    cmd->define<FlagKind::Feature>("sanitize-memory", "MemorySanitizer")
    cmd->define<FlagKind::Feature>("sanitize-ub", "UndefinedBehaviourSanitizer")

    // ELF/Linux specific
    cmd->define<FlagKind::Feature>(
        "relro",
        "partial RELRO: -z relro (ELF only; add --now for full RELRO)",
    )

    cmd->define<FlagKind::Feature>(
        "eh-frame-hdr",
        "emit .eh_frame_hdr section (ELF only, on by default; -fno-eh-frame-hdr turns it off)",
    )

    cmd->define<FlagKind::Feature>(
        "gc-sections",
        "linker dead section elimination (ELF/Wasm/MinGW --gc-sections, Mach-O -dead_strip, MSVC -opt:ref)",
    )

    // macOS/Darwin specific
    cmd->define<FlagKind::Feature>(
        "dead-strip",
        "Mach-O dead stripping (-dead_strip; also implied by -fgc-sections)",
    )

    cmd->define<FlagKind::Feature>(
        "bitcode",
        "embed LLVM bitcode in Mach-O output (Apple deprecated bitcode)",
    )

    // Windows/PE specific
    cmd->define<FlagKind::Feature>(
        "high-entropy-va",
        "64-bit ASLR in PE output (/highentropyva[:no]; lld default on 64-bit)",
    )

    cmd->define<FlagKind::Feature>(
        "dynamicbase",
        "ASLR in PE output (/dynamicbase[:no]; lld default on)",
    )

    cmd->define<FlagKind::Feature>(
        "nxcompat",
        "mark PE binary as NX compatible (/nxcompat[:no]; lld default on)",
    )

    cmd->define<FlagKind::Feature>(
        "guard-cf",
        "Windows Control Flow Guard (/guard:cf, -fno-guard-cf passes /guard:no)",
    )

    cmd->define<FlagKind::Feature>(
        "tsaware",
        "mark PE binary as terminal-server aware (/tsaware[:no]; lld default on)",
    )

    // WASM proposals
    cmd->define<FlagKind::Feature>(
        "wasm-bulk-memory",
        "enable WASM bulk memory operations proposal",
    )

    cmd->define<FlagKind::Feature>(
        "wasm-threads",
        "WASM threads: link with --shared-memory (needs +atomics in the objects)",
    )

    cmd->define<FlagKind::Feature>("wasm-tail-calls", "enable WASM tail calls proposal")
    cmd->define<FlagKind::Feature>("wasm-simd", "enable WASM SIMD proposal")
    cmd->define<FlagKind::Feature>("wasm-sign-ext", "enable WASM sign extension operators proposal")
    cmd->define<FlagKind::Feature>("wasm-reference-types", "enable WASM reference types proposal")
    cmd->define<FlagKind::Feature>("wasm-exceptions", "enable WASM exception handling proposal")

    //  DEFINES & CONFIG FLAGS

    cmd->define<FlagKind::StringList>(
        "define",
        "D",
        "",
        "define a preprocessor macro for Kairo source (not forwarded to clang): -DNAME or -DNAME=VALUE (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "cfg",
        "",
        "cfg",
        "set a named config flag for conditional compilation: --cfg name or --cfg name=value (repeatable)",
    )

    cmd->define<FlagKind::String>(
        "profile-use",
        "",
        "profile-use",
        "path to .profdata file for PGO-guided optimization",
        "",
    )

    cmd->define<FlagKind::String>(
        "coverage-format",
        "",
        "coverage-format",
        "coverage output format: lcov|gcov|llvm (default: llvm)",
        "llvm",
    )

    cmd->define<FlagKind::StringList>(
        "coverage-prefix-map",
        "",
        "coverage-prefix-map",
        "remap source paths in coverage output (repeatable)",
    )

    //  WARNINGS & DIAGNOSTICS

    cmd->define<FlagKind::Bool>(
        "Wall",
        "",
        "Wall",
        "forwarded to clang for the generated C++; no Kairo diagnostic is gated",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "Wextra",
        "",
        "Wextra",
        "forwarded to clang for the generated C++; no Kairo diagnostic is gated",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "Wpedantic",
        "",
        "Wpedantic",
        "forwarded to clang for the generated C++; no Kairo diagnostic is gated",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "Wshift-count-unproven",
        "",
        "Wshift-count-unproven",
        "warn on an ARM32 shift whose count is not proven below the width (its mask costs an instruction)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "Wconst-self",
        "",
        "Wconst-self",
        "warn on a method that never mutates self (declare it 'const self', SC273W) and an @inout parameter never mutated (declare it 'const', SC274W); off by default",
        false,
    )

    cmd->define<FlagKind::Bool>("Werror", "", "Werror", "treat all warnings as errors", false)
    cmd->define<FlagKind::Bool>("nowarn", "w", "", "suppress all warnings", false)
    cmd->define<FlagKind::StringList>(
        "warn",
        "W",
        "",
        "enable a diagnostic by code, e.g. R020E; overrides an earlier -A (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "allow",
        "A",
        "",
        "silence a warning, note or remark by code, e.g. R020E; errors are never silenced (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "deny",
        "E",
        "error",
        "promote a warning to error by code, e.g. R020E (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "forbid",
        "F",
        "",
        "force a diagnostic to error by code, e.g. R020E; not overridable by -A or -W (repeatable)",
    )

    cmd->define<FlagKind::String>(
        "error-format",
        "",
        "error-format",
        "diagnostic output format: pretty|basic|json (default: pretty)",
        "pretty",
    )

    cmd->define<FlagKind::Bool>(
        "no-color",
        "",
        "no-color",
        "disable ANSI color in diagnostic output (also off when stdout is not a terminal)",
        false,
    )

    cmd->define<FlagKind::String>(
        "progress",
        "",
        "progress",
        "build progress on stderr: auto|always|never|lines (default: auto, a pinned status line whenever stderr is a terminal and TERM is not dumb; lines prints machine-readable @progress events)",
        "auto",
    )

    cmd->define<FlagKind::Bool>(
        "diag-show-ids",
        "",
        "diag-show-ids",
        "print diagnostic codes (always on; accepted for compatibility)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "diag-cascade",
        "",
        "diag-cascade",
        "enable cascade suppression via poisoned scopes (default: on)",
        true,
    )

    cmd->define<FlagKind::Bool>(
        "diag-absolute-paths",
        "",
        "diag-absolute-paths",
        "print absolute paths in diagnostic messages",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "diag-show-context",
        "",
        "diag-show-context",
        "print surrounding source lines in diagnostics (default: on)",
        true,
    )

    cmd->define<FlagKind::Bool>(
        "dump-type-info",
        "",
        "dump-type-info",
        "dump inferred types for all expressions after sema",
        false,
    )

    //  BCIR / AMT INTERNALS

    cmd->define<FlagKind::Bool>(
        "verify-bcir",
        "",
        "verify-bcir",
        "run BCIR integrity verifier pass after borrow-check lowering",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "bcir-verbose",
        "",
        "bcir-verbose",
        "verbose BCIR output with every AMT decision annotated",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "bcir-stats",
        "",
        "bcir-stats",
        "print BCIR statistics: borrows tracked, AMT rewrites made, scopes poisoned",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-regalloc",
        "",
        "print-regalloc",
        "dump register allocation decisions from LLVM backend",
        false,
    )

    //  INCREMENTAL COMPILATION

    cmd->define<FlagKind::Bool>(
        "incremental",
        "",
        "incremental",
        "enable incremental compilation",
        false,
    )

    cmd->define<FlagKind::String>(
        "incremental-dir",
        "",
        "incremental-dir",
        "directory for incremental compilation cache (default: .kairo-cache)",
        ".kairo-cache",
    )

    cmd->define<FlagKind::Bool>(
        "force-recompile",
        "",
        "force-recompile",
        "ignore the incremental object cache and the runtime cache: compile everything",
        false,
    )

    //  MODULE SYSTEM

    cmd->define<FlagKind::String>(
        "module-name",
        "",
        "module-name",
        "override the module name for this compilation unit",
        "",
    )

    cmd->define<FlagKind::String>(
        "module-cache-dir",
        "",
        "module-cache-dir",
        "directory for compiled module artifacts (default: .kairo-modules)",
        ".kairo-modules",
    )

    cmd->define<FlagKind::Bool>(
        "no-module-cache",
        "",
        "no-module-cache",
        "disable module caching entirely (always recompile imported modules)",
        false,
    )

    //  LINKING

    cmd->define<FlagKind::StringList>(
        "lib-dirs",
        "L",
        "lib-dir",
        "add directory to library search path (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "link-libs",
        "l",
        "link",
        "link against named library, optionally qualified: -l static:foo or -l dynamic:bar (repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "rpath",
        "",
        "rpath",
        "add runtime library search path (ELF/Mach-O, repeatable; dropped on static links)",
    )

    cmd->define<FlagKind::StringList>(
        "rpath-link",
        "",
        "rpath-link",
        "link-time-only rpath entries (ELF, repeatable)",
    )

    cmd->define<FlagKind::String>(
        "linker-script",
        "",
        "linker-script",
        "pass a linker script to the linker (lld; ELF only)",
        "",
    )

    cmd->define<FlagKind::String>(
        "version-script",
        "",
        "version-script",
        "pass a symbol version script to the linker (lld; ELF only)",
        "",
    )

    cmd->define<FlagKind::String>(
        "map-file",
        "",
        "map-file",
        "write a linker map file (symbol -> section -> address) to this path",
        "",
    )

    cmd->define<FlagKind::String>(
        "build-id",
        "",
        "build-id",
        "emit build-id note section: none|fast|sha1|uuid (default: fast)",
        "fast",
    )

    cmd->define<FlagKind::Bool>(
        "export-dynamic",
        "",
        "export-dynamic",
        "pass --export-dynamic to the linker: export all dynamic symbols (dlopen/plugins)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "now",
        "",
        "now",
        "full RELRO: resolve all symbols at load time (-z now, ELF)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "z-noexecstack",
        "",
        "z-noexecstack",
        "mark stack non-executable in ELF PT_GNU_STACK note",
        false,
    )

    cmd->define<FlagKind::String>(
        "hash-style",
        "",
        "hash-style",
        "ELF hash section style, dynamic links only: gnu|sysv|both (default: gnu)",
        "gnu",
    )

    cmd->define<FlagKind::String>(
        "dynamic-linker",
        "",
        "dynamic-linker",
        "override the dynamic linker path, dynamic links only (e.g. /lib/ld-musl-x86_64.so.1)",
        "",
    )

    cmd->define<FlagKind::String>(
        "emulation",
        "",
        "emulation",
        "linker emulation: elf_x86_64|elf_i386|aarch64elf|... (default: auto)",
        "",
    )

    cmd->define<FlagKind::String>(
        "compress-debug",
        "",
        "compress-debug",
        "compress DWARF debug sections: none|zlib|zstd (default: none)",
        "none",
    )

    cmd->define<FlagKind::StringList>(
        "ld-flags",
        "",
        "ld-flags",
        "raw flag passthrough to the linker (lld; repeatable)",
    )

    cmd->define<FlagKind::StringList>(
        "cxx-flags",
        "",
        "cxx-flags",
        "clang driver words for C/C++ inputs, passed verbatim and last (repeatable); kairo's own code never sees them",
    )

    //  PLATFORM: macOS / Darwin

    cmd->define<FlagKind::String>(
        "macos-version-min",
        "",
        "macos-version-min",
        "minimum macOS deployment target, -platform_version (e.g. 14.0); beats the environment and triple",
        "",
    )

    cmd->define<FlagKind::String>(
        "ios-version-min",
        "",
        "ios-version-min",
        "minimum iOS deployment target, -platform_version (e.g. 17.0)",
        "",
    )

    cmd->define<FlagKind::String>(
        "macos-sdk",
        "",
        "macos-sdk",
        "path to MacOSX.sdk; becomes -syslibroot and beats --sysroot",
        "",
    )

    cmd->define<FlagKind::String>(
        "install-name",
        "",
        "install-name",
        "dylib install name (-install_name; --shared only, default @rpath/<output>)",
        "",
    )

    cmd->define<FlagKind::String>(
        "rpath-origin",
        "",
        "rpath-origin",
        "add an -rpath anchored at @loader_path or @executable_path (optional /subpath)",
        "",
    )

    cmd->define<FlagKind::StringList>(
        "force-load",
        "",
        "force-load",
        "force load an archive (-force_load: all members, not just referenced; repeatable)",
    )

    cmd->define<FlagKind::I32>(
        "headerpad",
        "",
        "headerpad",
        "extra padding in bytes for Mach-O load commands (-headerpad, 0 = linker default)",
        0i32,
        0i32,
        65536i32,
    )

    //  PLATFORM: Windows / PE-COFF

    cmd->define<FlagKind::String>(
        "subsystem",
        "",
        "subsystem",
        "PE subsystem: console|windows|native|posix|efi_application|efi_boot_service_driver|efi_rom|efi_runtime_driver|boot_application (default: console)",
        "console",
    )

    cmd->define<FlagKind::String>(
        "pdb",
        "",
        "pdb",
        "path for PDB debug info output (/pdb:, Windows)",
        "",
    )

    cmd->define<FlagKind::String>(
        "def",
        "",
        "def",
        "module-definition (.def) file for DLL exports (/def:)",
        "",
    )

    cmd->define<FlagKind::String>(
        "implib",
        "",
        "implib",
        "path for import library output (/implib:, .lib)",
        "",
    )

    cmd->define<FlagKind::Bool>(
        "manifest",
        "",
        "manifest",
        "embed a default Windows application manifest (/manifest:embed)",
        false,
    )

    cmd->define<FlagKind::String>(
        "manifest-file",
        "",
        "manifest-file",
        "embed this manifest file instead of the default (/manifestinput:)",
        "",
    )

    cmd->define<FlagKind::Bool>(
        "dll",
        "",
        "dll",
        "produce a DLL (alias of --shared on every target)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "kill-at",
        "",
        "kill-at",
        "remove @n size suffix from stdcall symbol exports (/kill-at, PE only)",
        false,
    )

    cmd->define<FlagKind::I32>(
        "stack-size",
        "",
        "stack-size",
        "stack size in the PE header (/stack:, bytes, 0 = linker default)",
        0i32,
        0i32,
        2147483647i32,
    )

    cmd->define<FlagKind::I32>(
        "heap-size",
        "",
        "heap-size",
        "heap size in the PE header (/heap:, bytes, 0 = linker default)",
        0i32,
        0i32,
        2147483647i32,
    )

    //  PLATFORM: WASM / WASI

    cmd->define<FlagKind::StringList>(
        "wasm-export",
        "",
        "wasm-export",
        "export a symbol from the wasm module (wasm-ld --export=; repeatable)",
    )

    cmd->define<FlagKind::Bool>(
        "wasm-import-memory",
        "",
        "wasm-import-memory",
        "import linear memory from the host instead of defining it (--import-memory)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "wasm-export-memory",
        "",
        "wasm-export-memory",
        "export linear memory to the host (--export-memory)",
        false,
    )

    cmd->define<FlagKind::I32>(
        "wasm-max-memory",
        "",
        "wasm-max-memory",
        "maximum WASM linear memory in bytes, multiple of 65536 (--max-memory, 0 = no limit)",
        0i32,
        0i32,
        2147483647i32,
    )

    cmd->define<FlagKind::I32>(
        "wasm-initial-memory",
        "",
        "wasm-initial-memory",
        "initial WASM linear memory in bytes, multiple of 65536 (--initial-memory; only passed when given) (default: 65536)",
        65536i32,
        65536i32,
        2147483647i32,
    )

    cmd->define<FlagKind::I32>(
        "wasm-stack-size",
        "",
        "wasm-stack-size",
        "WASM shadow stack size in bytes, 16-aligned (-z stack-size=; only passed when given) (default: 65536)",
        65536i32,
        4096i32,
        2147483647i32,
    )

    cmd->define<FlagKind::Bool>(
        "wasi",
        "",
        "wasi",
        "target WASI ABI (sets default imports/exports for WASI runtime)",
        false,
    )

    cmd->define<FlagKind::String>(
        "wasi-version",
        "",
        "wasi-version",
        "WASI ABI version: preview1|preview2 (default: preview1)",
        "preview1",
    )

    //  PLATFORM: Embedded / Bare Metal

    cmd->define<FlagKind::I32>(
        "pic-level",
        "",
        "pic-level",
        "PIC level on any target: 0|1|2 (default: 0 = none forced); overrides -fpic/-fno-pic",
        0i32,
        0i32,
        2i32,
    )

    cmd->define<FlagKind::Bool>(
        "no-stack-check",
        "",
        "no-stack-check",
        "disable stack overflow checking entirely (bare metal)",
        false,
    )

    cmd->define<FlagKind::I32>(
        "fixed-stack-size",
        "",
        "fixed-stack-size",
        "fix stack size at compile time in bytes (for static analysis, 0 = dynamic)",
        0i32,
        0i32,
        2147483647i32,
    )

    //  TESTING

    cmd->define<FlagKind::Bool>(
        "test",
        "",
        "test",
        "compile and run all test{} blocks; exit 0 on pass",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "test-list",
        "",
        "test-list",
        "list all test{} block names without running them",
        false,
    )

    cmd->define<FlagKind::String>(
        "test-filter",
        "",
        "test-filter",
        "run only tests whose name matches this pattern (substring or glob)",
        "",
    )

    cmd->define<FlagKind::String>(
        "test-format",
        "",
        "test-format",
        "test result output format: pretty|json|tap (default: pretty)",
        "pretty",
    )

    cmd->define<FlagKind::I32>(
        "test-threads",
        "",
        "test-threads",
        "parallelism for test execution (0 = logical CPU count)",
        0i32,
        0i32,
        1024i32,
    )

    cmd->define<FlagKind::Bool>(
        "test-no-capture",
        "",
        "test-no-capture",
        "do not capture stdout/stderr from test{} blocks",
        false,
    )

    cmd->define<FlagKind::I32>(
        "test-timeout",
        "",
        "test-timeout",
        "per-test timeout in milliseconds (0 = no timeout)",
        0i32,
        0i32,
        3600000i32,
    )

    cmd->define<FlagKind::I32>(
        "test-exit-code",
        "",
        "test-exit-code",
        "override exit code on test failure (default: 1)",
        1i32,
        0i32,
        255i32,
    )

    //  OUTPUT VERBOSITY

    cmd->define<FlagKind::Bool>(
        "verbose",
        "v",
        "verbose",
        "print the linker invocation and INFO log lines",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "quiet",
        "",
        "quiet",
        "suppress warnings, notes and remarks; errors still print",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "suppress",
        "",
        "suppress",
        "route all output to stderr, nothing to stdout",
        false,
    )

    cmd->define<FlagKind::I32>(
        "threads",
        "",
        "threads",
        "parallelism for compilation, also the lld --threads count (0 = logical CPU count)",
        0i32,
        0i32,
        1024i32,
    )

    cmd->define<FlagKind::I32>(
        "sema-threads",
        "",
        "sema-threads",
        "threads that run Sema over the import groups (0 = --threads; 1 = the one-thread loop)",
        0i32,
        0i32,
        1024i32,
    )

    cmd->define<FlagKind::I32>(
        "codegen-threads",
        "",
        "codegen-threads",
        "threads that run the per-TU C++ compiles (0 = --threads; always capped at the TU count)",
        0i32,
        0i32,
        1024i32,
    )

    cmd->define<FlagKind::Bool>(
        "time-passes",
        "",
        "time-passes",
        "print per-pass timing breakdown after compilation",
        false,
    )

    cmd->define<FlagKind::String>(
        "time-trace",
        "",
        "time-trace",
        "emit Chrome-format trace JSON here (implies --time-passes)",
        "",
    )

    //  DEVELOPER / DUMP INTERNALS

    cmd->define<FlagKind::Bool>(
        "print-cg",
        "",
        "print-cg",
        "dump the codegen token stream for every TU, incl. builtin/std",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-ir",
        "",
        "print-ir",
        "dump the generated C++ source for every TU, incl. builtin/std",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-bcir",
        "",
        "print-bcir",
        "dump BCIR before and after borrow-check lowering",
        false,
    )

    cmd->define<FlagKind::String>(
        "print-ast",
        "",
        "print-ast",
        "AST dump format: tree|flat|canonical; give the value as --print-ast=FORMAT (--print-ast= alone means tree)",
        "",
    )

    cmd->define<FlagKind::Bool>(
        "print-sema",
        "",
        "print-sema",
        "dump resolved Sema declarations for every TU, incl. builtin/std",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-lowered",
        "",
        "print-lowered",
        "dump resolved Sema declarations again after the Lower/ passes, for every TU incl. builtin/std",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-tokens",
        "",
        "print-tokens",
        "dump token stream after preprocessing",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-macros",
        "",
        "print-macros",
        "list every macro after preprocessing: name, parameter count, definition location",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-imports",
        "",
        "print-imports",
        "dump the import resolution graph, followed by the overlay section",
        false,
    )

    cmd->define<FlagKind::String>(
        "dump-import-uses",
        "",
        "dump-import-uses",
        "after sema, write each TU's imports and the names resolved through each one, with use sites, as JSON to this path (Scripts/import_lint.py)",
        "",
    )

    cmd->define<FlagKind::String>(
        "dump-interface",
        "",
        "dump-interface",
        "after sema, write each file's interface hashes (per declaration: DeclId, interface hash, body hash; per scope: its names) as JSON to this path (Compiler/Spec/IncrementalSema.md)",
        "",
    )

    cmd->define<FlagKind::String>(
        "dump-deps",
        "",
        "dump-deps",
        "after sema, write each file's dependency log (the names, declarations and bodies of other files its check read) as JSON to this path (Compiler/Spec/IncrementalSema.md)",
        "",
    )

    cmd->define<FlagKind::Bool>(
        "print-emit-plan",
        "",
        "print-emit-plan",
        "dump the per-TU EmitPlan: the foreign decls a C++ header would supply",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-cxx",
        "",
        "print-cxx",
        "print the TU's C++ preamble (every declaration, no bodies) as text",
        false,
    )

    cmd->define<FlagKind::String>(
        "emit-headers",
        "",
        "emit-headers",
        "write each non-entry module's C++ interop header under this directory (skipped when sema reports errors)",
        "",
    )

    cmd->define<FlagKind::Bool>(
        "print-symbols",
        "",
        "print-symbols",
        "dump the frozen per-DeclContext symbol tables (uses --print-ast style)",
        false,
    )

    cmd->define<FlagKind::String>(
        "emit-ast-bin",
        "",
        "emit-ast-bin",
        "write the entry file's parsed AST, serialized, to this path (Compiler/Spec/Serialization.md)",
        "",
    )

    cmd->define<FlagKind::Bool>(
        "ast-roundtrip",
        "",
        "ast-roundtrip",
        "serialize and reload every parsed file's AST and continue with the reloaded tree (also KAIRO_AST_ROUNDTRIP=1)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "verify-ast-roundtrip",
        "",
        "verify-ast-roundtrip",
        "serialize and reload every parsed file's AST and report any difference from the parsed tree",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "preserve-comments",
        "",
        "preserve-comments",
        "keep comments in the token stream; they reach the AST as annotations",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-generics",
        "",
        "print-generics",
        "dump every generic instantiation and its origin site",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "print-panic-sets",
        "",
        "print-panic-sets",
        "dump every Panic<T, E...> instance: its canonical set, each type id, and its layout",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "test-panic-type",
        "",
        "test-panic-type",
        "compiler tests only: let source name the Panic<T, E...> lang item (SC116E otherwise)",
        false,
    )

    cmd->define<FlagKind::I32>(
        "test-panic-id-bits",
        "",
        "test-panic-id-bits",
        "compiler tests only: keep this many low bits of each panic type id, to force collisions",
        32i32,
        1i32,
        32i32,
    )

    cmd->define<FlagKind::Bool>(
        "test-fold-lie",
        "",
        "test-fold-lie",
        "compiler tests only: the late eval-if fold reads every is_trivially_* fact inverted, so the clang agreement pin must fail the build",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "verify-ir",
        "",
        "verify-ir",
        "run LLVM IR verifier after codegen",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "macro-debug",
        "",
        "macro-debug",
        "print each macro expansion to stderr (no -v needed)",
        false,
    )

    cmd->define<FlagKind::String>(
        "macro-debug-filter",
        "",
        "macro-debug-filter",
        "requires --macro-debug; limit the trace to this macro name (without '!')",
        "",
    )

    //  COMPILER LIMITS  (--c prefix, query via get_cfg_*)

    //  macro system
    cmd->define_cfg<FlagKind::I32>(
        "max-macro-depth",
        "maximum macro recursion depth",
        128i32,
        1i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-macro-expansions",
        "maximum total macro expansion nodes across compilation",
        65536i32,
        1i32,
        16777216i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-macro-backtrace",
        "maximum frames shown in macro expansion error backtraces",
        8i32,
        0i32,
        64i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "macro-trace-depth",
        "needs --macro-debug; maximum depth of the expansion trace (0 = unlimited)",
        0i32,
        0i32,
        65536i32,
    )

    //  generic instantiation
    cmd->define_cfg<FlagKind::I32>(
        "max-generic-depth",
        "maximum generic instantiation chain length; a longer chain is an error",
        128i32,
        1i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-generic-backtrace",
        "maximum instantiation-chain notes shown per error (0 = all)",
        5i32,
        0i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-generic-instantiations",
        "maximum total generic instantiations across compilation (0 = unlimited)",
        16384i32,
        0i32,
        16777216i32,
    )

    //  const / eval
    cmd->define_cfg<FlagKind::I32>(
        "max-const-eval-steps",
        "maximum steps in a single const/eval expression evaluation",
        1000000i32,
        1i32,
        2147483647i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-const-eval-depth",
        "maximum call depth during const/eval evaluation",
        512i32,
        1i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-const-backtrace",
        "maximum frames shown in const eval error backtraces",
        8i32,
        0i32,
        64i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-for-unroll-count",
        "maximum iterations for eval for{} compile-time loop unrolling",
        1024i32,
        1i32,
        16777216i32,
    )

    //  inline / codegen
    cmd->define_cfg<FlagKind::I32>(
        "max-inline-depth",
        "maximum inlining depth (passed to LLVM inliner)",
        256i32,
        1i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::F64>(
        "inline-cost-threshold",
        "base inliner cost threshold (higher = inline more aggressively)",
        225.0,
        0.0,
        100000.0,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-lambda-capture-size",
        "maximum bytes a lambda may capture by value",
        1024i32,
        0i32,
        67108864i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-unroll-count",
        "maximum loop unroll count (0 = backend default)",
        0i32,
        0i32,
        4096i32,
    )

    //  import / module resolution
    cmd->define_cfg<FlagKind::I32>(
        "max-import-depth",
        "maximum import resolution depth (guards circular import chains)",
        512i32,
        1i32,
        65536i32,
    )

    //  parser / expression
    cmd->define_cfg<FlagKind::I32>(
        "max-expr-depth",
        "maximum expression nesting depth (guards parser stack overflow)",
        512i32,
        1i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-scope-depth",
        "maximum nested scope depth",
        256i32,
        1i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "tab-width",
        "tab stop width for column numbers in diagnostics",
        4i32,
        1i32,
        16i32,
    )

    //  type system
    cmd->define_cfg<FlagKind::I32>(
        "max-struct-fields",
        "error when a struct or class declares more fields than this (0 = unlimited)",
        0i32,
        0i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-function-params",
        "error when a function declares more parameters than this (0 = unlimited)",
        255i32,
        0i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-tuple-arity",
        "maximum elements in a tuple type, at most 128 (0 = no cap below 128)",
        128i32,
        0i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-enum-variants",
        "error when an enum declares more variants than this (0 = unlimited)",
        0i32,
        0i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-match-arms",
        "error when a match has more arms than this (0 = unlimited)",
        0i32,
        0i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-union-width",
        "error when a union declares more members than this (0 = unlimited)",
        64i32,
        0i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-type-alias-depth",
        "maximum type alias chain depth before hard error",
        64i32,
        1i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-interface-impls",
        "error when a struct or class lists more impl interfaces than this (0 = unlimited)",
        0i32,
        0i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-extend-chain",
        "error when a type has more extend{} blocks than this in one file",
        64i32,
        1i32,
        65536i32,
    )

    //  error / warning budget
    cmd->define_cfg<FlagKind::I32>(
        "max-errors",
        "stop after N errors (0 = unlimited)",
        20i32,
        0i32,
        100000i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-warnings",
        "suppress warnings after N (0 = unlimited)",
        0i32,
        0i32,
        100000i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-notes",
        "suppress notes after N per diagnostic (0 = unlimited)",
        0i32,
        0i32,
        100000i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-diag-context-lines",
        "maximum source lines shown per diagnostic caret (0 = no limit)",
        3i32,
        0i32,
        32i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-suggestion-count",
        "maximum fix-it suggestions kept per diagnostic (0 = none)",
        5i32,
        0i32,
        64i32,
    )

    //  source / lexer
    cmd->define_cfg<FlagKind::I32>(
        "max-file-size-mb",
        "reject source files larger than this size in MB (0 = unlimited)",
        256i32,
        0i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-token-count",
        "reject files longer than this many tokens, per file including builtin/std (0 = unlimited)",
        0i32,
        0i32,
        2147483647i32,
    )

    //  codegen
    cmd->define_cfg<FlagKind::I32>(
        "max-codegen-passes",
        "maximum LLVM optimization passes to run (0 = pipeline default)",
        0i32,
        0i32,
        1024i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-object-size-mb",
        "reject object files larger than this size in MB (0 = unlimited)",
        512i32,
        0i32,
        65536i32,
    )

    //  borrow checker / AMT
    cmd->define_cfg<FlagKind::I32>(
        "max-borrow-depth",
        "maximum simultaneous live borrows tracked per scope",
        512i32,
        1i32,
        65536i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-amt-smartptr-rewrites",
        "maximum BCIR invalid-borrow -> smart-pointer rewrites per TU (0 = unlimited)",
        8192i32,
        0i32,
        2147483647i32,
    )

    //  threading
    cmd->define_cfg<FlagKind::I32>(
        "max-threads",
        "hard cap on compilation threads regardless of --threads (0 = no cap)",
        0i32,
        0i32,
        1024i32,
    )

    //  floating point
    cmd->define(
        FlagDef::str_c(
            "interface-pch",
            "",
            "interface-pch",
            "one precompiled interface per flavour ahead of the per-TU compiles: auto|on|off (default: auto, only for a flavour of 2+ TUs and 1 MiB of Kairo; --verbose shows a failed build's clang diagnostics)",
            "auto",
            _interface_pch_choices(),
            "on",
        ),
    )

    cmd->define(
        FlagDef::str_c(
            "fp-model",
            "",
            "fp-model",
            "floating-point semantics: precise|strict|fast (default: precise)",
            "precise",
            _fp_model_choices(),
            "precise",
        ),
    )

    cmd->define(
        FlagDef::str_c(
            "fp-contract",
            "",
            "fp-contract",
            "fused FP ops (FMAs): off|on|fast (default: off; wins over --fp-model)",
            "off",
            _fp_contract_choices(),
            "off",
        ),
    )

    cmd->define<FlagKind::Bool>(
        "signed-wrap",
        "",
        "signed-wrap",
        "treat signed integer overflow as two's complement instead of UB",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "unsigned-trap",
        "",
        "unsigned-trap",
        "trap on unsigned integer overflow (extends --no-overflow to unsigned)",
        false,
    )

    //  codegen optimizations
    cmd->define<FlagKind::Bool>(
        "strict-aliasing",
        "",
        "strict-aliasing",
        "enable strict aliasing optimizations (off in debug, on in release)",
        false,
    )

    cmd->define(
        FlagDef::str_c(
            "thread-model",
            "",
            "thread-model",
            "threading model: posix|single (default: posix)",
            "posix",
            _thread_model_choices(),
            "posix",
        ),
    )

    // Empty default: the policy follows -O (CodeGenOptions::unmatched_policy).
    cmd->define(
        FlagDef::str_c(
            "unmatched",
            "",
            "unmatched",
            "an undeclared value reaching an exhaustive match: trap|unreachable (default: trap, unreachable at -O3; an ADT's tag: unreachable, see --hardening)",
            "",
            _unmatched_choices(),
            "",
        ),
    )

    // Repeatable and comma-separated; each item is checked against the list.
    cmd->define(
        FlagDef::list_c(
            "hardening",
            "",
            "hardening",
            "runtime checks the optimizer may not assume away: enum-tags (an ADT match traps on a tag no variant has)",
            _hardening_choices(),
        ),
    )

    // Empty defaults: unset means the target's (or the driver's) own choice,
    // which is not any one of the values.
    cmd->define(
        FlagDef::str_c(
            "tls-model",
            "",
            "tls-model",
            "TLS model for `thread` globals and C++ thread_locals: global-dynamic|local-dynamic|initial-exec|local-exec (default: picked per global, see the docs)",
            "",
            _tls_model_choices(),
            "",
        ),
    )

    cmd->define(
        FlagDef::str_c(
            "visibility",
            "",
            "visibility",
            "default symbol visibility: default|hidden|protected (default: default)",
            "",
            _visibility_choices(),
            "",
        ),
    )

    cmd->define(
        FlagDef::str_c(
            "stack-protector",
            "",
            "stack-protector",
            "stack canaries: none|basic|strong|all (wins over -f[no-]stack-protector, which is basic|none)",
            "",
            _stack_protector_choices(),
            "",
        ),
    )

    cmd->define(
        FlagDef::str_c(
            "cf-protection",
            "",
            "cf-protection",
            "x86 CET control-flow protection: none|branch|return|full",
            "",
            _cf_protection_choices(),
            "",
        ),
    )

    cmd->define(
        FlagDef::str_c(
            "trivial-auto-var-init",
            "",
            "trivial-auto-var-init",
            "fill uninitialized locals of the emitted C++: uninitialized|zero|pattern",
            "",
            _auto_var_init_choices(),
            "",
        ),
    )

    cmd->define(
        FlagDef::str_c(
            "mcmodel",
            "",
            "mcmodel",
            "code model: tiny|small|kernel|medium|large (default: per target, small on x86_64)",
            "",
            _mcmodel_choices(),
            "",
        ),
    )

    cmd->define(
        FlagDef::str_c(
            "zero-call-used-regs",
            "",
            "zero-call-used-regs",
            "zero registers on function return: skip|used-gpr-arg|used-gpr|used-arg|used|all-gpr-arg|all-gpr|all-arg|all",
            "",
            _zero_call_used_regs_choices(),
            "",
        ),
    )

    cmd->define(
        FlagDef::str_c(
            "unwind-tables",
            "",
            "unwind-tables",
            "unwind table emission: none|sync|async (default: per target; async on x86_64)",
            "",
            _unwind_tables_choices(),
            "",
        ),
    )

    cmd->define<FlagKind::String>(
        "rtlib",
        "",
        "rtlib",
        "compiler runtime library: compiler-rt|libgcc (default: the sysroot's, else libgcc on a glibc host with GCC)",
        "",
    )

    cmd->define<FlagKind::String>(
        "unwindlib",
        "",
        "unwindlib",
        "unwind library: libunwind|libgcc|none (default: libgcc with --rtlib=libgcc, else libunwind; a sysroot manifest may set it)",
        "",
    )

    //  debug info
    cmd->define<FlagKind::Bool>(
        "debug-macros",
        "",
        "debug-macros",
        "embed macro definitions in DWARF debug info (needs -g)",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "embed-source",
        "",
        "embed-source",
        "embed source text in DWARF debug sections (needs -g and DWARF 5)",
        false,
    )

    //  instrumentation
    cmd->define<FlagKind::Bool>(
        "instrument-functions",
        "",
        "instrument-functions",
        "insert entry/exit instrumentation calls on every function",
        false,
    )

    cmd->define<FlagKind::String>(
        "xray",
        "",
        "xray",
        "XRay instrumentation: none|basic|always (default: none)",
        "none",
    )

    cmd->define<FlagKind::I32>(
        "xray-threshold",
        "",
        "xray-threshold",
        "minimum instruction count to instrument with XRay",
        200i32,
        1i32,
        1000000i32,
    )

    //  link-time optimizations
    cmd->define<FlagKind::Bool>(
        "icf",
        "",
        "icf",
        "identical code folding: merge functions with identical machine code",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "no-icf",
        "",
        "no-icf",
        "no identical code folding (it is on by default above -O0)",
        false,
    )

    cmd->define<FlagKind::String>(
        "icf-mode",
        "",
        "icf-mode",
        "ICF aggressiveness, only with --icf: safe|all (default: safe)",
        "safe",
    )

    cmd->define<FlagKind::Bool>(
        "whole-program-vtables",
        "",
        "whole-program-vtables",
        "whole-program vtable devirtualization, requires --lto",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "devirt",
        "",
        "devirt",
        "dead virtual function elimination, requires --lto=full",
        false,
    )

    //  security hardening
    cmd->define<FlagKind::Bool>(
        "stack-clash",
        "",
        "stack-clash",
        "probe stack on large frame allocations to prevent clash attacks",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "hot-cold-split",
        "",
        "hot-cold-split",
        "split hot/cold function sections using PGO data (ELF x86/aarch64 only)",
        false,
    )

    //  WASM / WASI
    cmd->define<FlagKind::String>(
        "wasm-exec-model",
        "",
        "wasm-exec-model",
        "WASM execution model: command (_start) or reactor (--no-entry, crt1-reactor.o) (default: command)",
        "command",
    )

    //  platform-specific / embedded
    cmd->define<FlagKind::Bool>(
        "no-implicit-float",
        "",
        "no-implicit-float",
        "disallow implicit generation of float or vector instructions",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "kernel-mode",
        "",
        "kernel-mode",
        "kernel code model: no red zone, no implicit float, no SSE (x86 only)",
        false,
    )

    // Parsed into the invocation and consumed by nothing. Each one warns
    // (U005W) when given and renders as [not implemented] in --help, so a
    // user never believes a flag did something it did not. Remove an entry
    // here in the same commit that adds the consumer. Keys: the registry key
    // (cfg flags as "c:<name>", features by bare name).

    // driver / dumps: no pass pipeline, BCIR, IR verifier, regalloc or
    // generic-instantiation dump exists; --dump-type-info has no per-expr dump.
    cmd->mark_unimplemented("print-pass-pipeline")
    cmd->mark_unimplemented("print-bcir")
    cmd->mark_unimplemented("print-generics")
    cmd->mark_unimplemented("print-regalloc")
    cmd->mark_unimplemented("dump-type-info")
    cmd->mark_unimplemented("verify-ir")
    cmd->mark_unimplemented("verify-bcir")
    cmd->mark_unimplemented("bcir-verbose")
    cmd->mark_unimplemented("bcir-stats")
    cmd->mark_unimplemented("suppress")
    // incremental compilation is --cache-dir (Compiler/Spec/Incremental.md,
    // phase 1); these two older spellings of it are not wired. The module cache
    // is phase 2's.
    cmd->mark_unimplemented("incremental")
    cmd->mark_unimplemented("incremental-dir")
    cmd->mark_unimplemented("module-name")
    cmd->mark_unimplemented("module-cache-dir")
    cmd->mark_unimplemented("no-module-cache")
    // test runner: none exists.
    cmd->mark_unimplemented("test")
    cmd->mark_unimplemented("test-list")
    cmd->mark_unimplemented("test-filter")
    cmd->mark_unimplemented("test-format")
    cmd->mark_unimplemented("test-threads")
    cmd->mark_unimplemented("test-no-capture")
    cmd->mark_unimplemented("test-timeout")
    cmd->mark_unimplemented("test-exit-code")
    // target: --host is never read; the C++ ABI follows the triple.
    cmd->mark_unimplemented("host")
    cmd->mark_unimplemented("cxx-abi")
    // borrow checker / AMT / cfg / panic handler: the subsystems do not exist.
    // --borrow-check and --amt-mode values are still validated.
    cmd->mark_unimplemented("borrow-check")
    cmd->mark_unimplemented("amt-mode")
    cmd->mark_unimplemented("amt-report-file")
    cmd->mark_unimplemented("panic-handler")
    cmd->mark_unimplemented("cfg")
    cmd->mark_unimplemented("edition") // validated (2025|2026) but nothing reads it
    // language gates with no lowering or check point to hang them on.
    cmd->mark_unimplemented("no-assert")
    cmd->mark_unimplemented("no-finally")
    cmd->mark_unimplemented("no-exceptions")
    cmd->mark_unimplemented("no-overflow")
    cmd->mark_unimplemented("strict-const")
    cmd->mark_unimplemented("no-eval")
    cmd->mark_unimplemented("no-generics")
    cmd->mark_unimplemented("verify-interfaces")
    cmd->mark_unimplemented("const-checks")
    cmd->mark_unimplemented("overflow-checks")
    cmd->mark_unimplemented("strict-null")
    cmd->mark_unimplemented("union-inference")
    // codegen features with no cc1 spelling, or that need a runtime archive
    // the bundled sysroots do not ship (sanitizers, xray, coverage, PGO).
    cmd->mark_unimplemented("force-inline")
    cmd->mark_unimplemented("tail-call")
    cmd->mark_unimplemented("dead-code-elim")
    cmd->mark_unimplemented("export-all")
    cmd->mark_unimplemented("coverage")
    cmd->mark_unimplemented("profile-generate")
    cmd->mark_unimplemented("sanitize-address")
    cmd->mark_unimplemented("sanitize-thread")
    cmd->mark_unimplemented("sanitize-memory")
    cmd->mark_unimplemented("sanitize-ub")
    cmd->mark_unimplemented("profile-use")
    cmd->mark_unimplemented("coverage-format")
    cmd->mark_unimplemented("xray")
    cmd->mark_unimplemented("xray-threshold")
    cmd->mark_unimplemented("lto") // objects are never bitcode, so lld has nothing to optimise
    cmd->mark_unimplemented("whole-program-vtables")
    cmd->mark_unimplemented("devirt")
    cmd->mark_unimplemented("split-dwarf")
    cmd->mark_unimplemented("disable-llvm-pass")
    cmd->mark_unimplemented("unsigned-trap")
    cmd->mark_unimplemented("strict-aliasing") // TBAA is already on at -O1+; nothing to add
    // linker: no lld spelling, or deprecated by the platform.
    cmd->mark_unimplemented("bitcode")
    cmd->mark_unimplemented("wasi")
    cmd->mark_unimplemented("wasi-version")
    cmd->mark_unimplemented("no-stack-check")
    cmd->mark_unimplemented("fixed-stack-size")
    cmd->mark_unimplemented("wasm-bulk-memory")
    cmd->mark_unimplemented("wasm-tail-calls")
    cmd->mark_unimplemented("wasm-simd")
    cmd->mark_unimplemented("wasm-sign-ext")
    cmd->mark_unimplemented("wasm-reference-types")
    cmd->mark_unimplemented("wasm-exceptions")
    // diagnostics: byte columns only; cascade suppression has no switch.
    cmd->mark_unimplemented("c:tab-width")
    cmd->mark_unimplemented("diag-cascade")
    // --c* limits nothing enforces.
    cmd->mark_unimplemented("c:max-generic-instantiations")
    cmd->mark_unimplemented("c:max-const-eval-steps")
    cmd->mark_unimplemented("c:max-const-eval-depth")
    cmd->mark_unimplemented("c:max-const-backtrace")
    cmd->mark_unimplemented("c:max-for-unroll-count")
    cmd->mark_unimplemented("c:max-inline-depth")
    cmd->mark_unimplemented("c:max-lambda-capture-size")
    cmd->mark_unimplemented("c:max-codegen-passes")
    cmd->mark_unimplemented("c:max-object-size-mb")
    cmd->mark_unimplemented("c:max-borrow-depth")
    cmd->mark_unimplemented("c:max-amt-smartptr-rewrites")
}

pub fn register_test_flags(cmd: *Command) {
    // general
    //          Flag Type        Key             Short  Long           Description                                        Default
    cmd->define<FlagKind::Bool>("help", "h", "help", "show this help and exit", false)
    cmd->define<FlagKind::Bool>("version", "", "version", "print compiler version and exit", false)
    cmd->define<FlagKind::Bool>("verbose", "v", "verbose", "enable verbose output", false)
    cmd->define<FlagKind::Bool>("quiet", "", "quiet", "suppress all non-error output", false)
    cmd->define<FlagKind::String>(
        "explain",
        "",
        "explain",
        "explain a diagnostic code (e.g. U003E)",
        "",
    )

    // build
    cmd->define<FlagKind::String>(
        "profile",
        "",
        "profile",
        "build profile (debug|release|min-size)",
        "debug",
    )

    // output
    cmd->define<FlagKind::String>("output", "o", "output", "output file path")
    cmd->define<FlagKind::Bool>(
        "compile-only",
        "c",
        "compile-only",
        "compile only, do not link",
        false,
    )

    cmd->define<FlagKind::Bool>("emit-asm", "S", "emit-asm", "emit assembly output", false)
    cmd->define<FlagKind::Bool>("preprocess", "E", "preprocess", "run preprocessor only", false)
    cmd->define<FlagKind::String>("emit", "", "emit", "emit IR type (ast|ir|llvm|asm|obj)", "obj")

    // include / link
    cmd->define<FlagKind::PathList>(
        "include-dirs",
        "I",
        "include",
        "add directory to include search path",
    )

    cmd->define<FlagKind::PathList>(
        "lib-dirs",
        "L",
        "lib-dir",
        "add directory to library search path",
    )

    cmd->define<FlagKind::PathList>("link-libs", "l", "link", "link against library")
    cmd->define<FlagKind::String>("sysroot", "", "sysroot", "override sysroot", "")
    cmd->define<FlagKind::String>(
        "resource-dir",
        "",
        "resource-dir",
        "clang resource directory",
        "",
    )

    cmd->define<FlagKind::String>("prelude", "", "prelude", "path to custom prelude file", "")
    cmd->define<FlagKind::Bool>("no-prelude", "", "no-prelude", "disable implicit prelude", false)
    cmd->define<FlagKind::Bool>("no-stdlib", "", "no-stdlib", "disable standard library", false)

    // target
    cmd->define<FlagKind::String>(
        "target",
        "",
        "target",
        "target triple (e.g. x86_64-unknown-linux-gnu)",
        "",
    )

    cmd->define<FlagKind::String>("host", "", "host", "host triple", "")
    cmd->define<FlagKind::String>("march", "", "march", "target architecture", "")
    cmd->define<FlagKind::String>("mcpu", "", "mcpu", "target CPU", "")
    cmd->define<FlagKind::String>("mabi", "", "mabi", "target ABI", "")
    cmd->define<FlagKind::String>("mtune", "", "mtune", "tune for CPU", "")

    // optimization
    cmd->define(
        FlagDef::str_c("opt", "O", "", "optimization level", "0", _opt_level_choices(), "1"),
    )

    cmd->define<FlagKind::Bool>("debug", "g", "", "emit debug symbols", false)
    cmd->define<FlagKind::Bool>("no-debug", "", "g0", "strip debug symbols", false)

    // warnings
    cmd->define<FlagKind::Bool>("nowarn", "w", "", "suppress all warnings", false)
    cmd->define<FlagKind::Bool>("wall", "", "Wall", "enable common warnings", false)
    cmd->define<FlagKind::Bool>("wextra", "", "Wextra", "enable extra warnings", false)
    cmd->define<FlagKind::Bool>("werror", "", "Werror", "treat warnings as errors", false)
    cmd->define<FlagKind::String>(
        "diag-format",
        "",
        "fdiagnostics-format",
        "diagnostic format (pretty|json|clang)",
        "pretty",
    )

    // language features  (-f{name} / -fno-{name}, query via get_feature) ----
    cmd->define<FlagKind::Feature>("unsafe", "allow unsafe operations (-funsafe / -fno-unsafe)")
    cmd->define<FlagKind::Feature>(
        "exceptions",
        "enable C++ style exceptions (-fexceptions / -fno-exceptions)",
    )

    cmd->define<FlagKind::Feature>(
        "implicit-conv",
        "allow implicit type conversions (-fimplicit-conversions / -fno-...)",
    )

    cmd->define<FlagKind::Feature>(
        "strict-null",
        "strict null pointer checks (-fstrict-null / -fno-strict-null)",
    )

    cmd->define<FlagKind::Feature>("inline", "function inlining (-finline / -fno-inline)")
    cmd->define<FlagKind::Feature>(
        "const-checks",
        "const correctness checks (-fconst-checks / -fno-const-checks)",
    )

    cmd->define<FlagKind::Feature>(
        "dead-code-elim",
        "dead code elimination (-fdead-code-elim / -fno-dead-code-elim)",
    )

    cmd->define<FlagKind::Feature>(
        "tail-call",
        "tail call optimization (-ftail-call / -fno-tail-call)",
    )

    cmd->define<FlagKind::Feature>(
        "union-inference",
        "union type inference (-funion-inference / -fno-union-inference)",
    )

    cmd->define<FlagKind::Feature>("export", "module export (-fexport / -fno-export)")
    cmd->define<FlagKind::String>("std", "", "std", "language standard (e.g. kairo25)", "")

    // hardening
    cmd->define<FlagKind::StringList>(
        "sanitize",
        "",
        "fsanitize",
        "enable sanitizer (address|thread|ub|...)",
    )

    cmd->define<FlagKind::Bool>(
        "no-omit-fp",
        "",
        "fno-omit-frame-pointer",
        "keep frame pointer",
        false,
    )

    cmd->define<FlagKind::Bool>(
        "stack-prot",
        "",
        "fstack-protector",
        "enable stack protector",
        false,
    )

    cmd->define<FlagKind::Bool>("pie", "", "fPIE", "build position-independent executable", false)
    cmd->define<FlagKind::Bool>("pic", "", "fPIC", "build position-independent code", false)
    cmd->define<FlagKind::Bool>(
        "fast-math",
        "",
        "ffast-math",
        "enable fast-math optimisations",
        false,
    )

    cmd->define<FlagKind::Bool>("no-rtti", "", "fno-rtti-data", "disable RTTI data", false)

    // pass-through
    cmd->define<FlagKind::StringList>("xcxx", "", "Xcxx", "pass flag directly to C++ backend")
    cmd->define<FlagKind::StringList>("xlinker", "", "Xlinker", "pass flag directly to linker")

    // misc
    cmd->define<FlagKind::Bool>("save-temps", "", "save-temps", "keep intermediate files", false)
    cmd->define<FlagKind::Bool>(
        "coverage",
        "",
        "coverage",
        "enable coverage instrumentation",
        false,
    )

    cmd->define<FlagKind::Bool>("dump-passes", "", "dump-passes", "dump optimization passes", false)
    cmd->define<FlagKind::F64>("threshold", "", "threshold", "inlining threshold", 1.0, 0.0, 1.0)

    // config flags  (--c{key}=value, query via get_cfg_*) ------------------
    cmd->define_cfg<FlagKind::I32>(
        "max-recursion-depth",
        "maximum macro recursion depth",
        256i32,
        1i32,
        4096i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-errors",
        "stop after N errors (0 = unlimited)",
        50i32,
        0i32,
        10000i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-warnings",
        "suppress warnings after N (0 = unlimited)",
        0i32,
        0i32,
        10000i32,
    )

    cmd->define_cfg<FlagKind::I32>(
        "max-inline-depth",
        "inliner recursion depth limit",
        8i32,
        1i32,
        64i32,
    )

    cmd->define_cfg<FlagKind::F64>("inline-cost", "inliner cost threshold", 1.0, 0.0, 100.0)
    cmd->define_cfg<FlagKind::String>(
        "error-format",
        "error output format (pretty|json|clang)",
        "pretty",
    )

    cmd->define_cfg<FlagKind::Bool>("color", "force colored output", true)

    // positional files (must be last)
    cmd->define<FlagKind::PathList>("files", "or run command with --help to see usage")
}

pub fn Test() -> i32 {
    io::println("=== Command Test Suite ===\n")

    var suite = Assert("Command Tests")

    // shared fixture - used by non-error tests
    var diag = DiagEngine()
    var cmd  = Command(unsafe &diag)
    register_test_flags(&cmd)
    // The test lambdas capture by copy (stage1 semantics); parse_string
    // mutates the fixture, so they share it through this pointer.
    var *cmd_p = &cmd

    // isolated fixture for tests that expect errors
    fn fresh() -> (unsafe *DiagEngine, Command) {
        var unsafe *d = kairo::std::create<DiagEngine>()
        var        c  = Command(d)
        register_test_flags(&c)
        return (d, cxx::std::move(c))
    }

    //  BOOL FLAGS

    suite.equal<string>(
        "--verbose bool flag",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("--verbose main.k")
            if !r.get_bool("verbose") {
                return "expected verbose=true"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "-v short form",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-v main.k")
            if !r.get_bool("verbose") {
                return "expected verbose=true"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "bool default = false",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("main.k")
            if r.get_bool("verbose") {
                return "verbose should default to false"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "-gc short cluster",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-gc main.k")
            if !r.get_bool("debug") {
                return "expected debug=true"
            }

            if !r.get_bool("compile-only") {
                return "expected compile-only=true"
            }

            return "pass"
        },
        1000,
    )

    //  STRING FLAGS

    suite.equal<string>(
        "--output=./bin/app",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("--output=./bin/app main.k")
            if r.get_string("output") != "./bin/app" {
                return f"got '{r.get_string("output")}'"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "-o space-separated",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-o ./bin/app main.k")
            if r.get_string("output") != "./bin/app" {
                return f"got '{r.get_string("output")}'"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "-ofoo inline on short",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-ofoo.k main.k")
            if r.get_string("output") != "foo.k" {
                return f"got '{r.get_string("output")}'"
            }

            return "pass"
        },
        1000,
    )

    //  CHOICE  (-O2, -O3, -Os, bare -O, last wins, rejected values)

    suite.equal<string>(
        "-O2 joined value",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-O2 main.k")
            if r.get_string("opt") != "2" {
                return f"expected 2, got {r.get_string("opt")}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "-O3 joined value",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-O3 main.k")
            if r.get_string("opt") != "3" {
                return f"expected 3, got {r.get_string("opt")}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "-O9 not a choice -> error + ok=false",
        "pass",
        fn () -> string {
            var        pair = fresh()
            var unsafe *d   = pair.0
            var        c    = pair.1
            var        r    = c.parse_string("-O9 main.k")
            if !d->has_errors() {
                kairo::std::destroy(d)
                return "expected bounds error for -O9"
            }

            if r.ok {
                kairo::std::destroy(d)
                return "expected ok=false"
            }

            kairo::std::destroy(d)
            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "bare -O is -O1 and keeps the next argument",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-O main.k")
            if r.get_string("opt") != "1" {
                return f"expected 1, got {r.get_string("opt")}"
            }

            if r.files.size() != 1 {
                return "main.k was swallowed as the value"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "-O2 -Os: last wins",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-O2 -Os main.k")
            if r.get_string("opt") != "s" {
                return f"expected s, got {r.get_string("opt")}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "-Ofast -> error",
        "pass",
        fn () -> string {
            var        pair = fresh()
            var unsafe *d   = pair.0
            var        c    = pair.1
            var        r    = c.parse_string("-Ofast main.k")
            if !d->has_errors() {
                kairo::std::destroy(d)
                return "expected error for -Ofast"
            }

            if r.ok {
                kairo::std::destroy(d)
                return "expected ok=false"
            }

            kairo::std::destroy(d)
            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "--opt=2 long-form",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("--opt=2 main.k")
            if r.get_string("opt") != "2" {
                return f"expected 2, got {r.get_string("opt")}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "--opt=fast non-numeric -> error",
        "pass",
        fn () -> string {
            var        pair = fresh()
            var unsafe *d   = pair.0
            var        c    = pair.1
            c.parse_string("--opt=fast main.k")
            if !d->has_errors() {
                kairo::std::destroy(d)
                return "expected parse error for --opt=fast"
            }

            kairo::std::destroy(d)
            return "pass"
        },
        1000,
    )

    //  F64 WITH BOUNDS

    suite.equal<string>(
        "--threshold=0.5",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("--threshold=0.5 main.k")
            var v = r.get_f64("threshold")
            if v < 0.49 || v > 0.51 {
                return f"expected ~0.5, got {v}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "--threshold=1.5 out-of-bounds -> error",
        "pass",
        fn () -> string {
            var        pair = fresh()
            var unsafe *d   = pair.0
            var        c    = pair.1
            c.parse_string("--threshold=1.5 main.k")
            if !d->has_errors() {
                kairo::std::destroy(d)
                return "expected bounds error for threshold=1.5"
            }

            kairo::std::destroy(d)
            return "pass"
        },
        1000,
    )

    //  LIST FLAGS  (repeatable)

    suite.equal<string>(
        "-I repeatable list",
        "pass",
        fn () -> string {
            var r   = cmd_p->parse_string("-I./include -I/usr/include main.k")
            var lst = *r.get_list("include-dirs")
            if lst.size() != 2 {
                return f"expected 2 entries, got {lst.size()}"
            }

            if lst[0] != "./include" {
                return f"entry 0: '{lst[0]}'"
            }

            if lst[1] != "/usr/include" {
                return f"entry 1: '{lst[1]}'"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "-Lpath -lssl -lcrypto",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-Lpath/to/lib -lssl -lcrypto main.k")
            if r.get_list("lib-dirs")->size() != 1 {
                return "expected 1 lib dir"
            }

            if r.get_list("link-libs")->size() != 2 {
                return "expected 2 link libs"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "empty list default",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("main.k")
            if r.get_list("include-dirs")->size() != 0 {
                return "expected empty include list"
            }

            return "pass"
        },
        1000,
    )

    //  POSITIONAL FILES

    suite.equal<string>(
        "single file",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("main.k")
            if r.files.size() != 1 {
                return f"expected 1, got {r.files.size()}"
            }

            if r.files[0] != "main.k" {
                return f"got '{r.files[0]}'"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "multiple files",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("main.k util.k helper.k")
            if r.files.size() != 3 {
                return f"expected 3, got {r.files.size()}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "flags and files interleaved",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("main.k ---g -O2 util.k")
            if r.files.size() != 2 {
                return f"files: {r.files.size()}"
            }

            if !r.get_bool("debug") {
                return "debug"
            }

            if r.get_string("opt") != "2" {
                return "opt"
            }

            return "pass"
        },
        1000,
    )

    //  END-OF-OPTIONS  (--)

    suite.equal<string>(
        "-- stops flag parsing",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("--verbose -- --not-a-flag file.k")
            if !r.get_bool("verbose") {
                return "verbose before --"
            }

            if r.files.size() != 2 {
                return f"expected 2 files after --, got {r.files.size()}"
            }

            return "pass"
        },
        1000,
    )

    //  WINDOWS /flag

    suite.equal<string>(
        "/Wall",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("/Wall main.k")
            if !r.get_bool("wall") {
                return "expected wall=true from /Wall"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "/g",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("/g main.k")
            if !r.get_bool("debug") {
                return "expected debug=true from /g"
            }

            return "pass"
        },
        1000,
    )

    //  REAL-WORLD INVOCATIONS

    suite.equal<string>(
        "release build",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string(
                "-O3 -Wall -Wextra --output=./app --profile=release main.k util.k",
            )

            if r.get_string("opt") != "3" {
                return "opt"
            }

            if !r.get_bool("wall") {
                return "wall"
            }

            if !r.get_bool("wextra") {
                return "wextra"
            }

            if r.get_string("output") != "./app" {
                return "output"
            }

            if r.files.size() != 2 {
                return f"files: {r.files.size()}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "cross-compile",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("--target=aarch64-linux-gnu --march=armv8-a -O2 -g main.k")
            if r.get_string("target") != "aarch64-linux-gnu" {
                return "target"
            }

            if r.get_string("march") != "armv8-a" {
                return "march"
            }

            if r.get_string("opt") != "2" {
                return "opt"
            }

            if !r.get_bool("debug") {
                return "debug"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "kairo test.k ---I something -Lotherlib",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("test.k ---I something -Lotherlib")
            if r.files.size() != 1 {
                return f"files: {r.files.size()}"
            }

            if r.files[0] != "test.k" {
                return f"file: '{r.files[0]}'"
            }

            if r.get_list("include-dirs")->size() != 1 {
                return "include-dirs count"
            }

            if (*r.get_list("include-dirs"))[0] != "something" {
                return "include value"
            }

            if r.get_list("lib-dirs")->size() != 1 {
                return "lib-dirs count"
            }

            if (*r.get_list("lib-dirs"))[0] != "otherlib" {
                return "lib value"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "asan build",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-fsanitize=address -fno-omit-frame-pointer -g main.k")
            if r.get_list("sanitize")->size() == 0 {
                return "sanitize list empty"
            }

            if (*r.get_list("sanitize"))[0] != "address" {
                return "sanitize value"
            }

            if !r.get_bool("no-omit-fp") {
                return "no-omit-fp"
            }

            if !r.get_bool("debug") {
                return "debug"
            }

            return "pass"
        },
        1000,
    )

    //  ERROR CASES

    suite.equal<string>(
        "unknown flag -> U002E, ok=false",
        "pass",
        fn () -> string {
            var        pair = fresh()
            var unsafe *d   = pair.0
            var        c    = pair.1
            var        r    = c.parse_string("--totally-unknown main.k")
            if !d->has_errors() {
                kairo::std::destroy(d)
                return "expected U002E"
            }

            if r.ok {
                kairo::std::destroy(d)
                return "expected ok=false"
            }

            kairo::std::destroy(d)
            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "'/-' prefix -> U003E",
        "pass",
        fn () -> string {
            var        pair = fresh()
            var unsafe *d   = pair.0
            var        c    = pair.1
            c.parse_string("/-g")
            if !d->has_errors() {
                kairo::std::destroy(d)
                return "expected U003E"
            }

            kairo::std::destroy(d)
            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "required --output missing -> U004E",
        "pass",
        fn () -> string {
            var        pair = fresh()
            var unsafe *d   = pair.0
            var        c    = pair.1
            var        r    = c.parse_string("main.k")
            if !d->has_errors() {
                kairo::std::destroy(d)
                return "expected required-field error"
            }

            if r.ok {
                kairo::std::destroy(d)
                return "expected ok=false"
            }

            kairo::std::destroy(d)
            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "no files -> required-file error",
        "pass",
        fn () -> string {
            var        pair = fresh()
            var unsafe *d   = pair.0
            var        c    = pair.1
            var        r    = c.parse_string("-g --output=app")
            if !d->has_errors() {
                kairo::std::destroy(d)
                return "expected required-file error"
            }

            if r.ok {
                kairo::std::destroy(d)
                return "expected ok=false"
            }

            kairo::std::destroy(d)
            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "known flags only -> no errors",
        "pass",
        fn () -> string {
            var        pair = fresh()
            var unsafe *d   = pair.0
            var        c    = pair.1
            // suppress the required-field errors by providing required flags
            c.parse_string("-g -O2 --verbose --output=app main.k")
            if d->has_errors() {
                kairo::std::destroy(d)
                return f"unexpected {d->error_count()} error(s) for valid input"
            }

            kairo::std::destroy(d)
            return "pass"
        },
        1000,
    )

    // //  HELP GENERATION  (smoke)
    //  FEATURE FLAGS  (-f{name} / -fno-{name}  ->  get_feature returns -1/0/1)

    suite.equal<string>(
        "-funsafe enables feature",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-funsafe main.k")
            if r.get_feature("unsafe") != 1 {
                return f"expected 1 (enabled), got {r.get_feature("unsafe")}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "-fno-unsafe disables feature",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-fno-unsafe main.k")
            if r.get_feature("unsafe") != 0 {
                return f"expected 0 (disabled), got {r.get_feature("unsafe")}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "feature unset = -1",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("main.k")
            if r.get_feature("unsafe") != -1 {
                return f"expected -1 (unset), got {r.get_feature("unsafe")}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "-finline enable",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-finline main.k")
            if r.get_feature("inline") != 1 {
                return "expected inline=1"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "-fno-inline disable",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-fno-inline main.k")
            if r.get_feature("inline") != 0 {
                return "expected inline=0"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "multiple features in one invocation",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("-funsafe -fno-exceptions -fstrict-null main.k")
            if r.get_feature("unsafe") != 1 {
                return "unsafe"
            }

            if r.get_feature("exceptions") != 0 {
                return "exceptions"
            }

            if r.get_feature("strict-null") != 1 {
                return "strict-null"
            }

            return "pass"
        },
        1000,
    )

    //  CONFIG FLAGS  (--c{key}=value  ->  get_cfg_*)

    suite.equal<string>(
        "--cmax-recursion-depth=128",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("--cmax-recursion-depth=128 main.k")
            if r.get_cfg_i32("max-recursion-depth") != 128 {
                return f"expected 128, got {r.get_cfg_i32("max-recursion-depth")}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "--cmax-errors=0 (unlimited)",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("--cmax-errors=0 main.k")
            if r.get_cfg_i32("max-errors") != 0 {
                return f"expected 0, got {r.get_cfg_i32("max-errors")}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "--cinline-cost=2.5",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("--cinline-cost=2.5 main.k")
            var v = r.get_cfg_f64("inline-cost")
            if v < 2.4 || v > 2.6 {
                return f"expected ~2.5, got {v}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "--cerror-format=json",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("--cerror-format=json main.k")
            if r.get_cfg_str("error-format") != "json" {
                return f"expected 'json', got '{r.get_cfg_str("error-format")}'"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "config i32 out-of-bounds -> error",
        "pass",
        fn () -> string {
            var        pair = fresh()
            var unsafe *d   = pair.0
            var        c    = pair.1
            c.parse_string("--cmax-recursion-depth=99999 main.k")
            if !d->has_errors() {
                kairo::std::destroy(d)
                return "expected bounds error"
            }

            kairo::std::destroy(d)
            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "config default unchanged when absent",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("main.k")
            if r.get_cfg_i32("max-recursion-depth") != 256 {
                return f"expected default 256, got {r.get_cfg_i32("max-recursion-depth")}"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "cfg_is_set false when not provided",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("main.k")
            if r.cfg_is_set("max-errors") {
                return "expected cfg not set"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "cfg_is_set true when provided",
        "pass",
        fn () -> string {
            var r = cmd_p->parse_string("--cmax-errors=10 main.k")
            if !r.cfg_is_set("max-errors") {
                return "expected cfg to be set"
            }

            return "pass"
        },
        1000,
    )

    return 0
}
