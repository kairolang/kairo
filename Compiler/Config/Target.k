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
    pub var mfeatures: string = ""; ///< --mfeatures (e.g. +avx2,-sse4.1)
    pub var cxx_std:   string = "c++20";
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

    /// \brief Whether int64_t is `long`: LP64, i.e. a 64-bit pointer on
    ///        anything but Windows. LLP64 and every 32-bit target spell it
    ///        `long long`. DERIVED beside pointer_width, off the same Triple.
    ///
    /// \details true by default to agree with the unfilled pointer_width's
    ///          "treat 0 as 64": a hand-built invocation is a 64-bit host
    ///          build, and a default that disagreed with its own width would
    ///          spell i64 as a type of the wrong size.
    pub var lp64: bool = true;

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

    /// x86 or x86_64. The one ISA question the FRONTEND has to answer, because
    /// `f80` is the x87 80-bit extended format and exists nowhere else. Kept
    /// as a resolved bool rather than a string compare at each use so a new
    /// spelling of an x86 triple cannot quietly change the answer at one call
    /// site and not another.
    pub var is_x86: bool = false;

    /// What a diagnostic should call the target. The effective triple, or an
    /// explicit "not resolved" rather than an empty string, which in an error
    /// message reads as a compiler bug.
    fn describe(self) -> string {
        if !self.resolved                  { return "<target not resolved>"; }
        if self.effective_triple.size() == 0 { return "<unknown target>"; }
        return self.effective_triple;
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
        (o.cxx_abi)    = args.get_string("cxx-abi");
        (o.sysroot)    = args.get_string("sysroot");
        (o.resource_dir) = args.get_string("resource-dir");
        (o.pic_level)  = args.get_i32("pic-level");
        return o;
    }
}
