/// --- The Kairo Project ------------------------------ Config/Target.k --- ///
///
///   TargetOptions: target triple, ISA, host-system and C++ ABI settings.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import Command::FlagRegistry::DEFAULT_PIC_LEVEL
import Command::ParsedArgs::ParsedArgs

/// The target's object file format, from llvm::Triple::getObjectFormat()
/// (the one switch is CompilerInstance::_object_format_of; Config/ never
/// sees LLVM). The driver, the linker and the info queries branch on this.
/// \c Unresolved is "the driver has not filled the target yet", which is not
/// LLVM's unknown format: the emitter treats the two differently.
pub enum ObjectFormat derives u8 {
    Unresolved = 0,
    Unknown,
    Elf,
    MachO,
    Coff,
    Wasm,
    Xcoff,
    Goff,
    DxContainer,
    Spirv,
}

/// \p f as `kairo --print-target-info`, the linker's messages and the
/// emitter's comparisons (TargetOptions::object_format) spell it.
pub fn object_format_name(f: ObjectFormat) -> string {
    if f == ObjectFormat::Elf {
        return "ELF"
    } else if f == ObjectFormat::MachO {
        return "Mach-O"
    } else if f == ObjectFormat::Coff {
        return "COFF"
    } else if f == ObjectFormat::Wasm {
        return "Wasm"
    } else if f == ObjectFormat::Xcoff {
        return "XCOFF"
    } else if f == ObjectFormat::Goff {
        return "GOFF"
    } else if f == ObjectFormat::DxContainer {
        return "DXContainer"
    } else if f == ObjectFormat::Spirv {
        return "SPIR-V"
    } else if f == ObjectFormat::Unknown {
        return "unknown"
    }

    return ""
}

///
/// \class TargetOptions
///
/// \brief Target triple, ISA selection, and C++ interop ABI settings.
///
pub class TargetOptions {
    /// --target, canonicalised by the driver before anything reads it
    /// (CompilerInstance::_canonical_target): a glibc version is split off
    /// into `glibc`, and a versionless macOS gets its deployment floor.
    pub var triple:    string = ""
    pub var glibc:     string = "" ///< the glibc version --target spelled (`-glibc2.28`, `.2.28`), else ""
    pub var host:      string = "" ///< --host triple
    pub var march:     string = "" ///< -march / --march
    pub var mcpu:      string = "" ///< -mcpu  / --mcpu
    pub var mtune:     string = "" ///< --mtune
    pub var mabi:      string = "" ///< --mabi
    pub var mfeatures: string = "" ///< --mfeatures (e.g. +avx2,-sse4.1); read it through feature_list()
    pub var cxx_std:   string = "c++23"
    pub var c_std:     string = "c17" ///< --c-std: C inputs (and ObjC)
    /// Given on the command line. A C input under clang's driver gets
    /// clang's own default standard unless the user named one; a C++ input
    /// always gets cxx_std, the same standard kairo's own TUs compile under.
    pub var cxx_std_set:  bool   = false
    pub var c_std_set:    bool   = false
    pub var cxx_abi:      string = "itanium"
    pub var sysroot:      string = ""
    pub var resource_dir: string = "" ///< clang resource dir: its include/ holds the builtin headers (stddef.h).
    pub var pic_level:    i32    = DEFAULT_PIC_LEVEL
    pub var m32:          bool   = false
    pub var m64:          bool   = false
    pub var native:       bool   = false ///< --native: the host's own libc, headers and libraries
    /// --pkg-config names, in order. Run by the driver (_apply_host_system),
    /// whose output lands in the ordinary -I/-D/-L/-l lists.
    pub var pkg_config: cxx::std::vector<string>

    /// \brief How much of the host system a build may see. DERIVED by
    ///        CompilerInstance::_apply_host_system, once, from --target and
    ///        --native; every consumer reads this instead of re-asking.
    ///
    /// \details ""        hermetic: --target (or --sysroot, --freestanding)
    ///                    given. The bundled sysroot only, no host paths, no
    ///                    host env search paths: a cross build is
    ///                    reproducible.
    ///          "floor"   the default on a Linux host: the bundled sysroot is
    ///                    the C library (glibc 2.31 on a glibc host), and the
    ///                    host's system dirs come AFTER it, so only what the
    ///                    floor lacks (zlib.h, libcurl.so) is the host's.
    ///          "native"  --native: the host's libc, headers and libraries in
    ///                    clang's native order; the bundled libc++ and
    ///                    compiler-rt (native_bundle) on top.
    pub var host_mode: string = ""
    /// Host system include dirs, existing ones only, already deduplicated:
    /// -idirafter in "floor" mode, -isystem in "native" mode.
    pub var host_include_dirs: cxx::std::vector<string>
    /// Host system library dirs, searched after the sysroot's (-L).
    pub var host_lib_dirs: cxx::std::vector<string>
    /// LIBRARY_PATH (and NIX_LDFLAGS -L): link search after the sysroot's
    /// dirs and before the host's defaults, as clang adds it.
    pub var env_lib_dirs: cxx::std::vector<string>
    /// --native: the bundled sysroot for the host's C library flavour; its
    /// libc++ headers and archives and its compiler-rt are linked, its libc
    /// never is. "" otherwise.
    pub var native_bundle: string = ""

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
    pub var pointer_width: usize = 0

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
    pub var int64_is_long: bool = true

    /// # Derived target facts
    ///
    /// Everything below is DERIVED from the effective triple, exactly like
    /// pointer_width above and for the same reason: a fact that disagrees with
    /// the triple is not a target, so none of it is parsed and none of it has a
    /// flag. `CompilerInstance::_apply_invocation` writes all of it in one
    /// place, off one `llvm::Triple`, after -m32/-m64 have been applied -- so
    /// every consumer sees ONE consistent view of one target, and Config/ still
    /// never sees LLVM.
    ///
    /// `resolved` says whether the driver got here at all. A hand-built
    /// invocation that skipped _apply_invocation leaves it false, and a
    /// consumer that must not guess (portability checks) can say so instead of
    /// silently treating an empty arch as "not x86".

    /// True once the driver has filled the block below.
    pub var resolved: bool = false

    /// The normalized triple actually being compiled for: --target if given,
    /// else the host triple, after the -m32/-m64 arch-variant rewrite. This,
    /// not `triple`, is what a diagnostic should name.
    pub var effective_triple: string = ""

    pub var arch_name:     string = "" ///< first component, e.g. "x86_64".
    pub var vendor_name:   string = "" ///< second component, e.g. "pc".
    pub var os_name:       string = "" ///< third component, e.g. "linux".
    pub var env_name:      string = "" ///< fourth component, e.g. "gnu"; "" if none.
    /// What the driver and the linker branch on. \c object_format is its
    /// name (object_format_name), set beside it by the same writer
    /// (CompilerInstance::_apply_invocation): the emitter still compares
    /// the text.
    pub var object_format_kind: ObjectFormat = ObjectFormat::Unresolved
    pub var object_format:      string       = "" ///< "ELF" / "COFF" / "Mach-O" / ...

    pub var is_little_endian: bool = true

    /// x86 or x86_64, i.e. the CPU has an x87 stack. NOT the f80 gate -- that
    /// is long_double_is_x87 below, because an x86 ABI may still not expose
    /// x87 as `long double`. Kept so the f80 diagnostic can say which of the
    /// two it hit. A resolved bool rather than a string compare at each use
    /// so a new spelling of an x86 triple cannot quietly change the answer at
    /// one call site and not another.
    pub var is_x86: bool = false

    /// The triple names an OS (llvm::Triple's OS is not UnknownOS): a hosted
    /// target, which has an unwinder, so C++ exceptions default on
    /// (LangOptions::cxx_exceptions). A bare-metal triple has none.
    pub var has_os: bool = true

    /// # C++ `long double`, read from clang::TargetInfo
    ///
    /// `f80` lowers to C++ `long double`, so whether f80 exists is an ABI fact,
    /// not an ISA fact: x86_64-windows-msvc has x87 hardware and a binary64
    /// `long double`, x86_64-linux-android has a binary128 one. is_x86 above
    /// answers "does the CPU have x87"; these answer "is the `long double` we
    /// emit x87", which is the question TypeResolution actually has to ask.
    /// Taken from clang rather than a hand-written triple list because clang
    /// already knows every case a list gets wrong.

    /// The target ABI's `long double` IS x87 extended. The f80 gate.
    pub var long_double_is_x87: bool = false

    /// What `long double` is here, for diagnostics: "binary64", "binary128",
    /// "x87 extended", "IBM double-double", or "" when never filled.
    pub var long_double_fmt_name: string = ""

    /// sizeof(long double) * 8 and its alignment in bits. STORAGE, not value
    /// width: x87 is 80 value bits stored in 96 (i386) or 128 (x86_64). The
    /// type store lays f80 out from these. 0 means never filled.
    pub var long_double_bits:  usize = 0
    pub var long_double_align: usize = 0

    /// TargetInfo::hasFloat128Type(): whether `__float128`, hence `f128`, is
    /// available. Decides whether a diagnostic may suggest f128.
    pub var has_float128: bool = false

    /// sizeof(wchar_t) * 8: 32 on most targets, 16 on Windows. The type
    /// store lays std::c_wchar out from it (BuiltinKind::CWChar). 0 means
    /// never filled, and the store keeps 32.
    pub var wchar_bits: usize = 0

    /// # C++ `size_t` / `ptrdiff_t` against the fixed-width pair
    ///
    /// `usize` emits as `decltype(sizeof(0))` and `isize` as its signed twin,
    /// so whether `f(usize)` and `f(u64)` are ONE C++ function is whether
    /// size_t spells the same builtin as uint<pointer_width>_t. Pointer width
    /// alone does not answer that: Linux LP64 says `unsigned long` for both,
    /// Windows LLP64 `unsigned long long` for both, but Darwin is LP64 with a
    /// `long long` int64_t, so there size_t (`unsigned long`) and uint64_t are
    /// two types and the pair is two overloads. Asked of clang like int64_is_long.

    /// size_t is the same C++ type as u<pointer_width>.
    pub var usize_is_fixed: bool = true
    /// ptrdiff_t is the same C++ type as i<pointer_width>.
    pub var isize_is_fixed: bool = true

    /// What a diagnostic should call the target. The effective triple, or an
    /// explicit "not resolved" rather than an empty string, which in an error
    /// message reads as a compiler bug.
    pub fn describe(self) -> string {
        if !self.resolved {
            return "<target not resolved>"
        }

        if self.effective_triple.size() == 0 {
            return "<unknown target>"
        }

        return self.effective_triple
    }

    /// --mfeatures split on commas, each item as a signed LLVM feature name
    /// ("+avx2", "-sse4.1"). An unsigned item means "enable": cc1's
    /// -target-feature takes the sign as part of the value, and a bare name
    /// is silently ignored by the backend rather than rejected, so the sign
    /// is made explicit here instead of leaving a typo'd flag to do nothing.
    pub fn feature_list(self) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        var cur = ""
        for var i: usize = 0; i <= self.mfeatures.size(); ++i {
            if i == self.mfeatures.size() || self.mfeatures[i] == (',' as u8) {
                if cur.size() > 0 {
                    if cur[0] == ('+' as u8) || cur[0] == ('-' as u8) {
                        out.push_back(cur)
                    } else {
                        out.push_back("+" + cur)
                    }
                }

                cur = ""
                continue
            }

            cur.push_back(self.mfeatures[i])
        }

        return out
    }

    pub static fn from_args(@inout args: ParsedArgs) -> TargetOptions {
        var o = TargetOptions()
        o.triple    = args.get_string("target")
        o.host      = args.get_string("host")
        o.march     = args.get_string("march")
        o.mcpu      = args.get_string("mcpu")
        o.mtune     = args.get_string("mtune")
        o.mabi      = args.get_string("mabi")
        o.mfeatures = args.get_string("mfeatures")
        o.m32       = args.get_bool("m32")
        o.m64       = args.get_bool("m64")
        o.native    = args.get_bool("native")
        for s in *args.get_list("pkg-config") {
            o.pkg_config.push_back(s)
        }

        o.cxx_std      = args.get_string("cxx-std")
        o.cxx_std_set  = args.is_set("cxx-std")
        o.c_std        = args.get_string("c-std")
        o.c_std_set    = args.is_set("c-std")
        o.cxx_abi      = args.get_string("cxx-abi")
        o.sysroot      = args.get_string("sysroot")
        o.resource_dir = args.get_string("resource-dir")
        o.pic_level    = args.get_i32("pic-level")
        return o
    }
}
