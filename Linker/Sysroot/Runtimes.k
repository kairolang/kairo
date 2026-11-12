/// --- The Kairo Project ----------------------------- Sysroot/Runtimes.k --- ///
///
///   SysRuntimes: the builtins (4.5) and runtimes (4.7) stages. compiler-rt
///   builtins + crtbegin/crtend, libunwind, libc++abi and libc++ are built
///   from the share tree's runtimes source with NO CMake or ninja: one kcc
///   compile per source and one archive write per library, all read from
///   the tables in runtimes-recipe/ (build/sysroot-share/FORMAT.md,
///   "runtimes-recipe"; made by Scripts/runtimes_recipe.py). This is a port
///   of Scripts/build_runtimes_direct.py, the reference runner, step for
///   step:
///
///     1. targets/<name>.toml: the table key of each runtime and where every
///        archive ([archives]) and loose object ([objects]) lands, already
///        resolved through the family's [layout];
///     2. the build tree ({build}) from build/<key>.toml, before any compile:
///        libc++ and libc++abi include {build}/include/c++/v1;
///     3. every source of the stage's runtimes in one window of compiles
///        (SysJobs): no runtime needs another's objects, only headers;
///     4. each archive written in table order (llvm-ar qc + llvm-ar s, done
///        in-process by LLVM's archive writer), the crt objects copied;
///     5. headers/<key>.toml installed as the c++/v1 tree.
///
///   The two stages split the tables by runtime: builtins compiles only the
///   `builtins` runtime, runtimes the other four. Their products keep the
///   generic stage contract (assemble maps them through [layout]): the
///   builtins archive at <out>/<builtins_name>, every [layout] gather item at
///   <out>/<item>, crt objects at <out>/crt/<name>.
///
///   The tables come from runtimes-template/ when the share tree registers
///   it (SysTemplate::instantiate writes them, in this layout, under the
///   stage's work dir), else from runtimes-recipe/: the template is the
///   rule, the tables the targets it was derived from, and a target either
///   serves gets the same compiles from both.
///
///   Every compile gets --sysroot = a libc-headers root made from the
///   libc-headers stage (its include dirs, with no c++/ dir anywhere, plus
///   the target's SYSROOT.toml): an old libc++ on the include path would be
///   found by libc++'s own #include_next wrappers.
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
ffi "c++" import "algorithm"
ffi "c++" import "vector"

import API::FS::LinkFS
import API::SysrootManifest::SysrootManifest
import API::Text::LinkText
import Sysroot::Names::{
    SysNames,
    SysTarget,
}
import Sysroot::Outcome::SysOutcome
import Sysroot::Provider::StageCtx
import Sysroot::Share::SysRecipe
import Sysroot::SysRun::{
    SysJobs,
    SysRun,
}
import Sysroot::SysUtil::SysUtil
import Sysroot::Template::SysTemplate

/// The runtimes the runtimes stage compiles, in the reference runner's
/// order (builtins is its own stage).
fn rt_runtimes() -> cxx::std::vector<string> {
    var v = cxx::std::vector<string>()
    v.push_back("crt")
    v.push_back("libunwind")
    v.push_back("libcxxabi")
    v.push_back("libcxx")
    return v
}

/// What one stage's compiles need: the paths the table templates name and
/// the target's own table.
pub class RtEnv {
    pub var tables:  string ///< targets/ and <runtime>/: runtimes-recipe/, or the instantiated template
    pub var trees:   string ///< build/ and headers/: runtimes-recipe/ or runtimes-template/
    pub var src:     string ///< the runtimes source: {src}
    pub var work:    string ///< scratch under the stage dir: build/, obj/, sysroot/
    pub var build:   string ///< {build}
    pub var sysroot: string ///< {sysroot}, also --sysroot
    pub var share:   string ///< {share}
    pub var target:  SysRecipe ///< targets/<name>.toml
}

pub class SysRuntimes {
    /// The crt objects a recipe with crt_objects = true ships.
    pub static fn crt_names() -> cxx::std::vector<string> {
        var v = cxx::std::vector<string>()
        v.push_back("clang_rt.crtbegin.o")
        v.push_back("clang_rt.crtend.o")
        return v
    }

    /// Stage builtins: <out>/<builtins_name>. \p toml is the target's
    /// SYSROOT.toml text, for the libc-headers root.
    pub static fn builtins(ctx: *StageCtx, const toml: string, @inout out: SysOutcome) -> bool {
        var env = RtEnv()
        if !SysRuntimes::_prepare(ctx, toml, &env, false, &out) {
            return false
        }

        var rts = cxx::std::vector<string>()
        rts.push_back("builtins")
        if !SysRuntimes::_compile(ctx, &env, &rts, &out) {
            return false
        }

        var rl   = ctx->recipe.expand(ctx->recipe.str("", "resource_layout"), &ctx->target)
        var bn   = ctx->recipe.expand(ctx->recipe.str("", "builtins_name"), &ctx->target)
        var dest = rl + "/" + bn
        if env.target.list("archives", dest).empty() {
            return out.fail(
                f"the runtimes recipe for {ctx->target.name} has no archive {dest} (the recipe\x27s resource_layout + builtins_name)",
                "",
            )
        }

        if !SysRuntimes::_archive(ctx, &env, dest, ctx->stage + "/out/" + bn, &out) {
            return false
        }

        LinkFS::remove_tree(env.work)
        return true
    }

    /// Stage runtimes: every [layout] gather item at <out>/<item>, and
    /// <out>/crt/<name> when the recipe has crt_objects. Each gather item is
    /// looked up in the table at its root path (the same [layout] map
    /// assemble applies forward), so a recipe and a table that disagree fail
    /// here, not in a link.
    pub static fn runtimes(ctx: *StageCtx, const toml: string, @inout out: SysOutcome) -> bool {
        var gather = ctx->recipe.list("layout", "gather")
        var crt    = ctx->recipe.flag("", "crt_objects", false)
        if gather.empty() && !crt {
            return true
        }

        var env = RtEnv()
        if !SysRuntimes::_prepare(ctx, toml, &env, true, &out) {
            return false
        }

        var rts = rt_runtimes()
        if !SysRuntimes::_compile(ctx, &env, &rts, &out) {
            return false
        }

        var dst   = ctx->stage + "/out"
        var hdest = env.target.str("", "headers_dest")
        var done  = cxx::std::vector<string>()
        for var g: string in gather {
            var at = SysRuntimes::layout_path(&ctx->recipe, g)
            done.push_back(at)
            if at == hdest {
                if !SysRuntimes::_headers(&env, dst + "/" + g, &out) {
                    return false
                }

                continue
            }

            if env.target.list("archives", at).empty() {
                return out.fail(
                    f"the runtimes recipe for {ctx->target.name} has no {at} (gather item {g})",
                    "",
                )
            }

            if !SysRuntimes::_archive(ctx, &env, at, dst + "/" + g, &out) {
                return false
            }
        }

        // Anything the table builds that no gather item takes would be
        // dropped without a word: the builtins archive is the builtins
        // stage's, every other one must be gathered.
        var rl = ctx->recipe.expand(ctx->recipe.str("", "resource_layout"), &ctx->target)
        var bn = ctx->recipe.expand(ctx->recipe.str("", "builtins_name"), &ctx->target)
        for var a: string in env.target.keys_of("archives") {
            if a != rl + "/" + bn && !SysUtil::contains(&done, a) {
                return out.fail(
                    f"the runtimes recipe for {ctx->target.name} builds {a}, which no [layout] gather item takes",
                    "",
                )
            }
        }

        if crt {
            for var n: string in SysRuntimes::crt_names() {
                var ref = env.target.str("objects", rl + "/" + n)
                if ref.empty() {
                    return out.fail(
                        f"the runtimes recipe for {ctx->target.name} has no object {rl}/{n}",
                        "",
                    )
                }

                var from = SysRuntimes::_obj(&env, ref)
                if !SysRun::put_file(from, dst + "/crt/" + n, false) {
                    return out.fail(f"cannot copy {from}", "")
                }
            }
        }

        LinkFS::remove_tree(env.work)
        return true
    }

    /// The template \p tmpl instantiated for the stage's target into \p dst
    /// (targets/ and <runtime>/, the runtimes-recipe/ layout). False with
    /// \p why set when the template cannot serve the target.
    pub static fn from_template(tgt:        *SysTarget,
                                r:          *SysRecipe,
                                const tmpl: string,
                                const dst:  string,
                                @inout why: string) -> bool {
        var t = SysTemplate()
        if !t.load(tmpl) {
            why = t.error
            return false
        }

        var p = SysNames::properties(tgt)
        if !t.fits(tgt, &p, &why) {
            return false
        }

        // Not wiped first: the stage's work dir is fresh already, and
        // `ksys tables` may put several targets' tables in one dir.
        return t.instantiate(tgt, &p, r, dst, &why)
    }

    /// A [layout] gather item (an install path: include/..., lib/...) at
    /// its place in the root: the recipe's first include / lib dir.
    pub static fn layout_path(r: *SysRecipe, const g: string) -> string {
        var inc = r->list("layout", "include")
        var lib = r->list("layout", "lib")
        if LinkText::starts_with(g, "include/") && !inc.empty() {
            return inc[0] + LinkText::slice(g, 7, g.size())
        }

        if LinkText::starts_with(g, "lib/") && !lib.empty() {
            return lib[0] + LinkText::slice(g, 3, g.size())
        }

        return g
    }

    /// # Steps

    /// The inputs, the target's table, the libc-headers root and (when
    /// \p with_build) the build tree.
    priv static fn _prepare(ctx:        *StageCtx,
                            const toml: string,
                            @inout env: RtEnv,
                            with_build: bool,
                            @inout out: SysOutcome) -> bool {
        // Both are verified inputs (plan() hashed them against
        // registry.toml) or the stage cannot run: never a path that was
        // not checked.
        var tmpl = ctx->input_dir("runtimes-template")
        env.tables = ctx->input_dir("runtimes-recipe")
        env.src    = ctx->input_dir("runtimes")
        if env.tables.empty() && !tmpl.empty() {
            env.tables = tmpl
        }

        if env.tables.empty() || env.src.empty() {
            var miss = if (env.tables.empty()) => ("runtimes-recipe") else => "runtimes"
            return out.refuse(
                f"share input {miss} is not listed in {ctx->share}/registry.toml",
                "the builtins and runtimes stages compile from runtimes/ with the runtimes-recipe/ tables",
            )
        }

        // A registered tree that is not a runtimes source (a share view
        // holding only REVISION) would fail on its first compile, with a
        // missing-file error that names one source and not the cause.
        if !LinkFS::is_dir(env.src + "/compiler-rt/lib/builtins") {
            return out.refuse(
                f"share input {env.src} is not an LLVM runtimes source (no compiler-rt/lib/builtins)",
                "the builtins and runtimes stages compile it; install share/kairo/runtimes with the toolchain",
            )
        }

        env.share   = ctx->share
        env.work    = ctx->stage + "/work"
        env.build   = env.work + "/build"
        env.sysroot = env.work + "/sysroot"
        env.trees   = env.tables
        LinkFS::remove_tree(env.work)
        if !LinkFS::make_dirs(env.work) {
            return out.fail(f"cannot create {env.work}", "")
        }

        if !tmpl.empty() {
            var why = ""
            if !SysRuntimes::from_template(
                &ctx->target,
                &ctx->recipe,
                tmpl,
                env.work + "/tables",
                &why,
            ) {
                return out.refuse(why, "")
            }

            env.tables = env.work + "/tables"
            env.trees  = tmpl
        }

        var tpath = f"{env.tables}/targets/{ctx->target.name}.toml"
        if !LinkFS::is_file(tpath) {
            return out.refuse(
                f"no runtimes recipe for {ctx->target.name} in {env.tables}",
                "runtimes-recipe/index.toml lists the targets it was derived for",
            )
        }

        if !env.target.load(tpath) {
            return out.refuse(f"{tpath}: {env.target.error}", "")
        }

        // The tables hold every flag the quirks added at derivation time,
        // under this triple; compiled for another they would be wrong
        // without an error.
        var want = env.target.str("", "clang_triple")
        if want != ctx->target.clang_triple {
            return out.refuse(
                f"{tpath} was derived for {want}, and this target compiles as {ctx->target.clang_triple}",
                "regenerate runtimes-recipe/ (Scripts/ship_sysroot_inputs.py --only runtimes-recipe)",
            )
        }

        if !SysRuntimes::header_root(ctx, toml, env.sysroot, &out) {
            return false
        }

        var bkey = env.target.str("", "build")
        if with_build && !bkey.empty() {
            var man = f"{env.trees}/build/{bkey}.toml"
            var gen = f"{env.trees}/build/{bkey}"
            if !SysRuntimes::_materialise(man, gen, env.src, env.build, true, &out) {
                return false
            }
        }

        return true
    }

    /// The --sysroot every compile gets: the libc-headers stage's include
    /// dirs (those SYSROOT.toml names, outermost first, a dir under one
    /// already taken skipped) with no c++/ dir at any depth, and the
    /// SYSROOT.toml itself, so kcc puts exactly those dirs on the path.
    /// wasi's eh/ and noeh/ are its libc++ variants: C++ only, skipped too.
    /// The mingw provider compiles mingw-w64-crt against the same root.
    pub static fn header_root(ctx:        *StageCtx,
                              const toml: string,
                              const dst:  string,
                              @inout out: SysOutcome) -> bool {
        var prod = ctx->product("libc-headers")
        if prod.empty() {
            return out.fail("the libc-headers stage has not run", "")
        }

        var dirs = cxx::std::vector<string>()
        for var d: string in ctx->recipe.list("toml", "include_dirs") {
            dirs.push_back(ctx->recipe.expand(d, &ctx->target))
        }

        // Outermost first, ties in list order (an insertion sort is
        // stable): glibc lists include/<multiarch> before include/.
        for var i: usize = 1; i < dirs.size(); ++i {
            var j = i
            while j > 0 && SysRuntimes::_depth(dirs[j]) < SysRuntimes::_depth(dirs[j - 1]) {
                var t = dirs[j]
                dirs[j]     = dirs[j - 1]
                dirs[j - 1] = t
                j -= 1
            }
        }

        var skip = cxx::std::vector<string>()
        skip.push_back("c++")
        if ctx->target.family == "wasi" {
            skip.push_back("eh")
            skip.push_back("noeh")
        }

        var taken = cxx::std::vector<string>()
        for var d: string in dirs {
            if LinkText::contains("/" + d + "/", "/c++/") {
                continue
            }

            var under = false
            for var t: string in taken {
                if LinkText::starts_with(d, t + "/") {
                    under = true
                }
            }

            if under {
                continue
            }

            taken.push_back(d)
            var from = prod + "/" + d
            if LinkFS::is_dir(from) && !SysRuntimes::_tree(from, dst + "/" + d, &skip, 0) {
                return out.fail(f"cannot lay {from} into {dst}", "")
            }
        }

        LinkFS::make_dirs(dst)
        if !LinkFS::write(dst + "/" + SysrootManifest::file_name(), toml) {
            return out.fail(f"cannot write {dst}/SYSROOT.toml", "")
        }

        return true
    }

    priv static fn _depth(const s: string) -> usize {
        var n: usize = 0
        for var i: usize = 0; i < s.size(); ++i {
            if s[i] == ('/' as u8) {
                n += 1
            }
        }

        return n
    }

    /// link_tree with \p skip applied at every depth, not only the top.
    priv static fn _tree(const from:  string,
                         const to:    string,
                         @inout skip: cxx::std::vector<string>,
                         depth:       u32) -> bool {
        if depth > 64 || !LinkFS::make_dirs(to) {
            return false
        }

        for var name: string in LinkFS::list_dir(from) {
            if SysUtil::contains(&skip, name) {
                continue
            }

            var s    = from + "/" + name
            var d    = to + "/" + name
            var link = SysRun::read_link(s)
            if !link.empty() {
                if !SysRun::symlink(link, d) {
                    return false
                }

                continue
            }

            if LinkFS::is_dir(s) {
                if !SysRuntimes::_tree(s, d, &skip, depth + 1) {
                    return false
                }

                continue
            }

            if LinkFS::is_file(s) && !SysRun::put_file(s, d, true) {
                return false
            }
        }

        return true
    }

    /// A build/ or headers/ manifest: every [files] entry under \p dst,
    /// `src:<path>` from the runtimes source, `gen:<path>` from \p gen.
    /// \p hard links instead of copying (the build tree is scratch; the
    /// installed headers are not, and must not share inodes with the share
    /// tree).
    priv static fn _materialise(const man:  string,
                                const gen:  string,
                                const src:  string,
                                const dst:  string,
                                hard:       bool,
                                @inout out: SysOutcome) -> bool {
        var m = SysRecipe()
        if !m.load(man) {
            return out.refuse(f"{man}: {m.error}", "")
        }

        var n: usize = 0
        for var i: usize = 0; i < m.raw_keys.size(); ++i {
            if m.raw_tables[i] != "files" {
                continue
            }

            var how   = m.raw_vals[i].text
            var colon = LinkText::find(how, ":", 0)
            if colon >= how.size() {
                return out.refuse(
                    f"{man}: {m.raw_keys[i]} = \x22{how}\x22 is neither src: nor gen:",
                    "",
                )
            }

            var kind = LinkText::slice(how, 0, colon)
            var rel  = LinkText::slice(how, colon + 1, how.size())
            var from = if (kind == "src") => (src + "/" + rel) else => gen + "/" + rel
            if !SysRun::put_file(from, dst + "/" + m.raw_keys[i], hard) {
                return out.fail(f"cannot copy {from}", "")
            }

            n += 1
        }

        if n == 0 {
            return out.refuse(f"{man} lists no [files]", "")
        }

        return true
    }

    /// Every source of \p rts in one window of compiles. The flags are the
    /// table's, in its order; nothing from quirks.toml is applied again
    /// (the tables already carry what the quirks added).
    priv static fn _compile(ctx:        *StageCtx,
                            env:        *RtEnv,
                            @inout rts: cxx::std::vector<string>,
                            @inout out: SysOutcome) -> bool {
        var logs = ctx->log_dir + "/cc"
        LinkFS::make_dirs(logs)
        var base = ctx->kcc(env->sysroot)
        // Keep the build machine's paths out of the objects (libc++abi's
        // asserts embed __FILE__) and make a rebuild comparable byte for
        // byte, wherever the share tree and the cache are.
        var maps = cxx::std::vector<string>()
        maps.push_back(f"-ffile-prefix-map={env->src}=kairo-runtimes")
        maps.push_back(f"-ffile-prefix-map={env->work}=kairo-work")

        var jobs = SysJobs()
        jobs.limit(ctx->jobs)
        var n: usize = 0
        for var rt: string in rts {
            var key = env->target.str("", rt)
            if key.empty() {
                continue
            }

            var tpath = f"{env->tables}/{rt}/{key}.toml"
            var t     = SysRecipe()
            if !t.load(tpath) {
                return out.refuse(f"{tpath}: {t.error}", "")
            }

            var od = env->work + "/obj/" + rt
            if !LinkFS::make_dirs(od) {
                return out.fail(f"cannot create {od}", "")
            }

            var members = cxx::std::vector<string>()
            for var g: string in SysRuntimes::_groups(&t) {
                var lang = t.str(g, "lang")
                var fl   = cxx::std::vector<string>()
                for var f: string in t.list("flags", lang) {
                    fl.push_back(SysRuntimes::_expand(env, f))
                }

                for var f: string in t.list(g, "flags") {
                    fl.push_back(SysRuntimes::_expand(env, f))
                }

                for var e: string in t.list(g, "sources") {
                    var path   = SysRuntimes::_entry_path(e)
                    var member = SysRuntimes::_entry_member(e)
                    members.push_back(member)
                    var argv = base
                    for var f: string in fl {
                        argv.push_back(f)
                    }

                    for var f: string in maps {
                        argv.push_back(f)
                    }

                    argv.push_back("-c")
                    argv.push_back(env->src + "/" + path)
                    argv.push_back("-o")
                    argv.push_back(od + "/" + member)
                    if !jobs.add(&argv, f"{logs}/{rt}-{n}.log") {
                        break
                    }

                    n += 1
                }
            }

            // Two entries with one member name would leave one object in
            // the archive twice and the other in none.
            cxx::std::sort(members.begin(), members.end())
            for var i: usize = 1; i < members.size(); ++i {
                if members[i] == members[i - 1] {
                    jobs.wait_all()
                    return out.refuse(f"{tpath}: member {members[i]} is named twice", "")
                }
            }
        }

        if !jobs.wait_all() {
            var text = ""
            LinkFS::read(jobs.failed_log, &text)
            var first = SysRuntimes::_first_error(text)
            // The note, not the message: the generator renames the stage
            // dir to .failed and rewrites the note's path to match.
            return out.fail(first, f"compile log: {jobs.failed_log}")
        }

        LinkFS::remove_tree(logs)
        return true
    }

    /// The [group.*] tables of \p t, in file order.
    priv static fn _groups(t: *SysRecipe) -> cxx::std::vector<string> {
        var gs = cxx::std::vector<string>()
        for var tb: string in t->raw_tables {
            if LinkText::starts_with(tb, "group.") && (gs.empty() || gs[gs.size() - 1] != tb) {
                gs.push_back(tb)
            }
        }

        return gs
    }

    /// The archive the table puts at root path \p dest, written to \p to:
    /// its members in table order, symbol table and all (CMake's `<AR> qc`
    /// then `<RANLIB>`). COFF targets get a COFF archive, as llvm-ar picks
    /// one from COFF members.
    priv static fn _archive(ctx:        *StageCtx,
                            env:        *RtEnv,
                            const dest: string,
                            const to:   string,
                            @inout out: SysOutcome) -> bool {
        var objs = cxx::std::vector<string>()
        for var m: string in env->target.list("archives", dest) {
            var o = SysRuntimes::_obj(env, m)
            if !LinkFS::is_file(o) {
                return out.fail(f"{dest}: member {m} was not compiled", "")
            }

            objs.push_back(o)
        }

        var norm = llvm::Triple::normalize(kairo::sref(ctx->target.clang_triple))
        var tt   = llvm::Triple(norm)
        var coff = tt.isOSBinFormatCOFF()
        LinkFS::make_dirs(LinkFS::parent(to))
        if !LinkFS::write_archive_as(to, &objs, coff) {
            return out.fail(f"cannot write {to}", "")
        }

        return true
    }

    /// Installs the table's c++/v1 headers at \p to.
    priv static fn _headers(env: *RtEnv, const to: string, @inout out: SysOutcome) -> bool {
        var key = env->target.str("", "headers")
        if key.empty() {
            return out.fail("the runtimes recipe has headers_dest but no headers key", "")
        }

        LinkFS::remove_tree(to)
        var man = f"{env->trees}/headers/{key}.toml"
        var gen = f"{env->trees}/headers/{key}"
        return SysRuntimes::_materialise(man, gen, env->src, to, false, &out)
    }

    /// The object a member ref `<runtime>:<entry>` was compiled to.
    priv static fn _obj(env: *RtEnv, const ref: string) -> string {
        var colon = LinkText::find(ref, ":", 0)
        var rt    = LinkText::slice(ref, 0, colon)
        var e     = LinkText::slice(ref, colon + 1, ref.size())
        return env->work + "/obj/" + rt + "/" + SysRuntimes::_entry_member(e)
    }

    /// `<path>` or `<path>=<member>`: the source path.
    priv static fn _entry_path(const e: string) -> string {
        var eq = LinkText::find(e, "=", 0)
        return if (eq >= e.size()) => (e) else => LinkText::slice(e, 0, eq)
    }

    /// The member (object) name: after `=`, else the file name + ".o".
    priv static fn _entry_member(const e: string) -> string {
        var eq = LinkText::find(e, "=", 0)
        if eq < e.size() {
            return LinkText::slice(e, eq + 1, e.size())
        }

        return LinkFS::filename(e) + ".o"
    }

    priv static fn _expand(env: *RtEnv, const f: string) -> string {
        if !LinkText::contains(f, "{") {
            return f
        }

        var s = SysUtil::fill(f, "src", env->src)
        s = SysUtil::fill(s, "build", env->build)
        s = SysUtil::fill(s, "sysroot", env->sysroot)
        return SysUtil::fill(s, "share", env->share)
    }

    priv static fn _first_error(const text: string) -> string {
        for var l: string in LinkText::split_lines(text) {
            if LinkText::contains(l, "error") {
                return LinkText::trim(l)
            }
        }

        var lines = LinkText::split_lines(text)
        return if (lines.empty()) => ("compile failed (no output)") else => LinkText::trim(lines[0])
    }
}
