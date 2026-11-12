/// --- The Kairo Project ------------------------------- API/EnvNames.k --- ///
///
///   EnvNames: the environment variables the compiler and the linker read,
///   spelled once, and cache_root(), the toolchain's cache directory that
///   both derive from them.
///
///   One table because three parties must agree on each name: the reader,
///   the incremental record (Driver/ModuleRecords.k keys the run on the
///   variables that can change it, by these names), and the docs. One
///   copy of the cache-root chain serves the driver and the sysroot cache;
///   two copies could drift and split the runtime objects and the sysroot
///   cache across two roots. Debug switches read in one
///   file stay beside their reader.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import API::FS::LinkFS

pub class EnvNames {
    /// # The cache root, in the order cache_root() tries them

    pub static fn kairo_cache_dir() -> string {
        return "KAIRO_CACHE_DIR"
    }

    pub static fn xdg_cache_home() -> string {
        return "XDG_CACHE_HOME"
    }

    pub static fn home() -> string {
        return "HOME"
    }

    /// Windows, where HOME is usually unset.
    pub static fn local_app_data() -> string {
        return "LOCALAPPDATA"
    }

    /// # Sysroots

    /// The sysroot cache, ahead of <cache root>/sysroot (Sysroot/Cache.k).
    pub static fn kairo_sysroot_cache() -> string {
        return "KAIRO_SYSROOT_CACHE"
    }

    /// The share tree ksys builds sysroots from (Sysroot/Share.k).
    pub static fn kairo_sysroot_share() -> string {
        return "KAIRO_SYSROOT_SHARE"
    }

    /// Apple SDKs (Toolchain::find_sdk).
    pub static fn sdkroot() -> string {
        return "SDKROOT"
    }

    pub static fn developer_dir() -> string {
        return "DEVELOPER_DIR"
    }

    /// MSVC: an xwin splat and the msvc cache (Sysroot/Sdk.k), and the
    /// LIB / INCLUDE a developer prompt sets.
    pub static fn xwin() -> string {
        return "XWIN"
    }

    pub static fn msvc_cache() -> string {
        return "MSVC_CACHE"
    }

    pub static fn lib() -> string {
        return "LIB"
    }

    pub static fn include() -> string {
        return "INCLUDE"
    }

    /// # Host header and library search (--native / --host)

    pub static fn nix_cflags_compile() -> string {
        return "NIX_CFLAGS_COMPILE"
    }

    /// Link only: a hit links again, so it is not keyed.
    pub static fn nix_ldflags() -> string {
        return "NIX_LDFLAGS"
    }

    /// Link only, as NIX_LDFLAGS.
    pub static fn library_path() -> string {
        return "LIBRARY_PATH"
    }

    pub static fn pkg_config_sysroot_dir() -> string {
        return "PKG_CONFIG_SYSROOT_DIR"
    }

    pub static fn pkg_config_libdir() -> string {
        return "PKG_CONFIG_LIBDIR"
    }

    pub static fn cpath() -> string {
        return "CPATH"
    }

    pub static fn c_include_path() -> string {
        return "C_INCLUDE_PATH"
    }

    pub static fn cplus_include_path() -> string {
        return "CPLUS_INCLUDE_PATH"
    }

    /// Read only for C and C++ inputs (ClangJobs), which compile through
    /// their own cache: not keyed.
    pub static fn objc_include_path() -> string {
        return "OBJC_INCLUDE_PATH"
    }

    /// # Rendering

    pub static fn no_color() -> string {
        return "NO_COLOR"
    }

    /// Read by LLVM's colour detection, not by Kairo code.
    pub static fn term() -> string {
        return "TERM"
    }

    /// # Incremental Sema

    /// "1" turns --incremental-sema on.
    pub static fn kairo_incr_sema() -> string {
        return "KAIRO_INCR_SEMA"
    }

    /// Read by nothing: a keyed variable the tests set to see a miss.
    pub static fn kairo_incr_test() -> string {
        return "KAIRO_INCR_TEST"
    }

    /// Stands in for the compiler executable in the record (the tests
    /// cannot swap the binary under lit).
    pub static fn kairo_incr_test_exe() -> string {
        return "KAIRO_INCR_TEST_EXE"
    }
}

/// \brief the toolchain's cache root, shared by the Kairo library, the
///        runtime and LTO objects (Driver/CompilerCache.k) and the sysroot
///        cache (Sysroot/Cache.k): $KAIRO_CACHE_DIR, else
///        $XDG_CACHE_HOME/kairo, else ~/.cache/kairo, else
///        %LOCALAPPDATA%/kairo. "" when none is set: nothing is cached.
pub fn cache_root() -> string {
    var root = LinkFS::env(EnvNames::kairo_cache_dir())
    if root.empty() {
        var xdg = LinkFS::env(EnvNames::xdg_cache_home())
        if !xdg.empty() {
            root = xdg + "/kairo"
        }
    }

    if root.empty() {
        var home = LinkFS::env(EnvNames::home())
        if !home.empty() {
            root = home + "/.cache/kairo"
        }
    }

    if root.empty() {
        var local = LinkFS::env(EnvNames::local_app_data())
        if !local.empty() {
            root = local + "/kairo"
        }
    }

    // One separator. Windows hands back C:\Users\... and the library code
    // compares paths the source manager spells with '/' against ones built
    // here: a mixed C:\...\Local/kairo/... root never matched, so the
    // library's own temporary entry was recorded as a source and the cache
    // was "incomplete" on every Windows run. Windows takes '/' everywhere.
    eval if defined!(_WIN32) {
        for var i: usize = 0; i < root.size(); ++i {
            if root[i] == ('\\' as u8) {
                root[i] = ('/' as u8)
            }
        }
    }

    return root
}
