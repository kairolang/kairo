/// --- The Kairo Project -------------------------------- Sysroot/Share.k --- ///
///
///   The shipped input tree, <install>/share/kairo/sysroot (SysRoot.md
///   section 3): registry.toml, the family recipes, glibc/VERSIONS.toml and
///   quirks.toml. The format is build/sysroot-share/FORMAT.md, the contract
///   with the maintainer-side producer; everything here reads only what that
///   file promises.
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
import Sysroot::Names::SysTarget
import Sysroot::SysUtil::SysUtil
import std::env

/// One family recipe, families/<family>.toml. Only the keys step 3 needs
/// are read; [toml] and [validate] are the later stages' (FORMAT.md).
pub class SysRecipe {
    pub var path:         string
    pub var family:       string ///< the recipe id (musl, glibc, ...)
    pub var triple:       string ///< template of SYSROOT.toml's triple, {triple}
    pub var clang_triple: string ///< template override, "" = built in
    /// [per_arch.<var>] tables flattened: `<var>.<arch>` -> value, for
    /// {per_arch.<var>} in any template.
    pub var per_arch_keys: cxx::std::vector<string>
    pub var per_arch_vals: cxx::std::vector<string>
    pub var os_version:    string
    pub var arches:        cxx::std::vector<string> ///< empty = the built-in list
    pub var inputs:        cxx::std::vector<string> ///< templates
    pub var runtimes:      cxx::std::vector<string>
    pub var error:         string

    pub fn load(self, const path: string) -> bool {
        self.path = path
        var text = ""
        if !LinkFS::read(path, &text) {
            self.error = "cannot read the file"
            return false
        }

        var toml = TomlLite(text)
        var key  = ""
        var val  = TomlValue{}
        while toml.next(&key, &val) {
            if LinkText::starts_with(toml.table, "per_arch.") && val.kind == 1 {
                var v = LinkText::slice(toml.table, 9, toml.table.size())
                self.per_arch_keys.push_back(v + "." + key)
                self.per_arch_vals.push_back(val.text)
                continue
            }

            if !toml.table.empty() {
                continue
            }

            if key == "family" && val.kind == 1 {
                self.family = val.text
            } else if key == "triple" && val.kind == 1 {
                self.triple = val.text
            } else if key == "clang_triple" && val.kind == 1 {
                self.clang_triple = val.text
            } else if key == "os_version" && val.kind == 1 {
                self.os_version = val.text
            } else if key == "arches" && val.kind == 3 {
                self.arches = val.list
            } else if key == "inputs" && val.kind == 3 {
                self.inputs = val.list
            } else if key == "runtimes" && val.kind == 3 {
                self.runtimes = val.list
            }
        }

        if !toml.error.empty() {
            self.error = toml.error
            return false
        }

        return true
    }

    /// \p tmpl with {per_arch.<var>}, {triple}, {arch}, {libc_version} and
    /// {os_version} filled for \p t. {triple} is the recipe's own `triple`
    /// template, itself expanded (glibc's names go through it).
    pub fn expand(self, const tmpl: string, t: *SysTarget) -> string {
        var s = tmpl
        for var i: usize = 0; i < self.per_arch_keys.size(); ++i {
            var dot = LinkText::find(self.per_arch_keys[i], ".", 0)
            var v   = LinkText::slice(self.per_arch_keys[i], 0, dot)
            var a   = LinkText::slice(self.per_arch_keys[i], dot + 1, self.per_arch_keys[i].size())
            if a == t->arch {
                s = SysUtil::fill(s, "per_arch." + v, self.per_arch_vals[i])
            }
        }

        if !self.triple.empty()
            && LinkText::contains(s, "{triple}")
            && !LinkText::contains(self.triple, "{triple}") {
            s = SysUtil::fill(s, "triple", self.expand(self.triple, t))
        }

        s = SysUtil::fill(s, "arch", t->arch)
        s = SysUtil::fill(s, "libc_version", t->libc_version)
        return SysUtil::fill(s, "os_version", self.os_version)
    }
}

/// glibc/VERSIONS.toml.
pub class GlibcVersions {
    pub var versions: cxx::std::vector<string>
    pub var floor:    string
    pub var default_: string
    pub var error:    string

    pub fn load(self, const path: string) -> bool {
        var text = ""
        if !LinkFS::read(path, &text) {
            self.error = "cannot read the file"
            return false
        }

        var toml = TomlLite(text)
        var key  = ""
        var val  = TomlValue{}
        while toml.next(&key, &val) {
            if key == "versions" && val.kind == 3 {
                self.versions = val.list
            } else if key == "floor" && val.kind == 1 {
                self.floor = val.text
            } else if key == "default" && val.kind == 1 {
                self.default_ = val.text
            }
        }

        if !toml.error.empty() {
            self.error = toml.error
            return false
        }

        return true
    }
}

/// One `[quirk.<id>]` of quirks.toml (SysRoot.md section 6).
pub struct SysQuirk {
    pub var id:                   string
    pub var match_arch:           cxx::std::vector<string>
    pub var match_family:         cxx::std::vector<string>
    pub var match_os:             cxx::std::vector<string>
    pub var match_env:            cxx::std::vector<string>
    pub var match_probe:          cxx::std::vector<string>
    pub var target_rewrite:       string
    pub var cflags_stages:        cxx::std::vector<string>
    pub var cflags_add:           cxx::std::vector<string>
    pub var cflags_add_cxx:       cxx::std::vector<string>
    pub var cmake_stages:         cxx::std::vector<string>
    pub var cmake_defs:           cxx::std::vector<string>
    pub var force_include_stages: cxx::std::vector<string>
    pub var force_include_file:   string
    pub var post_archive:         string
    pub var required_symbols:     cxx::std::vector<string>
    pub var assert_file_contains: cxx::std::vector<string>
    pub var assert_compiles:      cxx::std::vector<string>
    pub var musl_arch:            string
    /// Every key as read, `key=value` in file order: what a stage key hashes
    /// when it hashes "this quirk's effects".
    pub var effects: cxx::std::vector<string>
}

pub class QuirkSet {
    pub var quirks: cxx::std::vector<SysQuirk>
    pub var error:  string

    /// Validates the schema as it reads: an unknown key or table is an
    /// error naming the quirk, so a typo never silently disables one.
    pub fn load(self, const path: string) -> bool {
        var text = ""
        if !LinkFS::read(path, &text) {
            self.error = f"{path}: cannot read the file"
            return false
        }

        var toml = TomlLite(text)
        var key  = ""
        var val  = TomlValue{}
        while toml.next(&key, &val) {
            if !LinkText::starts_with(toml.table, "quirk.") {
                self.error = f"{path}: key {key} outside a [quirk.<id>] table"
                return false
            }

            var id = LinkText::slice(toml.table, 6, toml.table.size())
            if self.quirks.empty() || self.quirks[self.quirks.size() - 1].id != id {
                var q = SysQuirk{}
                q.id = id
                self.quirks.push_back(q)
            }

            var *q = &self.quirks[self.quirks.size() - 1]
            if !QuirkSet::_set(q, key, &val) {
                self.error = f"{path}: quirk {id}: unknown key {key} (or wrong value type)"
                return false
            }
        }

        if !toml.error.empty() {
            self.error = f"{path}: {toml.error}"
            return false
        }

        return true
    }

    /// The quirks whose match keys all hold for \p t. \p probe holds the
    /// probe facts that are true (`int128`).
    pub fn matching(self,
                    t:            *SysTarget,
                    const os:     string,
                    const env_:   string,
                    @inout probe: cxx::std::vector<string>) -> cxx::std::vector<SysQuirk> {
        var out = cxx::std::vector<SysQuirk>()
        for var q: SysQuirk in self.quirks {
            if !q.match_arch.empty() && !SysUtil::contains(&q.match_arch, t->arch) {
                continue
            }

            if !q.match_family.empty() && !SysUtil::contains(&q.match_family, t->recipe) {
                continue
            }

            if !q.match_os.empty() && !SysUtil::contains(&q.match_os, os) {
                continue
            }

            if !q.match_env.empty() && !SysUtil::contains(&q.match_env, env_) {
                continue
            }

            var probe_ok = true
            for var p: string in q.match_probe {
                var neg  = LinkText::starts_with(p, "!")
                var fact = if (neg) => (LinkText::slice(p, 1, p.size())) else => p
                if SysUtil::contains(&probe, fact) == neg {
                    probe_ok = false
                }
            }

            if probe_ok {
                out.push_back(q)
            }
        }

        return out
    }

    priv static fn _set(q: *SysQuirk, const key: string, @inout v: TomlValue) -> bool {
        var as_text = if (v.kind == 3) => (SysUtil::joined(&v.list, ",")) else => v.text
        q->effects.push_back(key + "=" + as_text)
        if v.kind == 1 {
            if key == "target_rewrite" {
                q->target_rewrite = v.text
            } else if key == "force_include_file" {
                q->force_include_file = v.text
            } else if key == "post_archive" {
                q->post_archive = v.text
            } else if key == "musl_arch" {
                q->musl_arch = v.text
            } else {
                return false
            }

            return true
        }

        if v.kind != 3 {
            return false
        }

        if key == "match_arch" {
            q->match_arch = v.list
        } else if key == "match_family" {
            q->match_family = v.list
        } else if key == "match_os" {
            q->match_os = v.list
        } else if key == "match_env" {
            q->match_env = v.list
        } else if key == "match_probe" {
            q->match_probe = v.list
        } else if key == "cflags_stages" {
            q->cflags_stages = v.list
        } else if key == "cflags_add" {
            q->cflags_add = v.list
        } else if key == "cflags_add_cxx" {
            q->cflags_add_cxx = v.list
        } else if key == "cmake_stages" {
            q->cmake_stages = v.list
        } else if key == "cmake_defs" {
            q->cmake_defs = v.list
        } else if key == "force_include_stages" {
            q->force_include_stages = v.list
        } else if key == "required_symbols" {
            q->required_symbols = v.list
        } else if key == "assert_file_contains" {
            q->assert_file_contains = v.list
        } else if key == "assert_compiles" {
            q->assert_compiles = v.list
        } else {
            return false
        }

        return true
    }
}

/// The share tree itself: where it is, and its registry.
pub class ShareTree {
    pub var dir:   string
    pub var error: string
    /// registry.toml [inputs], as parallel lists (input dir -> tree_sha256).
    pub var input_dirs: cxx::std::vector<string>
    pub var input_sha:  cxx::std::vector<string>
    /// registry.toml [licenses], same keys.
    pub var license_dirs: cxx::std::vector<string>
    pub var license_ids:  cxx::std::vector<string>

    /// \p flag (--share), else $KAIRO_SYSROOT_SHARE, else
    /// <prefix>/share/kairo/sysroot with <prefix> the dir above bin/.
    pub static fn locate(const flag: string) -> string {
        if !flag.empty() {
            return LinkText::strip_slash(flag)
        }

        var e = LinkFS::env("KAIRO_SYSROOT_SHARE")
        if !e.empty() {
            return LinkText::strip_slash(e)
        }

        var prefix = LinkFS::parent(LinkFS::parent(env::exe_path()))
        return LinkText::join(prefix, "share/kairo/sysroot")
    }

    pub static fn present(const dir: string) -> bool {
        return LinkFS::is_file(LinkText::join(dir, "registry.toml"))
    }

    pub fn load(self, const dir: string) -> bool {
        self.dir = dir
        var path = LinkText::join(dir, "registry.toml")
        var text = ""
        if !LinkFS::read(path, &text) {
            self.error = f"{path} is missing"
            return false
        }

        var toml   = TomlLite(text)
        var key    = ""
        var val    = TomlValue{}
        var schema = ""
        while toml.next(&key, &val) {
            if toml.table.empty() && key == "schema" {
                schema = val.text
            } else if toml.table == "inputs" && val.kind == 1 {
                self.input_dirs.push_back(key)
                self.input_sha.push_back(val.text)
            } else if toml.table == "licenses" && val.kind == 1 {
                self.license_dirs.push_back(key)
                self.license_ids.push_back(val.text)
            }
        }

        if !toml.error.empty() {
            self.error = f"{path}: {toml.error}"
            return false
        }

        if schema != "1" {
            self.error = f"{path}: schema is \x27{schema}\x27, this ksys reads schema 1"
            return false
        }

        return true
    }

    /// The registered tree_sha256 of input dir \p rel; "" when unlisted.
    pub fn registered(self, const rel: string) -> string {
        for var i: usize = 0; i < self.input_dirs.size(); ++i {
            if self.input_dirs[i] == rel {
                return self.input_sha[i]
            }
        }

        return ""
    }

    /// An input dir on disk. `runtimes` falls back to the 0.2.0 sibling
    /// share/kairo/runtimes, so the tree need not carry it twice.
    pub fn input_path(self, const rel: string) -> string {
        var p = LinkText::join(self.dir, rel)
        if rel == "runtimes" && !LinkFS::is_dir(p) {
            return LinkText::join(LinkFS::parent(self.dir), "runtimes")
        }

        return p
    }

    /// runtimes/REVISION, trimmed; "" when absent.
    pub fn revision(self) -> string {
        var text = ""
        if !LinkFS::read(LinkText::join(self.input_path("runtimes"), "REVISION"), &text) {
            return ""
        }

        return LinkText::trim(text)
    }
}
