/// --- The Kairo Project ----------------------------- API/HostSystem.k --- ///
///
///   What the build machine has: C library, system dirs, pkg-config.
///
///     A default build on a Linux host compiles against the bundled glibc
///     2.31 sysroot (the "floor") and only then searches the host's system
///     dirs, so a header or library the floor lacks (zlib.h, libcurl.so)
///     comes from the host while <stdio.h> and libc never do. A host shared
///     library was built against the host's own, newer glibc; after the link
///     its DT_VERNEED says which glibc the program now needs to run, which is
///     what glibc_needs reads (a small in-process ELF reader: section
///     headers, .gnu.version_r, .dynamic).
///
///     Only what EXISTS is returned, deduplicated by real path: on a merged-
///     /usr host /lib, /lib64 and /usr/lib64 are all /usr/lib, and a
///     multiarch dir is a Debian-ism other distros do not have.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/Support/Program.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "optional"
ffi "c++" import "string"

import API::FS::LinkFS
import API::Text::LinkText
import API::Toolchain::Toolchain

/// What glibc_needs found in one shared library.
pub struct HostLibNeeds {
    var ok:        bool   = false ///< an ELF shared object that could be read
    var soname:    string         ///< DT_SONAME, else the file's real basename
    var max_glibc: string         ///< highest GLIBC_<v> it needs, "" for none
}

/// Why `HostSystem::pkg_config` could not answer: pkg-config is missing or
/// failed. The message is complete; the caller prefixes the package's flag.
pub struct PkgConfigError {
    pub var message: string

    fn op panic(const self) -> string {
        return self.message
    }
}

pub class HostSystem {
    /// # The host's C library

    /// "glibc", "musl" or "" for the Linux host's C library, by its dynamic
    /// loader: the compiler's own process triple is fixed when it is built
    /// and says nothing about the machine it runs on. glibc wins when both
    /// are installed (a glibc distro with musl-gcc beside it). \p arch is
    /// Toolchain's canonical spelling, \p hf whether 32-bit ARM is hard-float.
    pub static fn host_libc(const arch: string, hf: bool) -> string {
        var env_g = if (hf) => ("gnueabihf") else => "gnu"
        var env_m = if (hf) => ("musleabihf") else => "musl"
        var gl    = Toolchain::dynamic_linker_for(arch, "linux", env_g, "glibc")
        if !gl.empty() && LinkFS::exists(gl) {
            return "glibc"
        }

        var ml = Toolchain::dynamic_linker_for(arch, "linux", env_m, "musl")
        if !ml.empty() && LinkFS::exists(ml) {
            return "musl"
        }

        return ""
    }

    /// # System dirs, in clang's Linux order

    /// /usr/local/include, /usr/include/<multiarch>, /usr/include.
    pub static fn include_dirs(const arch: string, const env: string) -> cxx::std::vector<string> {
        var out  = cxx::std::vector<string>()
        var seen = cxx::std::vector<string>()
        var ma   = Toolchain::multiarch(arch, "linux", env)
        HostSystem::add_dir(&out, &seen, "/usr/local/include")
        if !ma.empty() {
            HostSystem::add_dir(&out, &seen, f"/usr/include/{ma}")
        }

        HostSystem::add_dir(&out, &seen, "/usr/include")
        return out
    }

    /// /usr/local/lib, /usr/lib/<multiarch>, /usr/lib64, /usr/lib,
    /// /lib/<multiarch>, /lib64, /lib. lib64 only for a 64-bit target: it is
    /// where Fedora and SUSE keep 64-bit libraries, and the wrong class
    /// for 32-bit ones.
    pub static fn lib_dirs(const arch: string,
                           const env:  string,
                           is64:       bool) -> cxx::std::vector<string> {
        var out  = cxx::std::vector<string>()
        var seen = cxx::std::vector<string>()
        var ma   = Toolchain::multiarch(arch, "linux", env)
        HostSystem::add_dir(&out, &seen, "/usr/local/lib")
        if !ma.empty() {
            HostSystem::add_dir(&out, &seen, f"/usr/lib/{ma}")
        }

        if is64 {
            HostSystem::add_dir(&out, &seen, "/usr/lib64")
        }

        HostSystem::add_dir(&out, &seen, "/usr/lib")
        if !ma.empty() {
            HostSystem::add_dir(&out, &seen, f"/lib/{ma}")
        }

        if is64 {
            HostSystem::add_dir(&out, &seen, "/lib64")
        }

        HostSystem::add_dir(&out, &seen, "/lib")
        return out
    }

    /// Appends \p d to \p out when it is a directory whose real path is not
    /// in \p seen yet.
    pub static fn add_dir(@inout out:  cxx::std::vector<string>,
                          @inout seen: cxx::std::vector<string>,
                          const d:     string) {
        if d.empty() || !LinkFS::is_dir(d) {
            return
        }

        var r = LinkFS::real(d)
        for var s: string in seen {
            if s == r {
                return
            }
        }

        seen.push_back(r)
        out.push_back(d)
    }

    /// An environment search-path list (CPATH, LIBRARY_PATH), split on ':'
    /// as clang's driver splits it: an empty element is the current
    /// directory. "" when unset.
    pub static fn env_list(const name: string) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        var v   = LinkFS::env(name)
        if v.empty() {
            return out
        }

        var b: usize = 0
        for var i: usize = 0; i <= v.size(); ++i {
            if i == v.size() || v[i] == (':' as u8) {
                var part = LinkText::slice(v, b, i)
                if part.empty() {
                    part = "."
                }

                out.push_back(part)
                b = i + 1
            }
        }

        return out
    }

    /// # pkg-config

    /// `pkg-config --cflags --libs <name>`, split into words. The child gets
    /// this process's environment untouched: PKG_CONFIG_PATH,
    /// PKG_CONFIG_LIBDIR and PKG_CONFIG_SYSROOT_DIR are pkg-config's to read.
    /// $PKG_CONFIG names the program, as for autotools and meson.
    ///
    /// \panic PkgConfigError: no pkg-config, or it failed (an unknown
    ///        package; its own first line of stderr is appended). A user
    ///        error the caller reports, so a panic and not an ICE; \p words
    ///        is untouched then.
    pub static fn pkg_config(const name:   string,
                             @inout words: cxx::std::vector<string>) panic(PkgConfigError) {
        var prog_name = LinkFS::env("PKG_CONFIG")
        if prog_name.empty() {
            prog_name = "pkg-config"
        }

        var prog = prog_name
        if !LinkText::contains(prog_name, "/") {
            var found = llvm::sys::findProgramByName(kairo::sref(prog_name))
            if found.getError().value() != 0 {
                panic PkgConfigError { message: f"{prog_name} was not found on PATH" }
            }

            prog = string(
                unsafe ((found.get().c_str() as unsafe *const u8) as *const u8),
            )
        } else if !LinkFS::is_file(prog_name) {
            panic PkgConfigError { message: f"{prog_name} does not exist" }
        }

        var out_path = LinkFS::temp_file("kairo-pkgconfig-out", "txt")
        var err_path = LinkFS::temp_file("kairo-pkgconfig-err", "txt")
        finally {
            if !out_path.empty() {
                LinkFS::remove(out_path)
            }

            if !err_path.empty() {
                LinkFS::remove(err_path)
            }
        }

        if out_path.empty() || err_path.empty() {
            panic PkgConfigError {
                message: "cannot create a temporary file for pkg-config's output",
            }
        }

        var args = cxx::std::vector<string>()
        args.push_back(prog)
        args.push_back("--cflags")
        args.push_back("--libs")
        args.push_back(name)
        // Views of args' own bytes; args is not touched again while refs lives.
        var refs: cxx::std::vector<llvm::StringRef>
        refs.reserve(args.size())
        for var i: usize = 0; i < args.size(); ++i {
            refs.push_back(kairo::sref(args[i]))
        }

        var nout = kairo::std::to_std_string(out_path)
        var nerr = kairo::std::to_std_string(err_path)
        var redir: cxx::std::vector<cxx::std::optional<llvm::StringRef>>
        redir.push_back(cxx::std::optional<llvm::StringRef>(cxx::std::nullopt))
        redir.push_back(
            cxx::std::optional<llvm::StringRef>(llvm::StringRef(nout)),
        )

        redir.push_back(
            cxx::std::optional<llvm::StringRef>(llvm::StringRef(nerr)),
        )

        var emsg:  cxx::std::string
        var failed                  = false
        var rc = llvm::sys::ExecuteAndWait(
            refs[0],
            llvm::ArrayRef<llvm::StringRef>(refs),
            cxx::std::optional<llvm::ArrayRef<llvm::StringRef>>(
                cxx::std::nullopt,
            ),
            llvm::ArrayRef<cxx::std::optional<llvm::StringRef>>(redir),
            0,
            0,
            unsafe &emsg,
            unsafe &failed,
        )

        if failed {
            panic PkgConfigError {
                message: f"cannot run {prog}: {string(unsafe ((emsg.data() as unsafe *const u8) as *const u8), emsg.size())}",
            }
        }

        var text = ""
        if rc != 0 {
            LinkFS::read(err_path, &text)
            var lines = LinkText::split_lines(text)
            var why   = ""
            for var l: string in lines {
                var t = LinkText::trim(l)
                if !t.empty() {
                    why = t
                    break
                }
            }

            var msg = f"pkg-config does not know the package '{name}\x27"
            if !why.empty() {
                msg = msg + f" ({why})"
            }

            panic PkgConfigError { message: msg }
        }

        LinkFS::read(out_path, &text)
        words = HostSystem::split_words(text)
    }

    /// Shell-style words: whitespace separates, a backslash escapes the next
    /// character (pkg-config's spelling of a space in a path), and single or
    /// double quotes group.
    pub static fn split_words(text: string) -> cxx::std::vector<string> {
        var out            = cxx::std::vector<string>()
        var cur            = ""
        var have           = false
        var in_quote       = false
        var quote          = (' ' as u8)
        var i:       usize = 0
        while i < text.size() {
            var c = text[i]
            if in_quote {
                if c == quote {
                    in_quote = false
                } else {
                    cur.push_back(c)
                }

                i += 1
                continue
            }

            if c == ('\\' as u8) && i + 1 < text.size() {
                cur.push_back(text[i + 1])
                have = true
                i += 2
                continue
            }

            var code = ((c) as u32)
            if code == ('"' as u32) || code == ('\'' as u32) {
                quote    = c
                in_quote = true
                have     = true
                i += 1
                continue
            }

            if c == (' ' as u8) || c == ('\t' as u8) || c == ('\n' as u8) || c == ('\r' as u8) {
                if have {
                    out.push_back(cur)
                }

                cur  = ""
                have = false
                i += 1
                continue
            }

            cur.push_back(c)
            have = true
            i += 1
        }

        if have {
            out.push_back(cur)
        }

        return out
    }

    /// # Library resolution

    /// The file lld would take for `-l<name>` searching \p dirs in order:
    /// per directory lib<name>.so, then lib<name>.a (only .a when
    /// \p static_only). "" when none matches.
    static fn find_lib(const name:  string,
                       @inout dirs: cxx::std::vector<string>,
                       static_only: bool) -> string {
        for var d: string in dirs {
            if !static_only {
                var so = LinkText::join(d, f"lib{name}.so")
                if LinkFS::is_file(so) {
                    return so
                }
            }

            var ar = LinkText::join(d, f"lib{name}.a")
            if LinkFS::is_file(ar) {
                return ar
            }
        }

        return ""
    }

    /// Whether \p path names a shared object: foo.so or foo.so.1.2.
    pub static fn is_shared(const path: string) -> bool {
        var base = LinkFS::filename(path)
        return LinkText::ends_with(base, ".so") || LinkText::contains(base, ".so.")
    }

    /// Whether \p path lies under directory \p root (both made real).
    static fn under(const path: string, const root: string) -> bool {
        if root.empty() || root == "/" {
            return false
        }

        var p = LinkFS::real(path)
        var r = LinkText::strip_slash(LinkFS::real(root))
        return LinkText::starts_with(p, r + "/")
    }

    /// # DT_VERNEED

    /// The highest GLIBC_<version> \p path needs and its soname. A linker
    /// script (libc.so is one) or any non-ELF file comes back !ok; so does a
    /// truncated one, rather than reading past its end.
    static fn glibc_needs(const path: string) -> HostLibNeeds {
        var r    = HostLibNeeds{}
        var real = LinkFS::real(path)
        r.soname = LinkFS::filename(real)
        var d = ""
        if !LinkFS::read(real, &d) {
            return r
        }

        if d.size() < 64 {
            return r
        }

        if ((d[0]) as u32) != 127
            || d[1] != ('E' as u8)
            || d[2] != ('L' as u8)
            || d[3] != ('F' as u8) {
            return r
        }

        var cls = ((d[4]) as u32)
        var enc = ((d[5]) as u32)
        if cls != 1 && cls != 2 || enc != 1 && enc != 2 {
            return r
        }

        var w64 = cls == 2
        var be  = enc == 2

        var shoff: u64 = if (w64) => (HostSystem::_rd(&d, 40, 8, be))
                         else => HostSystem::_rd(&d, 32, 4, be)
        var shentsize: u64 = if (w64) => (HostSystem::_rd(&d, 58, 2, be))
                             else => HostSystem::_rd(&d, 46, 2, be)
        var shnum: u64 = if (w64) => (HostSystem::_rd(&d, 60, 2, be))
                         else => HostSystem::_rd(&d, 48, 2, be)
        var size = (d.size() as u64)
        if shoff == 0 || shentsize == 0 || shoff + shentsize * shnum > size {
            return r
        }

        r.ok = true

        for var i: u64 = 0; i < shnum; ++i {
            var sh = shoff + i * shentsize
            var ty = HostSystem::_rd(&d, sh + 4, 4, be)
            var off: u64 = if (w64) => (HostSystem::_rd(&d, sh + 24, 8, be))
                           else => HostSystem::_rd(&d, sh + 16, 4, be)
            var len: u64 = if (w64) => (HostSystem::_rd(&d, sh + 32, 8, be))
                           else => HostSystem::_rd(&d, sh + 20, 4, be)
            var link: u64 = if (w64) => (HostSystem::_rd(&d, sh + 40, 4, be))
                            else => HostSystem::_rd(&d, sh + 24, 4, be)
            if off + len > size {
                continue
            }

            if link >= shnum {
                continue
            }

            var lsh = shoff + link * shentsize
            var str_off: u64 = if (w64) => (HostSystem::_rd(&d, lsh + 24, 8, be))
                               else => HostSystem::_rd(&d, lsh + 16, 4, be)
            var str_len: u64 = if (w64) => (HostSystem::_rd(&d, lsh + 32, 8, be))
                               else => HostSystem::_rd(&d, lsh + 20, 4, be)
            if str_off + str_len > size {
                continue
            }

            if ty == 1879048190 { // SHT_GNU_verneed (0x6ffffffe)
                var vn         = off
                var guard: u32 = 0
                while vn + 16 <= off + len && guard < 4096 {
                    guard += 1
                    var cnt  = HostSystem::_rd(&d, vn + 2, 2, be)
                    var aux  = HostSystem::_rd(&d, vn + 8, 4, be)
                    var next = HostSystem::_rd(&d, vn + 12, 4, be)
                    var va   = vn + aux
                    for var k: u64 = 0; k < cnt && va + 16 <= off + len; ++k {
                        var nm = HostSystem::_cstr(
                            &d,
                            str_off,
                            str_len,
                            HostSystem::_rd(&d, va + 8, 4, be),
                        )

                        var v = HostSystem::glibc_version_of(nm)
                        if !v.empty()
                            && (r.max_glibc.empty() || Toolchain::version_less(r.max_glibc, v)) {
                            r.max_glibc = v
                        }

                        var anext = HostSystem::_rd(&d, va + 12, 4, be)
                        if anext == 0 {
                            break
                        }

                        va = va + anext
                    }

                    if next == 0 {
                        break
                    }

                    vn = vn + next
                }
            } else if ty == 6 { // SHT_DYNAMIC
                var esz: u64 = if (w64) => (16) else => 8
                var e        = off
                while e + esz <= off + len {
                    var tag = HostSystem::_rd(&d, e, ((if (w64) => (8) else => 4) as u64), be)
                    if tag == 0 {
                        break
                    }

                    if tag == 14 { // DT_SONAME
                        var val = HostSystem::_rd(&d, e + esz / 2, ((if (w64) => (8) else => 4) as u64), be)
                        var so = HostSystem::_cstr(&d, str_off, str_len, val)
                        if !so.empty() {
                            r.soname = so
                        }
                    }

                    e = e + esz
                }
            }
        }

        return r
    }

    /// "2.34" for "GLIBC_2.34"; "" for anything else (GLIBC_PRIVATE too).
    static fn glibc_version_of(name: string) -> string {
        if !LinkText::starts_with(name, "GLIBC_") {
            return ""
        }

        if name.size() < 7 {
            return ""
        }

        if name[6] < ('0' as u8) || name[6] > ('9' as u8) {
            return ""
        }

        return LinkText::slice(name, 6, name.size())
    }

    /// \p n bytes at \p off as an unsigned integer; 0 past the end.
    priv static fn _rd(@inout d: string, off: u64, n: u64, be: bool) -> u64 {
        if off + n > (d.size() as u64) {
            return 0
        }

        var v: u64 = 0
        for var i: u64 = 0; i < n; ++i {
            var idx: u64 = off + i
            if be {
                idx = off + (n - 1 - i)
            }

            var bv = ((d[idx as usize]) as u64)
            v = v | bv << 8 * i
        }

        return v
    }

    /// The NUL-terminated string at \p idx of the string table at
    /// [\p base, \p base + \p len); "" when out of range.
    priv static fn _cstr(@inout d: string, base: u64, len: u64, idx: u64) -> string {
        if idx >= len {
            return ""
        }

        var s   = ""
        var p   = base + idx
        var end = base + len
        while p < end && ((d[p as usize]) as u32) != 0 {
            s.push_back(d[p as usize])
            p += 1
        }

        return s
    }
}
