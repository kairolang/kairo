/// --- The Kairo Project -------------------------------- Sysroot/Names.k --- ///
///
///   Sysroot names and clang triples (SysRoot.md section 2), kept apart:
///
///     name          armv7-linux-musl, x86_64-linux-gnu-glibc2.31, wasm32-wasi:
///                   the directory, SYSROOT.toml's `triple`, what --target
///                   matches.
///     clang_triple  armv7-unknown-linux-musleabihf, x86_64-unknown-linux-gnu:
///                   every --target= handed to kcc and cmake.
///
///   The family table (section 14) is built in, so a name parses with no
///   share tree: the driver hook names a cache entry before it knows whether
///   it can build one. A family recipe may still narrow the arches and
///   override the clang_triple (Share.k).
///
///   Either form parses. A name must match exactly; anything else is read
///   as a triple and compared as the bundled-sysroot lookup compares
///   (Toolchain::same_target, plus the sub-arch so arm64e is not arm64).
///   In-process, through llvm::Triple: kcc -print-target-triple would be a
///   spawn per parse for the same answer.
///
///   A well-formed triple the table does not list (riscv32-linux-gnu,
///   aarch64_be-linux-musl, thumbv7-unknown-linux-musleabihf) still names a
///   target: its family comes from the triple's OS and environment and its
///   arch is the triple's, spelled as written. Whether anything can build
///   it is the provider's and the runtimes template's question, asked later
///   with a refusal of their own, not the parser's.
///
///   A glibc version is `-glibc<X.Y>` (ours, and the name's) or Zig's
///   `.<X.Y>` after the environment: x86_64-linux-gnu.2.17 is
///   x86_64-linux-gnu-glibc2.17.
///
///   properties() is what the runtimes template's rules and the probe read
///   about a target. It is the twin of Scripts/runtimes_template.py
///   props_of(): the two must agree, and the template's index.toml records
///   the Python side's verdict for every target it was derived from.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import API::Text::LinkText
import API::Toolchain::Toolchain
import Sysroot::SysUtil::SysUtil

/// glibc version a name without `-glibc<X.Y>` means when no share tree says
/// otherwise (glibc/VERSIONS.toml `default`): the version 0.2.0's roots are.
pub fn glibc_default_version() -> string {
    return "2.31"
}

pub struct SysTarget {
    pub var name:         string
    pub var clang_triple: string
    pub var arch:         string ///< as the name spells it: x86_64 aarch64 armv7 i686 riscv64 ...
    pub var family:       string ///< SYSROOT.toml `family`: linux-musl linux-gnu windows-gnu ...
    /// The share tree's recipe id (families/<recipe>.toml, quirks'
    /// match_family): musl glibc mingw freebsd netbsd wasi msvc darwin.
    pub var recipe:       string
    pub var provider:     string         ///< musl | glibc | mingw | wasi | bundle | user
    pub var libc_version: string         ///< glibc only
    pub var host_only:    bool   = false ///< darwin: built on a macOS host only
}

/// A target's properties, in SysNames::rule_props() order then the
/// descriptive ones (threads, exceptions).
pub class SysProps {
    pub var keys: cxx::std::vector<string>
    pub var vals: cxx::std::vector<string>

    pub fn put(self, const k: string, const v: string) {
        self.keys.push_back(k)
        self.vals.push_back(v)
    }

    /// "" when \p k is not a property.
    pub fn get(self, const k: string) -> string {
        for var i: usize = 0; i < self.keys.size(); ++i {
            if self.keys[i] == k {
                return self.vals[i]
            }
        }

        return ""
    }

    /// `k=v k=v ...`, for the probe table.
    pub fn text(self) -> string {
        var s = ""
        for var i: usize = 0; i < self.keys.size(); ++i {
            if i > 0 {
                s += " "
            }

            s += self.keys[i] + "=" + self.vals[i]
        }

        return s
    }
}

pub class SysNames {
    /// The families of SysRoot.md section 14, in table order.
    pub static fn families() -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        out.push_back("linux-musl")
        out.push_back("linux-gnu")
        out.push_back("windows-gnu")
        out.push_back("freebsd")
        out.push_back("netbsd")
        out.push_back("wasi")
        out.push_back("windows-msvc")
        out.push_back("darwin")
        return out
    }

    pub static fn arches(const family: string) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        if family == "linux-musl" {
            out.push_back("x86_64")
            out.push_back("aarch64")
            out.push_back("armv7")
            out.push_back("armv6")
            out.push_back("i686")
            out.push_back("riscv64")
            out.push_back("riscv32")
        } else if family == "linux-gnu" {
            out.push_back("x86_64")
            out.push_back("aarch64")
            out.push_back("armv7")
            out.push_back("i686")
            out.push_back("riscv64")
        } else if family == "windows-gnu" {
            out.push_back("x86_64")
            out.push_back("aarch64")
            out.push_back("armv7")
            out.push_back("i686")
        } else if family == "freebsd" {
            out.push_back("x86_64")
            out.push_back("aarch64")
        } else if family == "netbsd" {
            out.push_back("x86_64")
        } else if family == "wasi" {
            out.push_back("wasm32")
        } else if family == "windows-msvc" {
            out.push_back("x86_64")
            out.push_back("aarch64")
            out.push_back("i686")
        } else if family == "darwin" {
            out.push_back("x86_64")
            out.push_back("arm64")
            out.push_back("arm64e")
        }

        return out
    }

    pub static fn recipe_of(const family: string) -> string {
        if family == "linux-musl" {
            return "musl"
        }

        if family == "linux-gnu" {
            return "glibc"
        }

        if family == "windows-gnu" {
            return "mingw"
        }

        if family == "windows-msvc" {
            return "msvc"
        }

        return family
    }

    pub static fn provider_of(const family: string) -> string {
        if family == "linux-musl" {
            return "musl"
        }

        if family == "linux-gnu" {
            return "glibc"
        }

        if family == "windows-gnu" {
            return "mingw"
        }

        if family == "windows-msvc" || family == "darwin" {
            return "user"
        }

        if family == "wasi" {
            return "wasi"
        }

        return "bundle"
    }

    /// The target \p family / \p arch names, glibc at \p glibc.
    pub static fn make(const family: string, const arch: string, const glibc: string) -> SysTarget {
        var t = SysTarget{}
        t.family   = family
        t.arch     = arch
        t.provider = SysNames::provider_of(family)
        t.recipe   = SysNames::recipe_of(family)
        // 32-bit Arm on Linux is hard-float (eabihf) here, whatever the
        // sub-arch: the names carry no float ABI, and every root is hard-float.
        var arm = SysNames::cpu_of(arch) == "arm"
        if family == "linux-musl" {
            t.name = f"{arch}-linux-musl"
            t.clang_triple = if (arm) => (f"{arch}-unknown-linux-musleabihf")
                             else => f"{arch}-unknown-linux-musl"
        } else if family == "linux-gnu" {
            var env = if (arm) => ("gnueabihf") else => "gnu"
            t.name         = f"{arch}-linux-{env}-glibc{glibc}"
            t.clang_triple = f"{arch}-unknown-linux-{env}"
            t.libc_version = glibc
        } else if family == "windows-gnu" {
            t.name         = f"{arch}-windows-gnu"
            t.clang_triple = f"{arch}-w64-windows-gnu"
        } else if family == "freebsd" {
            t.name         = f"{arch}-unknown-freebsd"
            t.clang_triple = f"{arch}-unknown-freebsd"
        } else if family == "netbsd" {
            t.name         = f"{arch}-unknown-netbsd"
            t.clang_triple = f"{arch}-unknown-netbsd"
        } else if family == "wasi" {
            // compiler-rt/lib/wasm32-unknown-wasi is the dir the builtins go
            // in; the driver turns -wasi into -wasip1 on the way to clang.
            t.name         = f"{arch}-wasi"
            t.clang_triple = f"{arch}-unknown-wasi"
        } else if family == "windows-msvc" {
            t.name         = f"{arch}-windows-msvc"
            t.clang_triple = f"{arch}-pc-windows-msvc"
        } else if family == "darwin" {
            // The deployment floors the 0.2.0 roots were built for.
            var ver = if (arch == "x86_64") => ("10.15") else => "11.0"
            t.name         = f"{arch}-apple-macosx"
            t.clang_triple = f"{arch}-apple-macosx{ver}"
            t.host_only    = true
        }

        return t
    }

    /// Every target the table knows, glibc at \p glibc.
    pub static fn all(const glibc: string) -> cxx::std::vector<SysTarget> {
        var out = cxx::std::vector<SysTarget>()
        for var f: string in SysNames::families() {
            for var a: string in SysNames::arches(f) {
                out.push_back(SysNames::make(f, a, glibc))
            }
        }

        return out
    }

    /// \p input (a name or a clang triple) to the one target it means.
    /// False with \p why set when it means none, or several (\p cands then
    /// holds their names). \p glibc_default is the version a glibc input
    /// without `-glibc<X.Y>` gets.
    pub static fn parse(const input:         string,
                        const glibc_default: string,
                        @inout out:          SysTarget,
                        @inout cands:        cxx::std::vector<string>,
                        @inout why:          string) -> bool {
        cands.clear()
        var spelled = input
        var glibc   = glibc_default

        // Zig's spelling, `<...>-gnu<env>.<X.Y>`: the same as -glibc<X.Y>.
        var gnu = LinkText::find(spelled, "-gnu", 0)
        if gnu < spelled.size() {
            // The dot ends the environment component: -glibc2.31 has its own
            // dash first, and is not this spelling.
            var dot  = LinkText::find(spelled, ".", gnu)
            var dash = LinkText::find(spelled, "-", gnu + 1)
            var tail = LinkText::slice(spelled, dot + 1, spelled.size())
            if dot < spelled.size() && dash > dot && SysNames::_is_version(tail) {
                var head = LinkText::slice(spelled, 0, dot)
                var ver  = LinkText::slice(spelled, dot + 1, spelled.size())
                spelled = head + "-glibc" + ver
            }
        }

        var named = spelled

        // `-glibc<X.Y>` is ours, not llvm's: split it off before either match.
        var at = LinkText::find(spelled, "-glibc", 0)
        if at < spelled.size() {
            glibc   = LinkText::slice(spelled, at + 6, spelled.size())
            spelled = LinkText::slice(spelled, 0, at)
            if glibc.empty() {
                why = f"\x27{input}\x27 names no glibc version after -glibc"
                return false
            }
        }

        var table = SysNames::all(glibc)
        for var t: SysTarget in table {
            if t.name == named || t.family == "linux-gnu" && t.name == spelled + "-glibc" + glibc {
                out = t
                return true
            }
        }

        var hits = cxx::std::vector<SysTarget>()
        for var t: SysTarget in table {
            if SysNames::same_target(spelled, t.clang_triple) {
                hits.push_back(t)
            }
        }

        if hits.size() == 1 {
            out = hits[0]
            return true
        }

        // A prefix of names (`x86_64-linux`): the one it completes to, or
        // every one it could mean.
        if hits.empty() {
            for var t: SysTarget in table {
                if LinkText::starts_with(t.name, input + "-") {
                    hits.push_back(t)
                }
            }

            if hits.size() == 1 {
                out = hits[0]
                return true
            }
        }

        if hits.empty() {
            var g = SysTarget{}
            if SysNames::_generic(spelled, glibc, &g, &why) {
                out = g
                return true
            }

            if why.empty() {
                why = f"\x27{input}\x27 is not a sysroot name, or the triple of one"
            }

            return false
        }

        for var t: SysTarget in hits {
            cands.push_back(t.name)
        }

        var list = SysUtil::joined(&cands, ", ")
        why = f"\x27{input}\x27 is ambiguous: {list}"
        return false
    }

    /// A triple the table does not list, as the family its OS and
    /// environment name. False with \p why empty when it names none of ours
    /// (the caller then says the input is no target), or set when it names
    /// one in a form no root is made in.
    priv static fn _generic(const spelled: string,
                            const glibc:   string,
                            @inout out:    SysTarget,
                            @inout why:    string) -> bool {
        var norm = llvm::Triple::normalize(kairo::sref(spelled))
        var tt   = llvm::Triple(norm)
        var parts = SysUtil::split(string(unsafe ((norm.c_str() as unsafe *const u8) as *const u8)), ('-' as u8))
        if tt.getArch() == llvm::Triple::UnknownArch || parts.size() < 3 {
            return false
        }

        var arch = parts[0]
        var os   = parts[2]
        var env  = if (parts.size() > 3) => (parts[3]) else => ""
        var fam  = ""
        if tt.isOSLinux() {
            if LinkText::starts_with(env, "musl") {
                fam = "linux-musl"
            } else if env.empty() || LinkText::starts_with(env, "gnu") {
                fam = "linux-gnu"
            } else {
                why = f"\x27{spelled}\x27: Linux sysroots are musl or gnu, not {env}"
                return false
            }

            // The roots are hard-float: a soft-float Arm environment would
            // get a hard-float root under a name that does not say so.
            if SysNames::cpu_of(arch) == "arm" && (env == "musleabi" || env == "gnueabi") {
                why = f"\x27{spelled}\x27 is soft-float Arm; sysroots are built for {env}hf only"
                return false
            }
        } else if tt.isOSWindows() {
            fam = if (env == "gnu") => ("windows-gnu") else => "windows-msvc"
        } else if LinkText::starts_with(os, "freebsd") {
            fam = "freebsd"
        } else if LinkText::starts_with(os, "netbsd") {
            fam = "netbsd"
        } else if LinkText::starts_with(os, "wasi") {
            fam = "wasi"
        } else if tt.isOSDarwin() {
            fam = "darwin"
        } else {
            return false
        }

        out = SysNames::make(fam, arch, glibc)
        return true
    }

    priv static fn _is_version(const s: string) -> bool {
        if s.empty() {
            return false
        }

        for var i: usize = 0; i < s.size(); ++i {
            var c = s[i]
            if (c < ('0' as u8) || c > ('9' as u8)) && c != ('.' as u8) {
                return false
            }
        }

        return true
    }

    /// The CPU family of an arch as a name or triple spells it.
    pub static fn cpu_of(const arch: string) -> string {
        if arch == "x86_64"
            || arch.size() == 4 && arch[0] == ('i' as u8) && LinkText::ends_with(arch, "86") {
            return "x86"
        }

        if LinkText::starts_with(arch, "aarch64") || LinkText::starts_with(arch, "arm64") {
            return "aarch64"
        }

        if LinkText::starts_with(arch, "arm") || LinkText::starts_with(arch, "thumb") {
            return "arm"
        }

        if LinkText::starts_with(arch, "riscv") {
            return "riscv"
        }

        if LinkText::starts_with(arch, "wasm") {
            return "wasm"
        }

        if LinkText::starts_with(arch, "powerpc") {
            return "powerpc"
        }

        if arch == "s390x" {
            return "systemz"
        }

        if LinkText::starts_with(arch, "mips") {
            return "mips"
        }

        if LinkText::starts_with(arch, "loongarch") {
            return "loongarch"
        }

        if LinkText::starts_with(arch, "sparc") {
            return "sparc"
        }

        return arch
    }

    /// 64-bit pointers, as the arch spells it (every aarch64 too).
    pub static fn is_64(const arch: string) -> bool {
        return arch == "x86_64"
            || arch == "riscv64"
            || arch == "wasm64"
            || arch == "powerpc64"
            || arch == "powerpc64le"
            || arch == "s390x"
            || arch == "mips64"
            || arch == "mips64el"
            || arch == "loongarch64"
            || arch == "sparcv9"
            || arch == "sparc64"
            || SysNames::cpu_of(arch) == "aarch64"
    }

    /// Big-endian, as the arch spells it: *_be / *eb, s390x, sparc but
    /// sparcel, powerpc and mips without le / el.
    pub static fn is_big_endian(const arch: string) -> bool {
        if LinkText::ends_with(arch, "_be") || LinkText::ends_with(arch, "eb") || arch == "s390x" {
            return true
        }

        if LinkText::starts_with(arch, "sparc") {
            return arch != "sparcel"
        }

        if LinkText::starts_with(arch, "powerpc") || LinkText::starts_with(arch, "mips") {
            return !LinkText::ends_with(arch, "le") && !LinkText::ends_with(arch, "el")
        }

        return false
    }

    /// The properties the runtimes template's rules read, in its order
    /// (runtimes-template/index.toml `properties`).
    pub static fn rule_props() -> cxx::std::vector<string> {
        var v = cxx::std::vector<string>()
        v.push_back("libc")
        v.push_back("os")
        v.push_back("objfmt")
        v.push_back("bits")
        v.push_back("int128")
        v.push_back("cpu")
        v.push_back("rt_arch")
        v.push_back("float")
        v.push_back("crt_arch")
        v.push_back("endian")
        v.push_back("arch")
        return v
    }

    /// \p t's properties, from its recipe id, arch and clang_triple (after
    /// the recipe and the quirks): the twin of runtimes_template.py
    /// props_of(), then threads and exceptions (descriptive; no rule reads
    /// them yet).
    pub static fn properties(t: *SysTarget) -> SysProps {
        var p    = SysProps()
        var libc = t->recipe
        var arch = t->arch
        var cpu  = SysNames::cpu_of(arch)
        var os = if (libc == "musl" || libc == "glibc") => ("linux")
                 else => if (libc == "mingw") => ("windows") else => libc
        var b64  = SysNames::is_64(arch)
        var bits = if (b64) => ("64") else => "32"
        var objfmt = if (os == "windows") => ("coff")
                     else => if (cpu == "wasm") => ("wasm") else => "elf"
        var int128 = if (b64 || cpu == "wasm") => ("native") else => "soft"
        var big    = SysNames::is_big_endian(arch)
        var fl     = "na"
        if cpu == "arm" {
            // armv7-linux-gnueabihf has no vendor: the env is the last component.
            fl = if (os == "windows" || LinkText::ends_with(t->clang_triple, "hf")) => ("hard")
                 else => "soft"
        }

        // compiler-rt's builtins arch (its <arch>_SOURCES): armv6 is
        // arm_min, armv7 and later arm (soft) / armhf (hard), MinGW's arm,
        // i?86 i386.
        var rt = arch
        if cpu == "x86" {
            rt = if (b64) => ("x86_64") else => "i386"
        } else if cpu == "aarch64" {
            rt = "aarch64"
        } else if cpu == "arm" {
            var skip: usize = if (LinkText::starts_with(arch, "thumb")) => (5) else => 3
            var sub         = LinkText::slice(arch, skip, arch.size())
            if os == "windows" {
                rt = "arm"
            } else if LinkText::starts_with(sub, "v6") {
                rt = "armv6"
            } else if LinkText::starts_with(sub, "v5") || LinkText::starts_with(sub, "v4") {
                rt = "armv" + LinkText::slice(sub, 1, sub.size())
            } else {
                rt = if (fl == "hard") => ("armhf") else => "arm"
            }
        }

        if arch == "sparc64" {
            rt = "sparcv9"
        }

        // The arch in crtbegin/crtend's object names (the crt configure's
        // own spelling).
        var crt = rt
        if cpu == "arm" {
            crt = if (fl == "hard") => ("armhf") else => "arm"
        }

        p.put("libc", libc)
        p.put("os", os)
        p.put("objfmt", objfmt)
        p.put("bits", bits)
        p.put("int128", int128)
        p.put("cpu", cpu)
        p.put("rt_arch", rt)
        p.put("float", fl)
        p.put("crt_arch", crt)
        p.put("endian", if (big) => ("big") else => "little")
        p.put("arch", arch)

        // libc++'s thread API and the unwinder the C++ runtimes are built
        // for: what the tables encode per family today.
        var threads = if (os == "windows") => ("win32")
                      else => if (cpu == "wasm") => ("none") else => "posix"
        var eh = "dwarf"
        if os == "windows" && cpu != "x86" || os == "windows" && b64 {
            eh = "seh"
        } else if cpu == "arm" {
            eh = "arm-ehabi"
        } else if cpu == "wasm" {
            eh = "none"
        }

        p.put("threads", threads)
        p.put("exceptions", eh)
        return p
    }

    /// Same target, as the bundled-sysroot lookup decides it.
    pub static fn same_target(const a: string, const b: string) -> bool {
        if !Toolchain::same_target(a, b) {
            return false
        }

        var ta = llvm::Triple(llvm::Triple::normalize(kairo::sref(a)))
        var tb = llvm::Triple(llvm::Triple::normalize(kairo::sref(b)))
        return ta.getSubArch() == tb.getSubArch()
    }
}
