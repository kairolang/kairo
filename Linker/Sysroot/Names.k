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
    pub var provider:     string         ///< musl | glibc | mingw | bundle | user
    pub var libc_version: string         ///< glibc only
    pub var host_only:    bool   = false ///< darwin: built on a macOS host only
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

        return "bundle"
    }

    /// The target \p family / \p arch names, glibc at \p glibc.
    pub static fn make(const family: string, const arch: string, const glibc: string) -> SysTarget {
        var t = SysTarget{}
        t.family   = family
        t.arch     = arch
        t.provider = SysNames::provider_of(family)
        t.recipe   = SysNames::recipe_of(family)
        if family == "linux-musl" {
            t.name = f"{arch}-linux-musl"
            t.clang_triple = if (arch == "armv7"
                                 || arch == "armv6") => (f"{arch}-unknown-linux-musleabihf")
                             else => f"{arch}-unknown-linux-musl"
        } else if family == "linux-gnu" {
            var env = if (arch == "armv7") => ("gnueabihf") else => "gnu"
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
            if t.name == input || t.family == "linux-gnu" && t.name == spelled + "-glibc" + glibc {
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
            why = f"\x27{input}\x27 is not a sysroot name, or the triple of one"
            return false
        }

        for var t: SysTarget in hits {
            cands.push_back(t.name)
        }

        var list = SysUtil::joined(&cands, ", ")
        why = f"\x27{input}\x27 is ambiguous: {list}"
        return false
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
