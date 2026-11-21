/// --- The Kairo Project ----------------------------- Providers/Wasi.k --- ///
///
///   The wasi provider: wasm32-wasi (SysRoot.md 4.4, 4.6). The C library is
///   built from the wasi-libc input (FORMAT.md "wasi-libc"; the reference
///   runner is Scripts/build_wasi_libc_direct.py): its headers laid out, its
///   sources compiled, its archives written, its shared libraries linked by
///   kld's wasm flavor. libc++ (the eh/ and noeh/ trees beside the libc) is
///   not built from source yet and comes from the wasi/<v> base, copied per
///   [bundle_layout] as the bundle provider copies one.
///
///   Without the wasi-libc input (an older share) the base is the whole
///   root, as for the bundle provider.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import API::FS::LinkFS
import API::Text::LinkText
import Sysroot::CrtTable::{
    CrtArchive,
    CrtEnv,
    CrtLink,
    CrtPair,
    SysCrt,
    SysCrtTable,
}
import Sysroot::Outcome::SysOutcome
import Sysroot::Provider::{
    StageCtx,
    SysrootProvider,
}
import Sysroot::SysRun::SysRun

pub class WasiProvider derives SysrootProvider {
    pub fn WasiProvider(self) = default

    pub override fn id(self) -> string {
        return "wasi"
    }

    /// Stage libc-headers: the base per [bundle_layout] (libc++ and, from an
    /// older share, a prebuilt libc), then wasi-libc's [headers] over it.
    pub override fn headers(self,
                            ctx:        *StageCtx,
                            const dst:  string,
                            @inout out: SysOutcome) -> bool {
        if ctx->inputs.empty() {
            return out.refuse(
                f"the {ctx->target.recipe} recipe names no input to bundle",
                "",
            )
        }

        var base = ctx->inputs[0].copy()
        for *k in ctx->recipe.keys_of("bundle_layout") {
            var from = base.copy() + "/" + *k
            if !LinkFS::is_dir(from) {
                return out.refuse(f"share input {from} missing", "")
            }

            if !ctx->materialise(
                from,
                dst.copy() + "/" + ctx->recipe.str("bundle_layout", *k),
                &out,
            ) {
                return false
            }
        }

        var tables = ctx->input_dir("wasi-libc")
        if tables.is_empty() {
            return true
        }

        var t = SysCrtTable()
        if !WasiProvider::_table(ctx, tables, &t, &out) {
            return false
        }

        var err = ""
        for *h in t.headers {
            if !SysCrt::put_ref(
                h->val,
                tables.copy() + "/src",
                tables.copy() + "/gen",
                dst.copy() + "/" + h->key,
                false,
                &err,
            ) {
                return out.refuse(f"{t.path}: [headers] {h->key}: {err}", "")
            }
        }

        return true
    }

    /// Stage libc-libs: wasi-libc's lib/ (FORMAT.md "wasi-libc", steps 1-5).
    /// Runs after builtins: libc.so links the builtins archive.
    pub override fn libs(self, ctx: *StageCtx, const dst: string, @inout out: SysOutcome) -> bool {
        var tables = ctx->input_dir("wasi-libc")
        if tables.is_empty() {
            return LinkFS::make_dirs(dst) || out.fail(f"cannot create {dst}", "")
        }

        var t = SysCrtTable()
        if !WasiProvider::_table(ctx, tables, &t, &out) {
            return false
        }

        // {build} is the work dir itself and {sysroot} a dir in it, as the
        // runner lays them out: the object paths are {build}-relative and
        // never start with sysroot/.
        var work = ctx->stage.copy() + "/libc"
        var env  = CrtEnv()
        env.src     = tables.copy() + "/src"
        env.build   = work.copy()
        env.sysroot = work.copy() + "/sysroot"
        env.src_tag = "wasi-libc"
        LinkFS::remove_tree(work)
        if !LinkFS::make_dirs(env.sysroot) {
            return out.fail(f"cannot create {env.sysroot}", "")
        }

        var err = ""
        for *h in t.headers {
            if !SysCrt::put_ref(
                h->val,
                env.src,
                tables.copy() + "/gen",
                env.sysroot.copy() + "/" + h->key,
                true,
                &err,
            ) {
                return out.refuse(f"{t.path}: [headers] {h->key}: {err}", "")
            }
        }

        if !LinkFS::write(
            env.sysroot.copy() + "/SYSROOT.toml",
            ctx->recipe.render_toml(&ctx->target),
        ) {
            return out.fail(f"cannot write {env.sysroot}/SYSROOT.toml", "")
        }

        // Where the table's link lines look for it: libc.so names it, the
        // other shared libraries find it through -L.
        var bn = ctx->recipe.expand(
            ctx->recipe.str("", "builtins_name"),
            &ctx->target,
        )

        var rt = ctx->product("builtins") + "/" + bn
        var rd = env.sysroot.copy() + "/compiler-rt/lib/" + t.clang_triple
        if !LinkFS::is_file(rt)
            || !SysRun::put_file(
                rt,
                rd.copy() + "/libclang_rt.builtins.a",
                true,
            ) {
            return out.fail(f"the builtins stage left no {bn}", "")
        }

        if !SysCrt::compile(ctx, &t, &env, &out) {
            return false
        }

        for *a in t.archives {
            var objs = cxx::std::vector<string>()
            for *m in a->members {
                objs.push_back(env.build.copy() + "/" + *m)
            }

            var o = env.build.copy() + "/" + a->out
            LinkFS::make_dirs(LinkFS::parent(o))
            LinkFS::remove(o)
            if !LinkFS::write_archive(o, &objs) {
                return out.fail(f"cannot write {o}", "")
            }
        }

        for *e in t.empty {
            if !SysCrt::write_empty_archive(env.sysroot.copy() + "/" + *e) {
                return out.fail(f"cannot write {env.sysroot}/{*e}", "")
            }
        }

        WasiProvider::_install_ready(&t, &env)
        // Not a kcc link: that would link the Kairo runtime  in. The
        // lines are what clang's driver ran for wasi-libc's own link.
        for *l in t.links {
            var argv: [string]
            argv.push(ctx->tool("kld"))
            argv.push("-flavor")
            argv.push("wasm")
            for *x in l->ld {
                if *x == "{members}" {
                    for *m in l->members {
                        argv.push(env.build.copy() + "/" + *m)
                    }
                } else {
                    argv.push(SysCrt::expand(&env, *x))
                }
            }

            var o = env.build.copy() + "/" + l->out
            LinkFS::make_dirs(LinkFS::parent(o))
            argv.push("-o")
            argv.push(o)
            var log = f"{ctx->log_dir}/link-{LinkFS::filename(l->out)}.log"
            if SysRun::run(&argv, log) != 0 {
                var text = ""
                LinkFS::read(log, &text)
                return out.fail(
                    f"{l->out}: link failed: {SysCrt::first_error(text)}",
                    f"log: {log}",
                )
            }

            // Later links take -lc and crt1-reactor.o from {sysroot}.
            WasiProvider::_install_ready(&t, &env)
        }

        for *i in t.install {
            if !LinkFS::is_file(env.sysroot.copy() + "/" + i->key) {
                return out.fail(
                    f"{t.path}: [install] {i->key}: nothing built {i->val}",
                    "",
                )
            }
        }

        var none: [string]
        if !SysRun::link_tree(
            env.sysroot.copy() + "/lib",
            dst.copy() + "/lib",
            &none,
        ) {
            return out.fail(f"cannot lay {env.sysroot}/lib into {dst}", "")
        }

        LinkFS::remove_tree(work)
        return true
    }

    priv static fn _table(ctx:          *StageCtx,
                          const tables: string,
                          t:            *SysCrtTable,
                          @inout out:   SysOutcome) -> bool {
        var tpath = f"{tables}/{ctx->target.name}.toml"
        if !LinkFS::is_file(tpath) {
            return out.refuse(
                f"share input wasi-libc has no table for {ctx->target.name} ({tpath})",
                "",
            )
        }

        if !t->load(tpath) {
            return out.refuse(t->error, "")
        }

        if t->clang_triple != ctx->target.clang_triple {
            return out.refuse(
                f"{tpath} was derived for {t->clang_triple}, and this target compiles as {ctx->target.clang_triple}",
                "",
            )
        }

        return true
    }

    /// Every [install] entry whose source exists now and is not in {sysroot}
    /// yet, copied there.
    priv static fn _install_ready(t: *SysCrtTable, env: *CrtEnv) {
        for *i in t->install {
            var from = env->build.copy() + "/" + i->val
            var to   = env->sysroot.copy() + "/" + i->key
            if LinkFS::is_file(from) && !LinkFS::exists(to) {
                SysRun::put_file(from, to, true)
            }
        }
    }
}
