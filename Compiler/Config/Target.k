/// --- The Kairo Project ------------------------------ Config/Target.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Command::ParsedArgs::*;

///
/// \class TargetOptions
///
/// \brief Target triple, ISA selection, and C++ interop ABI settings.
///
class TargetOptions {
    pub var triple:    string = ""; ///< --target triple
    pub var host:      string = ""; ///< --host triple
    pub var march:     string = ""; ///< -march / --march
    pub var mcpu:      string = ""; ///< -mcpu  / --mcpu
    pub var mtune:     string = ""; ///< --mtune
    pub var mabi:      string = ""; ///< --mabi
    pub var mfeatures: string = ""; ///< --mfeatures (e.g. +avx2,-sse4.1); read it through feature_list()
    pub var cxx_std:   string = "c++23";
    pub var c_std:     string = "c17";   ///< --c-std: C inputs (and ObjC)
    /// Given on the command line. A C input under clang's driver gets
    /// clang's own default standard unless the user named one; a C++ input
    /// always gets cxx_std, the same standard kairo's own TUs compile under.
    pub var cxx_std_set: bool = false;
    pub var c_std_set:   bool = false;
    pub var cxx_abi:   string = "itanium";
    pub var sysroot:   string = "";
    pub var resource_dir: string = "";  ///< clang resource dir: its include/ holds the builtin headers (stddef.h).
    pub var pic_level: i32    = 0;
    pub var m32:       bool   = false;
    pub var m64:       bool   = false;

    /// \brief Pointer width in bits. DERIVED, not parsed: a width that
    ///        disagrees with the triple is not a target, so there is no flag.
    ///
    /// \details Filled by CompilerInstance::_apply_invocation from
    ///          llvm::Triple::getArchPointerBitWidth() on the effective
    ///          triple, after -m32/-m64 have been applied via the Triple's
    ///          32/64-bit arch variants -- the same rewrite clang performs. A
    ///          value of 0 means it was never filled (hand-built invocation
    ///          that skipped _apply_invocation); consumers treat 0 as 64.
    ///          Config/ stays LLVM-free by having the driver write this rather
    ///          than computing it here.
    pub var pointer_width: usize = 0;

    /// \brief Whether int64_t is `long` rather than `long long`. Not the
    ///        same question as LP64: Darwin and OpenBSD are LP64 and still
    ///        spell it `long long`, as do LLP64 (Windows) and every 32-bit
    ///        target. DERIVED from clang::TargetInfo for the same Triple as
    ///        pointer_width.
    ///
    /// \details true by default to agree with the unfilled pointer_width's
    ///          "treat 0 as 64": a hand-built invocation is a 64-bit host
    ///          build, and a default that disagreed with its own width would
    ///          spell i64 as a type of the wrong size.
    pub var int64_is_long: bool = true;

    // --- Derived target facts -------------------------------------------------
    //
    // Everything below is DERIVED from the effective triple, exactly like
    // pointer_width above and for the same reason: a fact that disagrees with
    // the triple is not a target, so none of it is parsed and none of it has a
    // flag. `CompilerInstance::_apply_invocation` writes all of it in one
    // place, off one `llvm::Triple`, after -m32/-m64 have been applied -- so
    // every consumer sees ONE consistent view of one target, and Config/ still
    // never sees LLVM.
    //
    // `resolved` says whether the driver got here at all. A hand-built
    // invocation that skipped _apply_invocation leaves it false, and a
    // consumer that must not guess (portability checks) can say so instead of
    // silently treating an empty arch as "not x86".

    /// True once the driver has filled the block below.
    pub var resolved: bool = false;

    /// The normalized triple actually being compiled for: --target if given,
    /// else the host triple, after the -m32/-m64 arch-variant rewrite. This,
    /// not `triple`, is what a diagnostic should name.
    pub var effective_triple: string = "";

    pub var arch_name:     string = "";  ///< first component, e.g. "x86_64".
    pub var vendor_name:   string = "";  ///< second component, e.g. "pc".
    pub var os_name:       string = "";  ///< third component, e.g. "linux".
    pub var env_name:      string = "";  ///< fourth component, e.g. "gnu"; "" if none.
    pub var object_format: string = "";  ///< "ELF" / "COFF" / "Mach-O" / ...

    pub var is_little_endian: bool = true;

    /// x86 or x86_64, i.e. the CPU has an x87 stack. NOT the f80 gate -- that
    /// is long_double_is_x87 below, because an x86 ABI may still not expose
    /// x87 as `long double`. Kept so the f80 diagnostic can say which of the
    /// two it hit. A resolved bool rather than a string compare at each use
    /// so a new spelling of an x86 triple cannot quietly change the answer at
    /// one call site and not another.
    pub var is_x86: bool = false;

    /// The triple names an OS (llvm::Triple's OS is not UnknownOS): a hosted
    /// target, which has an unwinder, so C++ exceptions default on
    /// (LangOptions::cxx_exceptions). A bare-metal triple has none.
    pub var has_os: bool = true;

    // --- C++ `long double`, read from clang::TargetInfo ----------------------
    //
    // `f80` lowers to C++ `long double`, so whether f80 exists is an ABI fact,
    // not an ISA fact: x86_64-windows-msvc has x87 hardware and a binary64
    // `long double`, x86_64-linux-android has a binary128 one. is_x86 above
    // answers "does the CPU have x87"; these answer "is the `long double` we
    // emit x87", which is the question TypeResolution actually has to ask.
    // Taken from clang rather than a hand-written triple list because clang
    // already knows every case a list gets wrong.

    /// The target ABI's `long double` IS x87 extended. The f80 gate.
    pub var long_double_is_x87: bool = false;

    /// What `long double` is here, for diagnostics: "binary64", "binary128",
    /// "x87 extended", "IBM double-double", or "" when never filled.
    pub var long_double_fmt_name: string = "";

    /// sizeof(long double) * 8 and its alignment in bits. STORAGE, not value
    /// width: x87 is 80 value bits stored in 96 (i386) or 128 (x86_64). The
    /// type store lays f80 out from these. 0 means never filled.
    pub var long_double_bits:  usize = 0;
    pub var long_double_align: usize = 0;

    /// TargetInfo::hasFloat128Type(): whether `__float128`, hence `f128`, is
    /// available. Decides whether a diagnostic may suggest f128.
    pub var has_float128: bool = false;

    // --- C++ `size_t` / `ptrdiff_t` against the fixed-width pair ------------
    //
    // `usize` emits as `decltype(sizeof(0))` and `isize` as its signed twin,
    // so whether `f(usize)` and `f(u64)` are ONE C++ function is whether
    // size_t spells the same builtin as uint<pointer_width>_t. Pointer width
    // alone does not answer that: Linux LP64 says `unsigned long` for both,
    // Windows LLP64 `unsigned long long` for both, but Darwin is LP64 with a
    // `long long` int64_t, so there size_t (`unsigned long`) and uint64_t are
    // two types and the pair is two overloads. Asked of clang like int64_is_long.

    /// size_t is the same C++ type as u<pointer_width>.
    pub var usize_is_fixed: bool = true;
    /// ptrdiff_t is the same C++ type as i<pointer_width>.
    pub var isize_is_fixed: bool = true;

    /// What a diagnostic should call the target. The effective triple, or an
    /// explicit "not resolved" rather than an empty string, which in an error
    /// message reads as a compiler bug.
    fn describe(self) -> string {
        if !self.resolved                  { return "<target not resolved>"; }
        if self.effective_triple.size() == 0 { return "<unknown target>"; }
        return self.effective_triple;
    }

    /// --mfeatures split on commas, each item as a signed LLVM feature name
    /// ("+avx2", "-sse4.1"). An unsigned item means "enable": cc1's
    /// -target-feature takes the sign as part of the value, and a bare name
    /// is silently ignored by the backend rather than rejected, so the sign
    /// is made explicit here instead of leaving a typo'd flag to do nothing.
    fn feature_list(self) -> vec::<string> {
        var out = vec::<string>();
        var cur = "";
        for var i: usize = 0; i <= self.mfeatures.size(); ++i {
            if (i == self.mfeatures.size()) || (self.mfeatures[i] == ',') {
                if cur.size() > 0 {
                    if (cur[0] == '+') || (cur[0] == '-') { out.push_back(cur); }
                    else                                   { out.push_back("+" + cur); }
                }
                cur = "";
                continue;
            }
            cur += self.mfeatures[i];
        }
        return out;
    }

    static fn from_args(args: ref!(ParsedArgs)) -> TargetOptions {
        var o = TargetOptions();
        (o.triple)     = args.get_string("target");
        (o.host)       = args.get_string("host");
        (o.march)      = args.get_string("march");
        (o.mcpu)       = args.get_string("mcpu");
        (o.mtune)      = args.get_string("mtune");
        (o.mabi)       = args.get_string("mabi");
        (o.mfeatures)  = args.get_string("mfeatures");
        (o.m32)        = args.get_bool("m32");
        (o.m64)        = args.get_bool("m64");
        (o.cxx_std)    = args.get_string("cxx-std");
        (o.cxx_std_set) = args.is_set("cxx-std");
        (o.c_std)      = args.get_string("c-std");
        (o.c_std_set)  = args.is_set("c-std");
        (o.cxx_abi)    = args.get_string("cxx-abi");
        (o.sysroot)    = args.get_string("sysroot");
        (o.resource_dir) = args.get_string("resource-dir");
        (o.pic_level)  = args.get_i32("pic-level");
        return o;
    }
}
