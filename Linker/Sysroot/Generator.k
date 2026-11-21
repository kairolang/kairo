/// --- The Kairo Project ---------------------------- Sysroot/Generator.k --- ///
///
///   SysGen: the sysroot pipeline (SysRoot.md section 4) and every ksys
///   command over it. The ksys tool and the kairo driver's hook both call
///   this in-process, as kairo calls the linker library.
///
///     parse -> probe -> inputs -> libc-headers -> builtins -> libc-libs
///           -> runtimes -> assemble -> toml -> validate -> cache
///
///   Every stage writes its product under <stage dir>/out/ and reads the
///   earlier ones' through StageCtx::product. The provider stages are the
///   providers'; builtins and runtimes (compiler-rt, libunwind, libc++abi,
///   libc++, compiled from the runtimes-recipe/ tables with no CMake) are
///   Runtimes.k's; assemble, toml, validate and the cache publish are here.
///   Every refusal is exit 2 with one actionable line, never a half-built
///   root.
///
///   No network, ever (section 1): every input comes from the share tree or
///   --input.
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
ffi "c++" import "llvm/MC/TargetRegistry.h"
ffi "c++" import "llvm/Support/Program.h"
ffi "c++" import "llvm/TargetParser/Host.h"
ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "Native/Shims.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "algorithm"
ffi "c++" import "vector"

import API::FS::LinkFS
import API::SysrootManifest::{
    SysrootManifest,
    TomlLite,
    TomlValue,
}
import API::Text::LinkText
import Sysroot::Cache::{
    SysCache,
    SysLock,
    SysStage,
}
import Sysroot::KccArgv::KccArgv
import Sysroot::Names::{
    SysNames,
    SysTarget,
    glibc_default_version,
}
import Sysroot::Outcome::{
    SYS_STATUS_FAILED,
    SysOutcome,
}
import Sysroot::Provider::{
    StageCtx,
    SysrootProvider,
}
import Sysroot::Providers::ProviderSet::ProviderSet
import Sysroot::Runtimes::SysRuntimes
import Sysroot::Sdk::SysSdk
import Sysroot::Share::{
    GlibcVersions,
    QuirkSet,
    ShareTree,
    SysQuirk,
    SysRecipe,
}
import Sysroot::SysRun::SysRun
import Sysroot::SysUtil::{
    SysJsonField,
    SysUtil,
}
import Sysroot::Template::SysTemplate
import std::env
import std::io

/// The stages after inputs, in order (SysRoot.md section 4).
fn sys_stages() -> [string] {
    var s: [string]
    s.push("libc-headers")
    s.push("builtins")
    s.push("libc-libs")
    s.push("runtimes")
    s.push("assemble")
    s.push("toml")
    s.push("validate")
    return s
}

/// Everything parse, probe and inputs resolved for one target.
pub class SysPlan {
    pub var target:     SysTarget
    pub var recipe:     SysRecipe
    pub var share:      ShareTree
    pub var quirks:     [SysQuirk]
    pub var probe:      [string]   ///< probe facts that hold: int128
    pub var rows:       [string]   ///< the probe table, `label: value`
    pub var tools:      string                     ///< dir kcc/kld/llvm-ar were found in
    pub var os:         string
    pub var env_:       string
    pub var inputs:     [string]   ///< input dirs, relative to the share tree
    pub var in_paths:   [string]   ///< the same, absolute
    pub var in_sha:     [string]
    pub var extra:      [string]   ///< provider key_extra
    pub var floor:      string                     ///< glibc floor (the runtimes stage's libc)
    pub var stage_keys: [string]   ///< parallel to sys_stages()
    pub var key:        string                     ///< the sysroot's key
    pub var key_json:   string

    pub fn row(self, const label: string, const value: string) {
        var pad = label.copy() + ":"
        while pad.size() < 14 {
            pad += " "
        }

        self.rows.push(pad.copy() + value)
    }
}

pub class SysGen {
    pub var share_flag: string         ///< --share
    pub var cache_root: string         ///< "" = SysCache::default_root()
    pub var glibc:      string         ///< --glibc
    pub var input:      string         ///< --input
    pub var quiet:      bool   = false
    pub var jobs:       usize  = 0     ///< -j: compiles in flight, 0 = SysRun::jobs()
    /// --libc-only (build): the libc stages alone, published as include/ +
    /// lib/ + SYSROOT.toml, for a target no runtimes table serves yet (the
    /// root runtimes_recipe.py --headers derives its tables from).
    pub var libc_only: bool = false

    pub fn SysGen(self) = default

    /// The LLVM runtimes revision this binary was built from; the share
    /// tree's runtimes/REVISION must equal it.
    pub static fn runtimes_revision() -> string {
        return string(
            unsafe ((kairo::runtimes_revision_string() as unsafe *const u8) as *const u8),
        )
    }

    pub static fn tool_version() -> string {
        return string(
            unsafe ((kairo::version_string() as unsafe *const u8) as *const u8),
        )
    }

    pub fn cache(self) -> SysCache {
        var r = self.cache_root.copy()
        if r.is_empty() {
            r = SysCache::default_root()
        }

        return SysCache(r)
    }

    /// # Commands

    /// `ksys probe <target>`: parse and probe, and the table. The table is
    /// printed even when a probe refuses: the rows before it say why.
    pub fn probe(self, const target: string, @inout out: SysOutcome) -> bool {
        var p  = SysPlan()
        var ok = self.plan(target, &p, &out, false)
        for *r in p.rows {
            io::println(*r)
        }

        return ok
    }

    /// `ksys ensure <target>`: the cached sysroot, built first if need be.
    /// `path` receives it.
    pub fn ensure(self, const target: string, @inout path: string, @inout out: SysOutcome) -> bool {
        // macOS and MSVC roots are the user's SDK plus the shipped overlay,
        // not the share tree's stages (Sdk.k).
        var st    = SysTarget{}
        var cands = cxx::std::vector<string>()
        var why   = ""
        if SysNames::parse(target, glibc_default_version(), &st, &cands, &why)
            && SysSdk::handles(&st) {
            var sc = self.cache()
            return SysSdk::ensure(
                &sc,
                &st,
                self.input,
                SysGen::_tools_dir(),
                &path,
                &out,
            )
        }

        var p = SysPlan()
        if !self.plan(target, &p, &out, true) {
            return false
        }

        // The key on stderr: what `ksys ls` and the cache dirs are named by.
        self._log(f"{p.target.name}: key {p.key}")
        var c = self.cache()
        if c.root.is_empty() {
            return out.refuse(
                "no cache directory for sysroots",
                "set KAIRO_SYSROOT_CACHE (or KAIRO_CACHE_DIR, XDG_CACHE_HOME, HOME)",
            )
        }

        var lock = SysLock()
        if !lock.acquire(c.lock_path(p.key)) {
            return out.fail(f"cannot lock {c.lock_path(p.key)}", "")
        }

        // After the lock: a concurrent ensure of this key that held it may
        // have finished the root while this one waited.
        var done_dir = c.sysroot_dir(p.key)
        if LinkFS::is_file(done_dir.copy() + "/.ok") {
            if !c.publish(p.target.name, p.key) {
                return out.fail(
                    f"cannot write {c.root}/by-name/{p.target.name}",
                    "",
                )
            }

            path = done_dir.copy()
            return true
        }

        if !self._run_stages(&p, &c, "", &out) {
            return false
        }

        path = done_dir.copy()
        return c.publish(p.target.name, p.key)
    }

    /// `ksys tables <target> --out DIR`: the runtimes tables the builtins
    /// and runtimes stages would compile from, written in the
    /// runtimes-recipe/ layout (targets/<name>.toml, <runtime>/<name>.toml)
    /// and not built: the template instantiated, else the shipped tables
    /// copied. What a parity check diffs against the derived tables.
    pub fn tables(self,
                  const target:  string,
                  const out_dir: string,
                  @inout out:    SysOutcome) -> bool {
        var p = SysPlan()
        if !self.plan(target, &p, &out, true) {
            return false
        }

        if SysUtil::contains(&p.inputs, "runtimes-template") {
            var why  = ""
            var tmpl = p.share.input_path("runtimes-template")
            if !SysRuntimes::from_template(
                &p.target,
                &p.recipe,
                tmpl,
                out_dir,
                &why,
            ) {
                return out.refuse(why, "")
            }

            return true
        }

        if !SysUtil::contains(&p.inputs, "runtimes-recipe") {
            return out.refuse(
                f"{p.target.name} builds no runtimes from this share tree",
                "",
            )
        }

        var rdir = p.share.input_path("runtimes-recipe")
        var tt   = SysRecipe()
        var tp   = f"{rdir}/targets/{p.target.name}.toml"
        if !tt.load(tp) {
            return out.refuse(f"{tp}: {tt.error}", "")
        }

        LinkFS::make_dirs(out_dir.copy() + "/targets")
        if !SysRun::put_file(
            tp,
            f"{out_dir}/targets/{p.target.name}.toml",
            false,
        ) {
            return out.fail(f"cannot copy {tp}", "")
        }

        for *rt in SysTemplate::runtimes() {
            var key = tt.str("", *rt)
            if key.is_empty() {
                continue
            }

            LinkFS::make_dirs(out_dir.copy() + "/" + *rt)
            var from = f"{rdir}/{*rt}/{key}.toml"
            if !SysRun::put_file(
                from,
                f"{out_dir}/{*rt}/{p.target.name}.toml",
                false,
            ) {
                return out.fail(f"cannot copy {from}", "")
            }
        }

        return true
    }

    /// `ksys build <target> --out DIR`: the same pipeline, uncached.
    pub fn build(self,
                 const target:  string,
                 const out_dir: string,
                 @inout out:    SysOutcome) -> bool {
        var p = SysPlan()
        if !self.plan(target, &p, &out, true) {
            return false
        }

        if LinkFS::exists(out_dir) && !LinkFS::list_dir(out_dir).empty() {
            return out.refuse(f"--out {out_dir} exists and is not empty", "")
        }

        var scratch = LinkText::strip_slash(out_dir.copy()) + ".ksys-stages"
        var c       = SysCache(scratch)
        var ok      = self._run_stages(&p, &c, out_dir, &out)
        LinkFS::remove_tree(scratch)
        return ok
    }

    /// `ksys validate <dir>` (SysRoot.md 4.10): the manifest and the dirs it
    /// names, then t.c / t.cpp and the three .k programs built against the
    /// root through its SYSROOT.toml alone, and run where the recipe's
    /// [validate] run mode and the host allow. A step that cannot run is
    /// printed SKIP, never counted a pass.
    pub fn validate(self, const dir: string, @inout out: SysOutcome) -> bool {
        var mpath = LinkText::join(dir.copy(), SysrootManifest::file_name())
        if !LinkFS::is_file(mpath) {
            return out.fail(
                f"validation failed at manifest: {mpath} is missing",
                "",
            )
        }

        var m = SysrootManifest()
        if !SysrootManifest::load(mpath, &m) {
            return out.fail(
                f"validation failed at manifest: {mpath}: {m.error}",
                "",
            )
        }

        var t     = SysTarget{}
        var cands = cxx::std::vector<string>()
        var why   = ""
        if !SysNames::parse(m.triple, glibc_default_version(), &t, &cands, &why) {
            return out.fail(f"validation failed at manifest: triple: {why}", "")
        }

        // The share tree holds the programs and the recipe's run mode; the
        // structural checks need neither, so a missing tree is reported
        // after them (validate_root refuses on an empty `share`).
        var sdir   = ShareTree::locate(self.share_flag)
        var recipe = SysRecipe()
        var rpath  = LinkText::join(sdir.copy(), f"families/{t.recipe}.toml")
        if !ShareTree::present(sdir) {
            sdir = ""
        } else if !recipe.load(rpath) {
            return out.refuse(f"{rpath}: {recipe.error}", "")
        }

        var log = LinkFS::temp_dir("ksys-validate")
        if log.is_empty() {
            return out.fail(
                "cannot create a temporary directory for validation",
                "",
            )
        }

        var rep = ""
        var ok = SysGen::validate_root(
            dir,
            &t,
            &recipe,
            sdir,
            SysGen::_tools_dir(),
            log,
            &rep,
            &out,
        )

        io::print(rep)
        if ok {
            LinkFS::remove_tree(log)
        }

        return ok
    }

    /// The checks of `ksys validate` on `root` for target `t`, logs and
    /// scratch under `work`. One line per step goes to `rep`: a caller
    /// with a path to print on stdout (ensure) must not have it mixed in.
    pub static fn validate_root(const root:  string,
                                t:           *SysTarget,
                                recipe:      *SysRecipe,
                                const share: string,
                                const tools: string,
                                const work:  string,
                                @inout rep:  string,
                                @inout out:  SysOutcome) -> bool {
        var mpath = LinkText::join(root.copy(), SysrootManifest::file_name())
        var m     = SysrootManifest()
        if !SysrootManifest::load(mpath, &m) {
            return out.fail(
                f"validation failed at manifest: {mpath}: {m.error}",
                "",
            )
        }

        rep += f"manifest:     {mpath}" + "\n"
        rep += f"triple:       {m.triple} ({t->family})" + "\n"
        if m.clang_triple.is_empty() {
            rep += "clang_triple: (none: derived by the driver)" + "\n"
        } else {
            rep += f"clang_triple: {m.clang_triple}" + "\n"
        }

        var base = m.dir.copy()
        if !m.sysroot.is_empty() && m.sysroot != "." {
            base = LinkText::join(m.dir.copy(), m.sysroot.copy())
        }

        for *d in m.include_dirs {
            if !LinkFS::is_dir(LinkText::join(base.copy(), d->copy())) {
                return out.fail(
                    f"validation failed at manifest: include_dirs entry {*d} is not a directory under {base}",
                    "",
                )
            }
        }

        for *d in m.lib_dirs {
            if !LinkFS::is_dir(LinkText::join(base.copy(), d->copy())) {
                return out.fail(
                    f"validation failed at manifest: lib_dirs entry {*d} is not a directory under {base}",
                    "",
                )
            }
        }

        rep += "structure:    ok" + "\n"
        if share.is_empty() {
            return out.refuse(
                "validation needs the share tree: its validate/ programs and the family recipe",
                SysGen::_share_note(),
            )
        }

        var kcc   = SysGen::_exe(tools, "kcc")
        var kairo = SysGen::_exe(tools, "kairo")
        if !LinkFS::is_file(kcc) || !LinkFS::is_file(kairo) {
            return out.refuse(
                f"validation needs kcc and kairo beside {tools}",
                "reinstall the toolchain",
            )
        }

        LinkFS::make_dirs(work)
        var vdir = LinkText::join(share.copy(), "validate")
        var exp = SysGen::_expectations(
            LinkText::join(vdir.copy(), "expect.toml"),
        )

        if exp.is_empty() {
            return out.refuse(
                f"share input {vdir}/expect.toml missing or empty",
                "",
            )
        }

        // Every build names the manifest's own triple: the driver checks
        // it against --target, and a glibc name's -glibc<v> tag is not a
        // triple clang reads.
        // The driver takes a bundled <prefix>/sysroot/<name> over --sysroot:
        // prove this toolchain builds against `root` before believing a
        // single result.
        var real_root = LinkFS::real(root.copy())
        var probe: [string]
        probe.push(kcc.copy())
        KccArgv::push_target(&probe, m.triple, root)
        probe.push("-###")
        probe.push(LinkText::join(vdir.copy(), "t.c"))
        probe.push("-o")
        probe.push(LinkText::join(work.copy(), "probe"))
        var plog = LinkText::join(work.copy(), "probe.log")
        SysRun::run(&probe, plog)
        var ptext = ""
        LinkFS::read(plog, &ptext)
        var seen = SysGen::_sysroots_in(ptext)
        for *r in seen {
            if LinkFS::real(r->copy()) != real_root {
                return out.refuse(
                    f"cannot validate {root}: this toolchain builds {t->name} against {*r} (a bundled root shadows --sysroot)",
                    "run ksys from a toolchain without <prefix>/sysroot/" + t->name,
                )
            }
        }

        // replay-validate.sh passes the TOML's extra_cflags itself: the
        // driver does not read them yet, and wasm's
        // -fwasm-exceptions is what makes a C++ catch work there.
        var extra: [string]
        var mtext = ""
        LinkFS::read(mpath, &mtext)
        var mtoml = TomlLite(mtext)
        var mkey  = ""
        var mval  = TomlValue{}
        while mtoml.next(&mkey, &mval) {
            if mtoml.table.is_empty() && mkey == "extra_cflags" && mval.kind == 3 {
                extra = SysUtil::taken(&mval.list)
            }
        }

        var mode   = recipe->str("validate", "run")
        var runner: [string]
        var skip   = SysGen::_runner(t, mode, work, &runner)
        var ext    = ""
        if t->family == "windows-gnu" || t->family == "windows-msvc" {
            ext = ".exe"
        } else if t->family == "wasi" {
            ext = ".wasm"
        }

        var progs: [string]
        progs.push("t.c")
        if m.has_libcxx {
            progs.push("t.cpp")
        }

        progs.push("test.k")
        progs.push("floats.k")
        progs.push("tfbf.k")
        // A program spelling a float type the target lacks (clang has no
        // _Float16 on PowerPC or MIPS, no __bf16 there or on SystemZ, no
        // __float128 on any of them or LoongArch) cannot build there: SKIP
        // it, never a pass. One compile per type asks the toolchain itself.
        var have: [string]
        var lack: [string]
        for *src in progs {
            var want = SysGen::_expected(&exp, *src)
            var need = ""
            for *e in exp {
                if LinkText::starts_with(e->copy(), "types/" + *src + "=") {
                    need = LinkText::slice(*e, src->size() + 7, e->size())
                }
            }

            var missing = ""
            if !need.is_empty() {
                for *ty in SysUtil::split(need, (',' as u8)) {
                    if !SysGen::_has_type(
                        kcc,
                        m.triple,
                        root,
                        work,
                        *ty,
                        &have,
                        &lack,
                    ) {
                        missing += if (missing.is_empty()) => (ty->copy()) else => ", " + *ty
                    }
                }
            }

            if !missing.is_empty() {
                var spad = src->copy() + ":"
                while spad.size() < 14 {
                    spad += " "
                }

                rep += f"{spad}SKIP (the target has no {missing})" + "\n"
                continue
            }

            var dot  = LinkText::find(src->copy(), ".", 0)
            var stem = LinkText::slice(*src, 0, dot)
            var lang = LinkText::slice(*src, dot + 1, src->size())
            var bin = LinkText::join(
                work.copy(),
                stem.copy() + "-" + lang + ext,
            )

            var argv: [string]
            if lang == "k" {
                argv.push(kairo.copy())
                argv.push(LinkText::join(vdir.copy(), src->copy()))
                argv.push("--target")
                argv.push(m.triple.copy())
                argv.push("--sysroot")
                argv.push(root.copy())
                argv.push("--sysroot-exact")
                argv.push("-o")
                argv.push(bin.copy())
            } else {
                argv.push(kcc.copy())
                if lang == "cpp" {
                    argv.push("--driver-mode=g++")
                }

                KccArgv::push_target(&argv, m.triple, root)
                for *x in extra {
                    argv.push(x->copy())
                }

                argv.push(LinkText::join(vdir.copy(), src->copy()))
                argv.push("-o")
                argv.push(bin.copy())
            }

            var blog = LinkText::join(
                work.copy(),
                stem.copy() + "-" + lang + ".build.log",
            )

            var rc  = SysRun::run(&argv, blog)
            var pad = src->copy() + ":"
            while pad.size() < 14 {
                pad += " "
            }

            if rc != 0 {
                var text = ""
                LinkFS::read(blog, &text)
                return out.fail(
                    f"validation failed at {*src}: the build exited {rc}: {SysGen::_first_line(text)}",
                    f"log: {blog}",
                )
            }

            if !skip.is_empty() {
                rep += f"{pad}built; run SKIP ({skip})" + "\n"
                continue
            }

            var run = runner.copy()
            run.push(bin.copy())
            var rlog = LinkText::join(
                work.copy(),
                stem.copy() + "-" + lang + ".run.log",
            )

            var got = SysRun::run(&run, rlog)
            if f"{got}" != want {
                return out.fail(
                    f"validation failed at {*src}: it exited {got}, expected {want}",
                    f"log: {rlog}",
                )
            }

            rep += f"{pad}built, ran, exit {got}" + "\n"
        }

        return true
    }

    /// `ksys verify-share`: every registry input re-hashed, no memo. Lists
    /// each, then refuses on the first problem.
    pub fn verify_share(self, @inout out: SysOutcome) -> bool {
        var share = ShareTree()
        var sdir  = ShareTree::locate(self.share_flag)
        if !share.load(sdir) {
            return out.refuse(
                f"share input {share.error}",
                SysGen::_share_note(),
            )
        }

        var first = ""
        for var i: usize = 0; i < share.input_dirs.size(); ++i {
            var rel  = share.input_dirs[i].copy()
            var path = share.input_path(rel)
            if !LinkFS::is_dir(path) {
                io::println(f"MISSING   {rel}")
                if first.is_empty() {
                    first = f"share input {path} missing"
                }

                continue
            }

            var err = ""
            var got = SysUtil::tree_sha256(path, share.follows_links(), &err)
            if !err.is_empty() {
                io::println(f"ERROR     {rel}")
                if first.is_empty() {
                    first = f"share input {err}"
                }

                continue
            }

            if got != share.input_sha[i] {
                io::println(f"MISMATCH  {rel}")
                if first.is_empty() {
                    first = f"share input {path}: tree hash mismatch (registry.toml)"
                }

                continue
            }

            io::println(f"ok        {rel}")
        }

        var have = share.revision()
        var want = SysGen::runtimes_revision()
        if have != want && first.is_empty() {
            first = f"runtimes/REVISION {have} does not match the compiler ({want}); reinstall the toolchain"
        }

        if !first.is_empty() {
            return out.refuse(first, "")
        }

        return true
    }

    /// # The pipeline

    /// parse, probe and (when `with_inputs`) inputs and keys. False with
    /// `out` set on the first refusal.
    pub fn plan(self,
                const target: string,
                @inout p:     SysPlan,
                @inout out:   SysOutcome,
                with_inputs:  bool) -> bool {
        /// ## parse (4.1)
        var sdir    = ShareTree::locate(self.share_flag)
        var present = ShareTree::present(sdir)
        var gv      = GlibcVersions()
        var gdef    = glibc_default_version()
        var have_gv = present && gv.load(LinkText::join(sdir.copy(), "glibc/VERSIONS.toml"))
        if have_gv && !gv.default_.is_empty() {
            gdef = gv.default_.copy()
        }

        var cands = cxx::std::vector<string>()
        var why   = ""
        if !SysNames::parse(target, gdef, &p.target, &cands, &why) {
            return out.refuse(why, "")
        }

        if !self.glibc.is_empty() {
            if p.target.family != "linux-gnu" {
                return out.refuse(
                    f"--glibc applies to glibc targets, and {p.target.name} is not one",
                    "",
                )
            }

            p.target = SysNames::make(
                p.target.family,
                p.target.arch,
                self.glibc,
            )
        }

        p.row("name", p.target.name)
        p.row("family", p.target.family)
        p.row("provider", p.target.provider)
        if !p.target.libc_version.is_empty() {
            p.row("libc_version", p.target.libc_version)
        }

        if !present {
            p.row("share", f"{sdir} (missing)")
            return out.refuse(
                f"share input {sdir}/registry.toml missing",
                SysGen::_share_note(),
            )
        }

        p.row("share", sdir)
        if !p.share.load(sdir) {
            return out.refuse(
                f"share input {p.share.error}",
                SysGen::_share_note(),
            )
        }

        var have = p.share.revision()
        var want = SysGen::runtimes_revision()
        p.row(
            "runtimes",
            if (have.is_empty()) => ("(no REVISION)") else => have.copy(),
        )

        if have != want {
            var shown = if (have.is_empty()) => ("(missing)") else => have.copy()
            return out.refuse(
                f"runtimes/REVISION {shown} does not match the compiler ({want}); reinstall the toolchain",
                "",
            )
        }

        if p.target.family == "linux-gnu" {
            if !have_gv {
                return out.refuse(
                    f"share input {sdir}/glibc/VERSIONS.toml missing",
                    "",
                )
            }

            var v = p.target.libc_version.copy()
            if !SysUtil::contains(&gv.versions, v) {
                var list = SysUtil::joined(&gv.versions, ", ")
                return out.refuse(
                    f"glibc {v} is not in the shipped set {list}",
                    "",
                )
            }

            if SysUtil::version_less(v, gv.floor) {
                return out.refuse(
                    f"glibc {v} is below the floor {gv.floor}",
                    "",
                )
            }

            p.floor = gv.floor.copy()
        }

        var rpath = LinkText::join(
            sdir.copy(),
            f"families/{p.target.recipe}.toml",
        )

        if !LinkFS::is_file(rpath) {
            return out.refuse(f"share input {rpath} missing", "")
        }

        if !p.recipe.load(rpath) {
            return out.refuse(f"{rpath}: {p.recipe.error}", "")
        }

        // A recipe template keyed on a [per_arch] table has no row for an
        // arch it does not port (glibc's {per_arch.triple}): keep the
        // built-in triple then, so the backend probe and the provider's
        // refusal name the target and not the template.
        if !p.recipe.clang_triple.is_empty() {
            var ct = p.recipe.expand(p.recipe.clang_triple, &p.target)
            if !LinkText::contains(ct, "{") {
                p.target.clang_triple = ct.copy()
            }
        }

        /// ## probe (4.2)
        var norm = llvm::Triple::normalize(kairo::sref(p.target.clang_triple))
        var parts = SysUtil::split(string(unsafe ((norm.c_str() as unsafe *const u8) as *const u8)), ('-' as u8))
        p.os   = if (parts.size() > 2) => (parts[2].copy()) else => ""
        p.env_ = if (parts.size() > 3) => (parts[3].copy()) else => ""

        var tt                    = llvm::Triple(norm)
        var err: cxx::std::string
        var unsafe *backend = llvm::TargetRegistry::lookupTarget(tt, &err)
        var arch_name = if (parts.is_empty()) => (p.target.arch.copy()) else => parts[0].copy()
        if backend == &null {
            p.row("backend", "missing")
            return out.refuse(
                f"backend {arch_name} not compiled into this toolchain",
                "",
            )
        }

        p.row("backend", "ok")

        // What clang's TargetInfo decides (hasInt128Type): 64-bit pointers,
        // or wasm. Derived, not compiled for: a kcc spawn per probe would
        // put a process in the driver hook's path for the same answer.
        var int128 = tt.isArch64Bit() || tt.isWasm()
        p.row("int128", if (int128) => ("yes") else => "no")
        if int128 {
            p.probe.push("int128")
        }

        var qpath = LinkText::join(sdir.copy(), "quirks.toml")
        if LinkFS::is_file(qpath) {
            var qs = QuirkSet()
            if !qs.load(qpath) {
                return out.refuse(qs.error, "")
            }

            p.quirks = qs.matching(&p.target, p.os, p.env_, &p.probe)
        }

        var qids: [string]
        var rewrites: [string]
        for *q in p.quirks {
            qids.push(q->id.copy())
            if !q->target_rewrite.is_empty() {
                rewrites.push(q->id.copy())
                p.target.clang_triple = p.recipe.expand(
                    q->target_rewrite,
                    &p.target,
                )
            }
        }

        // After the recipe and the quirks: either may have rewritten it.
        p.row("clang_triple", p.target.clang_triple)
        p.row(
            "quirks",
            if (qids.is_empty()) => ("(none)") else => SysUtil::joined(&qids, ", "),
        )

        if rewrites.size() > 1 {
            var list = SysUtil::joined(&rewrites, ", ")
            return out.refuse(
                f"quirks {list} each rewrite the target; at most one may",
                "",
            )
        }

        var prov = ProviderSet::make(p.target.provider, self.input)
        if prov == &null {
            return out.refuse(f"no provider {p.target.provider}", "")
        }

        finally {
            kairo::std::destroy(prov)
        }

        if !prov->supports(&p.target, &p.recipe, &out) {
            p.row("supports", "no")
            // What the target is still worth showing: the probe of an arch
            // no provider ports yet is where its properties get checked.
            var np = SysNames::properties(&p.target)
            np.put(
                "backend",
                string(
                    unsafe ((backend->getName() as unsafe *const u8) as *const u8),
                ),
            )

            p.row("properties", np.text())
            return false
        }

        p.row("supports", "yes")
        p.extra = prov->key_extra(&p.target)

        var tools: [string]
        tools.push("kcc")
        tools.push("kld")
        tools.push("llvm-ar")
        for *t in tools {
            var at = SysGen::find_tool(*t)
            if at.is_empty() {
                p.row("tools", f"{*t} missing")
                return out.refuse(
                    f"{*t} not found beside {LinkFS::parent(env::exe_path())} or on PATH",
                    "reinstall the toolchain",
                )
            }

            if p.tools.is_empty() {
                p.tools = LinkFS::parent(at)
            }
        }

        p.row("tools", "ok")
        var props = SysNames::properties(&p.target)
        var be = string(
            unsafe ((backend->getName() as unsafe *const u8) as *const u8),
        )

        props.put("backend", be)
        p.row("properties", props.text())
        if !with_inputs {
            return true
        }

        /// ## inputs (4.3)
        var rels: [string]
        for *tmpl in p.recipe.inputs {
            rels.push(p.recipe.expand(*tmpl, &p.target))
        }

        // The builtins and runtimes stages compile the runtimes source with
        // the runtimes-recipe/ tables, so both are inputs, verified and in
        // every key: a changed table rebuilds the roots it serves. Required
        // up front when the recipe builds C++ runtimes; otherwise (wasi:
        // builtins only) taken when the registry lists them, and the
        // builtins stage refuses if it does not.
        // runtimes-template/ is the rule the tables follow and serves any
        // target in its domain; when the registry lists it the tables are
        // not needed (and taken only when listed too). Without it the
        // tables are required as before.
        var c        = self.cache()
        var has_tmpl = !p.share.registered("runtimes-template").is_empty()
        var rtin: [string]
        rtin.push("runtimes")
        rtin.push("runtimes-template")
        rtin.push("runtimes-recipe")
        for *rt in rtin {
            var need = !p.recipe.runtimes.is_empty() || !p.share.registered(*rt).is_empty()
            if *rt == "runtimes-template" {
                need = has_tmpl
            } else if *rt == "runtimes-recipe" && has_tmpl {
                need = !p.share.registered(*rt).is_empty()
            }

            if need && !SysUtil::contains(&rels, *rt) {
                rels.push(rt->copy())
            }
        }

        for *rel in rels {
            var reg = p.share.registered(*rel)
            if reg.is_empty() {
                return out.refuse(
                    f"share input {*rel} is not listed in {sdir}/registry.toml",
                    "",
                )
            }

            var path = p.share.input_path(*rel)
            if !LinkFS::is_dir(path) {
                return out.refuse(f"share input {path} missing", "")
            }

            var err = ""
            var got = SysGen::_verified_sha(
                &c,
                path,
                p.share.follows_links(),
                &err,
            )

            if !err.is_empty() {
                return out.refuse(f"share input {err}", "")
            }

            if got != reg {
                return out.refuse(
                    f"share input {path}: tree hash mismatch (registry.toml)",
                    "",
                )
            }

            p.inputs.push(rel->copy())
            p.in_paths.push(path.copy())
            p.in_sha.push(got.copy())
        }

        // A target neither the template nor the tables serve would fail in
        // the builtins stage, after the libc stages: refuse it before them.
        if self.libc_only {
            p.row("runtimes_from", "none (--libc-only)")
        } else if SysUtil::contains(&p.inputs, "runtimes-template") {
            var t = SysTemplate()
            if !t.load(p.share.input_path("runtimes-template")) {
                return out.refuse(t.error, "")
            }

            var why = ""
            if !t.fits(&p.target, &props, &why) {
                return out.refuse(
                    why,
                    "runtimes-template/index.toml [domain] lists what its rules were derived over",
                )
            }

            p.row("runtimes_from", "template")
        } else if SysUtil::contains(&p.inputs, "runtimes-recipe") {
            var rdir = p.share.input_path("runtimes-recipe")
            if !LinkFS::is_file(f"{rdir}/targets/{p.target.name}.toml") {
                return out.refuse(
                    f"no runtimes recipe for {p.target.name} in {rdir}",
                    "runtimes-recipe/index.toml lists the targets it was derived for",
                )
            }
        }

        /// ## keys (section 7)
        var build_id = SysGen::_compiler_build_id(&c, p.tools)
        for *s in sys_stages() {
            p.stage_keys.push(
                SysUtil::sha256(SysGen::_key_json(&p, build_id, *s)),
            )
        }

        p.key_json = SysGen::_key_json(&p, build_id, "")
        p.key      = SysUtil::sha256(p.key_json)
        return true
    }

    /// The stages after inputs, then the publish. Each stage is skipped
    /// when its key dir holds `.ok`; a refusal leaves nothing behind, a
    /// failure leaves `<dir>.failed/log`. `dest` "" publishes into the
    /// cache as sysroots/<key>, else into `dest` (`ksys build --out`).
    priv fn _run_stages(self,
                        p:          *SysPlan,
                        c:          *SysCache,
                        const dest: string,
                        @inout out: SysOutcome) -> bool {
        var prov = ProviderSet::make(p->target.provider, self.input)
        finally {
            kairo::std::destroy(prov)
        }

        var ctx = StageCtx()
        ctx.target = p->target.copy()
        ctx.recipe = p->recipe.copy()
        for *q in p->quirks {
            ctx.quirks.push(q->copy())
        }

        ctx.share       = p->share.dir.copy()
        ctx.inputs      = SysUtil::to_cxx(&p->in_paths)
        ctx.input       = self.input.copy()
        ctx.tools       = p->tools.copy()
        ctx.ar          = SysGen::find_tool("llvm-ar")
        ctx.jobs        = self.jobs
        ctx.input_names = p->inputs.copy()

        var stages = sys_stages()
        for var i: usize = 0; i < stages.size(); ++i {
            var name = stages[i].copy()
            if self.libc_only && name != "libc-headers" && name != "libc-libs" {
                continue
            }

            var st = SysStage(c->stage_dir(name, p->stage_keys[i]))
            if st.done() {
                ctx.done_names.push(name.copy())
                ctx.done_dirs.push(st.dir.copy())
                continue
            }

            if !st.begin() {
                return out.fail(
                    f"stage {name} failed: cannot create {st.tmp()}",
                    "",
                )
            }

            self._log(f"{p->target.name}: stage {name}")
            ctx.stage   = st.tmp()
            ctx.log_dir = st.log_dir()
            var dst = st.tmp() + "/out"
            LinkFS::make_dirs(dst)

            var ok = false
            if name == "libc-headers" {
                ok = prov->headers(&ctx, dst, &out)
            } else if name == "libc-libs" {
                ok = prov->libs(&ctx, dst, &out)
            } else if name == "builtins" {
                ok = SysGen::_stage_builtins(&ctx, &out)
            } else if name == "runtimes" {
                ok = SysGen::_stage_runtimes(&ctx, &out)
            } else if name == "assemble" {
                ok = SysGen::_stage_assemble(&ctx, p, &out)
            } else if name == "toml" {
                ok = SysGen::_stage_toml(&ctx, &out)
            } else {
                ok = SysGen::_stage_validate(&ctx, &out)
            }

            if !ok {
                if out.status == SYS_STATUS_FAILED {
                    var log = st.fail(out.message)
                    out.message = f"stage {name} failed: {out.message} (log: {log})"
                    out.note = SysGen::_moved(
                        out.note,
                        st.tmp(),
                        st.dir.copy() + ".failed",
                    )
                } else {
                    st.abandon()
                }

                return false
            }

            if !st.commit() {
                return out.fail(
                    f"stage {name} failed: cannot rename {st.tmp()}",
                    "",
                )
            }

            ctx.done_names.push(name.copy())
            ctx.done_dirs.push(st.dir.copy())
            if name == "validate" {
                var rep = ""
                LinkFS::read(st.dir.copy() + "/out/report.txt", &rep)
                for *line in LinkText::split_lines(rep.copy()) {
                    self._log(f"{p->target.name}: validate: {*line}")
                }
            }
        }

        if self.libc_only {
            return SysGen::_publish_libc(&ctx, p, dest, &out)
        }

        return SysGen::_publish(&ctx, p, c, dest, &out)
    }

    /// --libc-only: the libc-headers and libc-libs products merged into `dest`, with the target's SYSROOT.toml. Not a sysroot (no runtimes, no
    /// validation): never cached, only `ksys build --out`.
    priv static fn _publish_libc(ctx:        *StageCtx,
                                 p:          *SysPlan,
                                 const dest: string,
                                 @inout out: SysOutcome) -> bool {
        if dest.is_empty() {
            return out.refuse("--libc-only builds with --out only", "")
        }

        LinkFS::make_dirs(dest)
        var parts: [string]
        parts.push("libc-headers")
        parts.push("libc-libs")
        for *n in parts {
            var from = ctx->product(*n)
            if from.is_empty() || !LinkFS::copy_tree(from, dest) {
                return out.fail(f"cannot copy the {*n} product into {dest}", "")
            }
        }

        if !LinkFS::write(
            dest.copy() + "/" + SysrootManifest::file_name(),
            SysGen::render_toml(&p->recipe, &p->target),
        ) {
            return out.fail(f"cannot write {dest}/SYSROOT.toml", "")
        }

        return true
    }

    /// # Generic stages

    /// Stage builtins (4.5): <out>/<builtins_name>, the compiler-rt builtins
    /// archive for the target, compiled from the runtimes source
    /// (Runtimes.k).
    priv static fn _stage_builtins(ctx: *StageCtx, @inout out: SysOutcome) -> bool {
        var toml = SysGen::render_toml(&ctx->recipe, &ctx->target)
        return SysRuntimes::builtins(ctx, toml, &out)
    }

    /// Stage runtimes (4.7): an install prefix under <out>: every [layout]
    /// gather item at its install path (lib/libc++.a, include/c++/v1, ...),
    /// and crt/clang_rt.crtbegin.o / crtend.o when the recipe has
    /// crt_objects; compiled as the builtins are.
    priv static fn _stage_runtimes(ctx: *StageCtx, @inout out: SysOutcome) -> bool {
        var toml = SysGen::render_toml(&ctx->recipe, &ctx->target)
        return SysRuntimes::runtimes(ctx, toml, &out)
    }

    /// Stage assemble (4.8): the root, from the stages' products, per the
    /// recipe's [layout]; LICENSES/ per input (section 15); the
    /// __config_site and assert_file_contains checks.
    priv static fn _stage_assemble(ctx: *StageCtx, p: *SysPlan, @inout out: SysOutcome) -> bool {
        var root  = ctx->stage.copy() + "/out"
        var none: [string]
        var parts: [string]
        parts.push("libc-headers")
        parts.push("libc-libs")
        for *part in parts {
            var from = ctx->product(*part)
            if !SysRun::link_tree(from, root, &none) {
                return out.fail(f"cannot lay {from} into {root}", "")
            }
        }

        var rl = ctx->recipe.expand(
            ctx->recipe.str("", "resource_layout"),
            &ctx->target,
        )

        var bn = ctx->recipe.expand(
            ctx->recipe.str("", "builtins_name"),
            &ctx->target,
        )

        var bsrc = ctx->product("builtins") + "/" + bn
        if !LinkFS::is_file(bsrc)
            || !SysRun::put_file(bsrc, root.copy() + "/" + rl + "/" + bn, true) {
            return out.fail(f"the builtins stage left no {bn}", "")
        }

        var rt = ctx->product("runtimes")
        for *g in ctx->recipe.list("layout", "gather") {
            var from = rt.copy() + "/" + *g
            var to = root.copy() + "/" + SysRuntimes::layout_path(
                &ctx->recipe,
                *g,
            )

            if LinkFS::is_dir(from) {
                if !SysRun::link_tree(from, to, &none) {
                    return out.fail(f"cannot lay {from} into {to}", "")
                }
            } else if !LinkFS::is_file(from) || !SysRun::put_file(from, to, true) {
                return out.fail(f"the runtimes stage left no {*g}", "")
            }

            if *g == "include/c++/v1" && !LinkFS::is_file(to.copy() + "/__config_site") {
                return out.fail(
                    f"{to} has no __config_site beside the libc++ headers",
                    "",
                )
            }
        }

        if ctx->recipe.flag("", "crt_objects", false) {
            for *n in SysRuntimes::crt_names() {
                if !SysRun::put_file(
                    rt.copy() + "/crt/" + *n,
                    root.copy() + "/" + rl + "/" + *n,
                    true,
                ) {
                    return out.fail(f"the runtimes stage left no crt/{*n}", "")
                }
            }
        }

        // Section 15: every input's notices travel with the root, and the
        // compiler-rt / libc++ ones always (the builtins are in every root).
        var comps: [string]
        for *rel in p->inputs {
            var lic = ""
            for var i: usize = 0; i < p->share.license_dirs.size(); ++i {
                if p->share.license_dirs[i] == *rel {
                    lic = p->share.license_ids[i].copy()
                }
            }

            if lic.is_empty() {
                return out.refuse(
                    f"share input {*rel} has no [licenses] entry in registry.toml",
                    "",
                )
            }

            var comp = SysUtil::split(*rel, ('/' as u8))[0].copy()
            if !SysUtil::contains(&comps, comp) {
                comps.push(comp.copy())
            }
        }

        if !SysUtil::contains(&comps, "runtimes") {
            comps.push("runtimes")
        }

        for *comp in comps {
            var from = ctx->share.copy() + "/licenses/" + *comp
            if !LinkFS::is_dir(from)
                || !SysRun::copy_tree(
                    from,
                    root.copy() + "/LICENSES/" + *comp,
                    &none,
                ) {
                return out.refuse(f"share input {from} missing", "")
            }
        }

        for *q in ctx->quirks {
            for *a in q->assert_file_contains {
                var colon = LinkText::find(a->copy(), ":", 0)
                var file  = root.copy() + "/" + LinkText::slice(*a, 0, colon)
                var want  = LinkText::slice(*a, colon + 1, a->size())
                var text  = ""
                if !LinkFS::read(file, &text) || !LinkText::contains(text, want) {
                    return out.fail(
                        f"quirk {q->id}: {file} does not contain {want}",
                        "",
                    )
                }
            }
        }

        return true
    }

    /// Stage toml (4.9): SYSROOT.toml from the recipe's [toml], keys in
    /// table order, `f"{key:<13} = {value}"`, templates expanded.
    priv static fn _stage_toml(ctx: *StageCtx, @inout out: SysOutcome) -> bool {
        var text = SysGen::render_toml(&ctx->recipe, &ctx->target)
        if text.is_empty() {
            return out.refuse(
                f"the {ctx->target.recipe} recipe has no [toml] table",
                "",
            )
        }

        if !LinkFS::write(
            ctx->stage.copy() + "/out/" + SysrootManifest::file_name(),
            text,
        ) {
            return out.fail(f"cannot write {ctx->stage}/out/SYSROOT.toml", "")
        }

        return true
    }

    /// The SYSROOT.toml text for `t`; "" when the recipe has no [toml].
    pub static fn render_toml(r: *SysRecipe, t: *SysTarget) -> string {
        return r->render_toml(t)
    }

    /// Stage validate (4.10) on the assembled root plus its SYSROOT.toml.
    /// The root is a hard-link copy, removed after: the stage keeps only
    /// its logs.
    priv static fn _stage_validate(ctx: *StageCtx, @inout out: SysOutcome) -> bool {
        var rep  = ""
        var root = ctx->stage.copy() + "/root"
        var none: [string]
        var asm_ = ctx->product("assemble")
        var tom  = ctx->product("toml") + "/" + SysrootManifest::file_name()
        if !SysRun::link_tree(asm_, root, &none)
            || !SysRun::put_file(
                tom,
                root.copy() + "/" + SysrootManifest::file_name(),
                false,
            ) {
            return out.fail(f"cannot lay out {root} for validation", "")
        }

        var ok = SysGen::validate_root(
            root,
            &ctx->target,
            &ctx->recipe,
            ctx->share,
            ctx->tools,
            ctx->log_dir.copy() + "/validate",
            &rep,
            &out,
        )

        LinkFS::write(ctx->stage.copy() + "/out/report.txt", rep)
        LinkFS::remove_tree(root)
        return ok
    }

    /// The finished root into sysroots/<key> (or `dest`), with
    /// SYSROOT.toml and .kairo-sysroot.json; renamed into place whole, so a
    /// reader sees no root or a complete one.
    priv static fn _publish(ctx:        *StageCtx,
                            p:          *SysPlan,
                            c:          *SysCache,
                            const dest: string,
                            @inout out: SysOutcome) -> bool {
        var fin = if (dest.is_empty()) => (c->sysroot_dir(p->key))
                  else => LinkText::strip_slash(dest.copy())
        var tmp  = fin.copy() + ".tmp"
        var none: [string]
        LinkFS::remove_tree(tmp)
        var tom = ctx->product("toml") + "/" + SysrootManifest::file_name()
        if !SysRun::link_tree(ctx->product("assemble"), tmp, &none)
            || !SysRun::put_file(
                tom,
                tmp.copy() + "/" + SysrootManifest::file_name(),
                false,
            ) {
            LinkFS::remove_tree(tmp)
            return out.fail(f"cannot write {tmp}", "")
        }

        var f: [SysJsonField]
        SysUtil::field(&f, "key", SysUtil::json_str(p->key))
        SysUtil::field(&f, "key_object", p->key_json)
        var stages = sys_stages()
        var sk: [string]
        for var i: usize = 0; i < stages.size(); ++i {
            sk.push(stages[i].copy() + "=" + p->stage_keys[i])
        }

        SysUtil::field(&f, "stage_keys", SysUtil::json_list(&sk))
        var qids: [string]
        for *q in p->quirks {
            qids.push(q->id.copy())
        }

        SysUtil::field(&f, "quirks", SysUtil::json_list(&qids))
        var ins: [string]
        for var i: usize = 0; i < p->inputs.size(); ++i {
            ins.push(p->inputs[i].copy() + "=" + p->in_sha[i])
        }

        SysUtil::field(&f, "inputs", SysUtil::json_list(&ins))
        var lics = SysUtil::list_dir(tmp.copy() + "/LICENSES")
        SysUtil::sort(&lics)
        SysUtil::field(&f, "licenses", SysUtil::json_list(&lics))
        SysUtil::field(
            &f,
            "clang_triple",
            SysUtil::json_str(p->target.clang_triple),
        )

        SysUtil::field(
            &f,
            "libc_version",
            SysUtil::json_str(p->target.libc_version),
        )

        var by = "ksys " + SysGen::tool_version()
        SysUtil::field(&f, "generated_by", SysUtil::json_str(by))
        if !LinkFS::write(
            tmp.copy() + "/.kairo-sysroot.json",
            SysUtil::json_object(&f) + "\n",
        ) {
            LinkFS::remove_tree(tmp)
            return out.fail(f"cannot write {tmp}/.kairo-sysroot.json", "")
        }

        if dest.is_empty() && !LinkFS::write(tmp.copy() + "/.ok", "") {
            LinkFS::remove_tree(tmp)
            return out.fail(f"cannot write {tmp}/.ok", "")
        }

        LinkFS::remove_tree(fin)
        if !LinkFS::rename(tmp, fin) {
            LinkFS::remove_tree(tmp)
            return out.fail(f"cannot rename {tmp} to {fin}", "")
        }

        return true
    }

    /// The dir the toolchain binaries are in: kcc's, as plan() finds it.
    priv static fn _tools_dir() -> string {
        var k = SysGen::find_tool("kcc")
        return if (k.is_empty()) => (LinkFS::parent(env::exe_path())) else => LinkFS::parent(k)
    }

    priv static fn _exe(const dir: string, const name: string) -> string {
        var p = LinkText::join(dir.copy(), name.copy())
        eval if defined!(_WIN32) {
            p = p + ".exe"
        }

        return p
    }

    /// validate/expect.toml [exit] as `file=code` lines.
    priv static fn _expectations(const path: string) -> [string] {
        var out: [string]
        var text = ""
        if !LinkFS::read(path, &text) {
            return out
        }

        var toml = TomlLite(text)
        var key  = ""
        var val  = TomlValue{}
        while toml.next(&key, &val) {
            if toml.table == "exit" && val.kind == 1 {
                out.push(key.copy() + "=" + val.text)
            } else if toml.table == "types" && val.kind == 3 {
                // [types] "<file>" = ["f16", ...]: the Kairo float types the
                // program spells, kept as types/<file>=f16,bf16.
                var items = SysUtil::strings(&val.list)
                out.push("types/" + key + "=" + SysUtil::joined(&items, ","))
            }
        }

        return out
    }

    /// Whether kcc compiles a declaration of Kairo float type `ty`
    /// (f16 / bf16 / f128) for `triple`; memoised in `have` / `lack`.
    /// An unknown name is taken as present (the program then shows it).
    priv static fn _has_type(const kcc:    string,
                             const triple: string,
                             const root:   string,
                             const work:   string,
                             const ty:     string,
                             @inout have:  [string],
                             @inout lack:  [string]) -> bool {
        if SysUtil::contains(&have, ty) {
            return true
        }

        if SysUtil::contains(&lack, ty) {
            return false
        }

        var c = ""
        if ty == "f16" {
            c = "_Float16"
        } else if ty == "bf16" {
            c = "__bf16"
        } else if ty == "f128" {
            c = "__float128"
        } else {
            return true
        }

        var src = LinkText::join(work.copy(), f"type-{ty}.c")
        LinkFS::write(src, f"{c} kairo_type_probe;\n")
        var argv: [string]
        argv.push(kcc.copy())
        KccArgv::push_target(&argv, triple, root)
        argv.push("-c")
        argv.push(src.copy())
        argv.push("-o")
        argv.push(LinkText::join(work.copy(), f"type-{ty}.o"))
        var ok = SysRun::run(
            &argv,
            LinkText::join(work.copy(), f"type-{ty}.log"),
        ) == 0
        if ok {
            have.push(ty.copy())
        } else {
            lack.push(ty.copy())
        }

        return ok
    }

    priv static fn _expected(@inout exp: [string], const file: string) -> string {
        for *e in exp {
            if LinkText::starts_with(e->copy(), file.copy() + "=") {
                return LinkText::slice(*e, file.size() + 1, e->size())
            }
        }

        return "0"
    }

    /// Every --sysroot=<dir> in a driver's -### output.
    priv static fn _sysroots_in(const text: string) -> [string] {
        var out: [string]
        var pat = "--sysroot="
        var i   = LinkText::find(text.copy(), pat.copy(), 0)
        while i < text.size() {
            var b = i + pat.size()
            var e = b
            while e < text.size()
                && text.data()[e] != (' ' as u8)
                && text.data()[e] != ('\x22' as u8)
                && text.data()[e] != ('\n' as u8) {
                e += 1
            }

            var r = LinkText::slice(text, b, e)
            if !SysUtil::contains(&out, r) {
                out.push(r.copy())
            }

            i = LinkText::find(text.copy(), pat.copy(), e)
        }

        return out
    }

    /// How validation runs a program for `t` under run mode `mode`:
    /// `argv` receives the runner prefix (empty = run directly). Returns
    /// "" when it can run, else why it cannot (printed as SKIP).
    priv static fn _runner(t:           *SysTarget,
                           const mode:  string,
                           const work:  string,
                           @inout argv: [string]) -> string {
        var host = string(
            unsafe ((llvm::sys::getProcessTriple().c_str() as unsafe *const u8) as *const u8),
        )

        var hparts = SysUtil::split(host, ('-' as u8))
        var harch  = hparts[0].copy()
        var hos = if (LinkText::contains(host, "linux")) => ("linux") else => host
        var tos = if (LinkText::starts_with(t->family.copy(), "linux")) => ("linux")
                  else => t->family.copy()
        // x32 runs on an x86_64 kernel built with CONFIG_X86_X32_ABI; without
        // it the run fails rather than SKIPs (qemu-user has no x32 target).
        var native = harch == t->arch
            || harch == "x86_64" && t->arch == "i686"
            || harch == "x86_64" && t->arch == "x32"
        if mode == "link-only" || mode.is_empty() {
            return "link-only target"
        }

        if mode == "wine-if-present" {
            var wine = SysGen::find_tool("wine")
            if wine.is_empty() {
                return "no wine on PATH"
            }

            argv.push(wine.copy())
            return ""
        }

        if mode == "wasmtime-or-node-if-present" {
            // node first: clang's -fwasm-exceptions emits the legacy EH
            // encoding, which node runs (behind its exnref flag) and
            // wasmtime rejects.
            var node = SysGen::find_tool("node")
            if !node.is_empty() {
                var js   = LinkText::join(work.copy(), "run-wasi.mjs")
                var q    = "\x27"
                var code = "import { readFile } from " + q + "node:fs/promises" + q + ";\n"
                code += "import { WASI } from " + q + "node:wasi" + q + ";\n"
                code += "const wasi = new WASI({ version: " + q + "preview1" + q + ", args: process.argv.slice(2) });\n"
                code += "const mod = await WebAssembly.compile(await readFile(process.argv[2]));\n"
                code += "const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());\n"
                code += "process.exit(wasi.start(inst));\n"
                LinkFS::write(js, code)
                argv.push(node.copy())
                argv.push("--no-warnings")
                argv.push("--experimental-wasm-exnref")
                argv.push(js.copy())
                return ""
            }

            var wt = SysGen::find_tool("wasmtime")
            if wt.is_empty() {
                return "no wasmtime or node on PATH"
            }

            argv.push(wt.copy())
            argv.push("run")
            argv.push("-W")
            argv.push("exceptions=y")
            return ""
        }

        if mode == "native-if-host" {
            return if (native && hos == tos) => ("") else => f"not a {t->family} {t->arch} host"
        }

        // native-or-qemu, native-or-qemu-with-root: Linux targets.
        if native && hos == tos {
            return ""
        }

        var qa = t->arch.copy()
        if SysNames::cpu_of(qa) == "arm" {
            qa = "arm"
        } else if qa == "i686" {
            qa = "i386"
        } else if LinkText::starts_with(qa.copy(), "powerpc") {
            // qemu-ppc, qemu-ppc64, qemu-ppc64le
            qa = "ppc" + LinkText::slice(qa, 7, qa.size())
        }

        var qemu = SysGen::find_tool("qemu-" + qa)
        if qemu.is_empty() {
            return f"no qemu-{qa} on PATH"
        }

        argv.push(qemu.copy())
        if mode == "native-or-qemu-with-root" {
            var qroot = LinkFS::env("KAIRO_QEMU_ROOT_" + t->arch)
            if qroot.is_empty() {
                return f"a dynamic {t->arch} binary under qemu needs KAIRO_QEMU_ROOT_{t->arch}"
            }

            argv.push("-L")
            argv.push(qroot.copy())
        }

        return ""
    }

    /// `s` with the path prefix `from` (a stage's .tmp, renamed on
    /// failure) spelled `to`.
    priv static fn _moved(const s: string, const from: string, const to: string) -> string {
        var at = LinkText::find(s.copy(), from.copy(), 0)
        if at >= s.size() {
            return s.copy()
        }

        return LinkText::slice(s, 0, at) + to + LinkText::slice(
            s,
            at + from.size(),
            s.size(),
        )
    }

    priv static fn _first_line(const text: string) -> string {
        for *l in LinkText::split_lines(text.copy()) {
            if LinkText::contains(*l, "error") {
                return LinkText::trim(*l)
            }
        }

        var lines = LinkText::split_lines(text.copy())
        return if (lines.empty()) => ("(no output)") else => LinkText::trim(lines[0])
    }

    /// kcc, kld, llvm-ar, cmake, ninja: beside the running binary first (a
    /// release tree's own), then PATH. "" when neither has it.
    pub static fn find_tool(const name: string) -> string {
        var exe = name.copy()
        eval if defined!(_WIN32) {
            exe = name.copy() + ".exe"
        }

        var beside = LinkText::join(LinkFS::parent(env::exe_path()), exe.copy())
        if LinkFS::is_file(beside) {
            return beside
        }

        var found = llvm::sys::findProgramByName(kairo::sref(name))
        if found.getError().value() != 0 {
            return ""
        }

        return string(
            unsafe ((found.get().c_str() as unsafe *const u8) as *const u8),
        )
    }

    /// The canonical key object (section 7). `stage` "" is the sysroot's
    /// own key, over every quirk; a stage key carries the quirks that touch
    /// that stage only, so a changed quirk rebuilds just those stages.
    priv static fn _key_json(p: *SysPlan, const build_id: string, const stage: string) -> string {
        var f: [SysJsonField]
        SysUtil::field(&f, "schema", SysCache::key_schema())
        SysUtil::field(&f, "name", SysUtil::json_str(p->target.name))
        SysUtil::field(
            &f,
            "clang_triple",
            SysUtil::json_str(p->target.clang_triple),
        )

        SysUtil::field(&f, "provider", SysUtil::json_str(p->target.provider))
        var libc = p->target.libc_version.copy()
        // The runtimes are built once per glibc floor and serve every
        // newer version (4.7), so their key must not name the requested one.
        if stage == "runtimes" && p->target.family == "linux-gnu" {
            libc = p->floor.copy()
        }

        SysUtil::field(&f, "libc_version", SysUtil::json_str(libc))
        var ins: [string]
        for var i: usize = 0; i < p->inputs.size(); ++i {
            ins.push(p->inputs[i].copy() + "=" + p->in_sha[i])
        }

        SysUtil::field(&f, "inputs", SysUtil::json_list(&ins))
        SysUtil::field(
            &f,
            "runtimes_revision",
            SysUtil::json_str(SysGen::runtimes_revision()),
        )

        SysUtil::field(&f, "compiler_build_id", SysUtil::json_str(build_id))
        SysUtil::field(
            &f,
            "tool_version",
            SysUtil::json_str(SysGen::tool_version()),
        )

        SysUtil::field(&f, "provider_extra", SysUtil::json_list(&p->extra))
        if !stage.is_empty() {
            SysUtil::field(&f, "stage", SysUtil::json_str(stage))
        }

        var qs: [string]
        for *q in p->quirks {
            if stage.is_empty() || SysGen::_quirk_touches(q, stage) {
                qs.push(q->id.copy() + ":" + SysUtil::joined(&q->effects, ";"))
            }
        }

        SysUtil::field(&f, "quirks", SysUtil::json_list(&qs))
        return SysUtil::json_object(&f)
    }

    priv static fn _quirk_touches(q: *SysQuirk, const stage: string) -> bool {
        if !q->target_rewrite.is_empty() {
            return true
        }

        if SysUtil::contains(&q->cflags_stages, stage)
            || SysUtil::contains(&q->cmake_stages, stage)
            || SysUtil::contains(&q->force_include_stages, stage) {
            return true
        }

        if stage == "builtins" && (!q->post_archive.is_empty() || !q->required_symbols.is_empty()) {
            return true
        }

        if (stage == "libc-headers" || stage == "libc-libs") && !q->musl_arch.is_empty() {
            return true
        }

        if stage == "assemble" && !q->assert_file_contains.is_empty() {
            return true
        }

        return stage == "validate"
            && (!q->assert_compiles.is_empty() || !q->required_symbols.is_empty())
    }

    /// tree_sha256 of `dir`, memoised by the tree's names, sizes and mtimes
    /// (4.3): a rebuild does not re-read hundreds of MB of unchanged input.
    priv static fn _verified_sha(c:          *SysCache,
                                 const dir:  string,
                                 follow:     bool,
                                 @inout err: string) -> string {
        var stamp = SysUtil::tree_stamp(dir, follow)
        var memo  = ""
        if !c->root.is_empty() {
            memo = f"{c->root}/verify/{SysUtil::sha256(dir)}"
            var text = ""
            if LinkFS::read(memo, &text) {
                var parts = SysUtil::split(LinkText::trim(text), (' ' as u8))
                if parts.size() == 2 && parts[0] == stamp {
                    return parts[1].copy()
                }
            }
        }

        var sha = SysUtil::tree_sha256(dir, follow, &err)
        if !sha.is_empty() && !memo.is_empty() {
            LinkFS::make_dirs(LinkFS::parent(memo))
            LinkFS::write(memo, f"{stamp} {sha}\n")
        }

        return sha
    }

    /// sha256 over the toolchain binaries a sysroot's contents depend on
    /// (section 7), memoised by path, size and mtime: hashing two 100 MB
    /// compilers on every ensure would cost more than the lookup it gates.
    /// Libraries the binaries load are not in it yet (the spec's ldd step).
    priv static fn _compiler_build_id(c: *SysCache, const tools_dir: string) -> string {
        var bins: [string]
        var bin  = LinkFS::parent(env::exe_path())
        bins.push(LinkText::join(bin.copy(), "kairo"))
        bins.push(LinkText::join(tools_dir.copy(), "kcc"))
        bins.push(LinkText::join(tools_dir.copy(), "kld"))
        bins.push(SysGen::find_tool("llvm-ar"))
        // The generator's code shapes every stage and is linked into both
        // kairo (the driver's hook) and ksys: both are in the id, whichever
        // runs, so the two key a target alike.
        var ksys = LinkText::join(bin.copy(), "ksys")
        eval if defined!(_WIN32) {
            ksys = ksys + ".exe"
        }

        if LinkFS::is_file(ksys) {
            bins.push(ksys.copy())
        }

        var stamp = ""
        for b in bins {
            stamp += f"{b} {SysUtil::file_size(b)} {LinkFS::mtime(b)}\n"
        }

        var memo = if (c->root.is_empty()) => ("") else => c->root.copy() + "/build-id"
        var text = ""
        if !memo.is_empty() && LinkFS::read(memo, &text) {
            var lines = LinkText::split_lines(text.copy())
            if lines.size() >= 1 && text == stamp.copy() + lines[lines.size() - 1] + "\n" {
                return lines[lines.size() - 1].copy()
            }
        }

        var all = ""
        for *b in bins {
            all += LinkFS::filename(*b) + " " + SysUtil::sha256_file(*b) + "\n"
        }

        var id = SysUtil::sha256(all)
        if !memo.is_empty() {
            LinkFS::make_dirs(c->root)
            LinkFS::write(memo, stamp.copy() + id + "\n")
        }

        return id
    }

    priv static fn _share_note() -> string {
        return "this toolchain ships no sysroot inputs there; pass --sysroot, or point KAIRO_SYSROOT_SHARE (ksys: --share) at a share/kairo/sysroot tree"
    }

    priv fn _log(self, const s: string) {
        if !self.quiet {
            io::eprintln(f"ksys: {s}")
        }
    }
}
