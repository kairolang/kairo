/// --- The Kairo Project ---------------------------- Sysroot/Generator.k --- ///
///
///   SysGen: the sysroot pipeline (SysRoot.md section 4) and every ksys
///   command over it. The ksys tool and the kairo driver's hook both call
///   this in-process, as kairo calls the linker library.
///
///     parse -> probe -> inputs -> libc-headers -> builtins -> libc-libs
///           -> runtimes -> assemble -> toml -> validate -> cache
///
///   parse, probe, inputs, keys and the cache are real. The provider stages
///   are the providers' (stubs that refuse until SysRoot.md section 11
///   steps 4, 5, 7, 8); builtins, runtimes, assemble, toml and validate
///   refuse as not implemented until step 4. Every refusal is exit 2 with
///   one actionable line, never a half-built root.
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
ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "Native/KShims.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import API::FS::LinkFS
import API::SysrootManifest::SysrootManifest
import API::Text::LinkText
import Sysroot::Cache::{
    SysCache,
    SysLock,
    SysStage,
}
import Sysroot::Names::{
    SysNames,
    SysTarget,
    glibc_default_version,
}
import Sysroot::Outcome::SysOutcome
import Sysroot::Provider::{
    StageCtx,
    SysrootProvider,
}
import Sysroot::Providers::ProviderSet::ProviderSet
import Sysroot::Share::{
    GlibcVersions,
    QuirkSet,
    ShareTree,
    SysQuirk,
    SysRecipe,
}
import Sysroot::SysUtil::{
    SysJsonField,
    SysUtil,
}
import std::env
import std::io

/// The stages after inputs, in order (SysRoot.md section 4).
fn sys_stages() -> cxx::std::vector<string> {
    var s = cxx::std::vector<string>()
    s.push_back("libc-headers")
    s.push_back("builtins")
    s.push_back("libc-libs")
    s.push_back("runtimes")
    s.push_back("assemble")
    s.push_back("toml")
    s.push_back("validate")
    return s
}

/// Everything parse, probe and inputs resolved for one target.
pub class SysPlan {
    pub var target:     SysTarget
    pub var recipe:     SysRecipe
    pub var share:      ShareTree
    pub var quirks:     cxx::std::vector<SysQuirk>
    pub var probe:      cxx::std::vector<string>   ///< probe facts that hold: int128
    pub var rows:       cxx::std::vector<string>   ///< the probe table, `label: value`
    pub var tools:      string                     ///< dir kcc/kld/llvm-ar were found in
    pub var os:         string
    pub var env_:       string
    pub var inputs:     cxx::std::vector<string>   ///< input dirs, relative to the share tree
    pub var in_paths:   cxx::std::vector<string>   ///< the same, absolute
    pub var in_sha:     cxx::std::vector<string>
    pub var extra:      cxx::std::vector<string>   ///< provider key_extra
    pub var floor:      string                     ///< glibc floor (the runtimes stage's libc)
    pub var stage_keys: cxx::std::vector<string>   ///< parallel to sys_stages()
    pub var key:        string                     ///< the sysroot's key
    pub var key_json:   string

    pub fn row(self, const label: string, const value: string) {
        var pad = label + ":"
        while pad.size() < 14 {
            pad += " "
        }

        self.rows.push_back(pad + value)
    }
}

pub class SysGen {
    pub var share_flag: string         ///< --share
    pub var cache_root: string         ///< "" = SysCache::default_root()
    pub var glibc:      string         ///< --glibc
    pub var input:      string         ///< --input
    pub var quiet:      bool   = false

    pub fn SysGen(self) = default

    /// The LLVM runtimes revision this binary was built from; the share
    /// tree's runtimes/REVISION must equal it.
    pub static fn runtimes_revision() -> string {
        return string(unsafe ((kairo::runtimes_revision_string() as unsafe *const u8) as *const u8))
    }

    pub static fn tool_version() -> string {
        return string(unsafe ((kairo::version_string() as unsafe *const u8) as *const u8))
    }

    pub fn cache(self) -> SysCache {
        var r = self.cache_root
        if r.empty() {
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
        for var r: string in p.rows {
            io::println(r)
        }

        return ok
    }

    /// `ksys ensure <target>`: the cached sysroot, built first if need be.
    /// \p path receives it.
    pub fn ensure(self, const target: string, @inout path: string, @inout out: SysOutcome) -> bool {
        var p = SysPlan()
        if !self.plan(target, &p, &out, true) {
            return false
        }

        // The key on stderr: what `ksys ls` and the cache dirs are named by.
        self._log(f"{p.target.name}: key {p.key}")
        var c = self.cache()
        if c.root.empty() {
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
        if LinkFS::is_file(done_dir + "/.ok") {
            if !c.publish(p.target.name, p.key) {
                return out.fail(f"cannot write {c.root}/by-name/{p.target.name}", "")
            }

            path = done_dir
            return true
        }

        if !self._run_stages(&p, &c, "", &out) {
            return false
        }

        path = done_dir
        return c.publish(p.target.name, p.key)
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

        var scratch = LinkText::strip_slash(out_dir) + ".ksys-stages"
        var c       = SysCache(scratch)
        var ok      = self._run_stages(&p, &c, out_dir, &out)
        LinkFS::remove_tree(scratch)
        return ok
    }

    /// `ksys validate <dir>`. The structural checks run; steps 1-4 of
    /// SysRoot.md 4.10 (symbols, replay, kairo, run) refuse until step 4.
    pub fn validate(self, const dir: string, @inout out: SysOutcome) -> bool {
        var mpath = LinkText::join(dir, "SYSROOT.toml")
        if !LinkFS::is_file(mpath) {
            return out.fail(f"validation failed at manifest: {mpath} is missing", "")
        }

        var m = SysrootManifest()
        if !SysrootManifest::load(mpath, &m) {
            return out.fail(f"validation failed at manifest: {mpath}: {m.error}", "")
        }

        var t     = SysTarget{}
        var cands = cxx::std::vector<string>()
        var why   = ""
        if !SysNames::parse(m.triple, glibc_default_version(), &t, &cands, &why) {
            return out.fail(f"validation failed at manifest: triple: {why}", "")
        }

        io::println(f"manifest:     {mpath}")
        io::println(f"triple:       {m.triple} ({t.family})")
        if m.clang_triple.empty() {
            io::println("clang_triple: (none: a root older than ksys)")
        } else {
            io::println(f"clang_triple: {m.clang_triple}")
        }

        var root = m.dir
        if !m.sysroot.empty() && m.sysroot != "." {
            root = LinkText::join(m.dir, m.sysroot)
        }

        for var d: string in m.include_dirs {
            if !LinkFS::is_dir(LinkText::join(root, d)) {
                return out.fail(
                    f"validation failed at manifest: include_dirs entry {d} is not a directory under {root}",
                    "",
                )
            }
        }

        for var d: string in m.lib_dirs {
            if !LinkFS::is_dir(LinkText::join(root, d)) {
                return out.fail(
                    f"validation failed at manifest: lib_dirs entry {d} is not a directory under {root}",
                    "",
                )
            }
        }

        io::println("structure:    ok")
        return out.refuse(
            "validation steps symbols, replay, kairo and run are not implemented yet",
            "SysRoot.md section 11 step 4",
        )
    }

    /// `ksys verify-share`: every registry input re-hashed, no memo. Lists
    /// each, then refuses on the first problem.
    pub fn verify_share(self, @inout out: SysOutcome) -> bool {
        var share = ShareTree()
        var sdir  = ShareTree::locate(self.share_flag)
        if !share.load(sdir) {
            return out.refuse(f"share input {share.error}", SysGen::_share_note())
        }

        var first = ""
        for var i: usize = 0; i < share.input_dirs.size(); ++i {
            var rel  = share.input_dirs[i]
            var path = share.input_path(rel)
            if !LinkFS::is_dir(path) {
                io::println(f"MISSING   {rel}")
                if first.empty() {
                    first = f"share input {path} missing"
                }

                continue
            }

            var err = ""
            var got = SysUtil::tree_sha256(path, &err)
            if got != share.input_sha[i] {
                io::println(f"MISMATCH  {rel}")
                if first.empty() {
                    first = f"share input {path}: tree hash mismatch (registry.toml)"
                }

                continue
            }

            io::println(f"ok        {rel}")
        }

        var have = share.revision()
        var want = SysGen::runtimes_revision()
        if have != want && first.empty() {
            first = f"runtimes/REVISION {have} does not match the compiler ({want}); reinstall the toolchain"
        }

        if !first.empty() {
            return out.refuse(first, "")
        }

        return true
    }

    /// # The pipeline

    /// parse, probe and (when \p with_inputs) inputs and keys. False with
    /// \p out set on the first refusal.
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
        var have_gv = present && gv.load(LinkText::join(sdir, "glibc/VERSIONS.toml"))
        if have_gv && !gv.default_.empty() {
            gdef = gv.default_
        }

        var cands = cxx::std::vector<string>()
        var why   = ""
        if !SysNames::parse(target, gdef, &p.target, &cands, &why) {
            return out.refuse(why, "")
        }

        if !self.glibc.empty() {
            if p.target.family != "linux-gnu" {
                return out.refuse(
                    f"--glibc applies to glibc targets, and {p.target.name} is not one",
                    "",
                )
            }

            p.target = SysNames::make(p.target.family, p.target.arch, self.glibc)
        }

        p.row("name", p.target.name)
        p.row("family", p.target.family)
        p.row("provider", p.target.provider)
        if !p.target.libc_version.empty() {
            p.row("libc_version", p.target.libc_version)
        }

        if !present {
            p.row("share", f"{sdir} (missing)")
            return out.refuse(f"share input {sdir}/registry.toml missing", SysGen::_share_note())
        }

        p.row("share", sdir)
        if !p.share.load(sdir) {
            return out.refuse(f"share input {p.share.error}", SysGen::_share_note())
        }

        var have = p.share.revision()
        var want = SysGen::runtimes_revision()
        p.row("runtimes", if (have.empty()) => ("(no REVISION)") else => have)
        if have != want {
            var shown = if (have.empty()) => ("(missing)") else => have
            return out.refuse(
                f"runtimes/REVISION {shown} does not match the compiler ({want}); reinstall the toolchain",
                "",
            )
        }

        if p.target.family == "linux-gnu" {
            if !have_gv {
                return out.refuse(f"share input {sdir}/glibc/VERSIONS.toml missing", "")
            }

            var v = p.target.libc_version
            if !SysUtil::contains(&gv.versions, v) {
                var list = SysUtil::joined(&gv.versions, ", ")
                return out.refuse(f"glibc {v} is not in the shipped set {list}", "")
            }

            if SysUtil::version_less(v, gv.floor) {
                return out.refuse(f"glibc {v} is below the floor {gv.floor}", "")
            }

            p.floor = gv.floor
        }

        var rpath = LinkText::join(sdir, f"families/{p.target.recipe}.toml")
        if !LinkFS::is_file(rpath) {
            return out.refuse(f"share input {rpath} missing", "")
        }

        if !p.recipe.load(rpath) {
            return out.refuse(f"{rpath}: {p.recipe.error}", "")
        }

        if !p.recipe.clang_triple.empty() {
            p.target.clang_triple = p.recipe.expand(p.recipe.clang_triple, &p.target)
        }

        /// ## probe (4.2)
        var norm = llvm::Triple::normalize(kairo::sref(p.target.clang_triple))
        var parts = SysUtil::split(string(unsafe ((norm.c_str() as unsafe *const u8) as *const u8)), ('-' as u8))
        p.os   = if (parts.size() > 2) => (parts[2]) else => ""
        p.env_ = if (parts.size() > 3) => (parts[3]) else => ""

        var        tt                        = llvm::Triple(norm)
        var        err:     cxx::std::string
        var unsafe *backend                  = llvm::TargetRegistry::lookupTarget(tt, &err)
        var arch_name = if (parts.empty()) => (p.target.arch) else => parts[0]
        if backend == &null {
            p.row("backend", "missing")
            return out.refuse(f"backend {arch_name} not compiled into this toolchain", "")
        }

        p.row("backend", "ok")

        // What clang's TargetInfo decides (hasInt128Type): 64-bit pointers,
        // or wasm. Derived, not compiled for: a kcc spawn per probe would
        // put a process in the driver hook's path for the same answer.
        var int128 = tt.isArch64Bit() || tt.isWasm()
        p.row("int128", if (int128) => ("yes") else => "no")
        if int128 {
            p.probe.push_back("int128")
        }

        var qpath = LinkText::join(sdir, "quirks.toml")
        if LinkFS::is_file(qpath) {
            var qs = QuirkSet()
            if !qs.load(qpath) {
                return out.refuse(qs.error, "")
            }

            p.quirks = qs.matching(&p.target, p.os, p.env_, &p.probe)
        }

        var qids     = cxx::std::vector<string>()
        var rewrites = cxx::std::vector<string>()
        for var q: SysQuirk in p.quirks {
            qids.push_back(q.id)
            if !q.target_rewrite.empty() {
                rewrites.push_back(q.id)
                p.target.clang_triple = p.recipe.expand(q.target_rewrite, &p.target)
            }
        }

        // After the recipe and the quirks: either may have rewritten it.
        p.row("clang_triple", p.target.clang_triple)
        p.row("quirks", if (qids.empty()) => ("(none)") else => SysUtil::joined(&qids, ", "))
        if rewrites.size() > 1 {
            var list = SysUtil::joined(&rewrites, ", ")
            return out.refuse(f"quirks {list} each rewrite the target; at most one may", "")
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
            return false
        }

        p.row("supports", "yes")
        p.extra = prov->key_extra(&p.target)

        var tools = cxx::std::vector<string>()
        tools.push_back("kcc")
        tools.push_back("kld")
        tools.push_back("llvm-ar")
        for var t: string in tools {
            var at = SysGen::find_tool(t)
            if at.empty() {
                p.row("tools", f"{t} missing")
                return out.refuse(
                    f"{t} not found beside {LinkFS::parent(env::exe_path())} or on PATH",
                    "reinstall the toolchain",
                )
            }

            if p.tools.empty() {
                p.tools = LinkFS::parent(at)
            }
        }

        if !p.recipe.runtimes.empty() {
            if SysGen::find_tool("cmake").empty() || SysGen::find_tool("ninja").empty() {
                p.row("tools", "cmake / ninja missing")
                return out.refuse(
                    "cmake / ninja not found (needed for the runtimes stage until it is built in)",
                    "",
                )
            }
        }

        p.row("tools", "ok")
        if !with_inputs {
            return true
        }

        /// ## inputs (4.3)
        var rels = cxx::std::vector<string>()
        for var tmpl: string in p.recipe.inputs {
            rels.push_back(p.recipe.expand(tmpl, &p.target))
        }

        if !p.recipe.runtimes.empty() && !SysUtil::contains(&rels, "runtimes") {
            rels.push_back("runtimes")
        }

        var c = self.cache()
        for var rel: string in rels {
            var reg = p.share.registered(rel)
            if reg.empty() {
                return out.refuse(f"share input {rel} is not listed in {sdir}/registry.toml", "")
            }

            var path = p.share.input_path(rel)
            if !LinkFS::is_dir(path) {
                return out.refuse(f"share input {path} missing", "")
            }

            var got = SysGen::_verified_sha(&c, path)
            if got != reg {
                return out.refuse(f"share input {path}: tree hash mismatch (registry.toml)", "")
            }

            p.inputs.push_back(rel)
            p.in_paths.push_back(path)
            p.in_sha.push_back(got)
        }

        /// ## keys (section 7)
        var build_id = SysGen::_compiler_build_id(&c, p.tools)
        for var s: string in sys_stages() {
            p.stage_keys.push_back(SysUtil::sha256(SysGen::_key_json(&p, build_id, s)))
        }

        p.key_json = SysGen::_key_json(&p, build_id, "")
        p.key      = SysUtil::sha256(p.key_json)
        return true
    }

    /// The stages after inputs. Each is skipped when its key dir holds
    /// `.ok`; a refusal leaves nothing behind, a failure leaves
    /// `<dir>.failed/log`.
    priv fn _run_stages(self,
                        p:          *SysPlan,
                        c:          *SysCache,
                        const dest: string,
                        @inout out: SysOutcome) -> bool {
        var prov = ProviderSet::make(p->target.provider, self.input)
        finally {
            kairo::std::destroy(prov)
        }

        var stages = sys_stages()
        for var i: usize = 0; i < stages.size(); ++i {
            var name = stages[i]
            var st   = SysStage(c->stage_dir(name, p->stage_keys[i]))
            if st.done() {
                continue
            }

            if !st.begin() {
                return out.fail(f"stage {name} failed: cannot create {st.tmp()}", "")
            }

            self._log(f"{p->target.name}: stage {name}")
            var ctx = StageCtx{}
            ctx.target  = p->target
            ctx.share   = p->share.dir
            ctx.inputs  = p->in_paths
            ctx.input   = self.input
            ctx.stage   = st.tmp()
            ctx.log_dir = st.log_dir()
            ctx.tools   = p->tools

            var ok = false
            if name == "libc-headers" {
                ok = prov->headers(&ctx, st.tmp(), &out)
            } else if name == "libc-libs" {
                ok = prov->libs(&ctx, st.tmp(), &out)
            } else {
                ok = out.refuse(
                    f"stage {name} is not implemented yet",
                    "SysRoot.md section 11 step 4",
                )
            }

            if !ok {
                if out.status == 3 {
                    var log = st.fail(out.message)
                    out.message = f"stage {name} failed: {out.message} (log: {log})"
                } else {
                    st.abandon()
                }

                return false
            }

            if !st.commit() {
                return out.fail(f"stage {name} failed: cannot rename {st.tmp()}", "")
            }
        }

        // Reached only once every stage is real: assemble wrote the root to
        // the stage dir, and the cache (or --out) takes it from there.
        return out.refuse(
            "the sysroot cache stage is not implemented yet",
            "SysRoot.md section 11 step 4",
        )
    }

    /// kcc, kld, llvm-ar, cmake, ninja: beside the running binary first (a
    /// release tree's own), then PATH. "" when neither has it.
    pub static fn find_tool(const name: string) -> string {
        var exe = name
        eval if defined!(_WIN32) {
            exe = name + ".exe"
        }

        var beside = LinkText::join(LinkFS::parent(env::exe_path()), exe)
        if LinkFS::is_file(beside) {
            return beside
        }

        var found = llvm::sys::findProgramByName(kairo::sref(name))
        if found.getError().value() != 0 {
            return ""
        }

        return string(unsafe ((found.get().c_str() as unsafe *const u8) as *const u8))
    }

    /// The canonical key object (section 7). \p stage "" is the sysroot's
    /// own key, over every quirk; a stage key carries the quirks that touch
    /// that stage only, so a changed quirk rebuilds just those stages.
    priv static fn _key_json(p: *SysPlan, const build_id: string, const stage: string) -> string {
        var f = cxx::std::vector<SysJsonField>()
        SysUtil::field(&f, "schema", "1")
        SysUtil::field(&f, "name", SysUtil::json_str(p->target.name))
        SysUtil::field(&f, "clang_triple", SysUtil::json_str(p->target.clang_triple))
        SysUtil::field(&f, "provider", SysUtil::json_str(p->target.provider))
        var libc = p->target.libc_version
        // The runtimes are built once per glibc floor and serve every
        // newer version (4.7), so their key must not name the requested one.
        if stage == "runtimes" && p->target.family == "linux-gnu" {
            libc = p->floor
        }

        SysUtil::field(&f, "libc_version", SysUtil::json_str(libc))
        var ins = cxx::std::vector<string>()
        for var i: usize = 0; i < p->inputs.size(); ++i {
            ins.push_back(p->inputs[i] + "=" + p->in_sha[i])
        }

        SysUtil::field(&f, "inputs", SysUtil::json_list(&ins))
        SysUtil::field(&f, "runtimes_revision", SysUtil::json_str(SysGen::runtimes_revision()))
        SysUtil::field(&f, "compiler_build_id", SysUtil::json_str(build_id))
        SysUtil::field(&f, "tool_version", SysUtil::json_str(SysGen::tool_version()))
        SysUtil::field(&f, "provider_extra", SysUtil::json_list(&p->extra))
        if !stage.empty() {
            SysUtil::field(&f, "stage", SysUtil::json_str(stage))
        }

        var qs = cxx::std::vector<string>()
        for var q: SysQuirk in p->quirks {
            if stage.empty() || SysGen::_quirk_touches(&q, stage) {
                qs.push_back(q.id + ":" + SysUtil::joined(&q.effects, ";"))
            }
        }

        SysUtil::field(&f, "quirks", SysUtil::json_list(&qs))
        return SysUtil::json_object(&f)
    }

    priv static fn _quirk_touches(q: *SysQuirk, const stage: string) -> bool {
        if !q->target_rewrite.empty() {
            return true
        }

        if SysUtil::contains(&q->cflags_stages, stage)
            || SysUtil::contains(&q->cmake_stages, stage)
            || SysUtil::contains(&q->force_include_stages, stage) {
            return true
        }

        if stage == "builtins" && (!q->post_archive.empty() || !q->required_symbols.empty()) {
            return true
        }

        if (stage == "libc-headers" || stage == "libc-libs") && !q->musl_arch.empty() {
            return true
        }

        if stage == "assemble" && !q->assert_file_contains.empty() {
            return true
        }

        return stage == "validate" && (!q->assert_compiles.empty() || !q->required_symbols.empty())
    }

    /// tree_sha256 of \p dir, memoised by the tree's names, sizes and mtimes
    /// (4.3): a rebuild does not re-read hundreds of MB of unchanged input.
    priv static fn _verified_sha(c: *SysCache, const dir: string) -> string {
        var stamp = SysUtil::tree_stamp(dir)
        var memo  = ""
        if !c->root.empty() {
            memo = f"{c->root}/verify/{SysUtil::sha256(dir)}"
            var text = ""
            if LinkFS::read(memo, &text) {
                var parts = SysUtil::split(LinkText::trim(text), (' ' as u8))
                if parts.size() == 2 && parts[0] == stamp {
                    return parts[1]
                }
            }
        }

        var err = ""
        var sha = SysUtil::tree_sha256(dir, &err)
        if !sha.empty() && !memo.empty() {
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
        var bins = cxx::std::vector<string>()
        var bin  = LinkFS::parent(env::exe_path())
        bins.push_back(LinkText::join(bin, "kairo"))
        bins.push_back(LinkText::join(tools_dir, "kcc"))
        bins.push_back(LinkText::join(tools_dir, "kld"))
        bins.push_back(SysGen::find_tool("llvm-ar"))

        var stamp = ""
        for var b: string in bins {
            stamp += f"{b} {SysUtil::file_size(b)} {LinkFS::mtime(b)}\n"
        }

        var memo = if (c->root.empty()) => ("") else => c->root + "/build-id"
        var text = ""
        if !memo.empty() && LinkFS::read(memo, &text) {
            var lines = LinkText::split_lines(text)
            if lines.size() >= 1 && text == stamp + lines[lines.size() - 1] + "\n" {
                return lines[lines.size() - 1]
            }
        }

        var all = ""
        for var b: string in bins {
            all += LinkFS::filename(b) + " " + SysUtil::sha256_file(b) + "\n"
        }

        var id = SysUtil::sha256(all)
        if !memo.empty() {
            LinkFS::make_dirs(c->root)
            LinkFS::write(memo, stamp + id + "\n")
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
