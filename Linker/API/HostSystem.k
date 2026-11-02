/// --- The Kairo Project -------------------- Linker/API/HostSystem.k ----- ///
///
///   \brief What the build machine itself has: its C library flavour and
///          its system include and library dirs.
///
///   \detail
///     A default build on a Linux host compiles against the bundled glibc
///     2.31 sysroot (the "floor") and only then searches the host's system
///     dirs, so a header or library the floor lacks (zlib.h, libcurl.so)
///     comes from the host while <stdio.h> and libc never do. A host shared
///     library was built against the host's own, newer glibc, whose symbol
///     versions the floor's libc.so stubs lack; a link that takes one is
///     told so (--allow-shlib-undefined).
///
///     Only what EXISTS is returned, deduplicated by real path: on a merged-
///     /usr host /lib, /lib64 and /usr/lib64 are all /usr/lib, and a
///     multiarch dir is a Debian-ism other distros do not have.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Linker::API::Text::*;
import Linker::API::FS::*;
import Linker::API::Toolchain::*;

ffi "c++" import "llvm/ADT/StringRef.h";
ffi "c++" import "llvm/Support/Program.h";

class HostSystem {
    // --- The host's C library --------------------------------------------

    /// "glibc", "musl" or "" for the Linux host's C library, by its dynamic
    /// loader: the compiler's own process triple is fixed when it is built
    /// and says nothing about the machine it runs on. glibc wins when both
    /// are installed (a glibc distro with musl-gcc beside it). \p arch is
    /// Toolchain's canonical spelling, \p hf whether 32-bit ARM is hard-float.
    static fn host_libc(arch: string, hf: bool) -> string {
        var env_g = ("gnueabihf") if (hf) else ("gnu");
        var env_m = ("musleabihf") if (hf) else ("musl");
        var gl = Toolchain::dynamic_linker_for(arch, "linux", env_g, "glibc");
        if (!gl.empty()) && LinkFS::exists(gl) { return "glibc"; }
        var ml = Toolchain::dynamic_linker_for(arch, "linux", env_m, "musl");
        if (!ml.empty()) && LinkFS::exists(ml) { return "musl"; }
        return "";
    }

    // --- System dirs, in clang's Linux order ------------------------------

    /// /usr/local/include, /usr/include/<multiarch>, /usr/include.
    static fn include_dirs(arch: string, env: string) -> vec::<string> {
        var out  = vec::<string>();
        var seen = vec::<string>();
        var ma = Toolchain::multiarch(arch, "linux", env);
        HostSystem::add_dir(out, seen, "/usr/local/include");
        if !ma.empty() { HostSystem::add_dir(out, seen, f"/usr/include/{ma}"); }
        HostSystem::add_dir(out, seen, "/usr/include");
        return out;
    }

    /// /usr/local/lib, /usr/lib/<multiarch>, /usr/lib64, /usr/lib,
    /// /lib/<multiarch>, /lib64, /lib. lib64 only for a 64-bit target: it is
    /// where Fedora and SUSE keep 64-bit libraries, and the wrong class
    /// for 32-bit ones.
    static fn lib_dirs(arch: string, env: string, is64: bool) -> vec::<string> {
        var out  = vec::<string>();
        var seen = vec::<string>();
        var ma = Toolchain::multiarch(arch, "linux", env);
        HostSystem::add_dir(out, seen, "/usr/local/lib");
        if !ma.empty() { HostSystem::add_dir(out, seen, f"/usr/lib/{ma}"); }
        if is64 { HostSystem::add_dir(out, seen, "/usr/lib64"); }
        HostSystem::add_dir(out, seen, "/usr/lib");
        if !ma.empty() { HostSystem::add_dir(out, seen, f"/lib/{ma}"); }
        if is64 { HostSystem::add_dir(out, seen, "/lib64"); }
        HostSystem::add_dir(out, seen, "/lib");
        return out;
    }

    /// Appends \p d to \p out when it is a directory whose real path is not
    /// in \p seen yet.
    static fn add_dir(out: ref!(vec::<string>), seen: ref!(vec::<string>), d: string) {
        if d.empty() || (!LinkFS::is_dir(d)) { return; }
        var r = LinkFS::real(d);
        for s: string in seen { if s == r { return; } }
        seen.push_back(r);
        out.push_back(d);
    }

    /// An environment search-path list (CPATH, LIBRARY_PATH), split on ':'
    /// as clang's driver splits it: an empty element is the current
    /// directory. "" when unset.
    static fn env_list(name: string) -> vec::<string> {
        var out = vec::<string>();
        var v = LinkFS::env(name);
        if v.empty() { return out; }
        var b: usize = 0;
        for var i: usize = 0; i <= v.size(); ++i {
            if (i == v.size()) || (v[i] == ':') {
                var part = LinkText::slice(v, b, i);
                if part.empty() { part = "."; }
                out.push_back(part);
                b = i + 1;
            }
        }
        return out;
    }

    /// Shell-style words: whitespace separates, a backslash escapes the next
    /// character (pkg-config's spelling of a space in a path), and single or
    /// double quotes group.
    static fn split_words(text: string) -> vec::<string> {
        var out = vec::<string>();
        var cur = "";
        var have = false;
        var in_quote = false;
        var quote = ' ';
        var i: usize = 0;
        while i < text.size() {
            var c = text[i];
            if in_quote {
                if c == quote { in_quote = false; }
                else          { cur += c; }
                i += 1;
                continue;
            }
            if (c == '\\') && ((i + 1) < text.size()) {
                cur += text[i + 1];
                have = true;
                i += 2;
                continue;
            }
            var code = static_cast::<u32>(static_cast::<u8>(c));
            if (code == 34) || (code == 39) {   // a double or single quote
                quote = c;
                in_quote = true;
                have  = true;
                i += 1;
                continue;
            }
            if (c == ' ') || (c == '\t') || (c == '\n') || (c == '\r') {
                if have { out.push_back(cur); }
                cur  = "";
                have = false;
                i += 1;
                continue;
            }
            cur += c;
            have = true;
            i += 1;
        }
        if have { out.push_back(cur); }
        return out;
    }

    // --- Library resolution -------------------------------------------------

    /// The file lld would take for `-l<name>` searching \p dirs in order:
    /// per directory lib<name>.so, then lib<name>.a (only .a when
    /// \p static_only). "" when none matches.
    static fn find_lib(name: string, dirs: ref!(vec::<string>), static_only: bool) -> string {
        for d: string in dirs {
            if !static_only {
                var so = LinkText::join(d, f"lib{name}.so");
                if LinkFS::is_file(so) { return so; }
            }
            var ar = LinkText::join(d, f"lib{name}.a");
            if LinkFS::is_file(ar) { return ar; }
        }
        return "";
    }

    /// Whether \p path names a shared object: foo.so or foo.so.1.2.
    static fn is_shared(path: string) -> bool {
        var base = LinkFS::filename(path);
        return LinkText::ends_with(base, ".so") || LinkText::contains(base, ".so.");
    }

    /// Whether \p path lies under directory \p root (both made real).
    static fn under(path: string, root: string) -> bool {
        if root.empty() || (root == "/") { return false; }
        var p = LinkFS::real(path);
        var r = LinkText::strip_slash(LinkFS::real(root));
        return LinkText::starts_with(p, r + "/");
    }

        if d.size() < 64 { return r; }
        if (static_cast::<u32>(static_cast::<u8>(d[0])) != 127) || (d[1] != 'E') || (d[2] != 'L') || (d[3] != 'F') {
            return r;
        }
        var cls = static_cast::<u32>(static_cast::<u8>(d[4]));
        var enc = static_cast::<u32>(static_cast::<u8>(d[5]));
        if ((cls != 1) && (cls != 2)) || ((enc != 1) && (enc != 2)) { return r; }
        var w64 = cls == 2;
        var be  = enc == 2;

        var shoff:     u64 = (HostSystem::_rd(d, 40, 8, be)) if (w64) else (HostSystem::_rd(d, 32, 4, be));
        var shentsize: u64 = (HostSystem::_rd(d, 58, 2, be)) if (w64) else (HostSystem::_rd(d, 46, 2, be));
        var shnum:     u64 = (HostSystem::_rd(d, 60, 2, be)) if (w64) else (HostSystem::_rd(d, 48, 2, be));
        var size = static_cast::<u64>(d.size());
        if (shoff == 0) || (shentsize == 0) || ((shoff + shentsize * shnum) > size) { return r; }
        (r.ok) = true;

        for var i: u64 = 0; i < shnum; ++i {
            var sh = shoff + i * shentsize;
            var ty   = HostSystem::_rd(d, sh + 4, 4, be);
            var off:  u64 = (HostSystem::_rd(d, sh + 24, 8, be)) if (w64) else (HostSystem::_rd(d, sh + 16, 4, be));
            var len:  u64 = (HostSystem::_rd(d, sh + 32, 8, be)) if (w64) else (HostSystem::_rd(d, sh + 20, 4, be));
            var link: u64 = (HostSystem::_rd(d, sh + 40, 4, be)) if (w64) else (HostSystem::_rd(d, sh + 24, 4, be));
            if (off + len) > size { continue; }
            if link >= shnum { continue; }
            var lsh = shoff + link * shentsize;
            var str_off: u64 = (HostSystem::_rd(d, lsh + 24, 8, be)) if (w64) else (HostSystem::_rd(d, lsh + 16, 4, be));
            var str_len: u64 = (HostSystem::_rd(d, lsh + 32, 8, be)) if (w64) else (HostSystem::_rd(d, lsh + 20, 4, be));
            if (str_off + str_len) > size { continue; }

            if ty == 1879048190 {   // SHT_GNU_verneed (0x6ffffffe)
                var vn = off;
                var guard: u32 = 0;
                while ((vn + 16) <= (off + len)) && (guard < 4096) {
                    guard += 1;
                    var cnt  = HostSystem::_rd(d, vn + 2, 2, be);
                    var aux  = HostSystem::_rd(d, vn + 8, 4, be);
                    var next = HostSystem::_rd(d, vn + 12, 4, be);
                    var va = vn + aux;
                    for var k: u64 = 0; (k < cnt) && ((va + 16) <= (off + len)); ++k {
                        var nm = HostSystem::_cstr(d, str_off, str_len, HostSystem::_rd(d, va + 8, 4, be));
                        var v  = HostSystem::glibc_version_of(nm);
                        if (!v.empty()) && (r.max_glibc.empty() || Toolchain::version_less(r.max_glibc, v)) {
                            (r.max_glibc) = v;
                        }
                        var anext = HostSystem::_rd(d, va + 12, 4, be);
                        if anext == 0 { break; }
                        va = va + anext;
                    }
                    if next == 0 { break; }
                    vn = vn + next;
                }
            } else if ty == 6 {     // SHT_DYNAMIC
                var esz: u64 = (16) if (w64) else (8);
                var e = off;
                while (e + esz) <= (off + len) {
                    var tag = HostSystem::_rd(d, e, (8) if (w64) else (4), be);
                    if tag == 0 { break; }
                    if tag == 14 {      // DT_SONAME
                        var val = HostSystem::_rd(d, e + esz / 2, (8) if (w64) else (4), be);
                        var so = HostSystem::_cstr(d, str_off, str_len, val);
                        if !so.empty() { (r.soname) = so; }
                    }
                    e = e + esz;
                }
            }
        }
        return r;
    }

    /// "2.34" for "GLIBC_2.34"; "" for anything else (GLIBC_PRIVATE too).
    static fn glibc_version_of(name: string) -> string {
        if !LinkText::starts_with(name, "GLIBC_") { return ""; }
        if name.size() < 7 { return ""; }
        if (name[6] < '0') || (name[6] > '9') { return ""; }
        return LinkText::slice(name, 6, name.size());
    }

    /// \p n bytes at \p off as an unsigned integer; 0 past the end.
    priv static fn _rd(d: ref!(string), off: u64, n: u64, be: bool) -> u64 {
        if (off + n) > static_cast::<u64>(d.size()) { return 0; }
        var v: u64 = 0;
        for var i: u64 = 0; i < n; ++i {
            var idx: u64 = off + i;
            if be { idx = off + (n - 1 - i); }
            var bv = static_cast::<u64>(static_cast::<u8>(d[static_cast::<usize>(idx)]));
            v = v | (bv << (8 * i));
        }
        return v;
    }

    /// The NUL-terminated string at \p idx of the string table at
    /// [\p base, \p base + \p len); "" when out of range.
    priv static fn _cstr(d: ref!(string), base: u64, len: u64, idx: u64) -> string {
        if idx >= len { return ""; }
        var s = "";
        var p = base + idx;
        var end = base + len;
        while (p < end) && (static_cast::<u32>(static_cast::<u8>(d[static_cast::<usize>(p)])) != 0) {
            s += d[static_cast::<usize>(p)];
            p += 1;
        }
        return s;
    }
}
}
