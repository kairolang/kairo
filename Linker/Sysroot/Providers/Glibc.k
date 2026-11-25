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
///   Two input layouts (FORMAT.md). The per-release one (glibc/<X.Y>/<arch>:
///   Ubuntu's headers and crt objects, one abilist set) is read when the
///   recipe's [libc] has no `abilists`. The from-source one builds any
///   release for any arch from four inputs, the design after Zig's
///   src/libs/glibc.zig (no code copied):
///     glibc/abilists  every release's abilists merged, each entry with the
///                     releases that export it (Scripts/glibc_abilists.py);
///                     the stubs are the target release's projection;
///     glibc/headers   the newest release's install-headers for every arch,
///                     deduplicated: generic/ + <arch>/ (into include/ and
///                     include/<multiarch>/) minus [omit]; features.h gets
///                     the target's __GLIBC_MINOR__ (Scripts/glibc_headers.py);
///     glibc/src, glibc/crt  the crt objects and libc_nonshared.a, compiled
///                     from glibc's own sources with the compiles glibc's
///                     make ran, per era (2.32, 2.33, 2.34+) and arch
///                     (Scripts/glibc_crt_recipe.py).
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
    pub var versions: [string]
}

/// glibc/abilists/targets.toml: one arch's row and the [sonames] table.
pub struct GlibcRow {
    pub var abi:     string
    pub var ld:      string
    pub var floor:   string
    pub var so_keys: [string]
    pub var so_vals: [string]
}

/// One [compile.*] or [link.*] of a glibc/crt/<era>/<arch>.toml.
pub struct GlibcStep {
    pub var out:  string
    pub var args: [string] ///< compile: the argv after the program; link: inputs
}

/// glibc/crt/<era>/<arch>.toml (FORMAT.md "glibc/crt").
pub struct GlibcCrtTable {
    pub var era:       string
    pub var releases:  string      ///< "2.17-2.32", "2.34-newest"
    pub var crt:       [string]
    pub var nonshared: [string]
    pub var compiles:  [GlibcStep]
    pub var links:     [GlibcStep]
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
        if !ctx->recipe.str("libc", "headers").is_empty() {
            return GlibcProvider::source_headers(ctx, dst, &out)
        }

        var from = ctx->share_path(ctx->recipe.str("libc", "include"))
        if !LinkFS::is_dir(from) {
            return out.refuse(f"share input {from} missing", "")
        }

        var inc = dst.copy() + "/include"
        if !ctx->materialise(from, inc, &out) {
            return false
        }

        if LinkFS::is_file(inc.copy() + "/linux/version.h") {
            return true
        }

        var uapi: [string]
        uapi.push(ctx->share.copy() + "/linux-uapi/generic")
        uapi.push(ctx->share.copy() + "/linux-uapi/asm/" + ctx->target.arch)

        for *u in uapi {
            if !LinkFS::is_dir(*u) {
                return out.refuse(f"share input {*u} missing", "")
            }

            if !ctx->materialise(*u, inc, &out) {
                return false
            }
        }

        return true
    }

    pub override fn libs(self, ctx: *StageCtx, const dst: string, @inout out: SysOutcome) -> bool {
        if !ctx->recipe.str("libc", "abilists").is_empty() {
            return GlibcProvider::source_libs(ctx, dst, &out)
        }

        var crt = ctx->share_path(ctx->recipe.str("libc", "crt"))
        var ns  = ctx->share_path(ctx->recipe.str("libc", "nonshared"))
        var abi = ctx->share_path(ctx->recipe.str("libc", "abilist"))
        var fmt = GlibcProvider::output_format(ctx->target.arch)
        var lib = dst.copy() + "/lib"
        if !LinkFS::is_dir(crt)
            || !LinkFS::is_file(ns)
            || !LinkFS::is_file(abi.copy() + "/libs.toml") {
            return out.refuse(
                f"share input {LinkFS::parent(crt)} is missing crt/, libc_nonshared.a or abilist/",
                "",
            )
        }

        if fmt.is_empty() {
            return out.refuse(
                f"glibc: no linker-script OUTPUT_FORMAT known for {ctx->target.arch}",
                "",
            )
        }

        if !ctx->materialise(crt, lib, &out) {
            return false
        }

        if !SysRun::put_file(ns, lib.copy() + "/libc_nonshared.a", false) {
            return out.fail(f"cannot copy the crt objects into {lib}", "")
        }

        var libs: [GlibcLib]
        var why              = ""
        if !GlibcProvider::read_libs(abi.copy() + "/libs.toml", &libs, &why) {
            return out.refuse(f"share input {abi}/libs.toml: {why}", "")
        }

        var all: [[GlibcSym]]
        for *l in libs {
            var ab = ""
            var co = ""
            if !LinkFS::read(abi.copy() + "/" + l->stem + ".abilist", &ab) {
                return out.refuse(
                    f"share input {abi}/{l->stem}.abilist missing",
                    "",
                )
            }

            LinkFS::read(abi.copy() + "/" + l->stem + ".compat", &co)
            all.push(GlibcProvider::parse_abilist(ab, co))
        }

        return GlibcProvider::link_stubs(ctx, lib, fmt, &libs, &all, &out)
    }

    /// The stub DSOs of `libs` (symbols `all`, index for index) into
    /// `lib`, then the libc.so / libm.so scripts and the dev links.
    pub static fn link_stubs(ctx:         *StageCtx,
                             const lib:   string,
                             const fmt:   string,
                             @inout libs: [GlibcLib],
                             @inout all:  [[GlibcSym]],
                             @inout out:  SysOutcome) -> bool {
        var work = ctx->stage.copy() + "/stubs"
        var jobs = SysJobs()
        jobs.limit(ctx->jobs)
        for var li: usize = 0; li < libs.size(); ++li {
            var *l    = &libs[li]
            var *syms = &all[li]
            var c     = ""
            var map   = ""
            GlibcProvider::stub_sources(*syms, l->versions, &c, &map)
            var dir = work.copy() + "/" + l->stem
            LinkFS::make_dirs(dir)
            if !LinkFS::write(dir.copy() + "/stub.c", c)
                || !LinkFS::write(dir.copy() + "/stub.map", map) {
                return out.fail(f"cannot write {dir}", "")
            }

            // Compiled by kcc, linked by kld (4.6): a kcc link step would
            // also link the Kairo runtime, which a stub must not carry.
            var argv = ctx->kcc(ctx->stage)
            argv.push("-fPIC")
            argv.push("-O0")
            argv.push("-w")
            argv.push("-c")
            argv.push("-o")
            argv.push(dir.copy() + "/stub.o")
            argv.push(dir.copy() + "/stub.c")
            if !jobs.add(argv, f"{ctx->log_dir}/stub-{l->stem}.cc.log") {
                break
            }
        }

        if !jobs.wait_all() {
            return out.fail(
                f"glibc stub compile failed, see {jobs.failed_log}",
                "",
            )
        }

        var links = SysJobs()
        for *l in libs {
            var dir            = work.copy() + "/" + l->stem
            var argv: [string]
            argv.push(ctx->tool("kld"))
            argv.push("-flavor")
            argv.push("gnu")
            argv.push("-shared")
            argv.push("-soname")
            argv.push(l->soname.copy())
            // A library with no version node (a 2.34+ placeholder library on a
            // port newer than 2.34) has no script: lld rejects an empty one.
            if !l->versions.is_empty() {
                argv.push("--version-script")
                argv.push(dir.copy() + "/stub.map")
            }

            argv.push("-o")
            argv.push(
                lib.copy() + "/" + GlibcProvider::file_name(
                    l,
                    ctx->target.libc_version,
                ),
            )

            argv.push(dir.copy() + "/stub.o")
            if !links.add(argv, f"{ctx->log_dir}/stub-{l->stem}.ld.log") {
                break
            }
        }

        if !links.wait_all() {
            return out.fail(
                f"glibc stub link failed, see {links.failed_log}",
                "",
            )
        }

        LinkFS::remove_tree(work)
        for *l in libs {
            var file = GlibcProvider::file_name(l, ctx->target.libc_version)
            if file != l->soname && !SysRun::symlink(file, lib.copy() + "/" + l->soname) {
                return out.fail(f"cannot link {lib}/{l->soname}", "")
            }
        }

        var libc    = GlibcProvider::_soname(libs, "libc")
        var ld      = GlibcProvider::_soname(libs, "ld")
        var libm    = GlibcProvider::_soname(libs, "libm")
        var libmvec = GlibcProvider::_soname(libs, "libmvec")
        if libc.is_empty() || ld.is_empty() || libm.is_empty() {
            return out.refuse("the glibc libraries lack libc, ld or libm", "")
        }

        var script = "/* GNU ld script\n   Use the shared library, but some functions are only in\n   the static library, so try that secondarily.  */\n"
        script += f"OUTPUT_FORMAT({fmt})\nGROUP ( {libc} libc_nonshared.a  AS_NEEDED ( {ld} ) )\n"
        if !LinkFS::write(lib.copy() + "/libc.so", script) {
            return out.fail(f"cannot write {lib}/libc.so", "")
        }

        // libm.so is a script only where libmvec exists to pull in, as
        // glibc installs it; elsewhere the plain dev link.
        if !libmvec.is_empty() {
            var ms = f"/* GNU ld script\n*/\nOUTPUT_FORMAT({fmt})\nGROUP ( {libm}  AS_NEEDED ( {libmvec} ) )\n"
            if !LinkFS::write(lib.copy() + "/libm.so", ms) {
                return out.fail(f"cannot write {lib}/libm.so", "")
            }
        } else if !SysRun::symlink(libm, lib.copy() + "/libm.so") {
            return out.fail(f"cannot link {lib}/libm.so", "")
        }

        // The dev links -l<name> resolves through, for every other library.
        for *l in libs {
            if l->stem == "libc" || l->stem == "ld" || l->stem == "libm" {
                continue
            }

            if !SysRun::symlink(l->soname, lib.copy() + "/" + l->stem + ".so") {
                return out.fail(f"cannot link {lib}/{l->stem}.so", "")
            }
        }

        // Debian's armhf libc6 also installs the old loader name, which
        // binaries linked before the hard-float split ask for.
        if ld == "ld-linux-armhf.so.3" && !SysRun::symlink(ld, lib.copy() + "/ld-linux.so.3") {
            return out.fail(f"cannot link {lib}/ld-linux.so.3", "")
        }

        return true
    }

    /// The from-source include/: glibc/headers generic/ into include/, the
    /// arch's own files into include/<multiarch>/ (searched first, as
    /// SYSROOT.toml's include_dirs order it), the [omit] paths the arch's
    /// install lacks removed, then the UAPI, and features.h set to the
    /// target's __GLIBC_MINOR__ (the one change a release needs here:
    /// glibc_headers.py's gates key on it).
    pub static fn source_headers(ctx:        *StageCtx,
                                 const dst:  string,
                                 @inout out: SysOutcome) -> bool {
        var hroot = ctx->share_path(ctx->recipe.str("libc", "headers"))
        var arch  = ctx->target.arch.copy()
        var row   = GlibcRow{}
        if !GlibcProvider::target_row(ctx, &row, &out) {
            return false
        }

        var text = ""
        if !LinkFS::read(hroot.copy() + "/index.toml", &text)
            || !LinkFS::is_dir(hroot.copy() + "/generic") {
            return out.refuse(
                f"share input {hroot} lacks index.toml or generic/",
                "",
            )
        }

        var arches: [string]
        var omit:   [string]
        var toml             = TomlLite(text)
        var key              = ""
        var val              = TomlValue{}
        while toml.next(&key, &val) {
            if toml.table.is_empty() && key == "arches" && val.kind == 3 {
                arches = SysUtil::taken(&val.list)
            } else if toml.table == "omit" && key == arch && val.kind == 3 {
                omit = SysUtil::taken(&val.list)
            }
        }

        if !SysUtil::contains(arches, arch) {
            return out.refuse(
                f"share input {hroot} has no headers for {arch}",
                "",
            )
        }

        var ma = ctx->recipe.expand("{per_arch.multiarch}", &ctx->target)
        if LinkText::contains(ma, "{") {
            return out.refuse(
                f"the glibc recipe has no [per_arch.multiarch] for {arch}",
                "",
            )
        }

        var inc = dst.copy() + "/include"
        if !ctx->materialise(hroot.copy() + "/generic", inc, &out) {
            return false
        }

        for *r in omit {
            LinkFS::remove(inc.copy() + "/" + *r)
        }

        if LinkFS::is_dir(hroot.copy() + "/" + arch)
            && !ctx->materialise(
                hroot.copy() + "/" + arch,
                inc.copy() + "/" + ma,
                &out,
            ) {
            return false
        }

        for *u in ctx->recipe.list("libc", "uapi") {
            var from = ctx->share_path(*u)
            if !LinkFS::is_dir(from) {
                return out.refuse(f"share input {from} missing", "")
            }

            if !ctx->materialise(from, inc, &out) {
                return false
            }
        }

        var fh = inc.copy() + "/" + ma + "/features.h"
        if !LinkFS::is_file(fh) {
            fh = inc.copy() + "/features.h"
        }

        var ft = ""
        if !LinkFS::read(fh, &ft) {
            return out.refuse(
                f"share input {hroot}: no features.h for {arch}",
                "",
            )
        }

        var v     = ctx->target.libc_version.copy()
        var dot   = LinkText::find(v.copy(), ".", 0)
        var minor = LinkText::slice(v, dot + 1, v.size())
        var fixed = ""
        var hits  = 0
        var lines = LinkText::split_lines(ft.copy())
        for *line in lines {
            var w = GlibcProvider::_words(*line)
            if w.size() == 3 && w[0] == "#define" && w[1] == "__GLIBC_MINOR__" {
                *line = "#define\t__GLIBC_MINOR__\t" + minor
                hits += 1
            }

            fixed += *line
            fixed += "\n"
        }

        if hits != 1 {
            return out.fail(
                f"{fh}: expected one #define __GLIBC_MINOR__, found {hits}",
                "",
            )
        }

        // A materialised file may be a hard link into the share: replace it,
        // never write through it.
        LinkFS::remove(fh)
        if !LinkFS::write(fh, fixed) {
            return out.fail(f"cannot write {fh}", "")
        }

        return true
    }

    /// The from-source lib/: stub DSOs projected from glibc/abilists at the
    /// target release, then crt*.o and libc_nonshared.a compiled.
    pub static fn source_libs(ctx: *StageCtx, const dst: string, @inout out: SysOutcome) -> bool {
        var ab  = ctx->share_path(ctx->recipe.str("libc", "abilists"))
        var row = GlibcRow{}
        if !GlibcProvider::target_row(ctx, &row, &out) {
            return false
        }

        var fmt = ctx->recipe.expand("{per_arch.output_format}", &ctx->target)
        if LinkText::contains(fmt, "{") {
            fmt = GlibcProvider::output_format(ctx->target.arch)
        }

        if fmt.is_empty() {
            return out.refuse(
                f"glibc: no linker-script OUTPUT_FORMAT known for {ctx->target.arch}",
                "",
            )
        }

        var v                   = ctx->target.libc_version.copy()
        var folded              = !SysUtil::version_less(v, "2.34")
        var libs:  [GlibcLib]
        var all:   [[GlibcSym]]
        for *stem in GlibcProvider::stems() {
            var l = GlibcLib{}
            l.stem = stem->copy()
            l.soname = if (*stem == "ld") => (row.ld.copy())
                       else => GlibcProvider::_lookup(
                           row.so_keys,
                           row.so_vals,
                           *stem,
                       )

            var syms: [GlibcSym]
            var file             = ab.copy() + "/" + row.abi + "/" + *stem
            if LinkFS::is_file(file.copy() + ".abilist") {
                var a = ""
                var n = ""
                var c = ""
                LinkFS::read(file.copy() + ".abilist", &a)
                LinkFS::read(file.copy() + ".nodes", &n)
                LinkFS::read(file.copy() + ".compat", &c)
                syms = GlibcProvider::project(a, n, c, v, &l.versions)
            }

            // 2.34 folded these into libc and still installs them, empty or
            // placeholders only: a link naming -lpthread must find one.
            var keep = folded
                && (*stem == "libpthread"
                    || *stem == "libdl"
                    || *stem == "librt"
                    || *stem == "libutil"
                    || *stem == "libanl")
            if syms.is_empty() && !keep {
                continue
            }

            if l.soname.is_empty() {
                return out.refuse(
                    f"share input {ab}/targets.toml names no soname for {*stem}",
                    "",
                )
            }

            libs.push(l)
            all.push(syms)
        }

        var lib = dst.copy() + "/lib"
        LinkFS::make_dirs(lib)
        if !GlibcProvider::link_stubs(ctx, lib, fmt, &libs, &all, &out) {
            return false
        }

        return GlibcProvider::source_crt(ctx, lib, &out)
    }

    /// crt1.o, Scrt1.o, crti.o, crtn.o and libc_nonshared.a from the era's
    /// table: its compiles as glibc's make ran them, its `-r` links, the
    /// archive in member order.
    pub static fn source_crt(ctx: *StageCtx, const lib: string, @inout out: SysOutcome) -> bool {
        var croot = ctx->share_path(ctx->recipe.str("libc", "crt"))
        var sroot = ctx->share_path(ctx->recipe.str("libc", "src"))
        var arch  = ctx->target.arch.copy()
        var v     = ctx->target.libc_version.copy()
        var t     = GlibcCrtTable{}
        var found = false
        for *era in LinkFS::list_dir(croot) {
            var path = croot.copy() + "/" + *era + "/" + arch + ".toml"
            if !LinkFS::is_file(path) {
                continue
            }

            var c   = GlibcCrtTable{}
            var why = ""
            if !GlibcProvider::read_crt(path, &c, &why) {
                return out.refuse(f"share input {path}: {why}", "")
            }

            if GlibcProvider::in_ranges(c.releases, v) {
                t     = c
                found = true
                break
            }
        }

        if !found {
            return out.refuse(
                f"share input {croot} has no start-file table for {arch} at glibc {v}",
                "",
            )
        }

        var src  = sroot.copy() + "/" + t.era
        var gen  = croot.copy() + "/" + t.era + "/" + arch + "/gen"
        var work = ctx->stage.copy() + "/work/crt"
        var uapi = ctx->stage.copy() + "/work/uapi"
        LinkFS::remove_tree(work)
        LinkFS::remove_tree(uapi)
        for *u in ctx->recipe.list("libc", "uapi") {
            if !ctx->materialise(ctx->share_path(*u), uapi, &out) {
                return false
            }
        }

        var jobs = SysJobs()
        jobs.limit(ctx->jobs)
        for var i: usize = 0; i < t.compiles.size(); ++i {
            var *c   = &t.compiles[i]
            var argv = ctx->kcc(ctx->stage)
            for *a in c->args {
                var x = SysUtil::fill(*a, "src", src)
                x = SysUtil::fill(x, "gen", gen)
                x = SysUtil::fill(x, "uapi", uapi)
                x = SysUtil::fill(x, "out", work)
                argv.push(x)
            }

            argv.push(f"-ffile-prefix-map={src}=glibc-{t.era}")
            argv.push(f"-ffile-prefix-map={gen}=glibc-gen")
            LinkFS::make_dirs(LinkFS::parent(work.copy() + "/" + c->out))
            if !jobs.add(argv, f"{ctx->log_dir}/glibc-crt-{i}.log") {
                break
            }
        }

        if !jobs.wait_all() {
            return out.fail(
                f"glibc start-file compile failed, see {jobs.failed_log}",
                "",
            )
        }

        for var i: usize = 0; i < t.links.size(); ++i {
            var *l             = &t.links[i]
            var argv: [string]
            argv.push(ctx->tool("kld"))
            argv.push("-flavor")
            argv.push("gnu")
            argv.push("-r")
            argv.push("-o")
            argv.push(work.copy() + "/" + l->out)
            for *x in l->args {
                argv.push(work.copy() + "/" + *x)
            }

            if SysRun::run(argv, f"{ctx->log_dir}/glibc-crt-link-{i}.log") != 0 {
                return out.fail(
                    f"glibc start-file link {l->out} failed, see {ctx->log_dir}/glibc-crt-link-{i}.log",
                    "",
                )
            }
        }

        for *name in t.crt {
            var from = ""
            for *l in t.links {
                if LinkFS::filename(l->out) == *name {
                    from = work.copy() + "/" + l->out
                }
            }

            for *c in t.compiles {
                if from.is_empty() && LinkFS::filename(c->out) == *name {
                    from = work.copy() + "/" + c->out
                }
            }

            if from.is_empty() || !SysRun::put_file(from, lib.copy() + "/" + *name, false) {
                return out.fail(f"glibc start file {*name} was not built", "")
            }
        }

        var members = cxx::std::vector<string>()
        for *m in t.nonshared {
            members.push_back(work.copy() + "/" + *m)
        }

        if !LinkFS::write_archive(lib.copy() + "/libc_nonshared.a", members) {
            return out.fail(f"cannot write {lib}/libc_nonshared.a", "")
        }

        LinkFS::remove_tree(work)
        LinkFS::remove_tree(uapi)
        return true
    }

    /// The abilist stems a root is stubbed from, in glibc_abilists.py STEMS order.
    pub static fn stems() -> [string] {
        var v: [string]
        v.push("ld")
        v.push("libc")
        v.push("libm")
        v.push("libpthread")
        v.push("libdl")
        v.push("librt")
        v.push("libutil")
        v.push("libanl")
        v.push("libresolv")
        v.push("libmvec")
        return v
    }

    /// glibc/abilists/targets.toml for the target's arch: its abi dir, ld.so
    /// soname and floor, plus [sonames]; refuses a release below the floor.
    pub static fn target_row(ctx: *StageCtx, @inout row: GlibcRow, @inout out: SysOutcome) -> bool {
        var ab   = ctx->share_path(ctx->recipe.str("libc", "abilists"))
        var arch = ctx->target.arch.copy()
        var text = ""
        if !LinkFS::read(ab.copy() + "/targets.toml", &text) {
            return out.refuse(f"share input {ab}/targets.toml missing", "")
        }

        var toml = TomlLite(text)
        var key  = ""
        var val  = TomlValue{}
        while toml.next(&key, &val) {
            if toml.table == "sonames" && val.kind == 1 {
                row.so_keys.push(key.copy())
                row.so_vals.push(val.text.copy())
            } else if toml.table == arch && val.kind == 1 {
                if key == "abi" {
                    row.abi = val.text.copy()
                } else if key == "ld" {
                    row.ld = val.text.copy()
                } else if key == "floor" {
                    row.floor = val.text.copy()
                }
            }
        }

        if !toml.error.is_empty() {
            return out.refuse(
                f"share input {ab}/targets.toml: {toml.error}",
                "",
            )
        }

        if row.abi.is_empty() || row.ld.is_empty() {
            return out.refuse(
                f"glibc has no port for {arch} (share input {ab}/targets.toml)",
                "",
            )
        }

        var v = ctx->target.libc_version.copy()
        if !row.floor.is_empty() && SysUtil::version_less(v, row.floor) {
            return out.refuse(
                f"glibc {v} predates the {arch} port (first release {row.floor})",
                "",
            )
        }

        return true
    }

    /// One release of a merged abilist (glibc_abilists.py project): the
    /// entries whose releases hold `v`, @ / @@ by the newest-is-default
    /// rule unless a .compat row active at `v` says compat, the absolute
    /// version-name symbol of every node defined by `v`; `nodes` gets
    /// those nodes in order.
    pub static fn project(const abilist:    string,
                          const nodes_text: string,
                          const compat:     string,
                          const v:          string,
                          @inout nodes:     [string]) -> [GlibcSym] {
        var text = ""
        for *line in LinkText::split_lines(abilist.copy()) {
            var w = GlibcProvider::_words(*line)
            if w.size() < 4 || !GlibcProvider::in_ranges(w[w.size() - 1], v) {
                continue
            }

            text += w[0].copy() + " " + w[1] + " " + w[2]
            if w.size() > 4 {
                text += " " + w[3]
            }

            text += "\n"
        }

        var co = ""
        for *line in LinkText::split_lines(compat.copy()) {
            var w = GlibcProvider::_words(*line)
            if w.size() == 4 && GlibcProvider::in_ranges(w[3], v) {
                co += w[0].copy() + " " + w[1] + " " + w[2] + "\n"
            }
        }

        nodes.clear()
        for *line in LinkText::split_lines(nodes_text.copy()) {
            var w = GlibcProvider::_words(*line)
            if w.size() == 2 && !SysUtil::version_less(v, w[1]) {
                nodes.push(w[0].copy())
                text += w[0].copy() + " " + w[0] + " A\n"
            }
        }

        // .nodes is in version order already; parse_abilist keeps line order
        return GlibcProvider::parse_abilist(text, co)
    }

    /// `2.17`, `2.17-2.33`, `2.34-newest`, or a comma list of those: whether
    /// `v` is in it (a bare release means from it to the newest).
    pub static fn in_ranges(const spec: string, const v: string) -> bool {
        for *r in SysUtil::split(spec, (',' as u8)) {
            var dash = LinkText::find(r->copy(), "-", 0)
            var lo = if (dash < r->size()) => (LinkText::slice(*r, 0, dash)) else => r->copy()
            var hi = if (dash < r->size()) => (LinkText::slice(*r, dash + 1, r->size())) else => ""
            if SysUtil::version_less(v, lo) {
                continue
            }

            if hi.is_empty() || hi == "newest" || !SysUtil::version_less(hi, v) {
                return true
            }
        }

        return false
    }

    /// glibc/crt/<era>/<arch>.toml.
    pub static fn read_crt(const path: string,
                           @inout t:   GlibcCrtTable,
                           @inout why: string) -> bool {
        var text = ""
        if !LinkFS::read(path, &text) {
            why = "cannot read the file"
            return false
        }

        var toml = TomlLite(text)
        var key  = ""
        var val  = TomlValue{}
        var last = ""
        while toml.next(&key, &val) {
            var tb    = toml.table.copy()
            var fresh = tb != last
            last = tb.copy()
            if tb.is_empty() {
                if key == "era" {
                    t.era = val.text.copy()
                } else if key == "releases" {
                    t.releases = val.text.copy()
                } else if key == "crt" {
                    t.crt = SysUtil::taken(&val.list)
                } else if key == "nonshared" {
                    t.nonshared = SysUtil::taken(&val.list)
                }
            } else if LinkText::starts_with(tb.copy(), "compile.")
                || LinkText::starts_with(tb.copy(), "link.") {
                var link = LinkText::starts_with(tb.copy(), "link.")
                if fresh {
                    if link {
                        t.links.push(GlibcStep{})
                    } else {
                        t.compiles.push(GlibcStep{})
                    }
                }

                var n = if (link) => (t.links.size()) else => t.compiles.size()
                if n == 0 {
                    continue
                }

                if key == "out" {
                    if link {
                        t.links[n - 1].out = val.text.copy()
                    } else {
                        t.compiles[n - 1].out = val.text.copy()
                    }
                } else if (key == "args" || key == "inputs") && val.kind == 3 {
                    if link {
                        t.links[n - 1].args = SysUtil::taken(&val.list)
                    } else {
                        t.compiles[n - 1].args = SysUtil::taken(&val.list)
                    }
                }
            }
        }

        if !toml.error.is_empty() {
            why = toml.error.copy()
            return false
        }

        if t.era.is_empty() || t.releases.is_empty() || t.crt.is_empty() {
            why = "no era, releases or crt"
            return false
        }

        return true
    }

    priv static fn _lookup(const keys: [string], const vals: [string], const k: string) -> string {
        for var i: usize = 0; i < keys.size(); ++i {
            if keys[i] == k {
                return vals[i].copy()
            }
        }

        return ""
    }

    /// The file a library's stub is written to. Before 2.34 glibc installs
    /// lib<x>-<ver>.so with the SONAME a link to it (ld: ld-<ver>.so); from
    /// 2.34 the SONAME is the file.
    pub static fn file_name(l: *GlibcLib, const version: string) -> string {
        if version.is_empty() || !SysUtil::version_less(version, "2.34") {
            return l->soname.copy()
        }

        return l->stem.copy() + "-" + version + ".so"
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
                            @inout libs: [GlibcLib],
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
            if toml.table.is_empty() {
                continue
            }

            if libs.is_empty() || libs[libs.size() - 1].stem != toml.table {
                var l = GlibcLib{}
                l.stem = toml.table.copy()
                libs.push(l)
            }

            if key == "soname" && val.kind == 1 {
                libs[libs.size() - 1].soname = val.text.copy()
            } else if key == "versions" && val.kind == 3 {
                libs[libs.size() - 1].versions = SysUtil::taken(&val.list)
            }
        }

        if !toml.error.is_empty() {
            why = toml.error.copy()
            return false
        }

        return true
    }

    /// abilist + compat -> symbols with their @ / @@ decided: the newest
    /// version of a name is its default, unless compat says otherwise.
    pub static fn parse_abilist(const text: string, const compat: string) -> [GlibcSym] {
        var syms: [GlibcSym]
        for *line in LinkText::split_lines(text.copy()) {
            var w = GlibcProvider::_words(*line)
            if w.size() < 3 || LinkText::starts_with(w[0].copy(), "#") {
                continue
            }

            var s = GlibcSym{}
            s.version = w[0].copy()
            s.name    = w[1].copy()
            s.kind    = w[2].copy()
            if w.size() > 3 {
                s.size = w[3].copy()
            }

            syms.push(s)
        }

        // default_rule: name -> its newest version.
        var names:  [string]
        var newest: [string]
        for *s in syms {
            var found = false
            for var i: usize = 0; i < names.size(); ++i {
                if names[i] == s->name {
                    found = true
                    if GlibcProvider::ver_less(newest[i], s->version) {
                        newest[i] = s->version.copy()
                    }

                    break
                }
            }

            if !found {
                names.push(s->name.copy())
                newest.push(s->version.copy())
            }
        }

        var over_keys: [string]
        var over_vals: [string]
        for *line in LinkText::split_lines(compat.copy()) {
            var w = GlibcProvider::_words(*line)
            if w.size() == 3 {
                over_keys.push(w[0].copy() + " " + w[1])
                over_vals.push(w[2].copy())
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

            var k = syms[i].version.copy() + " " + syms[i].name
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
    pub static fn stub_sources(const syms:     [GlibcSym],
                               const versions: [string],
                               @inout c:       string,
                               @inout map:     string) {
        var q = "\x22"
        c = "/* generated by ksys (Linker/Sysroot/Providers/Glibc.k): a link-time stand-in, never run */\n"
        // Per node, the names its `global:` must list: the version-name
        // symbol, and every non-default name (lld would otherwise apply
        // `local: *` to a name@VER the node does not name).
        var abs_nodes: [string]
        var abs_names: [string]
        for var i: usize = 0; i < syms.size(); ++i {
            var *e = &syms[i]
            if e->kind == "A" {
                // lld does not invent GNU ld's version-name symbols: define
                // each absolute, and the script binds it to its node.
                c += "__asm__(" + q + ".globl \\" + q + e->name + "\\" + q + "\\n.set \\" + q + e->name + "\\" + q + ", 0" + q + ");\n"
                abs_nodes.push(e->version.copy())
                abs_names.push(e->name.copy())
                continue
            }

            var s = f"__kairo_stub_{i}"
            if e->kind == "F" {
                c += "void " + s + "(void) {}\n"
            } else if e->kind == "T" {
                c += "__thread char " + s + "[" + e->size + "] = {0};\n"
            } else {
                c += "char " + s + "[" + e->size + "] = {0};\n"
            }

            var at = if (e->dflt) => ("@@") else => "@"
            c += "__asm__(" + q + ".symver " + s + ", " + e->name + at + e->version + q + ");\n"
            if !e->dflt {
                abs_nodes.push(e->version.copy())
                abs_names.push(e->name.copy())
            }
        }

        // Nodes: libs.toml's order, then any other the symbols name, sorted.
        var extra: [string]
        for const *e in syms {
            if !SysUtil::contains(versions, e->version) && !SysUtil::contains(extra, e->version) {
                extra.push(e->version.copy())
            }
        }

        for var i: usize = 1; i < extra.size(); ++i {
            var j = i
            while j > 0 && GlibcProvider::ver_less(extra[j], extra[j - 1]) {
                extra[0..].swap(j, j - 1)
                j -= 1
            }
        }

        map = ""
        var prev       = ""
        var n:   usize = 0
        for const v in versions {
            GlibcProvider::_map_node(
                &map,
                &prev,
                v,
                n == 0,
                abs_nodes,
                abs_names,
            )

            n += 1
        }

        for const v in extra {
            GlibcProvider::_map_node(
                &map,
                &prev,
                v,
                n == 0,
                abs_nodes,
                abs_names,
            )

            n += 1
        }
    }

    /// Appends version node `v` to `map`: a `global:` list of the names
    /// `abs_names` binds to it, `local: *` in the script's first node, and
    /// the node before it (`prev`, then set to `v`) as its parent.
    priv static fn _map_node(@inout map:      string,
                             @inout prev:     string,
                             const v:         string,
                             const first:     bool,
                             const abs_nodes: [string],
                             const abs_names: [string]) {
        var body = ""
        for var j: usize = 0; j < abs_nodes.size(); ++j {
            if abs_nodes[j] == v {
                body += "  " + abs_names[j] + ";\n"
            }
        }

        if !body.is_empty() {
            body = "  global:\n" + body
        }

        if first {
            body += "  local: *;\n"
        }

        map += v
        map += " {\n" + body + "}"
        map += if (prev.is_empty()) => (";\n") else => " " + prev + ";\n"
        prev = v.copy()
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

    /// Where the trailing dotted number of `v` starts; v.size() if none.
    priv static fn _ver_digits(const v: string) -> usize {
        var i = v.size()
        while i > 0
            && (v.data()[i - 1] >= ('0' as u8) && v.data()[i - 1] <= ('9' as u8)
                || v.data()[i - 1] == ('.' as u8)) {
            i -= 1
        }

        while i < v.size() && v.data()[i] == ('.' as u8) {
            i += 1
        }

        return i
    }

    /// The name part of a version node, one `_` before the number dropped.
    priv static fn _ver_prefix(const v: string) -> string {
        var d = GlibcProvider::_ver_digits(v)
        if d >= v.size() {
            return v.copy()
        }

        var p = LinkText::slice(v, 0, d)
        if LinkText::ends_with(p.copy(), "_") {
            p = LinkText::slice(p, 0, p.size() - 1)
        }

        return p
    }

    priv static fn _soname(const libs: [GlibcLib], const stem: string) -> string {
        for const *l in libs {
            if l->stem == stem {
                return l->soname.copy()
            }
        }

        return ""
    }

    priv static fn _words(const line: string) -> [string] {
        var out:   [string]
        var start: usize    = 0 ///< where the current word begins
        for var i: usize = 0; i < line.size(); ++i {
            var ch = line.data()[i]
            if ch == (' ' as u8) || ch == ('\t' as u8) || ch == ('\r' as u8) {
                if i > start {
                    out.push(line[start..i].to_owned())
                }

                start = i + 1
            }
        }

        if line.size() > start {
            out.push(line[start..].to_owned())
        }

        return out
    }
}
