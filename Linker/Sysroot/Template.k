/// --- The Kairo Project ----------------------------- Sysroot/Template.k --- ///
///
///   SysTemplate: the runtimes template (build/sysroot-share/FORMAT.md,
///   "runtimes-template"; made by Scripts/runtimes_template.py from the
///   runtimes-recipe/ tables). Where a table is one target's compiles and
///   archives as CMake decided them, the template is the rule they follow:
///   ordered fragments of flags and of archive members, each with a `when`
///   predicate over the target's properties (SysNames::properties). The
///   fragments that hold for a target, concatenated, are its tables.
///
///   instantiate() writes exactly that, in the runtimes-recipe/ layout
///   (targets/<name>.toml and <runtime>/<name>.toml), so SysRuntimes runs
///   the same steps over a template as over the shipped tables, and a
///   target that was derived gets back its table compile for compile.
///   The build/ and headers/ trees are the template's own, one per family.
///
///   A target whose property values the rules were not derived over is
///   refused (fits()): a fragment keyed on that property cannot know about
///   the new value, and silently skipping its arch sources would build a
///   builtins archive that links nowhere.
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
import Sysroot::Names::{
    SysNames,
    SysProps,
    SysTarget,
}
import Sysroot::Share::SysRecipe
import Sysroot::SysUtil::SysUtil

/// One runtime's compiles, collected from the outputs that take them.
class TmplRuntime {
    pub var name:    string
    pub var langs:   [string] ///< per entry
    pub var pids:    [string] ///< per entry; "" = no profile
    pub var entries: [string] ///< per entry: <path>=<member>
}

pub class SysTemplate {
    pub var dir:   string
    pub var index: SysRecipe
    pub var error: string

    /// The runtimes the template has rules for, in compile order.
    pub static fn runtimes() -> [string] {
        var v: [string]
        v.push("builtins")
        v.push("crt")
        v.push("libunwind")
        v.push("libcxxabi")
        v.push("libcxx")
        return v
    }

    pub fn load(self, const dir: string) -> bool {
        self.dir = dir.copy()
        var at = dir.copy() + "/index.toml"
        if !self.index.load(at) {
            self.error = f"{at}: {self.index.error}"
            return false
        }

        if self.index.str("", "schema") != "1" {
            self.error = f"{at}: schema is not 1"
            return false
        }

        return true
    }

    /// Whether the rules were derived over every value of `p` they read.
    /// A target the template was derived from must also have the
    /// properties recorded for it: anything else means this side and
    /// runtimes_template.py compute them differently.
    pub fn fits(self, t: *SysTarget, p: *SysProps, @inout why: string) -> bool {
        for *k in self.index.keys_of("domain") {
            var v = p->get(*k)
            var d = self.index.list("domain", *k)
            if !SysUtil::contains(d, v) {
                var list = SysUtil::joined(d, ", ")
                why = f"the runtimes template has no rule for {*k}={v} ({t->name}); it was derived for {*k} in {list}"
                return false
            }
        }

        var tb = f"props.\x22{t->name}\x22"
        for k in self.index.keys_of(tb) {
            var want = self.index.str(tb, k)
            if p->get(k) != want {
                why = f"{t->name}: property {k} is {p->get(k)} here and {want} in {self.dir}/index.toml (the two property rules disagree)"
                return false
            }
        }

        return true
    }

    /// `t`'s tables under `dst`: targets/<name>.toml and
    /// <runtime>/<name>.toml. Archive and object paths go through `r`'s
    /// [layout], resource_layout and builtins_name, as the tables' do.
    pub fn instantiate(self,
                       t:          *SysTarget,
                       p:          *SysProps,
                       r:          *SysRecipe,
                       const dst:  string,
                       @inout why: string) -> bool {
        var outs = SysRecipe()
        var at   = self.dir.copy() + "/outputs.toml"
        if !outs.load(at) {
            why = f"{at}: {outs.error}"
            return false
        }

        var profs = SysRecipe()
        at = self.dir.copy() + "/profiles.toml"
        if !profs.load(at) {
            why = f"{at}: {profs.error}"
            return false
        }

        var rts: [TmplRuntime]
        for *n in SysTemplate::runtimes() {
            var rt = TmplRuntime()
            rt.name = n->copy()
            rts.push(rt)
        }

        var rl   = r->expand(r->str("", "resource_layout"), t)
        var bn   = r->expand(r->str("", "builtins_name"), t)
        var lib  = r->list("layout", "lib")
        var ldir = if (lib.is_empty()) => ("lib") else => lib[0].copy()
        var sfx  = if (p->get("objfmt") == "coff") => (".obj") else => ".o"

        var arch = ""
        for *id in self.index.keys_of("archive_files") {
            var es = SysTemplate::pick(&outs, "archive." + *id, p)
            if es.is_empty() {
                continue
            }

            var file = self.index.str("archive_files", *id)
            var dest = if (*id == "builtins") => (rl.copy() + "/" + bn)
                       else => ldir.copy() + "/" + file
            arch += f"\x22{dest}\x22 = [\n"
            for *e in es {
                var ref = ""
                if !SysTemplate::_take(&rts, *e, p, sfx, &ref, &why) {
                    return false
                }

                arch += f"    \x22{ref}\x22,\n"
            }

            arch += "]\n"
        }

        var objs = ""
        for *id in self.index.keys_of("object_files") {
            var es = SysTemplate::pick(&outs, "object." + *id, p)
            if es.is_empty() {
                continue
            }

            var ref = ""
            if !SysTemplate::_take(&rts, es[0], p, sfx, &ref, &why) {
                return false
            }

            var file = self.index.str("object_files", *id)
            objs += f"\x22{rl}/{file}\x22 = \x22{ref}\x22\n"
        }

        var fam = "family." + t->recipe
        var tt = "# instantiated by ksys from the runtimes template; FORMAT.md (runtimes-recipe).\n"
        tt += f"name         = \x22{t->name}\x22\n"
        tt += f"family       = \x22{t->recipe}\x22\n"
        tt += f"arch         = \x22{t->arch}\x22\n"
        tt += f"clang_triple = \x22{t->clang_triple}\x22\n"
        for *rt in rts {
            if rt->entries.is_empty() {
                continue
            }

            tt += f"{rt->name} = \x22{t->name}\x22\n"
            if !SysTemplate::_write_runtime(
                self.dir,
                rt,
                &profs,
                p,
                f"{dst}/{rt->name}/{t->name}.toml",
                &why,
            ) {
                return false
            }
        }

        var bkey = self.index.str(fam, "build")
        var hkey = self.index.str(fam, "headers")
        if !bkey.is_empty() {
            tt += f"build        = \x22{bkey}\x22\n"
        }

        if !hkey.is_empty() {
            tt += f"headers      = \x22{hkey}\x22\n"
            var hd = self.index.str(fam, "headers_dest")
            tt += f"headers_dest = \x22{hd}\x22\n"
        }

        tt += "\n[objects]\n" + objs + "\n[archives]\n" + arch
        var tpath = f"{dst}/targets/{t->name}.toml"
        LinkFS::make_dirs(LinkFS::parent(tpath))
        if !LinkFS::write(tpath, tt) {
            why = f"cannot write {tpath}"
            return false
        }

        return true
    }

    /// The `add` lists of `prefix`'s fragments ([<prefix>.fNNN]) whose
    /// `when` holds for `p`, concatenated in file order.
    pub static fn pick(r: *SysRecipe, const prefix: string, p: *SysProps) -> [string] {
        var out: [string]
        var pre           = prefix.copy() + ".f"
        for var i: usize = 0; i < r->raw_keys.size(); ++i {
            var tb = r->raw_tables[i].copy()
            if r->raw_keys[i] != "add" || !LinkText::starts_with(tb.copy(), pre.copy()) {
                continue
            }

            // Only [<prefix>.fNNN] itself: archive.cxx is not archive.cxxabi.
            if LinkText::contains(
                LinkText::slice(tb, pre.size(), tb.size()),
                ".",
            ) {
                continue
            }

            var when = r->list(tb, "when")
            if !SysTemplate::holds(when, p) {
                continue
            }

            for *x in r->raw_vals[i].list {
                out.push(x->copy())
            }
        }

        return out
    }

    /// `when`: alternatives (any holds), each space-separated `prop=v1|v2`
    /// clauses (all hold). An empty list always holds.
    pub static fn holds(const when: [string], p: *SysProps) -> bool {
        if when.is_empty() {
            return true
        }

        for const *alt in when {
            var all = true
            for *c in SysUtil::split(*alt, (' ' as u8)) {
                if c->is_empty() {
                    continue
                }

                var eq = LinkText::find(c->copy(), "=", 0)
                var vs = SysUtil::split(LinkText::slice(*c, eq + 1, c->size()), ('|' as u8))
                if !SysUtil::contains(vs, p->get(LinkText::slice(*c, 0, eq))) {
                    all = false
                    break
                }
            }

            if all {
                return true
            }
        }

        return false
    }

    /// Template entry `<rt>:<path>[=<member>][@<profile>]` into its
    /// runtime's compiles; `ref` the table's member ref for it.
    priv static fn _take(@inout rts: [TmplRuntime],
                         const e:    string,
                         p:          *SysProps,
                         const sfx:  string,
                         @inout ref: string,
                         @inout why: string) -> bool {
        var atp    = LinkText::find(e.copy(), "@", 0)
        var body   = LinkText::slice(e, 0, atp)
        var pid    = LinkText::slice(e, atp + 1, e.size())
        var col    = LinkText::find(body.copy(), ":", 0)
        var rt     = LinkText::slice(body, 0, col)
        var rest   = LinkText::slice(body, col + 1, body.size())
        var eq     = LinkText::find(rest.copy(), "=", 0)
        var path   = LinkText::slice(rest, 0, eq)
        var member = LinkFS::filename(path) + sfx
        if eq < rest.size() {
            member = SysUtil::fill(
                LinkText::slice(rest, eq + 1, rest.size()),
                "o",
                sfx,
            )

            member = SysUtil::fill(member, "crt_arch", p->get("crt_arch"))
        }

        var lang = ""
        if LinkText::ends_with(path.copy(), ".c") {
            lang = "c"
        } else if LinkText::ends_with(path.copy(), ".cpp") {
            lang = "cxx"
        } else if LinkText::ends_with(path.copy(), ".S") {
            lang = "asm"
        } else {
            why = f"runtimes template entry {e}: no language for its extension"
            return false
        }

        for var i: usize = 0; i < rts.size(); ++i {
            if rts[i].name == rt {
                rts[i].langs.push(lang)
                rts[i].pids.push(pid)
                rts[i].entries.push(path.copy() + "=" + member)
                ref = rt.copy() + ":" + path + "=" + member
                return true
            }
        }

        why = f"runtimes template entry {e}: no runtime {rt}"
        return false
    }

    /// <runtime>.toml's [flags] for the languages `rt` compiles, and one
    /// group per (language, profile) in order of first use.
    priv static fn _write_runtime(const dir:  string,
                                  rt:         *TmplRuntime,
                                  profs:      *SysRecipe,
                                  p:          *SysProps,
                                  const path: string,
                                  @inout why: string) -> bool {
        var rules = SysRecipe()
        var at    = f"{dir}/{rt->name}.toml"
        if !rules.load(at) {
            why = f"{at}: {rules.error}"
            return false
        }

        var s = "# instantiated by ksys from the runtimes template; FORMAT.md (runtimes-recipe).\n"
        s += f"runtime = \x22{rt->name}\x22\n\n[flags]\n"
        var langs: [string]
        for *l in rt->langs {
            if !SysUtil::contains(langs, *l) {
                langs.push(l->copy())
                s += l->copy() + " = " + SysTemplate::_array(
                    SysTemplate::pick(&rules, "flags." + *l, p),
                ) + "\n"
            }
        }

        var keys: [string]
        for var i: usize = 0; i < rt->entries.size(); ++i {
            var k = rt->langs[i].copy() + "@" + rt->pids[i]
            if SysUtil::contains(keys, k) {
                continue
            }

            keys.push(k)
            var srcs: [string]
            for var j: usize = i; j < rt->entries.size(); ++j {
                if rt->langs[j] == rt->langs[i] && rt->pids[j] == rt->pids[i] {
                    srcs.push(rt->entries[j].copy())
                }
            }

            var fl: [string]
            if !rt->pids[i].is_empty() {
                fl = SysTemplate::pick(profs, "profile." + rt->pids[i], p)
            }

            var g = keys.size() - 1
            s += f"\n[group.g{g}]\nlang    = \x22{rt->langs[i]}\x22\n"
            s += "flags   = " + SysTemplate::_array(fl) + "\n"
            s += "sources = " + SysTemplate::_array(srcs) + "\n"
        }

        LinkFS::make_dirs(LinkFS::parent(path))
        if !LinkFS::write(path, s) {
            why = f"cannot write {path}"
            return false
        }

        return true
    }

    priv static fn _array(xs: [string]) -> string {
        if xs.is_empty() {
            return "[]"
        }

        var s = "[\n"
        for *x in xs {
            s += f"    \x22{*x}\x22,\n"
        }

        return s.copy() + "]"
    }
}
