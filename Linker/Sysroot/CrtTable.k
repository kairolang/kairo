/// --- The Kairo Project ----------------------------- Sysroot/CrtTable.k --- ///
///
///   The libc-from-source tables of the share tree: mingw-crt/<arch>.toml
///   (mingw-w64-crt) and wasi-libc/<name>.toml (wasi-libc), as
///   build/sysroot-share/FORMAT.md "mingw-crt" and "wasi-libc" define them.
///   Both were derived from the library's own build (configure + make -n,
///   CMake + ninja) and replay it with no make, CMake or shell: SysCrtTable
///   reads one, SysCrt runs its compiles. What follows the compiles (import
///   libraries and archive merges, wasm links) is the provider's.
///
///   Ports of Scripts/build_mingw_crt_direct.py and
///   Scripts/build_wasi_libc_direct.py, the reference runners: same
///   commands, same order, so a root built here and one built there can be
///   compared byte for byte.
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
import API::SysrootManifest::{
    TomlLite,
    TomlValue,
}
import API::Text::LinkText
import Sysroot::Outcome::SysOutcome
import Sysroot::Provider::StageCtx
import Sysroot::SysRun::{
    SysJobs,
    SysRun,
}
import Sysroot::SysUtil::SysUtil

/// A `"key" = "value"` row of [files], [headers] or [install], in order.
pub struct CrtPair {
    pub var key: string
    pub var val: string
}

/// [flags] <lang>: the leading flags of every compile of that language.
pub struct CrtFlags {
    pub var lang: string
    pub var list: cxx::std::vector<string>
}

/// One [group.*]: sources compiled with the same flags.
pub struct CrtGroup {
    pub var lang:    string
    pub var flags:   cxx::std::vector<string>
    pub var sources: cxx::std::vector<string> ///< `<source template>=<object>`
}

/// One [def.*]: a .def.in preprocessed into a .def (mingw-crt).
pub struct CrtDef {
    pub var source:   string
    pub var out:      string
    pub var flags:    cxx::std::vector<string>
    pub var strip_at: bool                     = false
}

/// One [archive.*]: an import library (`def`), objects (`members`) or
/// the members of earlier archives (`addlib`).
pub struct CrtArchive {
    pub var out:     string
    pub var def:     string
    pub var members: cxx::std::vector<string>
    pub var addlib:  cxx::std::vector<string>
}

/// One [link.*]: a wasm shared library (wasi-libc).
pub struct CrtLink {
    pub var out:     string
    pub var ld:      cxx::std::vector<string>
    pub var members: cxx::std::vector<string>
}

pub class SysCrtTable {
    pub var path:            string
    pub var error:           string
    pub var clang_triple:    string
    pub var dlltool_machine: string
    pub var dlltool_flags:   cxx::std::vector<string>
    pub var empty:           cxx::std::vector<string>     ///< root paths of member-less archives
    pub var files:           cxx::std::vector<CrtPair>    ///< {build} path = gen:<path>
    pub var headers:         cxx::std::vector<CrtPair>    ///< root path = src:<path> | gen:<path>
    pub var install:         cxx::std::vector<CrtPair>    ///< root path = {build} path
    pub var flags:           cxx::std::vector<CrtFlags>
    pub var groups:          cxx::std::vector<CrtGroup>
    pub var defs:            cxx::std::vector<CrtDef>
    pub var archives:        cxx::std::vector<CrtArchive>
    pub var links:           cxx::std::vector<CrtLink>

    /// One pass over the file: the tables are large (1500 archives for
    /// armv7 MinGW), so nothing is looked up by key afterwards.
    pub fn load(self, const path: string) -> bool {
        self.path = path
        var text = ""
        if !LinkFS::read(path, &text) {
            self.error = f"{path}: cannot read the file"
            return false
        }

        var toml = TomlLite(text)
        var key  = ""
        var val  = TomlValue{}
        var last = ""
        while toml.next(&key, &val) {
            var tb    = toml.table
            var fresh = tb != last
            last = tb
            if tb.empty() {
                if key == "clang_triple" {
                    self.clang_triple = val.text
                } else if key == "dlltool_machine" {
                    self.dlltool_machine = val.text
                } else if key == "dlltool_flags" {
                    self.dlltool_flags = val.list
                } else if key == "empty" {
                    self.empty = val.list
                }
            } else if tb == "files" || tb == "headers" || tb == "install" {
                var pr = CrtPair{}
                pr.key = key
                pr.val = val.text
                if tb == "files" {
                    self.files.push_back(pr)
                } else if tb == "headers" {
                    self.headers.push_back(pr)
                } else {
                    self.install.push_back(pr)
                }
            } else if tb == "flags" {
                var f = CrtFlags{}
                f.lang = key
                f.list = val.list
                self.flags.push_back(f)
            } else if LinkText::starts_with(tb, "group.") {
                if fresh {
                    self.groups.push_back(CrtGroup{})
                }

                var *g = &self.groups[self.groups.size() - 1]
                if key == "lang" {
                    g->lang = val.text
                } else if key == "flags" {
                    g->flags = val.list
                } else if key == "sources" {
                    g->sources = val.list
                }
            } else if LinkText::starts_with(tb, "def.") {
                if fresh {
                    self.defs.push_back(CrtDef{})
                }

                var *d = &self.defs[self.defs.size() - 1]
                if key == "source" {
                    d->source = val.text
                } else if key == "out" {
                    d->out = val.text
                } else if key == "flags" {
                    d->flags = val.list
                } else if key == "strip_at" {
                    d->strip_at = val.flag
                }
            } else if LinkText::starts_with(tb, "archive.") {
                if fresh {
                    self.archives.push_back(CrtArchive{})
                }

                var *a = &self.archives[self.archives.size() - 1]
                if key == "out" {
                    a->out = val.text
                } else if key == "def" {
                    a->def = val.text
                } else if key == "members" {
                    a->members = val.list
                } else if key == "addlib" {
                    a->addlib = val.list
                }
            } else if LinkText::starts_with(tb, "link.") {
                if fresh {
                    self.links.push_back(CrtLink{})
                }

                var *l = &self.links[self.links.size() - 1]
                if key == "out" {
                    l->out = val.text
                } else if key == "ld" {
                    l->ld = val.list
                } else if key == "members" {
                    l->members = val.list
                }
            }
        }

        if !toml.error.empty() {
            self.error = f"{path}: {toml.error}"
            return false
        }

        if self.clang_triple.empty() {
            self.error = f"{path}: no clang_triple"
            return false
        }

        return true
    }

    /// [flags].<lang>; empty when the table has none for it.
    pub fn lang_flags(self, const lang: string) -> cxx::std::vector<string> {
        for var f: CrtFlags in self.flags {
            if f.lang == lang {
                return f.list
            }
        }

        return cxx::std::vector<string>()
    }
}

/// The directories a table's templates name.
pub class CrtEnv {
    pub var src:     string ///< {src}: the shipped sources
    pub var build:   string ///< {build}: the work dir every object lands in
    pub var sysroot: string ///< {sysroot}: the libc-headers root, also --sysroot
    pub var src_tag: string ///< what -ffile-prefix-map turns {src} into
}

pub class SysCrt {
    pub static fn expand(env: *CrtEnv, const s: string) -> string {
        if !LinkText::contains(s, "{") {
            return s
        }

        var r = SysUtil::fill(s, "src", env->src)
        r = SysUtil::fill(r, "build", env->build)
        return SysUtil::fill(r, "sysroot", env->sysroot)
    }

    /// Every [def.*] preprocessed and every [group.*] entry compiled, in one
    /// window (no compile reads a def or another object); then strip_at on
    /// the defs that ask for it. A failure is P010E with the first error
    /// line and the log in the note, as the runtimes stage reports one.
    pub static fn compile(ctx:        *StageCtx,
                          t:          *SysCrtTable,
                          env:        *CrtEnv,
                          @inout out: SysOutcome) -> bool {
        var logs = ctx->log_dir + "/crt"
        LinkFS::make_dirs(logs)
        var base = ctx->kcc(env->sysroot)
        // The objects name neither the share tree nor the cache, so two
        // builds of one table compare byte for byte wherever they ran.
        var maps = cxx::std::vector<string>()
        maps.push_back(f"-ffile-prefix-map={env->src}={env->src_tag}")
        maps.push_back(f"-ffile-prefix-map={env->build}=kairo-work")

        var jobs = SysJobs()
        jobs.limit(ctx->jobs)
        var n: usize = 0
        for var d: CrtDef in t->defs {
            var o = env->build + "/" + d.out
            LinkFS::make_dirs(LinkFS::parent(o))
            // -o, not stdout: a job's stdout is its log.
            var argv = base
            argv.push_back("-E")
            argv.push_back("-P")
            argv.push_back("-x")
            argv.push_back("c")
            for var f: string in d.flags {
                argv.push_back(SysCrt::expand(env, f))
            }

            argv.push_back("-Wp,-w")
            argv.push_back("-o")
            argv.push_back(o)
            argv.push_back(SysCrt::expand(env, d.source))
            if !jobs.add(&argv, f"{logs}/{n}.log") {
                break
            }

            n += 1
        }

        for var g: CrtGroup in t->groups {
            var fl = cxx::std::vector<string>()
            for var f: string in t->lang_flags(g.lang) {
                fl.push_back(SysCrt::expand(env, f))
            }

            for var f: string in g.flags {
                fl.push_back(SysCrt::expand(env, f))
            }

            for var e: string in g.sources {
                var eq = LinkText::find(e, "=", 0)
                if eq >= e.size() {
                    jobs.wait_all()
                    return out.refuse(f"{t->path}: source entry \x27{e}\x27 names no object", "")
                }

                var o = env->build + "/" + LinkText::slice(e, eq + 1, e.size())
                LinkFS::make_dirs(LinkFS::parent(o))
                var argv = base
                for var f: string in fl {
                    argv.push_back(f)
                }

                for var f: string in maps {
                    argv.push_back(f)
                }

                argv.push_back("-c")
                argv.push_back(SysCrt::expand(env, LinkText::slice(e, 0, eq)))
                argv.push_back("-o")
                argv.push_back(o)
                if !jobs.add(&argv, f"{logs}/{n}.log") {
                    break
                }

                n += 1
            }
        }

        if !jobs.wait_all() {
            var text = ""
            LinkFS::read(jobs.failed_log, &text)
            return out.fail(SysCrt::first_error(text), f"compile log: {jobs.failed_log}")
        }

        for var d: CrtDef in t->defs {
            if !d.strip_at {
                continue
            }

            var o    = env->build + "/" + d.out
            var text = ""
            if !LinkFS::read(o, &text) || !LinkFS::write(o, SysCrt::strip_at(text)) {
                return out.fail(f"cannot rewrite {o}", "")
            }
        }

        LinkFS::remove_tree(logs)
        return true
    }

    /// The Makefile's stdcall strip, `sed -E 's/^([^ ]+)@[0-9]+( |\r?$)/\1\2/'`
    /// on every line: a trailing @N comes off each line's first word, which
    /// the def of every arch but i686 must not carry.
    pub static fn strip_at(const text: string) -> string {
        var lines = SysUtil::split(text, ('\n' as u8))
        var res   = ""
        for var i: usize = 0; i < lines.size(); ++i {
            if i > 0 {
                res += "\n"
            }

            var l   = lines[i]
            var end = l.size()
            if end > 0 && l[end - 1] == ('\r' as u8) {
                end -= 1
            }

            var sp = LinkText::find(l, " ", 0)
            var we = if (sp < l.size()) => (sp) else => end
            var at = we
            for var j: usize = 0; j < we; ++j {
                if l[j] == ('@' as u8) {
                    at = j
                }
            }

            // One character at least before the @, one digit at least after,
            // nothing but digits up to the word's end.
            var digits = at > 0 && at + 1 < we
            for var j: usize = at + 1; j < we && digits; ++j {
                if l[j] < ('0' as u8) || l[j] > ('9' as u8) {
                    digits = false
                }
            }

            if digits {
                res += LinkText::slice(l, 0, at) + LinkText::slice(l, we, l.size())
            } else {
                res += l
            }
        }

        return res
    }

    pub static fn first_error(const text: string) -> string {
        for var l: string in LinkText::split_lines(text) {
            if LinkText::contains(l, "error") {
                return LinkText::trim(l)
            }
        }

        var lines = LinkText::split_lines(text)
        return if (lines.empty()) => ("compile failed (no output)") else => LinkText::trim(lines[0])
    }

    /// An archive with no members, as `llvm-ar crs` writes one.
    pub static fn write_empty_archive(const path: string) -> bool {
        LinkFS::make_dirs(LinkFS::parent(path))
        return LinkFS::write(path, "!<arch>\n")
    }

    /// Lays the [files] / [headers] row \p how (`gen:<path>` from \p gen,
    /// `src:<path>` from \p src) at \p to.
    pub static fn put_ref(const how:  string,
                          const src:  string,
                          const gen:  string,
                          const to:   string,
                          hard:       bool,
                          @inout err: string) -> bool {
        var colon = LinkText::find(how, ":", 0)
        var kind  = if (colon < how.size()) => (LinkText::slice(how, 0, colon)) else => ""
        if kind != "src" && kind != "gen" {
            err = f"\x27{how}\x27 is neither src: nor gen:"
            return false
        }

        var rel  = LinkText::slice(how, colon + 1, how.size())
        var from = if (kind == "src") => (src + "/" + rel) else => gen + "/" + rel
        if !SysRun::put_file(from, to, hard) {
            err = f"cannot copy {from} to {to}"
            return false
        }

        return true
    }
}
