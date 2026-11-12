/// --- The Kairo Project ---------------- Analyzer/Server/ClangdBridge.k --- ///
///
///   The C/C++ bridge: generated headers for .k files a C/C++ source includes, and clangd's overlay.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


ffi "c++" import "Native/Types.hh"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/Support/Program.h"
ffi "c++" import "optional"
ffi "c++" import "string"
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "chrono"

import API::FS::LinkFS
import DocumentStore::{
    DocumentStore,
    fnv1a,
    path_to_uri,
    uri_to_path,
}
import Index::Legend::*
import Index::Snapshot::*
import Protocol::*
import Tuning::*
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import Support::FileIO::Path::Path
import TextScan::{
    InterfacePlan,
    Span,
    call_at,
    interface_for,
    spans,
}
import Workspace::CompileCommandsLoader::{
    Project,
    project_file_name,
}
import std::io
import Server::CodeActions::*
import Server::Completion::*
import Server::Diagnostics::*
import Server::Features::*
import Server::Formatting::*
import Server::Lifecycle::*
import Server::Lookup::*
import Server::Navigation::*
import Server::Output::*
import Server::Scheduling::*
import Server::Server::*
import Server::SignatureHelp::*
import Server::Structure::*
import Server::TextUtil::*
import Server::Tokens::*
import Server::Workers::*

/// The '\n'-terminated words of \p text.
fn split_lines_(const text: string) -> [string] {
    var out: [string]
    var at: usize = 0
    while at < text.size() {
        var nl = find_from(text, "\n", at)
        if nl == usize::MAX {
            break
        }

        out.push_back(text.subslice(at, nl - at))
        at = nl + 1
    }

    return out
}

/// \p rel as a clangd PathMatch regex that matches only itself.
fn path_regex_(const rel: string) -> string {
    var out: string = ""
    var meta = ".^$|()[]{}*+?\\"
    for var i: usize = 0; i < rel.size(); ++i {
        var one = rel.subslice(i, 1)
        if find_from(meta, one, 0) != usize::MAX {
            out += "\\"
        }

        out += one
    }

    return out
}

/// \p w as a single-quoted YAML scalar: a path with a space, `,` or `#`
/// would end or comment out a plain one inside a flow sequence.
fn yaml_word_(const w: string) -> string {
    var out: string = "\x27"
    for var i: usize = 0; i < w.size(); ++i {
        var one = w.subslice(i, 1)
        if one == "\x27" {
            out += "\x27"
        }

        out += one
    }

    return out + "\x27"
}

/// The single-quoted YAML scalar after `'<key>': ` on \p line (the
/// overlay's one-entry-per-line form, yaml_word_), or "".
fn yaml_value_(const line: string, const key: string) -> string {
    var at = find_from(line, "\x27" + key + "\x27: \x27", 0)
    if at == usize::MAX {
        return ""
    }

    var out: string = ""
    var i = at + key.size() + 5
    while i < line.size() {
        if line[i] == 39 {
            if ((i + 1) < line.size()) && (line[i + 1] == 39) {
                out += "\x27"
                i += 2
                continue
            }

            return out
        }

        out += line.subslice(i, 1)
        i += 1
    }

    return ""
}

extend Server {
    fn bridge_root_(const self) -> string {
        if !self.project.dir.empty() {
            return self.project.dir
        }

        return self.root
    }

    fn bridge_dir_(const self) -> string {
        return Path::join_str(Path::join_str(self.bridge_root_(), ".kairo"), "clangd")
    }

    /// The text of \p path: its open buffer, else the disk.
    fn text_of_(self, const path: string) -> string {
        var di = self.docs.index_of_path(path)
        if di != usize::MAX {
            self.docs.sync_all()
            return self.docs.docs[di].text
        }

        var text: string = ""
        LinkFS::read(path, &text)
        return text
    }

    /// The C and C++ sources of the project: the `file`s of its
    /// compile_commands.json (the root's, or build/'s), else every C/C++
    /// file under the root (build trees and dot-directories skipped).
    fn bridge_sources_(self) -> [string] {
        var out: [string]
        var r = self.bridge_root_()
        var cands: [string]
        cands.push_back(Path::join_str(r, "compile_commands.json"))
        cands.push_back(Path::join_str(Path::join_str(r, "build"), "compile_commands.json"))
        for var c: usize = 0; c < cands.size(); ++c {
            var text: string = ""
            var doc = JsonDoc()
            if (!LinkFS::read(cands[c], &text)) || (!doc.parse(text)) {
                continue
            }

            var x = doc.first(doc.root)
            while x != JSON_NONE() {
                var f = doc.get_str(x, "file")
                if (!f.empty()) && (f[0] != 47) {
                    f = Path::join_str(doc.get_str(x, "directory"), f)
                }

                if is_cxx_source(f) {
                    out.push_back(f)
                }

                x = doc.next(x)
            }

            break
        }

        // A source the database does not list is still a source: clangd
        // opens it with an inferred command, and its `#include "x.k"` needs
        // the overlay as much (a scratch main.cc beside a 75,000-entry
        // database, P858). The walk is bounded (Tuning.k) and lists a
        // directory's files before its subdirectories, so the files nearest
        // the root are the ones the bound keeps.
        var walked: [string]
        self.walk_sources_(r, 0, &walked)
        for var w: usize = 0; w < walked.size(); ++w {
            out.push_back(walked[w])
        }

        // And the ones the editor reported (a watched-file event), wherever
        // they are.
        for var w: usize = 0; w < self.br_told.size(); ++w {
            out.push_back(self.br_told[w])
        }

        return out
    }

    fn walk_sources_(self, const dir: string, depth: u32, out: *[string]) {
        if (depth > SOURCE_WALK_DEPTH) || (out->size() > SOURCE_WALK_MAX_FILES) {
            return
        }

        var subs: [string]
        for var name: string in LinkFS::list_dir(dir) {
            if name.empty() || (name[0] == 46) || (name == "build") || (name == "node_modules") {
                continue
            }

            var p = Path::join_str(dir, name)
            if LinkFS::is_dir(p) {
                subs.push_back(p)
            } else if is_cxx_source(p) {
                out->push_back(p)
            }
        }

        for var q: usize = 0; q < subs.size(); ++q {
            self.walk_sources_(subs[q], depth + 1, out)
        }
    }

    /// \p name as `#include "name"` in \p from finds it: beside \p from,
    /// else under the project root; real path, or "" when neither exists.
    fn bridge_resolve_(self, const from: string, const name: string) -> string {
        var p = name
        if p[0] != 47 {
            var beside = Path::join_str(Path::parent_of(from), p)
            if LinkFS::is_file(beside) {
                p = beside
            } else {
                p = Path::join_str(self.bridge_root_(), p)
            }
        }

        if !LinkFS::is_file(p) {
            return ""
        }

        return Path::real_path_of(p)
    }

    /// The `.k` files \p src reaches through quoted includes, directly or
    /// through the headers it includes (P861: a.cc includes b.h, b.h
    /// includes c.k), into \p ks, and the headers read on the way into
    /// \p seen (an edit to one of them re-reads \p src), both
    /// '\n'-terminated, in include order. Bounded: headers
    /// BRIDGE_INCLUDE_DEPTH deep, and at most BRIDGE_INCLUDE_MAX_READS
    /// header reads per scan (\p budget), each file read once a scan
    /// (\p memo: its resolved `.k` includes and header includes). Textual:
    /// `#ifdef` is not evaluated, angle includes and -I roots are not
    /// followed.
    fn bridge_closure_(self,
                       const src: string,
                       ks: *string,
                       seen: *string,
                       budget: *usize,
                       memo: *{string: usize},
                       m_k: *[string],
                       m_h: *[string]) {
        var st_f: [string]
        var st_d: [u32]
        st_f.push_back(src)
        st_d.push_back(0)
        while !st_f.empty() {
            var f = st_f[st_f.size() - 1]
            var d = st_d[st_d.size() - 1]
            st_f.pop_back()
            st_d.pop_back()
            var at = usize::MAX
            var hit = memo->get(f)
            if hit != null {
                at = *hit
            } else {
                if d > 0 {
                    if *budget == 0 {
                        continue
                    }

                    *budget = *budget - 1
                }

                var kj: string = ""
                var hj: string = ""
                var names = quoted_includes(self.text_of_(f))
                for var i: usize = 0; i < names.size(); ++i {
                    var r = self.bridge_resolve_(f, names[i])
                    if r.empty() {
                        continue
                    }

                    if names[i].ends_with(".k") {
                        kj += r + "\n"
                    } else if is_cxx_source(r) {
                        hj += r + "\n"
                    }
                }

                at = m_k->size()
                m_k->push_back(kj)
                m_h->push_back(hj)
                (*memo)[f] = at
            }

            var kl = split_lines_((*m_k)[at])
            for var i: usize = 0; i < kl.size(); ++i {
                if find_from(*ks, kl[i] + "\n", 0) == usize::MAX {
                    *ks = *ks + kl[i] + "\n"
                }
            }

            if d >= BRIDGE_INCLUDE_DEPTH {
                continue
            }

            // Pushed last-first, so they are visited in include order.
            var hl = split_lines_((*m_h)[at])
            for var i = hl.size(); i > 0; --i {
                var h = hl[i - 1]
                if (h != src) && (find_from(*seen, h + "\n", 0) == usize::MAX) {
                    *seen = *seen + h + "\n"
                    st_f.push_back(h)
                    st_d.push_back(d + 1)
                }
            }
        }
    }

    /// Finds every `.k` the project's C/C++ sources include again (directly
    /// or through their headers), and rewrites the overlay when the set of
    /// files changed.
    fn bridge_scan_(self) {
        self.br_rescan = false
        var srcs = self.bridge_sources_()
        var found: [string]
        // A scan reads every source, and a large project has tens of
        // thousands: the `.k` files of a source nobody reported changed,
        // whose headers nobody did either, are the ones the last scan found
        // (kept in scan order, which a database keeps stable).
        var inc_of:  [string]
        var seen_of: [string]
        var budget: usize = BRIDGE_INCLUDE_MAX_READS
        var memo: {string: usize}
        var m_k: [string]
        var m_h: [string]
        for var i: usize = 0; i < srcs.size(); ++i {
            var known = (i < self.br_src.size()) && (self.br_src[i] == srcs[i]) && (i < self.br_src_seen.size())
            for var q: usize = 0; known && (q < self.br_changed.size()); ++q {
                if (self.br_changed[q] == srcs[i]) || (find_from(self.br_src_seen[i], self.br_changed[q] + "\n", 0) != usize::MAX) {
                    known = false
                }
            }

            if known {
                inc_of.push_back(self.br_src_inc[i])
                seen_of.push_back(self.br_src_seen[i])
            } else {
                var ks:   string = ""
                var seen: string = ""
                self.bridge_closure_(srcs[i], &ks, &seen, &budget, &memo, &m_k, &m_h)
                inc_of.push_back(ks)
                seen_of.push_back(seen)
            }
        }

        if budget == 0 {
            self.trace(f"bridge: the header scan stopped at {BRIDGE_INCLUDE_MAX_READS} reads")
        }

        self.br_src      = srcs
        self.br_src_inc  = inc_of
        self.br_src_seen = seen_of
        self.br_changed.clear()
        var rank: [usize] ///< per found file: the latest recency of a source including it
        for var i: usize = 0; i < srcs.size(); ++i {
            if inc_of[i].empty() {
                continue
            }

            var recency: usize = 0
            for var q: usize = 0; q < self.br_recent.size(); ++q {
                if self.br_recent[q] == srcs[i] {
                    recency = q + 1
                }
            }

            var incs = split_lines_(inc_of[i])
            for var k: usize = 0; k < incs.size(); ++k {
                var p = incs[k]
                var at = usize::MAX
                for var q: usize = 0; q < found.size(); ++q {
                    if found[q] == p {
                        at = q
                    }
                }

                if at == usize::MAX {
                    found.push_back(p)
                    rank.push_back(recency)
                } else if recency > rank[at] {
                    rank[at] = recency
                }
            }
        }

        // Keep what is known about a file that stays; a new one is due now.
        var files:   [string]
        var hdr:     [string]
        var deps:    [string]
        var dirty:   [bool]
        var running: [bool]
        var cxx_w:   [string]
        var c_w:     [string]
        for var q: usize = 0; q < found.size(); ++q {
            var old = usize::MAX
            for var b: usize = 0; b < self.br_files.size(); ++b {
                if self.br_files[b] == found[q] {
                    old = b
                }
            }

            files.push_back(found[q])
            if old != usize::MAX {
                hdr.push_back(self.br_hdr[old])
                deps.push_back(self.br_deps[old])
                dirty.push_back(self.br_dirty[old])
                running.push_back(self.br_running[old])
                cxx_w.push_back(self.br_cxx_w[old])
                c_w.push_back(self.br_c_w[old])
            } else {
                hdr.push_back("")
                deps.push_back("")
                dirty.push_back(true)
                running.push_back(false)
                cxx_w.push_back("")
                c_w.push_back("")
            }
        }

        self.br_files   = files
        self.br_hdr     = hdr
        self.br_deps    = deps
        self.br_dirty   = dirty
        self.br_running = running
        self.br_rank    = rank
        self.br_cxx_w   = cxx_w
        self.br_c_w     = c_w
        self.trace(f"bridge: {found.size()} included .k file(s) in {srcs.size()} C/C++ source(s)")
        self.bridge_overlay_()
    }

    /// The header job due next (usize::MAX: none), P863: a `.k` open in the
    /// editor first, then one included by the C/C++ source reported changed
    /// most recently (br_rank), then scan order. Jobs run one at a time and
    /// take about a second or two each, so on a project with tens of
    /// included files the one the user is looking at must not wait for the
    /// rest.
    fn bridge_next_(self) -> usize {
        var best = usize::MAX
        var best_rank: usize = 0
        var top = self.br_recent.size() + 1 // above any source's recency
        for var b: usize = 0; b < self.br_files.size(); ++b {
            if (!self.br_dirty[b]) || self.br_running[b] {
                continue
            }

            var r: usize = 0
            if self.docs.index_of_path(self.br_files[b]) != usize::MAX {
                r = top
            } else if b < self.br_rank.size() {
                r = self.br_rank[b]
            }

            if (best == usize::MAX) || (r > best_rank) {
                best = b
                best_rank = r
            }
        }

        return best
    }

    /// overlay.yaml, a clang VFS overlay mapping each included `.k` path to
    /// its header. `use-external-names: false`, at the top and on each
    /// entry, so clang names the file by its `.k` path.
    ///
    /// Shared (P863): two kals on one root (two editors) each write it, so
    /// it is a MERGE, not this process's view: the entries on disk whose
    /// `.k` and header both exist are kept beside this process's own, and
    /// for a `.k` both name, the newer header wins (whichever process ran
    /// its job last), so two processes agree instead of taking turns. Sorted
    /// by `.k` path, so equal sets give equal text. Written only when that
    /// text differs from the file (clangd re-reads a header it already has
    /// by itself), through a temporary file and a rename, so clangd never
    /// reads half a file. A write that lands between another process's read
    /// and rename is undone by that process's rename; the loop notices the
    /// changed mtime (BRIDGE_OVERLAY_CHECK_MS) and merges again. Entries
    /// that are gone are dropped. The same merge lists, at start, the
    /// headers an earlier session wrote: stale but present until each
    /// file's job regenerates it.
    fn bridge_overlay_(self) {
        var dir = self.bridge_dir_()
        var ov  = Path::join_str(dir, "overlay.yaml")
        var names: [string]
        var hdrs:  [string]
        for var b: usize = 0; b < self.br_files.size(); ++b {
            if (!self.br_hdr[b].empty()) && LinkFS::is_file(self.br_hdr[b]) {
                names.push_back(self.br_files[b])
                hdrs.push_back(self.br_hdr[b])
            }
        }

        var disk: string = ""
        LinkFS::read(ov, &disk)
        var lines = split_lines_(disk)
        for var i: usize = 0; i < lines.size(); ++i {
            var name = yaml_value_(lines[i], "name")
            var hdr  = yaml_value_(lines[i], "external-contents")
            if name.empty() || hdr.empty() || (!LinkFS::is_file(name)) || (!LinkFS::is_file(hdr)) {
                continue
            }

            var at = usize::MAX
            for var q: usize = 0; q < names.size(); ++q {
                if names[q] == name {
                    at = q
                }
            }

            if at == usize::MAX {
                names.push_back(name)
                hdrs.push_back(hdr)
            } else if (hdrs[at] != hdr) && (LinkFS::mtime(hdr) > LinkFS::mtime(hdrs[at])) {
                hdrs[at] = hdr
            }
        }

        if names.empty() {
            self.br_ov_mtime = LinkFS::mtime(ov)
            return
        }

        // Sorted by .k path (insertion: tens of entries).
        for var i: usize = 1; i < names.size(); ++i {
            var j = i
            while (j > 0) && (names[j] < names[j - 1]) {
                var n = names[j]
                names[j] = names[j - 1]
                names[j - 1] = n
                var h = hdrs[j]
                hdrs[j] = hdrs[j - 1]
                hdrs[j - 1] = h
                j -= 1
            }
        }

        var y: string = "{\n  \x27version\x27: 0,\n  \x27case-sensitive\x27: \x27true\x27,\n  \x27use-external-names\x27: false,\n  \x27roots\x27: [\n"
        for var q: usize = 0; q < names.size(); ++q {
            if q > 0 {
                y += ",\n"
            }

            y += "    { \x27type\x27: \x27file\x27, \x27name\x27: " + yaml_word_(names[q]) + ", "
            y += "\x27external-contents\x27: " + yaml_word_(hdrs[q]) + ", \x27use-external-name\x27: false }"
        }

        y += "\n  ]\n}\n"
        if y != disk {
            LinkFS::make_dirs(dir)
            var tmp = ov + "." + Path::filename_of(self.tmp) + ".tmp"
            if LinkFS::write(tmp, y) && LinkFS::rename(tmp, ov) {
                self.trace("bridge: wrote " + ov)
            } else {
                LinkFS::remove(tmp)
                self.trace("bridge: cannot write " + ov)
            }
        }

        self.br_ov_mtime = LinkFS::mtime(ov)
        // The mapping may stand while kcc's flags or the set of sources
        // that include a `.k` do not (the .clangd says both).
        self.bridge_clangd_(ov)
    }

    /// The C/C++ sources under the root that reach a `.k` (directly or
    /// through a header, P861), relative to it (clangd matches a fragment's
    /// PathMatch against that spelling), and, in \p words, kcc's words for
    /// each ('\n'-terminated): the C set for a `.c` / `.m`, the C++ set
    /// otherwise, from the header job of the first `.k` it reaches, so
    /// sources of entries with different flags get their own. A source whose
    /// `.k` files have no finished job yet takes the set of any file that
    /// has (at a restart every job is due again, and the source must not
    /// lose kcc's words until its own comes round); with none at all it is
    /// left out.
    fn bridge_includers_(self, words: *[string]) -> [string] {
        var out:   [string]
        var r    = self.bridge_root_()
        var rr   = Path::real_path_of(r)
        var any_cxx: string = ""
        var any_c:   string = ""
        for var b: usize = 0; b < self.br_files.size(); ++b {
            if any_cxx.empty() {
                any_cxx = self.br_cxx_w[b]
            }

            if any_c.empty() {
                any_c = self.br_c_w[b]
            }
        }

        for var i: usize = 0; i < self.br_src.size(); ++i {
            if (i >= self.br_src_inc.size()) || self.br_src_inc[i].empty() {
                continue
            }

            var p   = self.br_src[i]
            var rel = ""
            if p.starts_with(r + "/") {
                rel = p.subslice(r.size() + 1, p.size() - r.size() - 1)
            } else {
                var rp = Path::real_path_of(p)
                if rp.starts_with(rr + "/") {
                    rel = rp.subslice(rr.size() + 1, rp.size() - rr.size() - 1)
                }
            }

            if rel.empty() {
                continue // outside the root: this .clangd does not apply to it
            }

            var dup = false
            for var q: usize = 0; q < out.size(); ++q {
                if out[q] == rel {
                    dup = true
                }
            }

            if dup {
                continue
            }

            var is_c = p.ends_with(".c") || p.ends_with(".m")
            var w: string = ""
            var ks = split_lines_(self.br_src_inc[i])
            for var k: usize = 0; w.empty() && (k < ks.size()); ++k {
                for var b: usize = 0; w.empty() && (b < self.br_files.size()); ++b {
                    if self.br_files[b] == ks[k] {
                        if is_c {
                            w = self.br_c_w[b]
                        } else {
                            w = self.br_cxx_w[b]
                        }
                    }
                }
            }

            if w.empty() && is_c {
                w = any_c
            } else if w.empty() {
                w = any_cxx
            }

            if !w.empty() {
                out.push_back(rel)
                words->push_back(w)
            }
        }

        return out
    }

    /// The `.clangd` clangd needs for the bridge: the overlay and the cache
    /// root for every file, then, for the sources that reach a `.k`, the
    /// driver words kcc compiles such a source with (P859), one fragment per
    /// distinct set (P861: C and C++ sources, entries with other flags).
    /// The generated header's prelude includes the runtime's headers
    /// (`rt/*.h`, found under kcc's runtime root) and standard headers that
    /// must be the sysroot's libc++: under the host's libstdc++,
    /// `<type_traits>` declares `__make_unsigned`, clang then stops treating
    /// that name as its builtin, and rt/intrinsics.h does not parse. Scoped,
    /// because kcc's words carry its `-std` and standard library, which a C
    /// source or a C++ file built by another compiler must not get.
    fn bridge_fragment_(self, const ov: string, all_words: *[string]) -> string {
        var y = "CompileFlags:\n  Add: [-ivfsoverlay, " + yaml_word_(ov) + ", " + yaml_word_("-I" + self.bridge_dir_()) + "]\n"
        var words: [string]
        var inc = self.bridge_includers_(&words)
        var sets: [string]
        for var q: usize = 0; q < words.size(); ++q {
            var dup = false
            for var g: usize = 0; g < sets.size(); ++g {
                if sets[g] == words[q] {
                    dup = true
                }
            }

            if !dup {
                sets.push_back(words[q])
            }
        }

        for var g: usize = 0; g < sets.size(); ++g {
            y += "---\nIf:\n  PathMatch: ["
            var first = true
            for var q: usize = 0; q < inc.size(); ++q {
                if words[q] != sets[g] {
                    continue
                }

                if !first {
                    y += ", "
                }

                first = false
                y += yaml_word_(path_regex_(inc[q]))
            }

            y += "]\nCompileFlags:\n  Add: ["
            var ws = split_lines_(sets[g])
            for var k: usize = 0; k < ws.size(); ++k {
                if k > 0 {
                    y += ", "
                }

                y += yaml_word_(ws[k])
                all_words->push_back(ws[k])
            }

            y += "]\n"
        }

        return y
    }

    /// The `.clangd` fragment (bridge_fragment_): written when there is none
    /// or kals wrote the one there (its first line), and only when its text
    /// changed, since clangd reloads its config on every write. A `.clangd`
    /// a person wrote is never touched: the lines to add are said once per
    /// distinct text (a bridge pass runs after every header job, P857), and
    /// not at all when every flag word is already in the file.
    fn bridge_clangd_(self, const ov: string) {
        var marker = "# Written by kals, the Kairo language server: clangd reads Kairo headers through it. Remove this line to keep your own edits."
        var ws: [string]
        var frag = self.bridge_fragment_(ov, &ws)
        var path = Path::join_str(self.bridge_root_(), ".clangd")
        var old: string = ""
        if LinkFS::read(path, &old) && (!old.starts_with(marker)) {
            var have = find_from(old, ov, 0) != usize::MAX
            for var k: usize = 0; have && (k < ws.size()); ++k {
                have = find_from(old, ws[k], 0) != usize::MAX
            }

            if have || (frag == self.br_said) {
                return
            }

            self.br_said = frag
            self.say(MSG_INFO, "the C/C++ files include Kairo files; for clangd to resolve them, add to " + path + ":\n" + frag)
            return
        }

        // No header job has reported kcc's words yet (a restart, a second
        // kals on the root): the scoped fragments of the .clangd kals wrote
        // before are better than none until one has.
        if ws.empty() && old.starts_with(marker) && (find_from(old, "PathMatch", 0) != usize::MAX) {
            return
        }

        var text = marker + "\n" + frag
        if old != text {
            LinkFS::write(path, text)
        }
    }

    fn start_header_(self, b: usize) {
        if self.launch_held() {
            return // still due
        }

        self.docs.sync_all()
        var j = Job()
        j.kind  = JobKind::Header
        j.path  = self.br_files[b]
        j.out   = self.scratch(".json")
        j.log   = self.scratch(".log")
        j.rev   = self.rev
        j.started_ms = now_ms()

        var argv: [string]
        argv.push_back(self.exe)
        argv.push_back("--worker")
        argv.push_back(j.out)
        // The flags of the entry whose graph holds the file (its -I roots
        // name its imports), else the project's default_args.
        var held = usize::MAX
        for var e: usize = 0; e < self.entries.size(); ++e {
            if self.entries[e].holds(self.br_files[b]) && (held == usize::MAX) {
                held = e
            }
        }

        argv.push_back("--cwd")
        if held != usize::MAX {
            argv.push_back(self.entries[held].dir)
        } else {
            argv.push_back(self.bridge_root_())
        }

        argv.push_back("--as-module")
        for var i: usize = 0; i < self.docs.docs.size(); ++i {
            argv.push_back("--overlay")
            argv.push_back(self.docs.docs[i].path)
            argv.push_back(self.overlay_of_(i))
        }

        argv.push_back("--")
        if held != usize::MAX {
            for var i: usize = 0; i < self.entries[held].args.size(); ++i {
                argv.push_back(self.entries[held].args[i])
            }
        } else {
            for var i: usize = 0; i < self.project.default_args.size(); ++i {
                argv.push_back(self.project.default_args[i])
            }
        }

        argv.push_back("--emit-headers")
        argv.push_back(self.bridge_dir_())
        argv.push_back("--emit-headers-layout")
        argv.push_back(self.br_files[b])

        // Clean only once its job is running: a refused launch leaves the
        // row due, and bridge_next_ offers it again after the backoff.
        if self.launch_job(&argv, &j, "header") != LaunchResult::Started {
            return
        }

        self.br_dirty[b]   = false
        self.br_running[b] = true
        self.trace("bridge: header start " + j.path)
        self.jobs.push_back(j)
    }

    fn finish_header_(self, j: *Job, rc: i32) {
        var b = usize::MAX
        for var q: usize = 0; q < self.br_files.size(); ++q {
            if self.br_files[q] == j->path {
                b = q
            }
        }

        if b == usize::MAX {
            return // no longer included
        }

        self.br_running[b] = false
        var text: string = ""
        var doc = JsonDoc()
        if !(LinkFS::read(j->out, &text) && doc.parse(text) && doc.get_bool(doc.root, "ok")) {
            self.trace(f"bridge: header job failed rc={rc} " + j->path)
            return // the last good header stays
        }

        var deps: string = ""
        var x = doc.first(doc.get(doc.root, "deps"))
        while x != JSON_NONE() {
            deps += doc.str(x)
            deps += "\n"
            x = doc.next(x)
        }

        self.br_deps[b] = deps
        var h = Path::join_str(self.bridge_dir_(), doc.get_str(doc.root, "header"))
        if LinkFS::is_file(h) {
            self.br_hdr[b] = h
        }

        // kcc's words for a C++ and for a C source that includes this
        // file: per file, since entries' flags differ (P861).
        var cxx: string = ""
        var a = doc.first(doc.get(doc.root, "cxx_flags"))
        while a != JSON_NONE() {
            cxx += doc.str(a) + "\n"
            a = doc.next(a)
        }

        var cw: string = ""
        a = doc.first(doc.get(doc.root, "c_flags"))
        while a != JSON_NONE() {
            cw += doc.str(a) + "\n"
            a = doc.next(a)
        }

        if !cxx.empty() {
            self.br_cxx_w[b] = cxx
        }

        if !cw.empty() {
            self.br_c_w[b] = cw
        }

        var errs = doc.get_int(doc.root, "errors")
        self.trace(f"bridge: header done rc={rc} errors={errs} " + h)
        self.bridge_overlay_()
    }

    // --- workers ---------------------------------------------------------
}
