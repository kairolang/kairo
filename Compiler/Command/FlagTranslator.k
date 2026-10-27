/// --- The Kairo Project -------------------- Command/FlagTranslator.k --- ///
///
///   The one home where kairo flags meet clang's: kairo -> cc1, kairo ->
///   clang driver, and clang driver -> kairo.
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
///   No other file spells a clang flag for a kairo option. Before this file
///   the mapping lived in five places (CompilerInstance::_codegen_cc1,
///   _fast_math_cc1, _backend_config; ClangBackend::_clang_wargs_from_policy,
///   _driver_target_args) and only went one way. Now:
///
///     cc1     what kairo's own TUs (the hand-built invocation in
///             ClangBackend::_cc1_common) and the ffi header sets compile with.
///     Driver  the same decisions as clang DRIVER words, for C/C++ inputs
///             handed to clang's driver, and for the target probe.
///     reverse from_driver: a clang driver command line as kairo CLI words,
///             which then go through the ordinary kairo parser. kcc is
///             kairo fed a clang command line; it has no parser of its own.
///
///   Shape. Each concern is one function that decides ONCE what the user
///   asked for and writes it in the requested spelling, the two spellings
///   side by side. Order is part of the contract: cc1 takes the last of a
///   repeated option, so the broad switch comes before the specific one
///   (-ffast-math before --fp-contract) and --mllvm words come last. The cc1
///   output is byte-identical to what the five old sites produced; a golden
///   --print-clang-args corpus guards that.
///
///   What is NOT spelled here: the header-search roots model (it is a
///   property of the sysroot, not of a flag; ClangBackend::_cc1_common owns
///   it) and the per-TU plumbing (-emit-obj, the placeholder input).
///

ffi "c++" import "Native/Types.hh";
ffi "c++" import "clang/Options/Options.h";
ffi "c++" import "llvm/Option/Arg.h";
ffi "c++" import "llvm/Option/ArgList.h";
ffi "c++" import "llvm/Option/Option.h";
ffi "c++" import "llvm/Option/OptTable.h";
ffi "c++" import "llvm/TargetParser/Triple.h";
ffi "c++" import "llvm/Support/FileSystem.h";

import Config::Invocation::*;
import Config::CodeGen::*;
import Config::Target::*;
import Config::Language::*;
import Config::Diagnostic::*;
import Diagnostic::ClangDiagLookup::*;

/// Which clang command line a word is for.
enum ClangSpelling derives u8 {
    CC1,     ///< clang -cc1: the frontend's own option names
    Driver,  ///< clang / clang++: the user-facing names
}

// --- small helpers -------------------------------------------------------- //

fn _fx_push(o: *vec::<string>, a: string) { o->push_back(a); }
fn _fx_push2(o: *vec::<string>, a: string, b: string) { o->push_back(a); o->push_back(b); }

/// A cc1-only word reaching cc1 through the driver: `-Xclang <w>`.
fn _fx_xclang(o: *vec::<string>, w: string) { o->push_back("-Xclang"); o->push_back(w); }

/// \brief extracts the numeric part of a diagnostic code: "S025W" -> 25,
///        "C889" -> 889, 0 when there is no digit.
fn _fx_code_number(code: string) -> u32 {
    var n = code.length();
    var i: usize = 0;
    var val: u32 = 0;
    var seen: bool = false;
    while i < n {
        var c = code[i];
        if c >= '0' && c <= '9' {
            seen = true;
            val = val * 10 + static_cast::<u32>(c - '0');
        } else if seen {
            break; // digit run ended; ignore any trailing severity letter
        }
        i += 1;
    }
    return val;
}

/// True for a clang-sourced C-code (C followed by a digit: C889, C889W);
/// CL... (Lowering) and the native categories have no clang warning group.
fn _fx_is_clang_code(code: string) -> bool {
    var n = code.length();
    var i: usize = 0;
    while i < n && (code[i] == ' ' || code[i] == '\t') { i += 1; }
    if i >= n { return false; }
    if !(code[i] == 'C' || code[i] == 'c') { return false; }
    i += 1;
    if i >= n { return false; }
    return code[i] >= '0' && code[i] <= '9';
}

/// The standards kairo's --cxx-std / --c-std accept (FlagRegistry's
/// _cxx_std_choices / _c_std_choices); anything else stays a clang word.
fn _fx_known_cxx_std(v: string) -> bool {
    return (v == "c++20") || (v == "c++23") || (v == "c++26")
        || (v == "gnu++20") || (v == "gnu++23") || (v == "gnu++26");
}
fn _fx_known_c_std(v: string) -> bool {
    return (v == "c89") || (v == "c99") || (v == "c11") || (v == "c17") || (v == "c23")
        || (v == "gnu89") || (v == "gnu99") || (v == "gnu11") || (v == "gnu17") || (v == "gnu23");
}

// --- reverse table ---------------------------------------------------------- //

/// How a clang driver option becomes kairo words.
enum RevShape derives u8 {
    Flag,       ///< no value: kairo words verbatim
    Value,      ///< one value: kairo prefix + value (prefix ending in '=' joins)
    ValueSep,   ///< one value: kairo flag, then the value as its own word
    Commas,     ///< -Wl,a,b: one kairo word per comma piece
}

class RevRow {
    pub var clang: string;   ///< the option's prefixed name as clang's OptTable reports it
    pub var kairo: string;   ///< the kairo spelling (a prefix for valued rows)
    pub var shape: RevShape = RevShape::Flag;
}

fn _fx_row(rows: *vec::<RevRow>, clang: string, kairo: string, shape: RevShape) {
    var r = RevRow();
    (r.clang) = clang;
    (r.kairo) = kairo;
    (r.shape) = shape;
    rows->push_back(r);
}

/// \brief every clang driver option kairo has a flag for.
///
/// \details The left column is clang's prefixed option name (what
///          Option::getPrefixedName returns: `-O`, `--target=`, `-I`), so
///          joined and separate spellings (-Ifoo, -I foo) are one row. A
///          clang option with no row is not lost: from_driver returns it as
///          clang-only, and it reaches the C/C++ compiles verbatim.
///
///          Same decisions as the forward functions below, in the other
///          direction. A kairo flag that gains a clang spelling gets its row
///          here and its forward spelling in the matching function, in the
///          same commit.
fn _fx_reverse_rows() -> vec::<RevRow> {
    var r = vec::<RevRow>();
    // -- action / output ------------------------------------------------------
    _fx_row(&r, "-c",             "-c",               RevShape::Flag);
    _fx_row(&r, "-S",             "-S",               RevShape::Flag);
    _fx_row(&r, "-E",             "--preprocess",     RevShape::Flag);   // kairo -E is --error
    _fx_row(&r, "-fsyntax-only",  "--syntax-only",    RevShape::Flag);
    _fx_row(&r, "-o",             "-o",               RevShape::ValueSep);
    _fx_row(&r, "-x",             "-x",               RevShape::ValueSep);
    _fx_row(&r, "-v",             "-v",               RevShape::Flag);
    _fx_row(&r, "-save-temps",    "--save-temps",     RevShape::Flag);
    // -- target -----------------------------------------------------------------
    _fx_row(&r, "--target=",      "--target=",        RevShape::Value);
    _fx_row(&r, "-target",        "--target=",        RevShape::Value);
    _fx_row(&r, "-m32",           "--m32",            RevShape::Flag);
    _fx_row(&r, "-m64",           "--m64",            RevShape::Flag);
    _fx_row(&r, "-march=",        "--march=",         RevShape::Value);
    _fx_row(&r, "-mcpu=",         "--mcpu=",          RevShape::Value);
    _fx_row(&r, "-mtune=",        "--mtune=",         RevShape::Value);
    _fx_row(&r, "-mabi=",         "--mabi=",          RevShape::Value);
    _fx_row(&r, "--sysroot=",     "--sysroot=",       RevShape::Value);
    _fx_row(&r, "--sysroot",      "--sysroot=",       RevShape::Value);
    _fx_row(&r, "-resource-dir",  "--resource-dir=",  RevShape::Value);
    _fx_row(&r, "-resource-dir=", "--resource-dir=",  RevShape::Value);
    // -- optimization / debug ------------------------------------------------
    _fx_row(&r, "-O",             "-O",               RevShape::Value);
    _fx_row(&r, "-O0",            "-O0",              RevShape::Flag);
    _fx_row(&r, "-O4",            "-O3",              RevShape::Flag);   // clang: -O4 is -O3
    _fx_row(&r, "-g",             "-g",               RevShape::Flag);
    _fx_row(&r, "-g0",            "--g0",             RevShape::Flag);
    _fx_row(&r, "-gdwarf-2",      "-g --dwarf-version=2", RevShape::Flag);
    _fx_row(&r, "-gdwarf-3",      "-g --dwarf-version=3", RevShape::Flag);
    _fx_row(&r, "-gdwarf-4",      "-g --dwarf-version=4", RevShape::Flag);
    _fx_row(&r, "-gdwarf-5",      "-g --dwarf-version=5", RevShape::Flag);
    _fx_row(&r, "-fdebug-macro",  "--debug-macros",   RevShape::Flag);
    _fx_row(&r, "-gembed-source", "--embed-source",   RevShape::Flag);
    // -- language ---------------------------------------------------------------
    _fx_row(&r, "-std=",          "-std=",            RevShape::Value);  // split into c/cxx below
    _fx_row(&r, "-I",             "-I",               RevShape::ValueSep);  // kairo -I is clang's too, AND a .k search dir
    _fx_row(&r, "-D",             "--cxx-define=",    RevShape::Value);  // kairo -D is a Kairo macro
    _fx_row(&r, "-U",             "--cxx-undefine=",  RevShape::Value);
    _fx_row(&r, "-fexceptions",          "-fexceptions",          RevShape::Flag);
    _fx_row(&r, "-fno-exceptions",       "-fno-exceptions",       RevShape::Flag);
    _fx_row(&r, "-frtti",                "-frtti",                RevShape::Flag);
    _fx_row(&r, "-fno-rtti",             "-fno-rtti",             RevShape::Flag);
    // -- codegen toggles --------------------------------------------------------
    _fx_row(&r, "-fno-inline",           "-fno-inline",           RevShape::Flag);
    _fx_row(&r, "-funroll-loops",        "-funroll-loops",        RevShape::Flag);
    _fx_row(&r, "-fno-unroll-loops",     "-fno-unroll-loops",     RevShape::Flag);
    _fx_row(&r, "-ffunction-sections",   "-ffunction-sections",   RevShape::Flag);
    _fx_row(&r, "-fno-function-sections","-fno-function-sections",RevShape::Flag);
    _fx_row(&r, "-fdata-sections",       "-fdata-sections",       RevShape::Flag);
    _fx_row(&r, "-fno-data-sections",    "-fno-data-sections",    RevShape::Flag);
    _fx_row(&r, "-fomit-frame-pointer",  "-fomit-frame-pointer",  RevShape::Flag);
    _fx_row(&r, "-fno-omit-frame-pointer","-fno-omit-frame-pointer",RevShape::Flag);
    _fx_row(&r, "-ffast-math",           "-ffast-math",           RevShape::Flag);
    _fx_row(&r, "-fno-fast-math",        "-fno-fast-math",        RevShape::Flag);
    _fx_row(&r, "-fvectorize",           "-fvectorize",           RevShape::Flag);
    _fx_row(&r, "-fno-vectorize",        "-fno-vectorize",        RevShape::Flag);
    _fx_row(&r, "-fsplit-stack",         "-fsplit-stack",         RevShape::Flag);
    _fx_row(&r, "-fstack-protector",     "-fstack-protector",     RevShape::Flag);
    _fx_row(&r, "-fno-stack-protector",  "-fno-stack-protector",  RevShape::Flag);
    _fx_row(&r, "-fstack-clash-protection", "--stack-clash",      RevShape::Flag);
    _fx_row(&r, "-fPIC",                 "--pic-level=2",         RevShape::Flag);
    _fx_row(&r, "-fpic",                 "--pic-level=1",         RevShape::Flag);   // small-GOT PIC, not -fPIC
    _fx_row(&r, "-fno-PIC",              "-fno-pic",              RevShape::Flag);
    _fx_row(&r, "-fno-pic",              "-fno-pic",              RevShape::Flag);
    _fx_row(&r, "-fwrapv",               "--signed-wrap",         RevShape::Flag);
    _fx_row(&r, "-finstrument-functions","--instrument-functions",RevShape::Flag);
    _fx_row(&r, "-mno-implicit-float",   "--no-implicit-float",   RevShape::Flag);
    _fx_row(&r, "-msoft-float",          "-fsoft-float",          RevShape::Flag);
    _fx_row(&r, "-ffp-model=",           "--fp-model=",           RevShape::Value);
    _fx_row(&r, "-ffp-contract=",        "--fp-contract=",        RevShape::Value);
    _fx_row(&r, "-mthread-model",        "--thread-model=",       RevShape::Value);
    _fx_row(&r, "-fpass-plugin=",        "--pass-plugin=",        RevShape::Value);
    _fx_row(&r, "-ffile-prefix-map=",    "--remap-path-prefix=",  RevShape::Value);
    _fx_row(&r, "-fdebug-prefix-map=",   "--debug-prefix-map=",   RevShape::Value);
    _fx_row(&r, "-fcoverage-prefix-map=","--coverage-prefix-map=",RevShape::Value);
    _fx_row(&r, "-mllvm",                "--mllvm=",              RevShape::Value);
    // -- warnings -----------------------------------------------------------------
    _fx_row(&r, "-w",             "-w",               RevShape::Flag);
    _fx_row(&r, "-Wall",          "--Wall",           RevShape::Flag);   // kairo -W<x> enables a code
    _fx_row(&r, "-Wextra",        "--Wextra",         RevShape::Flag);
    _fx_row(&r, "-Wpedantic",     "--Wpedantic",      RevShape::Flag);
    _fx_row(&r, "-pedantic",      "--Wpedantic",      RevShape::Flag);
    _fx_row(&r, "-Werror",        "--Werror",         RevShape::Flag);
    // -- link -----------------------------------------------------------------------
    _fx_row(&r, "-L",             "-L",               RevShape::ValueSep);
    _fx_row(&r, "-l",             "-l",               RevShape::ValueSep);
    _fx_row(&r, "-shared",        "--shared",         RevShape::Flag);
    _fx_row(&r, "-s",             "--strip",          RevShape::Flag);
    _fx_row(&r, "-rdynamic",      "--ld-flags=--export-dynamic", RevShape::Flag);
    _fx_row(&r, "-nostdlib",      "--no-crt --no-default-libs",  RevShape::Flag);
    _fx_row(&r, "-nostartfiles",  "--no-crt",         RevShape::Flag);
    _fx_row(&r, "-nodefaultlibs", "--no-default-libs", RevShape::Flag);
    _fx_row(&r, "-static",        "--static",         RevShape::Flag);
    _fx_row(&r, "-Wl,",           "--ld-flags=",      RevShape::Commas);
    _fx_row(&r, "-Xlinker",       "--ld-flags=",      RevShape::Value);
    return r;
}

class FlagTranslator {

    // === forward: one function per concern ================================ //

    /// \brief the -ffast-math bundle as cc1 spells it (the driver has the
    ///        single word -ffast-math, and expands it to exactly this).
    static fn fast_math_cc1(complex_range: string) -> vec::<string> {
        var o = vec::<string>();
        o.push_back("-menable-no-infs");
        o.push_back("-menable-no-nans");
        o.push_back("-fapprox-func");
        o.push_back("-funsafe-math-optimizations");
        o.push_back("-fno-signed-zeros");
        o.push_back("-mreassociate");
        o.push_back("-freciprocal-math");
        o.push_back("-ffp-contract=fast");
        o.push_back("-ffast-math");
        o.push_back("-ffinite-math-only");
        o.push_back(f"-complex-range={complex_range}");
        return o;
    }

    /// \brief the floating-point semantics Kairo's own code has whatever the
    ///        target's C++ defaults are (IEEE 754, precise model): no
    ///        contraction, no fast-math, no errno from the math functions.
    ///
    /// \details For Kairo's compile line only, ahead of the user's own
    ///          codegen() words so an explicit --fp-contract / --fp-model /
    ///          -ffast-math still wins. cc1 spells two of the four by absence:
    ///          it has no -ffp-model (precise is its default) and no
    ///          -fno-math-errno (errno is off unless -fmath-errno is given,
    ///          and probe_filter never keeps that one). Contraction is the
    ///          one cc1 default the driver changes for C++ (-ffp-contract=on),
    ///          so it is pinned rather than left to the default.
    ///
    ///          C/C++ inputs never see these (they take the driver line), and
    ///          the ffi headers compiled in the same clang TU get their C++
    ///          defaults back through header_fp_pragmas: an imported header
    ///          keeps C++ semantics, and the same expression written in Kairo
    ///          keeps Kairo's.
    static fn kairo_fp_cc1() -> vec::<string> {
        var o = vec::<string>();
        o.push_back("-ffp-contract=off");
        return o;
    }

    /// \brief the pragma lines that open and close an ffi header region,
    ///        restoring for it the FP semantics clang++ would give C++ on
    ///        this target, where kairo_fp_cc1 changed them.
    ///
    /// \details Pragmas, not flags: the headers and Kairo's code are one
    ///          clang TU, and only the header text goes through the
    ///          preprocessor. clang records the FP state each body was
    ///          parsed under, and instantiates a template under its pattern's
    ///          state, so header code keeps it wherever Kairo uses it.
    ///
    ///          The values are the driver's C++ defaults (\p cxx_contract,
    ///          \p cxx_math_errno, read from the target probe before
    ///          probe_filter drops them), except where the user asked for
    ///          something: then the header follows the user's flag as a
    ///          C/C++ input would. \p user_cc1 is the user's codegen() words.
    ///
    ///          float_control(precise, on) is the only pragma that turns errno
    ///          back on; it also sets contraction on, so the contract pragma
    ///          comes after it. The push/pop pair puts Kairo's state back for
    ///          everything after the headers.
    static fn header_fp_pragmas(cxx_contract: string, cxx_math_errno: bool,
                                user_cc1: ref!(vec::<string>),
                                open: *vec::<string>, close: *vec::<string>) {
        var contract = cxx_contract;
        var fast = false;
        for w: string in user_cc1 {
            if w.starts_with("-ffp-contract=") { contract = string(w.raw() + 14, w.size() - 14); }
            if w == "-ffast-math" { fast = true; }
        }
        // `#pragma clang fp contract` takes on|off|fast; the honor-pragmas
        // variant only differs in how it treats pragmas like this one.
        if contract == "fast-honor-pragmas" { contract = "fast"; }
        if contract.empty() { contract = "off"; }

        open->push_back("#pragma float_control(push)");
        if cxx_math_errno && (!fast) { open->push_back("#pragma float_control(precise, on)"); }
        open->push_back(f"#pragma clang fp contract({contract})");
        close->push_back("#pragma float_control(pop)");
    }

    /// \brief the code-generation flags: target ISA tuning, -f[no-] toggles,
    ///        floating-point model, hardening and code model, the C++
    ///        language switches, the runtime model, reproducible-build maps,
    ///        pass plugins and -mllvm words.
    ///
    /// \details Only what the user asked for is written: anything cc1 (or
    ///          the driver) does by default is left out, so a plain build's
    ///          line -- and every header-set PCH keyed on it -- does not
    ///          change. That is also the "kairo flags override only when
    ///          given" rule C/C++ inputs follow under the driver spelling.
    ///
    ///          Each spelling was verified against clang -### / clang -cc1
    ///          -help; a flag with no direct spelling is not here.
    ///
    /// \param missing_plugins receives each --pass-plugin path that is not a
    ///        file; the caller reports them (this file reports nothing).
    static fn codegen(inv: ref!(CompilerInvocation), triple: string, sp: ClangSpelling,
                      missing_plugins: *vec::<string>) -> vec::<string> {
        var o   = vec::<string>();
        var cgo = inv.codegen;
        var tgt = inv.target;
        var lg  = inv.lang;
        var cc1 = sp == ClangSpelling::CC1;

        // -- target ISA ----------------------------------------------------
        // (--march rides the driver probe; --mcpu is in target(), which the
        // caller places so a cpu given there wins over a march's.)
        if !tgt.mtune.empty() {
            if cc1 { _fx_push2(&o, "-tune-cpu", tgt.mtune); } else { _fx_push(&o, f"-mtune={tgt.mtune}"); }
        }
        if !tgt.mabi.empty() {
            if cc1 { _fx_push2(&o, "-target-abi", tgt.mabi); } else { _fx_push(&o, f"-mabi={tgt.mabi}"); }
        }
        for ft: string in tgt.feature_list() {
            // The driver has one -m<feature> per feature, not a generic one.
            if cc1 { _fx_push2(&o, "-target-feature", ft); }
            else   { _fx_xclang(&o, "-target-feature"); _fx_xclang(&o, ft); }
        }

        // -- optimization toggles ------------------------------------------
        if cgo.f_inline == 0          { _fx_push(&o, "-fno-inline"); }
        if cgo.f_unroll_loops == 1    { _fx_push(&o, "-funroll-loops"); }
        if cgo.f_unroll_loops == 0    { _fx_push(&o, "-fno-unroll-loops"); }
        if cgo.f_merge_functions == 1 {
            // cc1-only: the driver has no spelling for it.
            if cc1 { _fx_push(&o, "-fmerge-functions"); } else { _fx_xclang(&o, "-fmerge-functions"); }
        }
        if cgo.f_function_sections == 1 { _fx_push(&o, "-ffunction-sections"); }
        if cgo.f_data_sections == 1     { _fx_push(&o, "-fdata-sections"); }
        if !cc1 {
            // cc1 has no "off" for these; the driver does, and a C/C++ input
            // given -fno-... must not keep clang's default.
            if cgo.f_function_sections == 0 { _fx_push(&o, "-fno-function-sections"); }
            if cgo.f_data_sections == 0     { _fx_push(&o, "-fno-data-sections"); }
        }
        // cc1 keeps no frame pointer unless told (the driver adds =all on
        // most Linux targets), so both directions are spelled out.
        if cgo.f_omit_frame_pointer == 1 {
            if cc1 { _fx_push(&o, "-mframe-pointer=none"); } else { _fx_push(&o, "-fomit-frame-pointer"); }
        }
        if cgo.f_omit_frame_pointer == 0 {
            if cc1 { _fx_push(&o, "-mframe-pointer=all"); } else { _fx_push(&o, "-fno-omit-frame-pointer"); }
        }

        // -- floating point ------------------------------------------------
        if cgo.f_fast_math == 1 {
            if cc1 { for t: string in FlagTranslator::fast_math_cc1("basic") { _fx_push(&o, t); } }
            else   { _fx_push(&o, "-ffast-math"); }
        }
        if (!cc1) && (cgo.f_fast_math == 0) { _fx_push(&o, "-fno-fast-math"); }
        if cgo.fp_model == "fast" {
            if cc1 { for t: string in FlagTranslator::fast_math_cc1("promoted") { _fx_push(&o, t); } }
            else   { _fx_push(&o, "-ffp-model=fast"); }
        } else if cgo.fp_model == "strict" {
            if cc1 {
                _fx_push(&o, "-ffp-contract=off");
                _fx_push(&o, "-frounding-math");
                _fx_push(&o, "-ffp-exception-behavior=strict");
                _fx_push(&o, "-complex-range=full");
            } else {
                _fx_push(&o, "-ffp-model=strict");
            }
        }
        if cgo.fp_contract_set { _fx_push(&o, f"-ffp-contract={cgo.fp_contract}"); }
        if cgo.signed_wrap     { _fx_push(&o, "-fwrapv"); }
        if cgo.f_soft_float == 1 {
            if cc1 { _fx_push(&o, "-msoft-float"); _fx_push2(&o, "-mfloat-abi", "soft"); }
            // -msoft-float, not -mfloat-abi=soft: the latter is ARM's, unused
            // on x86 (hard float would stay) and an error on SystemZ.
            else   { _fx_push(&o, "-msoft-float"); }
        }
        if cgo.no_implicit_float {
            if cc1 { _fx_push(&o, "-no-implicit-float"); } else { _fx_push(&o, "-mno-implicit-float"); }
        }

        // -- hardening / code model ----------------------------------------
        if cgo.f_stack_protector == 1 {
            if cc1 { _fx_push2(&o, "-stack-protector", "1"); } else { _fx_push(&o, "-fstack-protector"); }
        }
        if (!cc1) && (cgo.f_stack_protector == 0) { _fx_push(&o, "-fno-stack-protector"); }
        if cgo.stack_clash        { _fx_push(&o, "-fstack-clash-protection"); }
        if cgo.f_split_stack == 1 { _fx_push(&o, "-fsplit-stack"); }
        // --pic-level is the explicit spelling and wins; -f[no-]pic only
        // speaks when it was not given (target() spells --pic-level).
        if tgt.pic_level == 0 {
            if cgo.f_pic == 1 {
                if cc1 { _fx_push2(&o, "-mrelocation-model", "pic"); _fx_push2(&o, "-pic-level", "2"); }
                else   { _fx_push(&o, "-fPIC"); }
            } else if cgo.f_pic == 0 {
                if cc1 { _fx_push2(&o, "-mrelocation-model", "static"); }
                else   { _fx_push(&o, "-fno-pic"); }
            }
        }
        if cgo.kernel_mode {
            // Same set the driver makes of -mkernel, minus the hosted-library
            // bits (-fapple-kext, -fno-builtin, -ffreestanding) that would
            // break Kairo's own lowered C++. SSE is only taken away on x86,
            // where the kernel cannot save FP state; elsewhere there is no
            // single feature name for it.
            var tri = llvm::Triple(llvm::Triple::normalize(sref(triple)));
            if cc1 {
                _fx_push(&o, "-mcmodel=kernel");
                _fx_push2(&o, "-mrelocation-model", "static");
                _fx_push(&o, "-disable-red-zone");
                _fx_push(&o, "-no-implicit-float");
                if tri.isX86() { _fx_push2(&o, "-target-feature", "-sse"); }
            } else {
                _fx_push(&o, "-mcmodel=kernel");
                _fx_push(&o, "-fno-pic");
                _fx_push(&o, "-mno-red-zone");
                _fx_push(&o, "-mno-implicit-float");
                if tri.isX86() { _fx_push(&o, "-mno-sse"); }
            }
        }

        // -- language-level C++ switches (Config::Language) -----------------
        // Exceptions are ON by default on a hosted target: a Kairo TU's C++
        // includes C++ headers that throw, and a C++ exception must reach
        // a Kairo frame to be stopped there (noexcept, the default) or
        // passed on (@unwind / -funwind). A freestanding target (no OS in
        // the triple, --freestanding, kernel mode) keeps them off unless
        // -fexceptions asks: it has no unwinder, and on ARM EHABI every
        // function would reference a personality routine. A bare cc1 line
        // has them off, so it needs both switches when they are on; RTTI
        // is on by default, so only -fno-rtti does. The driver turns
        // exceptions on for C++ by itself, so it needs both directions.
        var hosted = !(lg.freestanding || cgo.kernel_mode);
        if hosted && (triple.size() > 0) {
            var etri = llvm::Triple(llvm::Triple::normalize(sref(triple)));
            if etri.getOS() == llvm::Triple::UnknownOS { hosted = false; }
        }
        if lg.cxx_exceptions(hosted) {
            if cc1 { _fx_push(&o, "-fcxx-exceptions"); _fx_push(&o, "-fexceptions"); }
            else if lg.exceptions == 1 { _fx_push(&o, "-fexceptions"); }
        }
        if (!cc1) && (lg.exceptions == 0) { _fx_push(&o, "-fno-exceptions"); }
        if lg.rtti == 0 { _fx_push(&o, "-fno-rtti"); }

        // -- runtime model -------------------------------------------------
        if cgo.thread_model != "posix" { _fx_push2(&o, "-mthread-model", cgo.thread_model); }
        if cgo.unwind_tables_set {
            if cc1 {
                if cgo.unwind_tables == "none"       { _fx_push(&o, "-funwind-tables=0"); }
                else if cgo.unwind_tables == "sync"  { _fx_push(&o, "-funwind-tables=1"); }
                else if cgo.unwind_tables == "async" { _fx_push(&o, "-funwind-tables=2"); }
            } else {
                if cgo.unwind_tables == "none" {
                    _fx_push(&o, "-fno-unwind-tables");
                    _fx_push(&o, "-fno-asynchronous-unwind-tables");
                } else if cgo.unwind_tables == "sync" {
                    _fx_push(&o, "-funwind-tables");
                    _fx_push(&o, "-fno-asynchronous-unwind-tables");
                } else if cgo.unwind_tables == "async" {
                    _fx_push(&o, "-fasynchronous-unwind-tables");
                }
            }
        }
        if cgo.instrument_functions { _fx_push(&o, "-finstrument-functions"); }

        // Coverage and PGO (-fcoverage, -fprofile-generate, --profile-use) are
        // deliberately NOT forwarded: the instrumented objects need
        // libclang_rt.profile on the link line, which no bundled sysroot
        // ships, so a wiring would only move the failure to the linker. They
        // stay marked unimplemented in the registry.

        // -- reproducible builds ---------------------------------------------
        // --remap-path-prefix is clang's -ffile-prefix-map, which cc1 only
        // knows as its three halves.
        for m: string in cgo.remap_path_prefix {
            if cc1 {
                _fx_push(&o, f"-fdebug-prefix-map={m}");
                _fx_push(&o, f"-fmacro-prefix-map={m}");
                _fx_push(&o, f"-fcoverage-prefix-map={m}");
            } else {
                _fx_push(&o, f"-ffile-prefix-map={m}");
            }
        }
        for m: string in cgo.debug_prefix_map    { _fx_push(&o, f"-fdebug-prefix-map={m}"); }
        for m: string in cgo.coverage_prefix_map { _fx_push(&o, f"-fcoverage-prefix-map={m}"); }
        // Only __DATE__/__TIME__/__TIMESTAMP__ in C and C++ sources read it:
        // Kairo objects carry no other timestamp. The driver has no flag
        // for it (it reads SOURCE_DATE_EPOCH from the environment).
        var epoch = "";
        if !cgo.source_date_epoch.empty() { epoch = cgo.source_date_epoch; }
        else if cgo.no_timestamps         { epoch = "0"; }
        if !epoch.empty() {
            if cc1 { _fx_push2(&o, "-source-date-epoch", epoch); }
            else   { _fx_xclang(&o, "-source-date-epoch"); _fx_xclang(&o, epoch); }
        }

        // -- LLVM pass control -----------------------------------------------
        for pl: string in cgo.pass_plugins {
            if !llvm::sys::fs::is_regular_file(llvm::Twine(sref(pl))) {
                missing_plugins->push_back(pl);
            } else {
                _fx_push(&o, f"-fpass-plugin={pl}");
            }
        }

        // -- -mllvm (applied once per process by ClangBackend::_apply_llvm_args)
        if cgo.hot_cold_split          { _fx_push2(&o, "-mllvm", "-hot-cold-split=true"); }
        if cgo.f_trap_unreachable == 1 { _fx_push2(&o, "-mllvm", "-trap-unreachable"); }
        // Both thresholds differ per level in LLVM itself, so a default value
        // must not be forwarded: only what the user set.
        if cgo.inline_cost_set {
            var thr: i32 = static_cast::<i32>(cgo.inline_cost);
            _fx_push2(&o, "-mllvm", f"-inline-threshold={thr}");
        }
        if cgo.max_unroll_count > 0 {
            _fx_push2(&o, "-mllvm", f"-unroll-count={cgo.max_unroll_count}");
        }
        for w: string in cgo.mllvm_flags { _fx_push2(&o, "-mllvm", w); }
        return o;
    }

    /// \brief --mcpu and --pic-level. Separate from codegen() because the
    ///        backend places them first: cc1 takes the last -target-cpu, and
    ///        --mcpu must beat the cpu the driver probe derived from --march.
    static fn target(tgt: ref!(TargetOptions), sp: ClangSpelling) -> vec::<string> {
        var o = vec::<string>();
        var cc1 = sp == ClangSpelling::CC1;
        if !tgt.mcpu.empty() {
            // Not the driver's -mcpu=: x86 rejects it (its CPU is -march=),
            // and elsewhere it also turns features on. kairo's --mcpu is the
            // CPU alone, over the features the target or --march implies,
            // and C/C++ inputs get exactly that.
            if cc1 { _fx_push2(&o, "-target-cpu", tgt.mcpu); }
            else   { _fx_xclang(&o, "-target-cpu"); _fx_xclang(&o, tgt.mcpu); }
        }
        if tgt.pic_level > 0 {
            if cc1 {
                _fx_push2(&o, "-mrelocation-model", "pic");
                _fx_push2(&o, "-pic-level", f"{tgt.pic_level}");
            } else {
                _fx_push(&o, ("-fpic") if (tgt.pic_level == 1) else ("-fPIC"));
            }
        }
        return o;
    }

    /// \brief --march, which only the DRIVER spells (cc1 has no -march:
    ///        the driver turns it into -target-cpu plus one -target-feature
    ///        per implied extension, which is right only per architecture).
    ///        For kairo's own TUs it rides the target probe.
    static fn march_driver(tgt: ref!(TargetOptions)) -> vec::<string> {
        var o = vec::<string>();
        if !tgt.march.empty() { _fx_push(&o, f"-march={tgt.march}"); }
        return o;
    }

    /// \brief the language standard for a C/C++ input of kind \p lang
    ///        (clang's -x name). cc1 always gets one (it has no default
    ///        worth having for kairo's interop). Through the driver a C++
    ///        input always gets --cxx-std too: clang's own default
    ///        (gnu++17) predates the C++20 an interface needs, and a .cc
    ///        and the Kairo TUs it links with agree on one standard. A C
    ///        input gets --c-std only when the user named one, so it
    ///        compiles under clang's default otherwise. IR, OpenCL and the
    ///        rest take none.
    static fn language_std(tgt: ref!(TargetOptions), lang: string, sp: ClangSpelling) -> vec::<string> {
        var o = vec::<string>();
        var cc1 = sp == ClangSpelling::CC1;
        // Headers too: a PCH built under another standard than the TUs that
        // include it does not load.
        var c_like   = (lang == "c") || (lang == "cpp-output") || (lang == "objective-c") || (lang == "objective-c-cpp-output")
                    || (lang == "c-header") || (lang == "objective-c-header");
        var cxx_like = (lang == "c++") || (lang == "c++-cpp-output") || (lang == "objective-c++") || (lang == "objective-c++-cpp-output")
                    || (lang == "c++-header") || (lang == "objective-c++-header");
        if c_like && (cc1 || tgt.c_std_set) { _fx_push(&o, f"-std={tgt.c_std}"); }
        if cxx_like { _fx_push(&o, f"-std={tgt.cxx_std}"); }
        return o;
    }

    /// \brief header directories the user names for clang (-I, which is
    ///        also a Kairo search dir, then --ffi-include and --cxx-include)
    ///        and user macros for clang (--cxx-define / --cxx-undefine).
    ///        Identical in both spellings.
    static fn preprocessor(inv: ref!(CompilerInvocation)) -> vec::<string> {
        var o = vec::<string>();
        for d: string in inv.clang_include_dirs() { _fx_push2(&o, "-I", d); }
        for d: string in inv.cxx_defines   { _fx_push(&o, f"-D{d}"); }
        for d: string in inv.cxx_undefines { _fx_push(&o, f"-U{d}"); }
        return o;
    }

    /// \brief the optimization level and the vectorizers.
    ///
    /// \details cc1: the level as -O<n> (cc1's own parsing then sets
    ///          everything that hangs off it in step), plus both vectorizers
    ///          at every level above -O0 unless -fno-vectorize -- cc1 leaves
    ///          them off and the driver is what normally asks, and Kairo asks
    ///          at every level, Oz included, unlike clang's
    ///          shouldEnableVectorizerAtOLevel.
    ///
    ///          Driver: the level, and the vectorizers only when the user
    ///          said so; otherwise the driver's own per-level rule applies to
    ///          C/C++ inputs, as under clang.
    ///
    /// \param opt_size 0 none, 1 -Os, 2 -Oz.
    /// \param f_vectorize -1 unset, 0 -fno-vectorize, 1 -fvectorize.
    static fn optimization(opt_level: i32, opt_size: i32, f_vectorize: i32, sp: ClangSpelling) -> vec::<string> {
        var o = vec::<string>();
        if opt_size == 2      { _fx_push(&o, "-Oz"); }
        else if opt_size == 1 { _fx_push(&o, "-Os"); }
        else                  { _fx_push(&o, f"-O{opt_level}"); }
        if sp == ClangSpelling::CC1 {
            if (f_vectorize != 0) && ((opt_level > 0) || (opt_size > 0)) {
                _fx_push(&o, "-vectorize-loops");
                _fx_push(&o, "-vectorize-slp");
            }
        } else {
            if f_vectorize == 1 { _fx_push(&o, "-fvectorize"); _fx_push(&o, "-fslp-vectorize"); }
            if f_vectorize == 0 { _fx_push(&o, "-fno-vectorize"); _fx_push(&o, "-fno-slp-vectorize"); }
        }
        return o;
    }

    /// \brief -g and its modifiers, as DRIVER words. cc1 never gets these
    ///        spelled by kairo: the driver picks CodeView or DWARF, the
    ///        debugger tuning and the info kind per target, and the probe
    ///        (probe_filter) carries its choice into cc1.
    static fn debug_driver(debug_info: bool, dwarf_version: i32, macros: bool, embed: bool) -> vec::<string> {
        var o = vec::<string>();
        if !debug_info { return o; }
        _fx_push(&o, "-g");
        if dwarf_version > 0 { _fx_push(&o, f"-gdwarf-{dwarf_version}"); }
        if macros            { _fx_push(&o, "-fdebug-macro"); }
        if embed             { _fx_push(&o, "-gembed-source"); }
        return o;
    }

    /// \brief whether this build emits debug info: -g0 wins over -g
    ///        wherever it sits.
    static fn debug_on(cgo: ref!(CodeGenOptions)) -> bool {
        return (cgo.debug_info) && (!cgo.no_debug_info);
    }

    /// \brief the DWARF version to ask for, 0 for "the target's default".
    ///        --dwarf-version always has a value (default 5), so it cannot say
    ///        whether DWARF was asked for; on MSVC it is left out and the
    ///        driver emits CodeView, which is what link.exe-style PDBs need.
    static fn dwarf_for(cgo: ref!(CodeGenOptions), triple: string) -> i32 {
        var tr = llvm::Triple(llvm::Triple::normalize(sref(triple)));
        if tr.isWindowsMSVCEnvironment() { return 0; }
        return cgo.dwarf_version;
    }

    /// \brief the whole clang DRIVER line for one C/C++ input of language
    ///        \p lang (clang's -x name), minus the roots (the backend's
    ///        sysroot_words), the action, the input and the output.
    ///
    /// \details The "clang's defaults, kairo flags override only when given"
    ///          rule: every word here is something the user asked for, except
    ///          --target, which is always the build's effective triple. The
    ///          driver must never pick its own: it would choose the host's
    ///          (glibc, msvc), and the C/C++ objects would not match the
    ///          Kairo objects in the same link. --cxx-flags words go last, so
    ///          they win.
    static fn to_driver(inv: ref!(CompilerInvocation), triple: string, lang: string,
                        missing_plugins: *vec::<string>) -> vec::<string> {
        var o   = vec::<string>();
        var cgo = inv.codegen;
        var tgt = inv.target;
        _fx_push(&o, f"--target={triple}");
        for a: string in FlagTranslator::march_driver(tgt) { _fx_push(&o, a); }
        for a: string in FlagTranslator::target(tgt, ClangSpelling::Driver) { _fx_push(&o, a); }
        for a: string in FlagTranslator::language_std(tgt, lang, ClangSpelling::Driver) { _fx_push(&o, a); }
        for a: string in FlagTranslator::codegen(inv, triple, ClangSpelling::Driver, missing_plugins) { _fx_push(&o, a); }
        var osz: i32 = 0;
        if cgo.opt_size_z    { osz = 2; }
        else if cgo.opt_size { osz = 1; }
        for a: string in FlagTranslator::optimization(cgo.opt_level, osz, cgo.f_vectorize, ClangSpelling::Driver) { _fx_push(&o, a); }
        for a: string in FlagTranslator::debug_driver(FlagTranslator::debug_on(cgo), FlagTranslator::dwarf_for(cgo, triple),
                                                      cgo.debug_macros, cgo.embed_source) {
            _fx_push(&o, a);
        }
        for a: string in FlagTranslator::warnings(inv.diag, ClangSpelling::Driver) { _fx_push(&o, a); }
        for a: string in FlagTranslator::preprocessor(inv) { _fx_push(&o, a); }
        for a: string in cgo.cxx_flags { _fx_push(&o, a); }
        return o;
    }

    /// \brief the diagnostic policy for clang-sourced diagnostics: the bulk
    ///        switches by their clang names, and each C-code the user
    ///        allowed, enabled, denied or forbade, as its clang warning group.
    ///        cc1 and the driver spell these the same.
    ///          allow  -> -Wno-<grp>   deny/forbid -> -Werror=<grp>
    ///          warn   -> -W<grp>
    ///        Native (non-C) codes are skipped; the emit layer governs them.
    static fn warnings(d: ref!(DiagnosticOptions), sp: ClangSpelling) -> vec::<string> {
        var out = vec::<string>();
        if d.suppress_warnings { out.push_back("-w"); }
        if d.Wall      { out.push_back("-Wall");      }
        if d.Wextra    { out.push_back("-Wextra");    }
        if d.Wpedantic { out.push_back("-Wpedantic"); }
        // --Werror makes a C/C++ input's warnings errors, as clang's -Werror
        // would. Not on kairo's own line: clang's warnings about Kairo's
        // lowered C++ are not the user's to fix, and that line never had it.
        if (sp == ClangSpelling::Driver) && d.warnings_as_errors { out.push_back("-Werror"); }
        // Kairo's own lowered C++ needs _BitInt wider than clang's default
        // cap; a C/C++ input keeps clang's.
        if sp == ClangSpelling::CC1 { out.push_back("-fexperimental-max-bitint-width=512"); }
        for c: string in d.allow_list {
            if _fx_is_clang_code(c) {
                var g = clang_diag_group(_fx_code_number(c));
                if !g.empty() { out.push_back(f"-Wno-{g}"); }
            }
        }
        for c: string in d.warn_list {
            if _fx_is_clang_code(c) {
                var g = clang_diag_group(_fx_code_number(c));
                if !g.empty() { out.push_back(f"-W{g}"); }
            }
        }
        for c: string in d.deny_list {
            if _fx_is_clang_code(c) {
                var g = clang_diag_group(_fx_code_number(c));
                if !g.empty() { out.push_back(f"-Werror={g}"); }
            }
        }
        for c: string in d.forbid_list {
            if _fx_is_clang_code(c) {
                var g = clang_diag_group(_fx_code_number(c));
                if !g.empty() { out.push_back(f"-Werror={g}"); }
            }
        }
        return out;
    }

    // === the target probe ================================================== //

    /// \brief the cc1 words the driver probe line is filtered down to: the
    ///        ones that decide the TARGET (CPU, features, ABI, float ABI,
    ///        char signedness, exception and unwind model, MSVC language
    ///        mode, debug format), never the rest of the driver's choices.
    ///
    /// \details The probe runs clang's driver once per triple because cc1 has
    ///          no defaults of its own for any of these, and a table here
    ///          would drift from clang. See ClangBackend::_driver_target_args
    ///          for why each group is taken.
    static fn probe_filter(cc1: ref!(libcxx::vector::<libcxx::string>)) -> vec::<string> {
        var out = vec::<string>();
        // Flags taking their value as the next word.
        var paired = vec::<string>();
        paired.push_back("-target-cpu");
        paired.push_back("-tune-cpu");
        paired.push_back("-target-feature");
        paired.push_back("-target-abi");
        paired.push_back("-mfloat-abi");
        var exact = vec::<string>();
        exact.push_back("-msoft-float");
        exact.push_back("-fno-signed-char");
        exact.push_back("-fno-use-cxa-atexit");
        exact.push_back("-fno-use-init-array");
        exact.push_back("-fms-extensions");
        exact.push_back("-fms-compatibility");
        exact.push_back("-fms-volatile");
        exact.push_back("-fdelayed-template-parsing");
        exact.push_back("-gcodeview");
        exact.push_back("-debug-info-macro");
        exact.push_back("-gembed-source");
        // Flags with their value joined by `=`.
        var joined = vec::<string>();
        joined.push_back("-exception-model=");
        joined.push_back("-funwind-tables=");
        joined.push_back("-fms-compatibility-version=");
        joined.push_back("-fgnuc-version=");
        joined.push_back("-debug-info-kind=");
        joined.push_back("-dwarf-version=");
        joined.push_back("-debugger-tuning=");
        joined.push_back("-fdebug-compilation-dir=");

        for var i: usize = 0; i < cc1.size(); ++i {
            var a = string(cc1[i]);
            var took = false;
            for p: string in paired {
                if (a == p) && (i + 1 < cc1.size()) {
                    out.push_back(a);
                    out.push_back(string(cc1[i + 1]));
                    i += 1;
                    took = true;
                    break;
                }
            }
            if took { continue; }
            for p: string in exact {
                if a == p { out.push_back(a); took = true; break; }
            }
            if took { continue; }
            for p: string in joined {
                if a.starts_with(p) { out.push_back(a); break; }
            }
        }
        return out;
    }

    // === reverse: a clang driver command line as kairo words =============== //

    /// \brief splits a clang driver command line into kairo CLI words and the
    ///        clang words kairo has no flag for.
    ///
    /// \details Tokenized by clang's own option table, so every clang
    ///          spelling of an option (-Ifoo, -I foo, -I=foo, --target x,
    ///          --target=x) is one Arg; matched on the option's prefixed
    ///          name against _fx_reverse_rows. Positional inputs pass
    ///          through as kairo words in place, so -x keeps applying to the
    ///          inputs after it. The kairo words are meant for the ordinary
    ///          kairo parser (Command); the clang-only words reach C/C++
    ///          compiles verbatim and nothing else.
    ///
    /// \param argv the clang command line WITHOUT argv[0].
    /// \return false when clang's table reports a missing value; \p error
    ///         says which.
    static fn from_driver(argv: ref!(vec::<string>),
                          kairo_out: *vec::<string>,
                          clang_only: *vec::<string>,
                          error: *string) -> bool {
        var rows = _fx_reverse_rows();
        var cargv: libcxx::vector::<std::ConstPtr::<std::Legacy::char>>;
        for var i: usize = 0; i < argv.size(); ++i { cargv.push_back(argv[i].c_str()); }

        var missing_idx: u32 = 0;
        var missing_cnt: u32 = 0;
        var table = &(clang::getDriverOptTable());
        // The plain driver's options only: without the mask, clang-cl's
        // spellings (/O, which also answers to -O) match too.
        var vis   = llvm::opt::Visibility(clang::options::ClangOption);
        var args  = table->ParseArgs(cargv, missing_idx, missing_cnt, vis);
        if missing_cnt > 0 {
            var w = argv[static_cast::<usize>(missing_idx)];
            (*error) = f"clang option '{w}\x27 is missing its value";
            return false;
        }

        var it  = args.begin();
        var end = args.end();
        while it != end {
            var a     = *it;
            var opt   = a->getOption();
            var psr   = opt.getPrefixedName();
            var pname = string(psr.data(), psr.size());
            var nval  = a->getNumValues();

            if opt.getKind() == llvm::opt::Option::InputClass {
                kairo_out->push_back(string(a->getValue(0)));
                ++it;
                continue;
            }

            // -std= is the one row that splits on its value: kairo keeps a C
            // and a C++ standard apart, clang has one flag for both.
            // A standard kairo has no choice for (c++17, c18, iso9899:1999)
            // stays clang's: the C/C++ inputs still get it, kairo's own code
            // keeps its own.
            if pname == "-std=" {
                var v = string(a->getValue(0));
                var is_cxx = !(string::npos == v.view().find(r"++"));
                if is_cxx && _fx_known_cxx_std(v)        { kairo_out->push_back(f"--cxx-std={v}"); }
                else if (!is_cxx) && _fx_known_c_std(v)  { kairo_out->push_back(f"--c-std={v}"); }
                else                                     { clang_only->push_back(f"-std={v}"); }
                ++it;
                continue;
            }

            // -W<x> is one clang option for every warning name; only the
            // bulk switches kairo spells (--Wall ...) are kairo's, the rest
            // name clang warning groups and stay clang's.
            if (pname == "-W") && (nval > 0) {
                var w = string(a->getValue(0));
                if (w == "all") || (w == "extra") || (w == "pedantic") || (w == "error") {
                    kairo_out->push_back(f"--W{w}");
                    ++it;
                    continue;
                }
            }

            var hit = false;
            for row: RevRow in rows {
                if row.clang != pname { continue; }
                hit = true;
                if row.shape == RevShape::Flag {
                    // A row may stand for more than one kairo word (-gdwarf-4).
                    var cur = "";
                    for var k: usize = 0; k < row.kairo.size(); ++k {
                        if row.kairo[k] == ' ' { kairo_out->push_back(cur); cur = ""; }
                        else { cur += row.kairo[k]; }
                    }
                    if !cur.empty() { kairo_out->push_back(cur); }
                } else if row.shape == RevShape::Commas {
                    for var k: u32 = 0; k < nval; ++k {
                        kairo_out->push_back(row.kairo + string(a->getValue(k)));
                    }
                } else {
                    var v = "";
                    if nval > 0 { v = string(a->getValue(0)); }
                    if row.shape == RevShape::ValueSep {
                        kairo_out->push_back(row.kairo);
                        kairo_out->push_back(v);
                    } else {
                        kairo_out->push_back(row.kairo + v);
                    }
                }
                break;
            }
            if !hit {
                // Rendered back exactly as clang would hand it to itself.
                var rendered: llvm::opt::ArgStringList;
                a->render(args, rendered);
                for var k: usize = 0; k < rendered.size(); ++k {
                    clang_only->push_back(string(rendered[k]));
                }
            }
            ++it;
        }
        return true;
    }
}
