/// --- The Kairo Project ------------------------ Driver/CompilerInit.k --- ///
///
///   CompilerInstance, part: `kairo --init [dir]`, which starts a project
///   from a template. The compiler only copies: the layout, the files and
///   the lines printed afterwards are the template's, read from
///   <prefix>/share/kairo/templates/<name>/template.toml. An `extend` of the
///   class in CompilerInstance.k (Driver/module.k).
///
///   template.toml is the flat TOML TomlLite reads:
///
///       next = ["line printed after the files", "..."]
///       [files]
///       "main.k" = "source/main.k"     # file in the template -> project path
///
///   `{{name}}` (the directory's base name) and `{{ident}}` (that name as a
///   Kairo identifier) are replaced in every file's contents, in every
///   destination path and in the `next` lines; nothing else is rewritten.
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
import Diagnostic::Registry::DiagID
import Driver::CompilerInstance::CompilerInstance
import Support::ExitCodes::{
    EXIT_FAILURE,
    EXIT_OK,
}
import Support::FileIO::Path::Path
import std::env
import std::io

/// `name` as a Kairo identifier: every byte outside [A-Za-z0-9_] becomes
/// '_', and a leading digit gets a '_' in front.
pub fn init_ident(const name: string) -> string {
    var out = ""
    for var i: usize = 0; i < name.size(); ++i {
        var c = name.data()[i]
        var ok = (c >= ('a' as u8) && c <= ('z' as u8))
            || (c >= ('A' as u8) && c <= ('Z' as u8))
            || (c >= ('0' as u8) && c <= ('9' as u8))
            || c == ('_' as u8)
        if ok {
            out += LinkText::slice(name, i, i + 1)
        } else {
            out += "_"
        }
    }

    if !out.is_empty() && out.data()[0] >= ('0' as u8) && out.data()[0] <= ('9' as u8) {
        return "_" + out
    }

    return out
}

/// `text` with the two placeholders filled. `{{ident}}` goes first: an
/// identifier holds no braces, so the name substituted after it is never
/// rescanned.
fn init_fill(const text: string, const name: string, const ident: string) -> string {
    return text.replace("{{ident}}", ident).replace("{{name}}", name)
}

fn init_has(const list: cxx::std::vector<string>, const s: string) -> bool {
    for var i: usize = 0; i < list.size(); ++i {
        if list[i] == s {
            return true
        }
    }

    return false
}

/// Removes the files a failed `--init` wrote, then the directories it made.
/// A directory is removed only once it is empty, and each pass empties the
/// parents of the ones it removed, so `dirs.size()` passes clear any nesting.
fn init_undo(const files: cxx::std::vector<string>, const dirs: cxx::std::vector<string>) {
    for var i: usize = 0; i < files.size(); ++i {
        LinkFS::remove(files[i])
    }

    for var pass: usize = 0; pass < dirs.size(); ++pass {
        for var i: usize = 0; i < dirs.size(); ++i {
            LinkFS::remove(dirs[i])
        }
    }
}

extend CompilerInstance {
    fn wants_init(self) -> bool {
        return self.invocation()->args.get_bool("init")
    }

    /// `--init [dir]`. Every destination is checked before the first write,
    /// so a project that already has any of the files is left untouched.
    fn run_init(self) -> i32 {
        var n_in = self.invocation()->args.inputs.size()
        if n_in > 1 {
            return self._init_fail(
                "--init takes one directory, the project to create",
            )
        }

        var given = if (n_in == 1) => (self.invocation()->args.inputs[0].path.copy()) else => "."
        var dir = Path(given).path_data.copy()
        while dir.size() > 1 && dir.data()[dir.size() - 1] == ('/' as u8) {
            dir = LinkText::slice(dir, 0, dir.size() - 1)
        }

        var name = Path::filename_of(dir)
        if name.is_empty() || name == "/" || name == "." || name == ".." {
            return self._init_fail(
                f"--init: '{given}' names no directory a project can be named after",
            )
        }

        if LinkFS::exists(dir) && !LinkFS::is_dir(dir) {
            return self._init_fail(
                f"--init: '{given}' exists and is not a directory",
            )
        }

        var ident = init_ident(name)
        var tdir = Path::join_str(
            Path::parent_of(Path::parent_of(env::exe_path())),
            "share/kairo/templates/exe",
        )

        var manifest = Path::join_str(tdir, "template.toml")
        var text     = ""
        if !LinkFS::read(manifest, &text) {
            return self._init_fail(
                f"--init: cannot read the project template '{manifest}'; this installation is incomplete",
            )
        }

        var srcs  = cxx::std::vector<string>()
        var dests = cxx::std::vector<string>()
        var next  = cxx::std::vector<string>()
        var toml  = TomlLite(text)
        var key   = ""
        var val   = TomlValue{}
        while toml.next(&key, &val) {
            if toml.table == "files" && val.kind == 1 {
                srcs.push_back(key.copy())
                dests.push_back(init_fill(val.text, name, ident))
            } else if toml.table.is_empty() && key == "next" && val.kind == 3 {
                next = val.take_list()
            }
        }

        if !toml.error.is_empty() {
            return self._init_fail(f"--init: {manifest}: {toml.error}")
        }

        // All or nothing: one existing file and nothing is written.
        for var i: usize = 0; i < dests.size(); ++i {
            var out = Path::join_str(dir, dests[i].copy())
            if LinkFS::exists(out) {
                return self._init_fail(
                    f"--init: '{out}' already exists; nothing was written",
                )
            }
        }

        var bodies = cxx::std::vector<string>()
        for var i: usize = 0; i < srcs.size(); ++i {
            var src  = Path::join_str(tdir, srcs[i].copy())
            var body = ""
            if !LinkFS::read(src, &body) {
                return self._init_fail(
                    f"--init: cannot read the template file '{src}'",
                )
            }

            bodies.push_back(init_fill(body, name, ident))
        }

        // The directories this run creates, so a failed write can remove them.
        var made = cxx::std::vector<string>()
        for var i: usize = 0; i < dests.size(); ++i {
            var p = Path::parent_of(Path::join_str(dir, dests[i].copy()))
            while !p.is_empty() && !LinkFS::exists(p) && !init_has(made, p) {
                made.push_back(p.copy())
                p = Path::parent_of(p)
            }
        }

        // All or nothing here too: a write that fails removes every file and
        // directory written before it. None of them existed (checked above).
        var written = cxx::std::vector<string>()
        for var i: usize = 0; i < dests.size(); ++i {
            var out = Path::join_str(dir, dests[i].copy())
            if !LinkFS::make_dirs(Path::parent_of(out)) || !LinkFS::write(out, bodies[i]) {
                // A write can fail after creating the file (a full disk).
                LinkFS::remove(out)
                init_undo(written, made)
                return self._init_fail(
                    f"--init: cannot write '{out}'; nothing was written",
                )
            }

            written.push_back(out.copy())
        }

        for var i: usize = 0; i < dests.size(); ++i {
            // Relative to where the command ran, as the directory was given.
            var shown = if (n_in == 1) => (LinkText::join(
                            given.copy(),
                            dests[i].copy(),
                        ))
                        else => dests[i].copy()
            io::println(f"created {shown}")
        }

        if next.size() > 0 {
            io::println("")
        }

        for var i: usize = 0; i < next.size(); ++i {
            io::println(init_fill(next[i], name, ident))
        }

        return EXIT_OK
    }

    priv fn _init_fail(self, const msg: string) -> i32 {
        self.diag()->report(DiagID::U001E, msg.copy()).emit()
        self.flush_errors()
        return EXIT_FAILURE
    }
}
