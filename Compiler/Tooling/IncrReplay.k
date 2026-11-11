/// --- The Kairo Project ------------------------- Tooling/IncrReplay.k --- ///
///
///   \brief --incr-replay=<script>: the driver's test mode for a live check
///          (Tooling/LiveCheck.k). The entry is type-checked once; then each
///          step of the script edits files on disk and the SAME process
///          brings the result up to date, printing the step's diagnostics.
///
///   The script, one command per line (`#` starts a comment):
///
///     step <name>                       a new step; the edits below are its
///     replace <file>:::<old>:::<new>    <old> occurs exactly once in <file>
///     write <file>:::<text>             create or overwrite
///     append <file>:::<text>            add at the end
///     remove <file>
///
///   `\n` in <old>, <new> and <text> is a line break. Paths are relative to
///   the working directory. Step 0 is the first check, before any edit.
///
///   Per step, on stdout: `incr-replay: step <n> <name>: <mode> (<why>),
///   <files> files, <errors> errors, <ms> ms`; on stderr a line
///   `== incr-replay step <n> <name>` and then the diagnostics exactly as a
///   run of `kairo --type-check-only` on the files as they then stand prints
///   them. That equality is what Scripts/incr_replay_check.py checks, with
///   --incr-replay-dump's interface dumps, against a fresh process per step.
///   The exit status is 1 only when the script cannot be applied.
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
ffi "c++" import "vector"
ffi "c++" import "chrono"
ffi "c++" import "cstdio"
ffi "c++" import "cstring"

import API::FS::*
import Support::FileIO::Path::Path
import Tooling::LiveCheck::LiveCheck
import std::c_char
import std::io

fn replay_find(const hay: string, const needle: string, from: usize) -> usize {
    var n = hay.size()
    var m = needle.size()
    if m == 0 || m > n {
        return usize::MAX
    }

    for var i: usize = from; i + m <= n; ++i {
        var j: usize = 0
        while j < m && hay[i + j] == needle[j] {
            j += 1
        }

        if j == m {
            return i
        }
    }

    return usize::MAX
}

/// `\n` (two characters) becomes a line break.
fn replay_unescape(const s: string) -> string {
    var out = ""
    var i: usize = 0
    while i < s.size() {
        if s[i] == (92 as u8) && i + 1 < s.size() && s[i + 1] == ('n' as u8) {
            out += "\n"
            i += 2
            continue
        }

        out += s.subslice(i, 1)
        i += 1
    }

    return out
}

/// The fields of `a:::b:::c`.
fn replay_fields(const s: string) -> cxx::std::vector<string> {
    var out          = cxx::std::vector<string>()
    var start: usize = 0
    while true {
        var at = replay_find(s, ":::", start)
        if at == usize::MAX {
            break
        }

        out.push_back(s.subslice(start, at - start))
        start = at + 3
    }

    out.push_back(s.subslice(start, s.size() - start))
    return out
}

fn replay_now_ms() -> u64 {
    return (cxx::std::chrono::duration_cast<cxx::std::chrono::milliseconds>(
        cxx::std::chrono::steady_clock::now().time_since_epoch(),
    ).count() as u64)
}

/// One edit command; "" when applied, else why not. \p touched gets the file.
fn replay_apply(const line: string, touched: *cxx::std::vector<string>) -> string {
    if line.starts_with("replace ") {
        var f = replay_fields(line.subslice(8, line.size() - 8))
        if f.size() != 3 {
            return "replace wants <file>:::<old>:::<new>"
        }

        var text = ""
        if !LinkFS::read(f[0], &text) {
            return "cannot read " + f[0]
        }

        var old_ = replay_unescape(f[1])
        var at   = replay_find(text, old_, 0)
        if at == usize::MAX {
            return "the old text is not in " + f[0]
        }

        if replay_find(text, old_, at + 1) != usize::MAX {
            return "the old text occurs more than once in " + f[0]
        }

        var next = text.subslice(0, at) + replay_unescape(f[2]) + text.subslice(
            at + old_.size(),
            text.size() - at - old_.size(),
        )

        if !LinkFS::write(f[0], next) {
            return "cannot write " + f[0]
        }

        touched->push_back(f[0])
        return ""
    }

    if line.starts_with("write ") {
        var f = replay_fields(line.subslice(6, line.size() - 6))
        if f.size() != 2 {
            return "write wants <file>:::<text>"
        }

        if !LinkFS::write(f[0], replay_unescape(f[1])) {
            return "cannot write " + f[0]
        }

        touched->push_back(f[0])
        return ""
    }

    if line.starts_with("append ") {
        var f = replay_fields(line.subslice(7, line.size() - 7))
        if f.size() != 2 {
            return "append wants <file>:::<text>"
        }

        var text = ""
        if !LinkFS::read(f[0], &text) {
            return "cannot read " + f[0]
        }

        if !LinkFS::write(f[0], text + replay_unescape(f[1])) {
            return "cannot write " + f[0]
        }

        touched->push_back(f[0])
        return ""
    }

    if line.starts_with("remove ") {
        var p = line.subslice(7, line.size() - 7)
        LinkFS::remove(p)
        touched->push_back(p)
        return ""
    }

    return "unknown command: " + line
}

fn replay_report(live: *LiveCheck, n: usize, const name: string, t0: u64) {
    var ms = replay_now_ms() - t0
    io::println(
        f"incr-replay: step {n} {name}: {live->mode} ({live->why}), {live->files} files, {live->errors} errors, {ms} ms",
    )

    if !live->detail.empty() {
        io::println(f"incr-replay:   detail: {live->detail}")
    }

    cxx::std::fflush(kairo::std_out())
    io::eprintln(f"== incr-replay step {n} {name}")
    live->flush()
}

/// \param argv  the driver's own command line; the two replay flags are
///              taken out and the rest is the compile command.
pub fn incr_replay_main(argc:         i32,
                        argv:         unsafe *(unsafe *c_char),
                        const script: string,
                        const dump:   string) -> i32 {
    var words    = cxx::std::vector<string>()
    var in_place   = false
    var strict_cxx = false
    for var i: i32 = 1; i < argc; ++i {
        var w = string(unsafe ((argv[i] as unsafe *const u8) as *const u8), cxx::std::strlen(argv[i]))
        if w == "--incr-replay-in-place" {
            in_place = true
        }

        if w == "--incr-replay-strict-cxx" {
            strict_cxx = true
        }

        if w.starts_with("--incr-replay") {
            continue
        }

        words.push_back(w)
    }

    var text = ""
    if !LinkFS::read(script, &text) {
        io::eprintln(f"error [U023E]: cannot read the --incr-replay script '{script}'")
        return 1
    }

    if (!dump.empty()) && !LinkFS::make_dirs(dump) {
        io::eprintln(f"error [U023E]: cannot create '{dump}'")
        return 1
    }

    var live = LiveCheck(words)
    live.in_place   = in_place
    live.strict_cxx = strict_cxx
    var n: usize = 0
    var t0 = replay_now_ms()
    if !dump.empty() {
        live.dump_interface = f"{dump}/step{n}.interface.json"
    }

    live.check()
    replay_report(&live, n, "initial", t0)

    // The script's lines, a step at a time: its edits, then one
    // replace_file per file they touched.
    var name    = ""
    var open_   = false
    var touched = cxx::std::vector<string>()
    var at: usize = 0
    while at <= text.size() {
        var e = at
        while e < text.size() && text[e] != ('\n' as u8) {
            e += 1
        }

        var line = text.subslice(at, e - at)
        var last = e >= text.size()
        at = e + 1
        var is_step = line.starts_with("step ")
        if (is_step || last) && open_ {
            if last && (!line.empty()) && (!is_step) && line[0] != ('#' as u8) {
                var why = replay_apply(line, &touched)
                if !why.empty() {
                    io::eprintln(f"error [U001E]: --incr-replay step '{name}': {why}")
                    return 1
                }
            }

            n += 1
            t0 = replay_now_ms()
            if !dump.empty() {
                live.dump_interface = f"{dump}/step{n}.interface.json"
            }

            // One call brings the result up to date today (every edit is a
            // full check); a step that touched nothing still re-checks.
            var first = if (touched.empty()) => ("") else => Path(touched[0]).full_path()
            live.replace_file(first)
            replay_report(&live, n, name, t0)
            touched.clear()
            open_ = false
        }

        if is_step {
            name  = line.subslice(5, line.size() - 5)
            open_ = true
            continue
        }

        if last || line.empty() || line[0] == ('#' as u8) {
            continue
        }

        if !open_ {
            io::eprintln(f"error [U001E]: --incr-replay: an edit before the first `step`: {line}")
            return 1
        }

        var why = replay_apply(line, &touched)
        if !why.empty() {
            io::eprintln(f"error [U001E]: --incr-replay step '{name}': {why}")
            return 1
        }
    }

    return 0
}
