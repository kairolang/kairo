/// --- The Kairo Project ----------------------------- Providers/Musl.k --- ///
///
///   The musl provider: musl from the shipped source tree (SysRoot.md 4.4 and
///   4.6), with no make and no shell.
///
///   headers is musl's `make install-headers ARCH=<a>` restated: include/,
///   then arch/generic/bits and arch/<a>/bits over include/bits, then the two
///   generated headers (bits/alltypes.h from tools/mkalltypes.sed, bits/
///   syscall.h from syscall.h.in), then the kernel UAPI from linux-uapi/.
///
///   libs is musl's Makefile source selection and compile rules, run as a
///   kcc loop: every src/*/<a>/*.[csS] replaces the generic src/*/*.c of the
///   same stem, libc.a holds src/ and compat/ objects (all -fPIC: with -fPIC
///   in CFLAGS configure sets AOBJS = LOBJS), crt objects get -DCRT, the
///   NOSSP list gets -fno-stack-protector. The flag sets are what musl's
///   configure decides for kcc (it decides the same on every arch ksys
///   builds; only ARCH and SUBARCH differ), so configure itself never runs.
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
import API::Text::LinkText
import Sysroot::Outcome::SysOutcome
import Sysroot::Provider::{
    StageCtx,
    SysrootProvider,
}
import Sysroot::Share::SysQuirk
import Sysroot::SysRun::{
    SysJobs,
    SysRun,
}
import Sysroot::SysUtil::SysUtil

/// configure's CFLAGS_C99FSE for kcc.
fn musl_c99fse() -> cxx::std::vector<string> {
    var v = cxx::std::vector<string>()
    v.push_back("-std=c99")
    v.push_back("-nostdinc")
    v.push_back("-ffreestanding")
    v.push_back("-fexcess-precision=standard")
    v.push_back("-frounding-math")
    v.push_back("-fno-strict-aliasing")
    v.push_back("-Wa,--noexecstack")
    return v
}

/// configure's CFLAGS_AUTO for kcc.
fn musl_cflags_auto() -> cxx::std::vector<string> {
    var v = cxx::std::vector<string>()
    v.push_back("-pipe")
    v.push_back("-fomit-frame-pointer")
    v.push_back("-fno-unwind-tables")
    v.push_back("-fno-asynchronous-unwind-tables")
    v.push_back("-ffunction-sections")
    v.push_back("-fdata-sections")
    v.push_back("-Wno-pointer-to-int-cast")
    v.push_back("-Werror=implicit-function-declaration")
    v.push_back("-Werror=implicit-int")
    v.push_back("-Werror=pointer-sign")
    v.push_back("-Werror=pointer-arith")
    v.push_back("-Werror=int-conversion")
    v.push_back("-Werror=incompatible-pointer-types")
    v.push_back("-Waddress")
    v.push_back("-Warray-bounds")
    v.push_back("-Wchar-subscripts")
    v.push_back("-Wduplicate-decl-specifier")
    v.push_back("-Winit-self")
    v.push_back("-Wreturn-type")
    v.push_back("-Wsequence-point")
    v.push_back("-Wstrict-aliasing")
    v.push_back("-Wunused-function")
    v.push_back("-Wunused-label")
    v.push_back("-Wunused-variable")
    return v
}

/// The Makefile's NOSSP_OBJS filter over libc objects (crt objects always).
fn musl_nossp(const stem: string) -> bool {
    return stem == "__libc_start_main"
        || stem == "__init_tls"
        || stem == "__stack_chk_fail"
        || stem == "__set_thread_area"
        || stem == "memset"
        || stem == "memcpy"
}

/// One object of the Makefile's ALL_OBJS: where it comes from.
pub struct MuslObj {
    pub var obj: string ///< "src/string/x86_64/memcpy" (no extension), as obj/<obj>.o
    pub var src: string ///< the source, relative to the musl tree
}

pub class MuslProvider derives SysrootProvider {
    pub fn MuslProvider(self) = default

    pub override fn id(self) -> string {
        return "musl"
    }

    /// Stage libc-headers: install-headers, then the UAPI.
    pub override fn headers(self,
                            ctx:        *StageCtx,
                            const dst:  string,
                            @inout out: SysOutcome) -> bool {
        var ma  = ""
        var src = ""
        if !MuslProvider::_resolve(ctx, &ma, &src, &out) {
            return false
        }

        var inc = dst + "/include"
        if !MuslProvider::install_headers(src, ma, inc) {
            return out.fail(f"musl install-headers ARCH={ma} into {inc} failed", "")
        }

        var none = cxx::std::vector<string>()
        for var u: string in ctx->recipe.list("libc", "uapi") {
            var from = ctx->share_path(u)
            if !LinkFS::is_dir(from) {
                return out.refuse(f"share input {from} missing", "")
            }

            if !SysRun::copy_tree(from, inc, &none) {
                return out.fail(f"cannot copy {from} into {inc}", "")
            }
        }

        return true
    }

    /// Stage libc-libs: libc.a, the crt objects and the empty libraries.
    pub override fn libs(self, ctx: *StageCtx, const dst: string, @inout out: SysOutcome) -> bool {
        var ma  = ""
        var src = ""
        if !MuslProvider::_resolve(ctx, &ma, &src, &out) {
            return false
        }

        var obj = ctx->stage + "/obj"
        var gen = obj + "/include/bits"
        if !LinkFS::make_dirs(gen) || !LinkFS::make_dirs(obj + "/src/internal") {
            return out.fail(f"cannot create {obj}", "")
        }

        if !LinkFS::write(gen + "/alltypes.h", MuslProvider::alltypes(src, ma))
            || !LinkFS::write(gen + "/syscall.h", MuslProvider::syscall_h(src, ma)) {
            return out.fail(f"cannot write the generated headers under {gen}", "")
        }

        var ver = ""
        LinkFS::read(src + "/VERSION", &ver)
        var vh = f"#define VERSION \x22{LinkText::trim(ver)}\x22\n"
        if !LinkFS::write(obj + "/src/internal/version.h", vh) {
            return out.fail(f"cannot write {obj}/src/internal/version.h", "")
        }

        var objs = MuslProvider::objects(src, ma)
        var base = ctx->kcc(ctx->stage)
        for var f: string in musl_c99fse() {
            base.push_back(f)
        }

        base.push_back("-D_XOPEN_SOURCE=700")
        base.push_back("-I" + src + "/arch/" + ma)
        base.push_back("-I" + src + "/arch/generic")
        base.push_back("-I" + obj + "/src/internal")
        base.push_back("-I" + src + "/src/include")
        base.push_back("-I" + src + "/src/internal")
        base.push_back("-I" + obj + "/include")
        base.push_back("-I" + src + "/include")
        for var f: string in musl_cflags_auto() {
            base.push_back(f)
        }

        for var f: string in ctx->recipe.list("libc", "cflags") {
            base.push_back(f)
        }

        var logs = ctx->log_dir + "/cc"
        LinkFS::make_dirs(logs)
        var jobs = SysJobs()
        jobs.limit(ctx->jobs)
        var archive = cxx::std::vector<string>()
        var crts    = cxx::std::vector<string>()
        for var i: usize = 0; i < objs.size(); ++i {
            var o   = objs[i]
            var crt = LinkText::starts_with(o.obj, "crt/")
            var libc = LinkText::starts_with(o.obj, "src/")
                || LinkText::starts_with(o.obj, "compat/")
            if !crt && !libc {
                continue
            }

            // libc objects are the Makefile's .lo (AOBJS = LOBJS); crt
            // objects stay .o.
            var ext  = if (crt) => (".o") else => ".lo"
            var path = obj + "/" + o.obj + ext
            LinkFS::make_dirs(LinkFS::parent(path))
            var argv = base
            var stem = LinkFS::filename(o.obj)
            if o.obj == "crt/Scrt1" || o.obj == "crt/rcrt1" {
                argv.push_back("-fPIC")
            }

            if crt || musl_nossp(stem) {
                argv.push_back("-fno-stack-protector")
            }

            if crt {
                argv.push_back("-DCRT")
            } else {
                argv.push_back("-fPIC")
            }

            argv.push_back("-c")
            argv.push_back("-o")
            argv.push_back(path)
            argv.push_back(src + "/" + o.src)
            if !jobs.add(&argv, f"{logs}/{i}.log") {
                break
            }

            if crt {
                crts.push_back(path)
            } else {
                archive.push_back(path)
            }
        }

        if !jobs.wait_all() {
            var text = ""
            LinkFS::read(jobs.failed_log, &text)
            var first = MuslProvider::_first_error(text)
            return out.fail(f"musl: {first}", "")
        }

        LinkFS::remove_tree(logs)
        var lib = dst + "/lib"
        LinkFS::make_dirs(lib)
        for var t: string in ctx->recipe.list("libc", "targets") {
            var name = LinkFS::filename(t)
            if name == "libc.a" {
                if !LinkFS::write_archive(lib + "/libc.a", &archive) {
                    return out.fail(f"cannot write {lib}/libc.a", "")
                }
            } else if LinkText::ends_with(name, ".o") {
                // lib/%.o: obj/crt/<ARCH>/%.o first, then obj/crt/%.o.
                var stem = LinkText::slice(name, 0, name.size() - 2)
                var from = obj + "/crt/" + ma + "/" + name
                if !LinkFS::is_file(from) {
                    from = obj + "/crt/" + name
                }

                if !LinkFS::is_file(from) {
                    return out.fail(f"musl: no crt object {stem} for ARCH={ma}", "")
                }

                if !SysRun::put_file(from, lib + "/" + name, false) {
                    return out.fail(f"cannot copy {from}", "")
                }
            } else if LinkText::ends_with(name, ".a") {
                // EMPTY_LIBS: `ar rc` with no members.
                if !LinkFS::write(lib + "/" + name, "!<arch>\n") {
                    return out.fail(f"cannot write {lib}/{name}", "")
                }
            }
        }

        LinkFS::remove_tree(obj)
        return true
    }

    /// `make install-headers` for ARCH \p ma from the musl tree \p src into
    /// \p inc. Later writes win, in the Makefile's rule order: include/,
    /// then the generated bits, then arch/generic/bits, then arch/<ma>/bits.
    pub static fn install_headers(const src: string, const ma: string, const inc: string) -> bool {
        var none = cxx::std::vector<string>()
        var sub  = src + "/include"
        for var n: string in LinkFS::list_dir(sub) {
            var p = sub + "/" + n
            if LinkFS::is_dir(p) {
                for var m: string in LinkFS::list_dir(p) {
                    if LinkText::ends_with(m, ".h") && LinkFS::is_file(p + "/" + m) {
                        if !SysRun::put_file(p + "/" + m, inc + "/" + n + "/" + m, false) {
                            return false
                        }
                    }
                }
            } else if LinkText::ends_with(n, ".h") {
                if !SysRun::put_file(p, inc + "/" + n, false) {
                    return false
                }
            }
        }

        LinkFS::make_dirs(inc + "/bits")
        if !LinkFS::write(inc + "/bits/alltypes.h", MuslProvider::alltypes(src, ma))
            || !LinkFS::write(inc + "/bits/syscall.h", MuslProvider::syscall_h(src, ma)) {
            return false
        }

        var dirs = cxx::std::vector<string>()
        dirs.push_back(src + "/arch/generic/bits")
        dirs.push_back(src + "/arch/" + ma + "/bits")
        for var d: string in dirs {
            for var n: string in LinkFS::list_dir(d) {
                if LinkText::ends_with(n, ".h")
                    && !SysRun::put_file(d + "/" + n, inc + "/bits/" + n, false) {
                    return false
                }
            }
        }

        return true
    }

    /// obj/include/bits/alltypes.h: tools/mkalltypes.sed over
    /// arch/<ma>/bits/alltypes.h.in then include/alltypes.h.in.
    pub static fn alltypes(const src: string, const ma: string) -> string {
        var a = ""
        var b = ""
        LinkFS::read(src + "/arch/" + ma + "/bits/alltypes.h.in", &a)
        LinkFS::read(src + "/include/alltypes.h.in", &b)
        var out = ""
        for var l: string in MuslProvider::_lines(a + b) {
            out += MuslProvider::_mkalltypes(l)
            out += "\n"
        }

        return out
    }

    /// obj/include/bits/syscall.h: syscall.h.in, then every line of it that
    /// names __NR_ again with its first __NR_ spelled SYS_.
    pub static fn syscall_h(const src: string, const ma: string) -> string {
        var text = ""
        LinkFS::read(src + "/arch/" + ma + "/bits/syscall.h.in", &text)
        var out = text
        for var l: string in MuslProvider::_lines(text) {
            var at = LinkText::find(l, "__NR_", 0)
            if at < l.size() {
                out += LinkText::slice(l, 0, at) + "SYS_" + LinkText::slice(
                    l,
                    at + 5,
                    l.size(),
                ) + "\n"
            }
        }

        return out
    }

    /// The Makefile's ALL_OBJS for ARCH \p ma, sorted as make sorts them,
    /// each with the source its pattern rules would pick.
    pub static fn objects(const src: string, const ma: string) -> cxx::std::vector<MuslObj> {
        var dirs = cxx::std::vector<string>()
        var top  = LinkFS::list_dir(src + "/src")
        cxx::std::sort(top.begin(), top.end())
        for var d: string in top {
            if LinkFS::is_dir(src + "/src/" + d) {
                dirs.push_back("src/" + d)
            }
        }

        dirs.push_back("src/malloc/mallocng")
        dirs.push_back("crt")
        dirs.push_back("ldso")
        var compat = MuslProvider::_compat_dirs(src, ma)
        for var d: string in compat {
            dirs.push_back(d)
        }

        var base_objs = cxx::std::vector<string>()
        var base_srcs = cxx::std::vector<string>()
        var arch_objs = cxx::std::vector<string>()
        var arch_srcs = cxx::std::vector<string>()
        for var d: string in dirs {
            for var n: string in LinkFS::list_dir(src + "/" + d) {
                if LinkText::ends_with(n, ".c") && LinkFS::is_file(src + "/" + d + "/" + n) {
                    base_objs.push_back(d + "/" + LinkText::slice(n, 0, n.size() - 2))
                    base_srcs.push_back(d + "/" + n)
                }
            }

            var ad = d + "/" + ma
            for var n: string in LinkFS::list_dir(src + "/" + ad) {
                var rank = MuslProvider::_ext_rank(n)
                if rank == 0 || !LinkFS::is_file(src + "/" + ad + "/" + n) {
                    continue
                }

                var stem = ad + "/" + LinkText::slice(n, 0, n.size() - 2)
                // Two arch sources of one stem: make's first pattern rule
                // that applies wins (.s, then .S, then .c).
                var dup = false
                for var i: usize = 0; i < arch_objs.size(); ++i {
                    if arch_objs[i] == stem {
                        dup = true
                        if rank < MuslProvider::_ext_rank(LinkFS::filename(arch_srcs[i])) {
                            arch_srcs[i] = ad + "/" + n
                        }
                    }
                }

                if !dup {
                    arch_objs.push_back(stem)
                    arch_srcs.push_back(ad + "/" + n)
                }
            }
        }

        // REPLACED_OBJS: an arch object stands in for the generic one at
        // the same path minus /<ARCH>/.
        var replaced = cxx::std::vector<string>()
        var marker   = "/" + ma + "/"
        for var o: string in arch_objs {
            var at = LinkText::find(o, marker, 0)
            if at < o.size() {
                replaced.push_back(
                    LinkText::slice(o, 0, at) + "/" + LinkText::slice(
                        o,
                        at + marker.size(),
                        o.size(),
                    ),
                )
            }
        }

        var keys = cxx::std::vector<string>()
        var out  = cxx::std::vector<MuslObj>()
        for var i: usize = 0; i < base_objs.size(); ++i {
            if !SysUtil::contains(&replaced, base_objs[i]) {
                keys.push_back(base_objs[i])
            }
        }

        for var o: string in arch_objs {
            if !SysUtil::contains(&replaced, o) {
                keys.push_back(o)
            }
        }

        cxx::std::sort(keys.begin(), keys.end())
        for var k: string in keys {
            var m = MuslObj{}
            m.obj = k
            for var i: usize = 0; i < arch_objs.size(); ++i {
                if arch_objs[i] == k {
                    m.src = arch_srcs[i]
                }
            }

            if m.src.empty() {
                m.src = k + ".c"
            }

            // libc.a lists src/ objects before compat/ ones; crt/ and ldso/
            // are not in it and keep their sorted place.
            out.push_back(m)
        }

        var ordered = cxx::std::vector<MuslObj>()
        for var m: MuslObj in out {
            if !LinkText::starts_with(m.obj, "compat/") {
                ordered.push_back(m)
            }
        }

        for var m: MuslObj in out {
            if LinkText::starts_with(m.obj, "compat/") {
                ordered.push_back(m)
            }
        }

        return ordered
    }

    /// musl's ARCH for the target: a quirk's musl_arch, else the recipe's
    /// [per_arch.musl_arch]. Also checks the source tree has that arch.
    priv static fn _resolve(ctx:        *StageCtx,
                            @inout ma:  string,
                            @inout src: string,
                            @inout out: SysOutcome) -> bool {
        ma = ""
        for var q: SysQuirk in ctx->quirks {
            if !q.musl_arch.empty() {
                ma = q.musl_arch
            }
        }

        if ma.empty() {
            ma = ctx->recipe.expand("{per_arch.musl_arch}", &ctx->target)
        }

        if ma.empty() || LinkText::contains(ma, "{") {
            return out.refuse(
                f"musl has no ARCH for {ctx->target.arch}: the recipe has no [per_arch.musl_arch] entry",
                "",
            )
        }

        src = ctx->share + "/musl"
        if !LinkFS::is_dir(src + "/arch/" + ma) || !LinkFS::is_file(src + "/VERSION") {
            return out.refuse(f"share input {src} is not a musl source tree with arch/{ma}", "")
        }

        return true
    }

    /// arch/<ma>/arch.mak's COMPAT_SRC_DIRS (compat/time32 on the 32-bit
    /// arches whose time_t was 32 bits).
    priv static fn _compat_dirs(const src: string, const ma: string) -> cxx::std::vector<string> {
        var out  = cxx::std::vector<string>()
        var text = ""
        if !LinkFS::read(src + "/arch/" + ma + "/arch.mak", &text) {
            return out
        }

        for var l: string in MuslProvider::_lines(text) {
            var t = LinkText::trim(l)
            if LinkText::starts_with(t, "COMPAT_SRC_DIRS") {
                var eq = LinkText::find(t, "=", 0)
                for var w: string in SysUtil::split(LinkText::trim(LinkText::slice(t, eq + 1, t.size())), (' ' as u8)) {
                    if !w.empty() {
                        out.push_back(w)
                    }
                }
            }
        }

        return out
    }

    /// 1 .s, 2 .S, 3 .c; 0 for anything else.
    priv static fn _ext_rank(const n: string) -> i32 {
        if LinkText::ends_with(n, ".s") {
            return 1
        }

        if LinkText::ends_with(n, ".S") {
            return 2
        }

        if LinkText::ends_with(n, ".c") {
            return 3
        }

        return 0
    }

    /// One line through tools/mkalltypes.sed's three substitutions.
    priv static fn _mkalltypes(const l: string) -> string {
        if LinkText::starts_with(l, "TYPEDEF ") && LinkText::ends_with(l, ";") {
            // TYPEDEF \(.*\) \([^ ]*\);$ : the name is the last word.
            var body = LinkText::slice(l, 8, l.size() - 1)
            var sp   = body.size()
            for var i: usize = 0; i < body.size(); ++i {
                if body[i] == (' ' as u8) {
                    sp = i
                }
            }

            if sp < body.size() {
                var ty   = LinkText::slice(body, 0, sp)
                var name = LinkText::slice(body, sp + 1, body.size())
                return f"#if defined(__NEED_{name}) && !defined(__DEFINED_{name})\ntypedef {ty} {name};\n#define __DEFINED_{name}\n#endif\n"
            }

            return l
        }

        var kinds = cxx::std::vector<string>()
        kinds.push_back("STRUCT")
        kinds.push_back("UNION")
        for var k: string in kinds {
            if !LinkText::starts_with(l, k) || !LinkText::ends_with(l, ";") {
                continue
            }

            // STRUCT * \([^ ]*\) \(.*\);$ : spaces, the tag, one space, the body.
            var i = k.size()
            if i >= l.size() || l[i] != (' ' as u8) {
                continue
            }

            while i < l.size() && l[i] == (' ' as u8) {
                i += 1
            }

            var j = i
            while j < l.size() && l[j] != (' ' as u8) {
                j += 1
            }

            if j >= l.size() - 1 {
                continue
            }

            var tag  = LinkText::slice(l, i, j)
            var body = LinkText::slice(l, j + 1, l.size() - 1)
            var lo   = if (k == "STRUCT") => ("struct") else => "union"
            return f"#if defined(__NEED_{lo}_{tag}) && !defined(__DEFINED_{lo}_{tag})\n{lo} {tag} {body};\n#define __DEFINED_{lo}_{tag}\n#endif\n"
        }

        return l
    }

    /// Lines without their '\n'; a final line without one is kept.
    priv static fn _lines(const s: string) -> cxx::std::vector<string> {
        var out       = cxx::std::vector<string>()
        var b:  usize = 0
        for var i: usize = 0; i < s.size(); ++i {
            if s[i] == ('\n' as u8) {
                out.push_back(LinkText::slice(s, b, i))
                b = i + 1
            }
        }

        if b < s.size() {
            out.push_back(LinkText::slice(s, b, s.size()))
        }

        return out
    }

    /// The first line of a compile log that says error, else its first line.
    priv static fn _first_error(const text: string) -> string {
        var lines = MuslProvider::_lines(text)
        for var l: string in lines {
            if LinkText::contains(l, "error") {
                return LinkText::trim(l)
            }
        }

        return if (lines.empty()) => ("a compile failed with no output")
               else => LinkText::trim(lines[0])
    }
}
