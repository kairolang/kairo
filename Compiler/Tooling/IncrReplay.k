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
///     prefer <file>                     with --incr-replay-two-tier: the
///                                       queue is re-checked towards this
///                                       file first, to the step's end
///     drain <n>                         with --incr-replay-two-tier: n of
///                                       the queued files are re-checked
///                                       before the step's next edit
///     aside <edit>                      with --incr-replay-two-tier and
///                                       --incr-replay-overlay: the edit
///                                       (a replace, write or append of an
///                                       existing .k file) is tried and
///                                       thrown away: re-checked in a copy
///                                       of the process (LiveCheck::aside,
///                                       with LiveCheck::past_syntax),
///                                       which prints `incr-replay:   aside
///                                       <file>: <mode> (<why>), <ms> ms`
///                                       and on stderr `== incr-replay
///                                       aside <n> <file>` with the file's
///                                       diagnostics; the session goes on
///                                       from the text before it
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
///   With --time-passes the timing report so far follows each step and
///   each first tier on stderr, after `== incr-replay times <tag>`.
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
ffi "c++" import "Native/KShims.hh"

import API::FS::*
import Sema::SemaContext::SemaContext
import Support::FileIO::Path::Path
import Support::TimeReport::{
    time_enabled,
    time_print,
}
import Tooling::LiveCheck::LiveCheck
import Tooling::SemaObserver::SemaObserver
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
    var out       = ""
    var i:  usize = 0
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

/// --incr-replay-observe: the observer a tool installs
/// (LiveCheck::observer), printing the files each step calls it for, in
/// call order: `incr-replay:   checked <file>` and `lowered <file>`.
class ReplayObserver derives SemaObserver {
    pub fn ReplayObserver(self) = default

    priv fn say_(self, const what: string, sc: unsafe *SemaContext) {
        if sc == &null || sc->ctx == &null {
            return
        }

        var name = Path(sc->ctx->sm->get_filename(sc->ctx->fid)).filename()
        io::println(f"incr-replay:   {what} {name}")
    }

    /* OVERRIDE */
    pub fn on_checked(self, sc: unsafe *SemaContext) {
        self.say_("checked", sc)
    }

    /* OVERRIDE */
    pub fn on_lowered(self, sc: unsafe *SemaContext) {
        self.say_("lowered", sc)
    }
}

/// The buffers of an overlay session (--incr-replay-overlay): the text of
/// each file an edit has touched, which the disk does not have.
class ReplayBuffers {
    pub var on:    bool                     = false
    pub var paths: cxx::std::vector<string>
    pub var texts: cxx::std::vector<string>

    pub fn ReplayBuffers(self) = default

    pub fn read(self, const path: string, @inout out: string) -> bool {
        for var i: usize = 0; i < self.paths.size(); ++i {
            if self.paths[i] == path {
                out = self.texts[i]
                return true
            }
        }

        return LinkFS::read(path, &out)
    }

    /// The edit's result: to the disk, or with \c on to the buffer (the
    /// caller hands it to the live check).
    pub fn write(self, const path: string, const text: string) -> bool {
        // A header is read by clang, which has no buffer of ours.
        if (!self.on) || (!path.ends_with(".k")) || !LinkFS::exists(path) {
            return LinkFS::write(path, text)
        }

        for var i: usize = 0; i < self.paths.size(); ++i {
            if self.paths[i] == path {
                self.texts[i] = text
                return true
            }
        }

        self.paths.push_back(path)
        self.texts.push_back(text)
        return true
    }
}

/// One edit command; "" when applied, else why not. \p touched gets the file.
fn replay_apply(const line: string,
                touched:    *cxx::std::vector<string>,
                bufs:       *ReplayBuffers) -> string {
    if line.starts_with("replace ") {
        var f = replay_fields(line.subslice(8, line.size() - 8))
        if f.size() != 3 {
            return "replace wants <file>:::<old>:::<new>"
        }

        var text = ""
        if !bufs->read(f[0], &text) {
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

        if !bufs->write(f[0], next) {
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

        if !bufs->write(f[0], replay_unescape(f[1])) {
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
        if !bufs->read(f[0], &text) {
            return "cannot read " + f[0]
        }

        if !bufs->write(f[0], text + replay_unescape(f[1])) {
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

/// --incr-replay-two-tier: the first tier of an edit of \p file, at once.
/// On stdout what it did; on stderr `== incr-replay fg <n> <file>` and the
/// diagnostics \p file owns now, which Scripts/incr_replay_check.py
/// compares with that file's part of the step's fresh run.
fn replay_fg(live:       *LiveCheck,
             bufs:       *ReplayBuffers,
             const file: string,
             n:          usize,
             const what: string) {
    var full = Path(file).full_path()
    if bufs->on {
        for var bi: usize = 0; bi < bufs->paths.size(); ++bi {
            if bufs->paths[bi] == file {
                live->set_overlay(full, bufs->texts[bi])
            }
        }
    }

    var t0 = replay_now_ms()
    live->replace_file(full)
    var ms = replay_now_ms() - t0
    replay_times(f"{what} {n}")
    io::println(
        f"incr-replay:   {what} {file}: {live->mode} ({live->why}), {ms} ms",
    )

    if !live->detail.empty() {
        io::println(f"incr-replay:   detail: {live->detail}")
    }

    cxx::std::fflush(kairo::std_out())
    io::eprintln(f"== incr-replay {what} {n} {file}")
    var unsafe *fd = live->file_diags()
    if fd != &null && live->ci() != &null {
        for var i: usize = 0; i < fd->diags.size(); ++i {
            // Its own, and what was reported for it before Sema (the
            // preprocessor's, the parser's: no file owns those).
            var owner: string = fd->owners[i]
            var early = owner.empty()
                && fd->diags[i]->has_loc
                && live->ci()->sm()->get_filename(fd->diags[i]->loc) == full
            if owner == full || early {
                io::eprint(f"{live->ci()->incr_render(fd->diags[i])}")
            }
        }
    }

    cxx::std::fflush(kairo::std_err())
}

/// `aside <edit>`: the edit and its first tier in a copy of this process,
/// which ends; this one is as it was. "" when the copy ran, else why not.
fn replay_aside(live: *LiveCheck, bufs: *ReplayBuffers, const edit: string, n: usize) -> string {
    if (!live->two_tier) || !bufs->on {
        return "aside needs --incr-replay-two-tier and --incr-replay-overlay"
    }

    var pid = kairo::aside_fork()
    if pid < 0 {
        return "aside: this platform has no copy of a process"
    }

    if pid == 0 {
        var touched = cxx::std::vector<string>()
        var why     = replay_apply(edit, &touched, bufs)
        if !why.empty() {
            io::eprintln(f"error [U001E]: --incr-replay aside: {why}")
            kairo::aside_exit(3)
        }

        // Nothing of this copy is the session's: no dump of the step's,
        // and none left over from an earlier step's path.
        live->dump_interface = ""
        if live->ci() != &null {
            live->ci()->invocation()->frontend.dump_interface = ""
        }

        live->past_syntax = true
        live->aside       = true
        replay_fg(live, bufs, touched.back(), n, "aside")
        kairo::aside_exit(0)
    }

    var rc = kairo::aside_wait(pid, 600000)
    if rc != 0 {
        return f"aside: the copy ended with {rc}"
    }

    return ""
}

/// --time-passes: the regions so far, on stderr after `== incr-replay
/// times <tag>`, after each step and each first tier. The report is
/// cumulative; one step's (one tier's) cost per stage is the difference
/// from the report before it (where an edit's time goes).
fn replay_times(const tag: string) {
    if !time_enabled() {
        return
    }

    cxx::std::fflush(kairo::std_out())
    io::eprintln(f"== incr-replay times {tag}")
    time_print()
    cxx::std::fflush(kairo::std_err())
}

fn replay_report(live: *LiveCheck, n: usize, const name: string, t0: u64) {
    var ms = replay_now_ms() - t0
    replay_times(f"step {n}")
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
    var words      = cxx::std::vector<string>()
    var in_place   = false
    var strict_cxx = false
    var bufs       = ReplayBuffers()
    var observe    = false
    var two        = false
    for var i: i32 = 1; i < argc; ++i {
        var w = string(
            unsafe ((argv[i] as unsafe *const u8) as *const u8),
            cxx::std::strlen(argv[i]),
        )

        if w == "--incr-replay-in-place" {
            in_place = true
        }

        // Edits of existing files reach the live check as overlays and the
        // disk keeps the old text: what a tool with unsaved buffers does.
        if w == "--incr-replay-overlay" {
            bufs.on = true
        }

        // The edited file first, the files that import it afterwards
        // (LiveCheck::two_tier): each edit command is re-checked as it is
        // read, `drain <n>` re-checks n queued files, and the step's
        // result is printed once the queue is empty.
        if w == "--incr-replay-two-tier" {
            two = true
        }

        if w == "--incr-replay-observe" {
            observe = true
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
        io::eprintln(
            f"error [U023E]: cannot read the --incr-replay script '{script}'",
        )

        return 1
    }

    if (!dump.empty()) && !LinkFS::make_dirs(dump) {
        io::eprintln(f"error [U023E]: cannot create '{dump}'")
        return 1
    }

    var        live   = LiveCheck(words)
    var unsafe *watch = kairo::std::create<ReplayObserver>()
    finally {
        kairo::std::destroy(watch)
    }

    if observe {
        live.observer = unsafe (watch as unsafe *void)
    }

    live.in_place   = in_place
    live.two_tier   = two && in_place
    two             = live.two_tier
    live.strict_cxx = strict_cxx
    var n: usize = 0
    var t0       = replay_now_ms()
    if !dump.empty() {
        live.dump_interface = f"{dump}/step{n}.interface.json"
    }

    live.check()
    replay_report(&live, n, "initial", t0)

    // The script's lines, a step at a time: its edits, then one
    // replace_file per file they touched.
    var name          = ""
    var open_         = false
    var touched       = cxx::std::vector<string>()
    var at:     usize = 0
    var pref          = cxx::std::vector<string>() ///< `prefer` lines of the open step
    var asides: usize = 0                          ///< `aside` lines of the open step
    while at <= text.size() {
        var e = at
        while e < text.size() && text[e] != ('\n' as u8) {
            e += 1
        }

        var line = text.subslice(at, e - at)
        var last = e >= text.size()
        at = e + 1
        if line.starts_with("aside ") {
            if !open_ {
                io::eprintln(
                    f"error [U001E]: --incr-replay: an edit before the first `step`: {line}",
                )

                return 1
            }

            var no = replay_aside(
                &live,
                &bufs,
                line.subslice(6, line.size() - 6),
                n + 1,
            )

            if !no.empty() {
                io::eprintln(
                    f"error [U001E]: --incr-replay step '{name}': {no}",
                )

                return 1
            }

            asides += 1
            line = ""
        }

        var is_step = line.starts_with("step ")
        if (is_step || last) && open_ {
            if last
                && (!line.empty())
                && (!is_step)
                && line[0] != ('#' as u8)
                && (!line.starts_with("drain "))
                && !line.starts_with("prefer ") {
                var why = replay_apply(line, &touched, &bufs)
                if !why.empty() {
                    io::eprintln(
                        f"error [U001E]: --incr-replay step '{name}': {why}",
                    )

                    return 1
                }

                if two {
                    replay_fg(&live, &bufs, touched.back(), n + 1, "fg")
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
            if two {
                // Each edit had its first tier when it was read; what is
                // still queued is re-checked now.
                // A step of asides alone changed nothing that is kept.
                if touched.empty() && asides == 0 {
                    live.replace_file(first)
                }

                while live.drain(1000000, pref) {
                    0
                }

                pref.clear()
            } else if bufs.on {
                // Every buffer the step changed, then one step per file:
                // a refresh re-reads only the files of its set.
                for var ti: usize = 0; ti < touched.size(); ++ti {
                    for var bi: usize = 0; bi < bufs.paths.size(); ++bi {
                        if bufs.paths[bi] == touched[ti] {
                            live.set_overlay(
                                Path(touched[ti]).full_path(),
                                bufs.texts[bi],
                            )
                        }
                    }
                }

                for var ti: usize = 0; ti < touched.size(); ++ti {
                    live.replace_file(Path(touched[ti]).full_path())
                }

                if touched.empty() {
                    live.replace_file(first)
                }
            } else {
                live.replace_file(first)
            }

            replay_report(&live, n, name, t0)
            touched.clear()
            asides = 0
            open_  = false
        }

        if is_step {
            name  = line.subslice(5, line.size() - 5)
            open_ = true
            // In two tiers an edit is re-checked as it is read, and one
            // that takes a full check writes the step's dump then.
            if two && !dump.empty() {
                live.dump_interface = f"{dump}/step{n + 1}.interface.json"
            }

            continue
        }

        if last || line.empty() || line[0] == ('#' as u8) {
            continue
        }

        if !open_ {
            io::eprintln(
                f"error [U001E]: --incr-replay: an edit before the first `step`: {line}",
            )

            return 1
        }

        // `prefer <file>`: from here to the step's end the queue is
        // re-checked towards that file first (LiveCheck::drain's prefer: a
        // tool's open buffers), then in Sema's order.
        if line.starts_with("prefer ") {
            pref.push_back(Path(line.subslice(7, line.size() - 7)).full_path())
            continue
        }

        // `drain <n>`: n queued files are re-checked before the step's next
        // edit (which then pre-empts the rest). Nothing, without two tiers.
        if line.starts_with("drain ") {
            if two {
                var k: usize = 0
                for var c: usize = 6; c < line.size(); ++c {
                    if line[c] >= (48 as u8) && line[c] <= (57 as u8) {
                        k = k * 10 + ((line[c] - (48 as u8)) as usize)
                    }
                }

                live.drain(k, pref)
                io::println(
                    f"incr-replay:   drain {k}: {live.mode} ({live.why})",
                )

                cxx::std::fflush(kairo::std_out())
            }

            continue
        }

        var why = replay_apply(line, &touched, &bufs)
        if !why.empty() {
            io::eprintln(f"error [U001E]: --incr-replay step '{name}': {why}")
            return 1
        }

        if two {
            replay_fg(&live, &bufs, touched.back(), n + 1, "fg")
        }
    }

    return 0
}
