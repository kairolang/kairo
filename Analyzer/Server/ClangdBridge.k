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

            return out
        }

        self.walk_sources_(r, 0, &out)
        return out
    }

    fn walk_sources_(self, const dir: string, depth: u32, out: *[string]) {
        if (depth > SOURCE_WALK_DEPTH) || (out->size() > SOURCE_WALK_MAX_FILES) {
            return
        }

        for var name: string in LinkFS::list_dir(dir) {
            if name.empty() || (name[0] == 46) || (name == "build") || (name == "node_modules") {
                continue
            }

            var p = Path::join_str(dir, name)
            if LinkFS::is_dir(p) {
                self.walk_sources_(p, depth + 1, out)
            } else if is_cxx_source(p) {
                out->push_back(p)
            }
        }
    }

    /// Finds every `#include "x.k"` of the project's C/C++ sources again, and
    /// rewrites the overlay when the set of files changed.
    fn bridge_scan_(self) {
        self.br_rescan = false
        var srcs = self.bridge_sources_()
        var found: [string]
        for var i: usize = 0; i < srcs.size(); ++i {
            var text = self.text_of_(srcs[i])
            var incs = k_includes(text)
            for var k: usize = 0; k < incs.size(); ++k {
                var p = incs[k]
                if p[0] != 47 {
                    var beside = Path::join_str(Path::parent_of(srcs[i]), p)
                    if LinkFS::is_file(beside) {
                        p = beside
                    } else {
                        p = Path::join_str(self.bridge_root_(), p)
                    }
                }

                if !LinkFS::is_file(p) {
                    continue
                }

                p = Path::real_path_of(p)
                var dup = false
                for var q: usize = 0; q < found.size(); ++q {
                    if found[q] == p {
                        dup = true
                    }
                }

                if !dup {
                    found.push_back(p)
                }
            }
        }

        // Keep what is known about a file that stays; a new one is due now.
        var files:   [string]
        var hdr:     [string]
        var deps:    [string]
        var dirty:   [bool]
        var running: [bool]
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
            } else {
                hdr.push_back("")
                deps.push_back("")
                dirty.push_back(true)
                running.push_back(false)
            }
        }

        self.br_files   = files
        self.br_hdr     = hdr
        self.br_deps    = deps
        self.br_dirty   = dirty
        self.br_running = running
        self.trace(f"bridge: {found.size()} included .k file(s) in {srcs.size()} C/C++ source(s)")
        self.bridge_overlay_()
    }

    /// overlay.yaml, a clang VFS overlay mapping each included `.k` path to
    /// its header, written only when that mapping changed (clangd re-reads
    /// a header it already has by itself). `use-external-names: false`, at
    /// the top and on each entry, so clang names the file by its `.k` path.
    fn bridge_overlay_(self) {
        var map: string = ""
        for var b: usize = 0; b < self.br_files.size(); ++b {
            if !self.br_hdr[b].empty() {
                map += self.br_files[b] + "\t" + self.br_hdr[b] + "\n"
            }
        }

        if map == self.br_mapped {
            return
        }

        self.br_mapped = map
        var y: string = "{\n  \x27version\x27: 0,\n  \x27case-sensitive\x27: \x27true\x27,\n  \x27use-external-names\x27: false,\n  \x27roots\x27: [\n"
        var first = true
        for var b: usize = 0; b < self.br_files.size(); ++b {
            if self.br_hdr[b].empty() {
                continue
            }

            if !first {
                y += ",\n"
            }

            first = false
            y += "    { \x27type\x27: \x27file\x27, \x27name\x27: \x27" + self.br_files[b] + "\x27, "
            y += "\x27external-contents\x27: \x27" + self.br_hdr[b] + "\x27, \x27use-external-name\x27: false }"
        }

        y += "\n  ]\n}\n"
        var dir = self.bridge_dir_()
        LinkFS::make_dirs(dir)
        var ov = Path::join_str(dir, "overlay.yaml")
        LinkFS::write(ov, y)
        self.trace("bridge: wrote " + ov)
        self.bridge_clangd_(ov)
    }

    /// A `.clangd` fragment that adds the overlay: written when there is none
    /// or kals wrote the one there (its first line); a `.clangd` a person
    /// wrote is never touched, and the lines to add are logged instead.
    fn bridge_clangd_(self, const ov: string) {
        var marker = "# Written by kals, the Kairo language server: clangd reads Kairo headers through it. Remove this line to keep your own edits."
        var add = "  Add: [-ivfsoverlay, " + ov + ", -I" + self.bridge_dir_() + "]"
        var path = Path::join_str(self.bridge_root_(), ".clangd")
        var old: string = ""
        if LinkFS::read(path, &old) && (!old.starts_with(marker)) {
            self.say(MSG_INFO, "the C/C++ files include Kairo files; for clangd to resolve them, add to " + path + ":\nCompileFlags:\n" + add)
            return
        }

        LinkFS::write(path, marker + "\nCompileFlags:\n" + add + "\n")
    }

    fn start_header_(self, b: usize) {
        self.docs.sync_all()
        var j = Job()
        j.kind  = JOB_HEADER()
        j.entry = b
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
            if (self.docs.docs[i].tmp_rev != self.docs.docs[i].revision) || self.docs.docs[i].tmp_path.empty() {
                if !self.docs.docs[i].tmp_path.empty() {
                    self.garbage.push_back(self.docs.docs[i].tmp_path)
                }

                self.docs.docs[i].tmp_path = self.scratch(".k")
                self.docs.docs[i].tmp_rev  = self.docs.docs[i].revision
                LinkFS::write(self.docs.docs[i].tmp_path, self.docs.docs[i].text)
            }

            argv.push_back("--overlay")
            argv.push_back(self.docs.docs[i].path)
            argv.push_back(self.docs.docs[i].tmp_path)
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
        argv.push_back("--emit-headers-line-directives")
        argv.push_back(self.br_files[b])

        self.br_dirty[b] = false
        if !self.launch(&argv, j.log, &j.pi) {
            self.log("cannot start the header worker (" + self.exe + ")")
            return
        }

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

        var errs = doc.get_int(doc.root, "errors")
        self.trace(f"bridge: header done rc={rc} errors={errs} " + h)
        self.bridge_overlay_()
    }

    // --- workers ---------------------------------------------------------
}
