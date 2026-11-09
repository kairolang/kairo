/// --- The Kairo Project ---------------------------- Providers/Glibc.k --- ///
///
///   The glibc provider (SysRoot.md 4.4, 4.6): the shipped headers and crt
///   objects as they are, and link-time stand-ins for the shared libraries.
///
///   A stub DSO is generated from glibc/<X.Y>/<arch>/abilist/: one C file
///   defining every public versioned symbol, bound with .symver, and a
///   version script declaring the library's version nodes in verdef order.
///   It carries the same SONAME and the same versioned dynsym (name, node,
///   @ or @@, function / object / TLS, object size) as the real library,
///   which is all a link reads; it is never run. Scripts/glibc_stubs.py is
///   the reference and FORMAT.md the input contract (abilist, .compat,
///   libs.toml).
///
///   libc.so and (where libmvec exists) libm.so are the GNU ld scripts glibc
///   installs, names only, so the root has no absolute path in it.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "algorithm"
ffi "c++" import "vector"

import API::FS::LinkFS
import API::SysrootManifest::{
    TomlLite,
    TomlValue,
}
import API::Text::LinkText
import Sysroot::Outcome::SysOutcome
import Sysroot::Provider::{
    StageCtx,
    SysrootProvider,
}
import Sysroot::SysRun::{
    SysJobs,
    SysRun,
}
import Sysroot::SysUtil::SysUtil

/// One abilist line: `VERSION SYMBOL F|D|T|A [0x<size>]`, plus whether the
/// symbol is the default (@@) at that version.
pub struct GlibcSym {
    pub var version: string
    pub var name:    string
    pub var kind:    string
    pub var size:    string         ///< as written ("0x10"); "" for F and A
    pub var dflt:    bool   = false
}

/// One [<stem>] of abilist/libs.toml.
pub struct GlibcLib {
    pub var stem:     string
    pub var soname:   string
    pub var versions: cxx::std::vector<string>
}

pub class GlibcProvider derives SysrootProvider {
    pub fn GlibcProvider(self) = default

    pub override fn id(self) -> string {
        return "glibc"
    }

    /// The shipped include/ (multiarch dir kept); the UAPI only when that
    /// include/ does not already carry the one glibc was configured with.
    pub override fn headers(self,
                            ctx:        *StageCtx,
                            const dst:  string,
                            @inout out: SysOutcome) -> bool {
        var from = ctx->share_path(ctx->recipe.str("libc", "include"))
        if !LinkFS::is_dir(from) {
            return out.refuse(f"share input {from} missing", "")
        }

        var inc  = dst + "/include"
        var none = cxx::std::vector<string>()
        if !SysRun::copy_tree(from, inc, &none) {
            return out.fail(f"cannot copy {from}", "")
        }

        if LinkFS::is_file(inc + "/linux/version.h") {
            return true
        }

        var uapi = cxx::std::vector<string>()
        uapi.push_back(ctx->share + "/linux-uapi/generic")
        uapi.push_back(ctx->share + "/linux-uapi/asm/" + ctx->target.arch)
        for var u: string in uapi {
            if !LinkFS::is_dir(u) || !SysRun::copy_tree(u, inc, &none) {
                return out.fail(f"cannot copy {u} into {inc}", "")
            }
        }

        return true
    }

    pub override fn libs(self, ctx: *StageCtx, const dst: string, @inout out: SysOutcome) -> bool {
        var crt  = ctx->share_path(ctx->recipe.str("libc", "crt"))
        var ns   = ctx->share_path(ctx->recipe.str("libc", "nonshared"))
        var abi  = ctx->share_path(ctx->recipe.str("libc", "abilist"))
        var fmt  = GlibcProvider::output_format(ctx->target.arch)
        var lib  = dst + "/lib"
        var none = cxx::std::vector<string>()
        if !LinkFS::is_dir(crt) || !LinkFS::is_file(ns) || !LinkFS::is_file(abi + "/libs.toml") {
            return out.refuse(
                f"share input {LinkFS::parent(crt)} is missing crt/, libc_nonshared.a or abilist/",
                "",
            )
        }

        if fmt.empty() {
            return out.refuse(
                f"glibc: no linker-script OUTPUT_FORMAT known for {ctx->target.arch}",
                "",
            )
        }

        if !SysRun::copy_tree(crt, lib, &none)
            || !SysRun::put_file(ns, lib + "/libc_nonshared.a", false) {
            return out.fail(f"cannot copy the crt objects into {lib}", "")
        }

        var libs = cxx::std::vector<GlibcLib>()
        var why  = ""
        if !GlibcProvider::read_libs(abi + "/libs.toml", &libs, &why) {
            return out.refuse(f"share input {abi}/libs.toml: {why}", "")
        }

        var work = ctx->stage + "/stubs"
        var jobs = SysJobs()
        for var l: GlibcLib in libs {
            var ab = ""
            var co = ""
            if !LinkFS::read(abi + "/" + l.stem + ".abilist", &ab) {
                return out.refuse(f"share input {abi}/{l.stem}.abilist missing", "")
            }

            LinkFS::read(abi + "/" + l.stem + ".compat", &co)
            var syms = GlibcProvider::parse_abilist(ab, co)
            var c    = ""
            var map  = ""
            GlibcProvider::stub_sources(&syms, &l.versions, &c, &map)
            var dir = work + "/" + l.stem
            LinkFS::make_dirs(dir)
            if !LinkFS::write(dir + "/stub.c", c) || !LinkFS::write(dir + "/stub.map", map) {
                return out.fail(f"cannot write {dir}", "")
            }

            // Compiled by kcc, linked by kld (4.6): a kcc link step would
            // also link the Kairo runtime, which a stub must not carry.
            var argv = ctx->kcc(ctx->stage)
            argv.push_back("-fPIC")
            argv.push_back("-O0")
            argv.push_back("-w")
            argv.push_back("-c")
            argv.push_back("-o")
            argv.push_back(dir + "/stub.o")
            argv.push_back(dir + "/stub.c")
            if !jobs.add(&argv, f"{ctx->log_dir}/stub-{l.stem}.cc.log") {
                break
            }
        }

        if !jobs.wait_all() {
            return out.fail(f"glibc stub compile failed, see {jobs.failed_log}", "")
        }

        var links = SysJobs()
        for var l: GlibcLib in libs {
            var dir  = work + "/" + l.stem
            var argv = cxx::std::vector<string>()
            argv.push_back(ctx->tool("kld"))
            argv.push_back("-flavor")
            argv.push_back("gnu")
            argv.push_back("-shared")
            argv.push_back("-soname")
            argv.push_back(l.soname)
            argv.push_back("--version-script")
            argv.push_back(dir + "/stub.map")
            argv.push_back("-o")
            argv.push_back(lib + "/" + GlibcProvider::file_name(&l, ctx->target.libc_version))
            argv.push_back(dir + "/stub.o")
            if !links.add(&argv, f"{ctx->log_dir}/stub-{l.stem}.ld.log") {
                break
            }
        }

        if !links.wait_all() {
            return out.fail(f"glibc stub link failed, see {links.failed_log}", "")
        }

        LinkFS::remove_tree(work)
        for var l: GlibcLib in libs {
            var file = GlibcProvider::file_name(&l, ctx->target.libc_version)
            if file != l.soname && !SysRun::symlink(file, lib + "/" + l.soname) {
                return out.fail(f"cannot link {lib}/{l.soname}", "")
            }
        }

        var libc    = GlibcProvider::_soname(&libs, "libc")
        var ld      = GlibcProvider::_soname(&libs, "ld")
        var libm    = GlibcProvider::_soname(&libs, "libm")
        var libmvec = GlibcProvider::_soname(&libs, "libmvec")
        if libc.empty() || ld.empty() || libm.empty() {
            return out.refuse(f"share input {abi}/libs.toml lacks libc, ld or libm", "")
        }

        var script = "/* GNU ld script\n   Use the shared library, but some functions are only in\n   the static library, so try that secondarily.  */\n"
        script += f"OUTPUT_FORMAT({fmt})\nGROUP ( {libc} libc_nonshared.a  AS_NEEDED ( {ld} ) )\n"
        if !LinkFS::write(lib + "/libc.so", script) {
            return out.fail(f"cannot write {lib}/libc.so", "")
        }

        // libm.so is a script only where libmvec exists to pull in, as
        // glibc installs it; elsewhere the plain dev link.
        if !libmvec.empty() {
            var ms = f"/* GNU ld script\n*/\nOUTPUT_FORMAT({fmt})\nGROUP ( {libm}  AS_NEEDED ( {libmvec} ) )\n"
            if !LinkFS::write(lib + "/libm.so", ms) {
                return out.fail(f"cannot write {lib}/libm.so", "")
            }
        } else if !SysRun::symlink(libm, lib + "/libm.so") {
            return out.fail(f"cannot link {lib}/libm.so", "")
        }

        // The dev links -l<name> resolves through, for every other library.
        for var l: GlibcLib in libs {
            if l.stem == "libc" || l.stem == "ld" || l.stem == "libm" {
                continue
            }

            if !SysRun::symlink(l.soname, lib + "/" + l.stem + ".so") {
                return out.fail(f"cannot link {lib}/{l.stem}.so", "")
            }
        }

        // Debian's armhf libc6 also installs the old loader name, which
        // binaries linked before the hard-float split ask for.
        if ld == "ld-linux-armhf.so.3" && !SysRun::symlink(ld, lib + "/ld-linux.so.3") {
            return out.fail(f"cannot link {lib}/ld-linux.so.3", "")
        }

        return true
    }

    /// The file a library's stub is written to. Before 2.34 glibc installs
    /// lib<x>-<ver>.so with the SONAME a link to it (ld: ld-<ver>.so); from
    /// 2.34 the SONAME is the file.
    pub static fn file_name(l: *GlibcLib, const version: string) -> string {
        if version.empty() || !SysUtil::version_less(version, "2.34") {
            return l->soname
        }

        return l->stem + "-" + version + ".so"
    }

    /// The linker scripts' OUTPUT_FORMAT, as glibc writes it per arch; ""
    /// for an arch with no glibc port here.
    pub static fn output_format(const arch: string) -> string {
        if arch == "x86_64" {
            return "elf64-x86-64"
        }

        if arch == "i686" {
            return "elf32-i386"
        }

        if arch == "aarch64" {
            return "elf64-littleaarch64"
        }

        if arch == "armv7" {
            return "elf32-littlearm"
        }

        if arch == "riscv64" {
            return "elf64-littleriscv"
        }

        return ""
    }

    /// abilist/libs.toml: `[<stem>]` tables with soname and versions.
    pub static fn read_libs(const path:  string,
                            @inout libs: cxx::std::vector<GlibcLib>,
                            @inout why:  string) -> bool {
        var text = ""
        if !LinkFS::read(path, &text) {
            why = "cannot read the file"
            return false
        }

        var toml = TomlLite(text)
        var key  = ""
        var val  = TomlValue{}
        while toml.next(&key, &val) {
            if toml.table.empty() {
                continue
            }

            if libs.empty() || libs[libs.size() - 1].stem != toml.table {
                var l = GlibcLib{}
                l.stem = toml.table
                libs.push_back(l)
            }

            if key == "soname" && val.kind == 1 {
                libs[libs.size() - 1].soname = val.text
            } else if key == "versions" && val.kind == 3 {
                libs[libs.size() - 1].versions = val.list
            }
        }

        if !toml.error.empty() {
            why = toml.error
            return false
        }

        return true
    }

    /// abilist + compat -> symbols with their @ / @@ decided: the newest
    /// version of a name is its default, unless compat says otherwise.
    pub static fn parse_abilist(const text:   string,
                                const compat: string) -> cxx::std::vector<GlibcSym> {
        var syms = cxx::std::vector<GlibcSym>()
        for var line: string in LinkText::split_lines(text) {
            var w = GlibcProvider::_words(line)
            if w.size() < 3 || LinkText::starts_with(w[0], "#") {
                continue
            }

            var s = GlibcSym{}
            s.version = w[0]
            s.name    = w[1]
            s.kind    = w[2]
            if w.size() > 3 {
                s.size = w[3]
            }

            syms.push_back(s)
        }

        // default_rule: name -> its newest version.
        var names  = cxx::std::vector<string>()
        var newest = cxx::std::vector<string>()
        for var s: GlibcSym in syms {
            var found = false
            for var i: usize = 0; i < names.size(); ++i {
                if names[i] == s.name {
                    found = true
                    if GlibcProvider::ver_less(newest[i], s.version) {
                        newest[i] = s.version
                    }

                    break
                }
            }

            if !found {
                names.push_back(s.name)
                newest.push_back(s.version)
            }
        }

        var over_keys = cxx::std::vector<string>()
        var over_vals = cxx::std::vector<string>()
        for var line: string in LinkText::split_lines(compat) {
            var w = GlibcProvider::_words(line)
            if w.size() == 3 {
                over_keys.push_back(w[0] + " " + w[1])
                over_vals.push_back(w[2])
            }
        }

        for var i: usize = 0; i < syms.size(); ++i {
            var d = false
            for var j: usize = 0; j < names.size(); ++j {
                if names[j] == syms[i].name {
                    d = newest[j] == syms[i].version
                    break
                }
            }

            var k = syms[i].version + " " + syms[i].name
            for var j: usize = 0; j < over_keys.size(); ++j {
                if over_keys[j] == k {
                    d = over_vals[j] == "@@"
                }
            }

            syms[i].dflt = d
        }

        return syms
    }

    /// The stub's C source and version script (glibc_stubs.py stub_sources).
    pub static fn stub_sources(@inout syms:     cxx::std::vector<GlibcSym>,
                               @inout versions: cxx::std::vector<string>,
                               @inout c:        string,
                               @inout map:      string) {
        var q = "\x22"
        c = "/* generated by ksys (Linker/Sysroot/Providers/Glibc.k): a link-time stand-in, never run */\n"
        // Per node, the names its `global:` must list: the version-name
        // symbol, and every non-default name (lld would otherwise apply
        // `local: *` to a name@VER the node does not name).
        var abs_nodes = cxx::std::vector<string>()
        var abs_names = cxx::std::vector<string>()
        for var i: usize = 0; i < syms.size(); ++i {
            var e = syms[i]
            if e.kind == "A" {
                // lld does not invent GNU ld's version-name symbols: define
                // each absolute, and the script binds it to its node.
                c += "__asm__(" + q + ".globl \\" + q + e.name + "\\" + q + "\\n.set \\" + q + e.name + "\\" + q + ", 0" + q + ");\n"
                abs_nodes.push_back(e.version)
                abs_names.push_back(e.name)
                continue
            }

            var s = f"__kairo_stub_{i}"
            if e.kind == "F" {
                c += "void " + s + "(void) {}\n"
            } else if e.kind == "T" {
                c += "__thread char " + s + "[" + e.size + "] = {0};\n"
            } else {
                c += "char " + s + "[" + e.size + "] = {0};\n"
            }

            var at = if (e.dflt) => ("@@") else => "@"
            c += "__asm__(" + q + ".symver " + s + ", " + e.name + at + e.version + q + ");\n"
            if !e.dflt {
                abs_nodes.push_back(e.version)
                abs_names.push_back(e.name)
            }
        }

        // Nodes: libs.toml's order, then any other the symbols name.
        var nodes = versions
        var extra = cxx::std::vector<string>()
        for var e: GlibcSym in syms {
            if !SysUtil::contains(&nodes, e.version) && !SysUtil::contains(&extra, e.version) {
                extra.push_back(e.version)
            }
        }

        for var i: usize = 1; i < extra.size(); ++i {
            var j = i
            while j > 0 && GlibcProvider::ver_less(extra[j], extra[j - 1]) {
                var t = extra[j]
                extra[j]     = extra[j - 1]
                extra[j - 1] = t
                j -= 1
            }
        }

        for var x: string in extra {
            nodes.push_back(x)
        }

        map = ""
        var prev = ""
        for var i: usize = 0; i < nodes.size(); ++i {
            var v    = nodes[i]
            var body = ""
            for var j: usize = 0; j < abs_nodes.size(); ++j {
                if abs_nodes[j] == v {
                    body += "  " + abs_names[j] + ";\n"
                }
            }

            if !body.empty() {
                body = "  global:\n" + body
            }

            if i == 0 {
                body += "  local: *;\n"
            }

            map += v + " {\n" + body + "}"
            map += if (prev.empty()) => (";\n") else => " " + prev + ";\n"
            prev = v
        }
    }

    /// glibc_stubs.py _ver_key order: the name part, then the numbers
    /// (GLIBC_2.2.5 < GLIBC_2.10).
    pub static fn ver_less(const a: string, const b: string) -> bool {
        var pa = GlibcProvider::_ver_prefix(a)
        var pb = GlibcProvider::_ver_prefix(b)
        if pa != pb {
            return pa < pb
        }

        if pa == a || pb == b {
            return false
        }

        return SysUtil::version_less(
            LinkText::slice(a, GlibcProvider::_ver_digits(a), a.size()),
            LinkText::slice(b, GlibcProvider::_ver_digits(b), b.size()),
        )
    }

    /// Where the trailing dotted number of \p v starts; v.size() if none.
    priv static fn _ver_digits(const v: string) -> usize {
        var i = v.size()
        while i > 0
            && (v[i - 1] >= ('0' as u8) && v[i - 1] <= ('9' as u8) || v[i - 1] == ('.' as u8)) {
            i -= 1
        }

        while i < v.size() && v[i] == ('.' as u8) {
            i += 1
        }

        return i
    }

    /// The name part of a version node, one `_` before the number dropped.
    priv static fn _ver_prefix(const v: string) -> string {
        var d = GlibcProvider::_ver_digits(v)
        if d >= v.size() {
            return v
        }

        var p = LinkText::slice(v, 0, d)
        if LinkText::ends_with(p, "_") {
            p = LinkText::slice(p, 0, p.size() - 1)
        }

        return p
    }

    priv static fn _soname(@inout libs: cxx::std::vector<GlibcLib>, const stem: string) -> string {
        for var l: GlibcLib in libs {
            if l.stem == stem {
                return l.soname
            }
        }

        return ""
    }

    priv static fn _words(const line: string) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        var cur = ""
        for var i: usize = 0; i < line.size(); ++i {
            var ch = line[i]
            if ch == (' ' as u8) || ch == ('\t' as u8) || ch == ('\r' as u8) {
                if !cur.empty() {
                    out.push_back(cur)
                    cur = ""
                }
            } else {
                cur.push_back(ch)
            }
        }

        if !cur.empty() {
            out.push_back(cur)
        }

        return out
    }
}
