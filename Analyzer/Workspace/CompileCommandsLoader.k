/// --- The Kairo Project --- Analyzer/Workspace/CompileCommandsLoader.k --- ///
///
///   Loads kairo_compile.json: the project's entry points and their flags.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   A Kairo compile command names an ENTRY POINT, not a file: the compiler
///   reaches every other file through imports. So the project file lists
///   entries, and a file belongs to whichever entry's import graph holds it.
///
///     {
///       "version": 1,
///       "entries": [
///         { "entry": "src/main.k",
///           "args": ["-I", "include/", "-fimplicit-conv"],
///           "directory": "." }
///       ],
///       "default_args": ["-I", "include/"]
///     }
///
///   entry         the file `kairo` is given, relative to `directory`
///   args          every other argument, exactly as on the command line
///   directory     where the command runs; relative to the project file's
///                 own directory, and "." when omitted
///   default_args  for a file no entry reaches (a scratch file, a new module
///                 not imported yet): it is checked as its own entry with
///                 these
///
///   INTERIM: build.k will write this once the self-hosted build tool lands;
///   until then it is written by hand. The shape is the contract either way.


import API::FS::LinkFS
import Json::{
    JSON_NONE,
    JsonDoc,
}
import Support::FileIO::Path::Path

pub fn project_file_name() -> string {
    return "kairo_compile.json"
}

/// One entry point and the command that compiles it.
pub class ProjectEntry {
    pub var entry: string   = "" ///< absolute path
    pub var dir:   string   = "" ///< absolute working directory
    pub var args:  [string]      ///< without the entry itself

    fn ProjectEntry(self) = default
}

pub class Project {
    pub var path:         string         = "" ///< the project file, or "" when there is none
    pub var dir:          string         = "" ///< its directory: the root files are indexed under
    pub var entries:      [ProjectEntry]
    pub var default_args: [string]
    pub var error:        string         = "" ///< why the file could not be used, for the editor

    fn Project(self) = default

    /// Looks for the project file in \p start and each directory above it.
    /// With none found, the project is \p start itself with no entries: every
    /// file is then its own entry with no flags, which is what a single
    /// script wants.
    fn load(self, const start: string) {
        self.path  = ""
        self.dir   = start
        self.error = ""
        self.entries.clear()
        self.default_args.clear()

        var dir = start
        for var depth: usize = 0; depth < 64; ++depth {
            var cand = Path::join_str(dir, project_file_name())
            if Path::exists_at(cand) {
                self.path = cand
                self.dir  = dir
                break
            }

            var up = Path::parent_of(dir)
            if up.empty() || (up == dir) {
                break
            }

            dir = up
        }

        if self.path.empty() {
            return
        }

        var text: string = ""
        if !LinkFS::read(self.path, &text) {
            self.error = "cannot read " + self.path
            return
        }

        var doc = JsonDoc()
        if !doc.parse(text) {
            self.error = self.path + ": " + doc.error
            return
        }

        var d = doc.get(doc.root, "default_args")
        var a = doc.first(d)
        while a != JSON_NONE() {
            self.default_args.push_back(doc.str(a))
            a = doc.next(a)
        }

        var e = doc.first(doc.get(doc.root, "entries"))
        while e != JSON_NONE() {
            var pe      = ProjectEntry()
            var rel_dir = doc.get_str(e, "directory")
            pe.dir = self.dir
            if !rel_dir.empty() {
                pe.dir = Path::absolute_if_exists(rel_dir, self.dir)
            }

            var entry = doc.get_str(e, "entry")
            if entry.empty() {
                self.error = self.path + ": an entry has no \"entry\" file"
                e          = doc.next(e)
                continue
            }

            pe.entry = Path::absolute_if_exists(entry, pe.dir)
            var arg = doc.first(doc.get(e, "args"))
            while arg != JSON_NONE() {
                pe.args.push_back(doc.str(arg))
                arg = doc.next(arg)
            }

            self.entries.push_back(pe)
            e = doc.next(e)
        }
    }
}
