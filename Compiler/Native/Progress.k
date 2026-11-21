/// --- The Kairo Project --------------------------- Native/Progress.k --- ///
///
///   ninja-style build progress: per-phase atomic counters, and either one
///   pinned status line on a terminal or `@progress` event lines for a
///   program that reads the stream (build.py). Kairo-side API:
///   Driver/Progress.k. The format is documented in Spec/Driver.md.
///
///   The Codegen worker loop and the Diagnostic consumers both report here,
///   and neither may import Driver/: a Native module both can import keeps
///   the layering.
///
///   OUTPUT RULE. The pinned line is only ever on screen between a redraw and
///   the next erase, and every byte the compiler prints to stderr while it may
///   be on screen goes between hold() and release(): hold() erases it and
///   stops redraws, so diagnostic text never shares a line with it.
///   `lines` mode never leaves anything to erase; each event is one fwrite.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Prelude.hh" // stderr_guard, stderr_is_tty
ffi "c++" import "Native/Shims.hh" // std_err, stderr_term_cols
ffi "c++" import "Native/Types.hh" // Atomic, Mutex, Thread, create
ffi "c++" import "Native/Win32.hh" // enable_vt_stderr
ffi "c++" import "chrono"
ffi "c++" import "condition_variable"
ffi "c++" import "cstdio"
ffi "c++" import "cstdlib"
ffi "c++" import "cstring"
ffi "c++" import "filesystem"
ffi "c++" import "mutex"
ffi "c++" import "string"

import std::c_char

/// The phases' slots. PhaseCount bounds the per-phase arrays.
eval PHASE_COUNT: usize = 7

pub class ProgressMeter {
    /// The phases. Codegen counts whole TUs; IRGen, Opt and Emit are its
    /// stages, counted once per TU as clang finishes it (stage()) and timed
    /// in the CPU time the TUs spent there; Link is the one link, timed on
    /// the wall clock. The pinned line shows the stages in place of Codegen.
    pub eval Parse:      i32 = 0
    pub eval Sema:       i32 = 1
    pub eval Codegen:    i32 = 2
    pub eval IRGen:      i32 = 3
    pub eval Opt:        i32 = 4
    pub eval Emit:       i32 = 5
    pub eval Link:       i32 = 6
    pub eval PhaseCount: i32 = 7

    /// Resolves `flag` (auto|always|never|lines; "" is auto). False for any
    /// other spelling, with the meter left off. `quiet_auto` is ignored (kept
    /// for the caller's signature); `auto` means progress is on whenever
    /// stderr is a terminal, --verbose included.
    pub static fn configure(flag: unsafe *const c_char, quiet_auto: bool) -> bool {
        var unsafe *s = Self::st()
        s->start = cxx::std::chrono::steady_clock::now()
        s->mode  = Self::Off
        // Writers that cannot import this module (the Logger's live echo)
        // reach hold() / release() through the guard. Both are no-ops unless
        // the line is pinned.
        kairo::native::stderr_guard().hold.store(
            ProgressMeter::hold,
            kairo::std::MemoryOrder::release,
        )

        kairo::native::stderr_guard().release.store(
            ProgressMeter::release,
            kairo::std::MemoryOrder::release,
        )

        var f = if flag != &null => cxx::std::string(flag) else => cxx::std::string()
        if f.empty() || f == cxx::std::string("auto") {
            const term = cxx::std::getenv("TERM")
            if !kairo::native::stderr_is_tty()
                || (term != &null && cxx::std::strcmp(term, "dumb") == 0) {
                return true
            }

            if Self::vt_ok(unsafe &s->cols) {
                s->mode = Self::Pinned
            }

            return true
        }

        if f == cxx::std::string("never") {
            return true
        }

        if f == cxx::std::string("always") {
            if Self::vt_ok(unsafe &s->cols) {
                s->mode = Self::Pinned
            }

            return true
        }

        if f == cxx::std::string("lines") {
            s->mode = Self::Lines
            return true
        }

        return false
    }

    /// A phase of `total` units starts. Counters reset: a driver running
    /// several inputs begins each phase once per input.
    pub static fn begin(p: i32, total: usize) {
        var unsafe *s = Self::st()
        if s->mode == Self::Off {
            return
        }

        var g = kairo::std::LockGuard<kairo::std::Mutex>(&s->mu)
        s->done[p].store(0)
        s->reused[p].store(0)
        s->cpu_ns[p].store(0)
        s->t0[p] = cxx::std::chrono::steady_clock::now()
        s->total[p].store(total)
        s->active[p] = true
        s->file.clear()
        if s->mode == Self::Lines {
            Self::emit_line(s, p, 0, &null)
        } else if s->thread_ == &null {
            s->stop = false
            s->thread_ = kairo::std::create<kairo::std::Thread>(
                fn ()|s| {
                    ProgressMeter::render_loop(s)
                },
            )
        }
    }

    /// `n` units of phase `p` finished; `file` is the one that did (may be
    /// null). Called from any thread.
    pub static fn tick(p: i32, file: unsafe *const c_char, n: usize = 1) {
        var unsafe *s = Self::st()
        if s->mode == Self::Off {
            return
        }

        var   g        = kairo::std::LockGuard<kairo::std::Mutex>(&s->mu)
        const d: usize = s->done[p].fetch_add(n) + n
        if file != &null {
            s->file = Self::display(s, file)
        }

        if s->mode == Self::Lines {
            Self::emit_line(
                s,
                p,
                d,
                if file != &null => s->file.c_str() else => &null,
            )
        }
    }

    /// A TU finished stage `p` (IRGen, Opt or Emit) after `ns` of CPU time.
    /// A TU clang runs twice (a retry) counts once. Called from any thread.
    pub static fn stage(p: i32, ns: u64) {
        var unsafe *s = Self::st()
        if s->mode == Self::Off {
            return
        }

        var g = kairo::std::LockGuard<kairo::std::Mutex>(&s->mu)
        s->cpu_ns[p].fetch_add(ns)
        var d: usize = s->done[p].load()
        if d < s->total[p].load() {
            ++d
            s->done[p].store(d)
        }

        if s->mode == Self::Lines {
            Self::emit_line(s, p, d, &null)
        }
    }

    /// Whether the stage phases are being fed (the caller arms its timer).
    pub static fn wants_stages() -> bool {
        return Self::st()->mode != Self::Off
    }

    /// `n` units of phase `p` were not done at all: the incremental cache
    /// already held their object. They count as done.
    pub static fn reuse(p: i32, n: usize) {
        var unsafe *s = Self::st()
        if s->mode == Self::Off || n == 0 {
            return
        }

        var g = kairo::std::LockGuard<kairo::std::Mutex>(&s->mu)
        s->reused[p].fetch_add(n)
        const d: usize = s->done[p].fetch_add(n) + n
        if s->mode == Self::Lines {
            Self::emit_line(s, p, d, &null)
        }
    }

    /// Phase `p` is over; its row leaves the pinned line. Link ends with its
    /// one unit done.
    pub static fn end(p: i32) {
        var unsafe *s = Self::st()
        if s->mode == Self::Off {
            return
        }

        var g = kairo::std::LockGuard<kairo::std::Mutex>(&s->mu)
        if p == Self::Link && s->active[p] {
            s->done[p].store(s->total[p].load())
            if s->mode == Self::Lines {
                Self::emit_line(s, p, s->done[p].load(), &null)
            }
        }

        s->active[p] = false
    }

    /// Erase the pinned line and keep it off until release(). Every write to
    /// stderr that can happen while a phase runs sits between the two. Nests.
    pub static fn hold() {
        var unsafe *s = Self::st()
        if s->mode != Self::Pinned {
            return
        }

        var g = kairo::std::LockGuard<kairo::std::Mutex>(&s->mu)
        ++s->held
        Self::erase_locked(s)
    }

    pub static fn release() {
        var unsafe *s = Self::st()
        if s->mode != Self::Pinned {
            return
        }

        var g = kairo::std::LockGuard<kairo::std::Mutex>(&s->mu)
        if s->held > 0 {
            --s->held
        }
    }

    /// The run is over (or is about to abort): erase the line, stop the thread.
    pub static fn finish() {
        var unsafe *s = Self::st()
        if s->mode != Self::Pinned {
            return
        }

        var t: unsafe *kairo::std::Thread = &null
        {
            var g = kairo::std::LockGuard<kairo::std::Mutex>(&s->mu)
            s->stop = true
            for var i: usize = 0; i < PHASE_COUNT; ++i {
                s->active[i] = false
            }

            Self::erase_locked(s)
            t          = s->thread_
            s->thread_ = &null
        }

        s->cv.notify_all()
        if t != &null {
            t->join()
            kairo::std::destroy(t)
        }
    }

    /// Whether the meter writes anything (0 off, 1 pinned, 2 lines).
    pub static fn mode() -> i32 {
        return Self::st()->mode
    }

    eval Off:    i32 = 0
    eval Pinned: i32 = 1
    eval Lines:  i32 = 2

    eval REDRAW_MS:       i32   = 100 ///< the pinned line's redraw period
    eval DEFAULT_COLS:    i32   = 80  ///< when the terminal does not say
    eval PATH_COMPONENTS: usize = 3   ///< of the current file, from its end

    class State {
        pub var mode: i32 = ProgressMeter::Off
        pub var cols: i32 = ProgressMeter::DEFAULT_COLS
        pub var start:  cxx::std::chrono::steady_clock::time_point
        pub var mu:     kairo::std::Mutex
        pub var cv:     cxx::std::condition_variable
        pub var done:   [kairo::std::Atomic<usize>; 7]
        pub var total:  [kairo::std::Atomic<usize>; 7]
        pub var reused: [kairo::std::Atomic<usize>; 7]
        pub var cpu_ns: [kairo::std::Atomic<u64>; 7]
        pub var t0:     [cxx::std::chrono::steady_clock::time_point; 7]
        pub var active: [bool; 7] = [false, false, false, false, false, false, false]
        pub var file:    cxx::std::string
        pub var cwd:     cxx::std::string
        pub var thread_: unsafe *kairo::std::Thread = &null
        pub var stop:    bool                       = false
        pub var drawn:   bool                       = false
        pub var held:    i32                        = 0
    }

    // Leaked on purpose: a joinable thread member destroyed at exit would
    // terminate the process.
    static fn st() -> unsafe *Self::State {
        static s: unsafe *ProgressMeter::State = kairo::std::create<ProgressMeter::State>()
        return s
    }

    static fn name(p: i32) -> cxx::std::string {
        if p == Self::Parse {
            return cxx::std::string("parse")
        } else if p == Self::Sema {
            return cxx::std::string("sema")
        } else if p == Self::IRGen {
            return cxx::std::string("irgen")
        } else if p == Self::Opt {
            return cxx::std::string("opt")
        } else if p == Self::Emit {
            return cxx::std::string("emit")
        } else if p == Self::Link {
            return cxx::std::string("link")
        }

        return cxx::std::string("codegen")
    }

    /// Whether stderr takes ANSI sequences, and how wide it is.
    static fn vt_ok(cols: unsafe *i32) -> bool {
        eval if defined!(_WIN32) {
            return kairo::win32::enable_vt_stderr(cols)
        } else {
            kairo::stderr_term_cols(cols)
            return true
        }
    }

    /// The path relative to the working directory when it is under it, so a
    /// reader sees `Sema/Type/CallTyping.k` and not a checkout's prefix.
    static fn display(s: unsafe *Self::State, path: unsafe *const c_char) -> cxx::std::string {
        if s->cwd.empty() {
            var ec = cxx::std::error_code()
            s->cwd = cxx::std::filesystem::current_path(&ec).generic_string()
            if s->cwd.empty() || s->cwd.back() != (('/' as u8) as c_char) {
                s->cwd += "/"
            }
        }

        var p = cxx::std::string(path)
        for var i: usize = 0; i < p.size(); ++i {
            if p[i] == (('\\' as u8) as c_char) {
                p[i] = ('/' as u8) as c_char
            }
        }

        if p.compare(0, s->cwd.size(), s->cwd) == 0 {
            p.erase(0, s->cwd.size())
        }

        return p
    }

    /// One `@progress` event: fixed key order, `file=` last and unquoted (it
    /// runs to the end of the line). The prefix cannot begin a diagnostic.
    /// Caller holds mu, so lines come out in `done` order.
    static fn emit_line(s: unsafe *Self::State, p: i32, d: usize, file: unsafe *const c_char) {
        var l = cxx::std::string("@progress phase=")
        l += Self::name(p)
        l += " done="
        l += cxx::std::to_string(d)
        l += " total="
        l += cxx::std::to_string(s->total[p].load())
        if p == Self::Codegen {
            l += " reused="
            l += cxx::std::to_string(s->reused[p].load())
        }

        if p >= Self::IRGen {
            l += " ms="
            l += cxx::std::to_string(Self::phase_ns(s, p) / 1000000)
        }

        if file != &null && *file != (0 as c_char) {
            l += " file="
            l += file
        }

        l += "\n"
        cxx::std::fwrite(l.data(), 1, l.size(), kairo::std_err())
        cxx::std::fflush(kairo::std_err())
    }

    /// The time shown for phase `p`: CPU time for a stage, wall time since
    /// the phase began for Link.
    static fn phase_ns(s: unsafe *Self::State, p: i32) -> u64 {
        if p == Self::Link {
            return cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(
                cxx::std::chrono::steady_clock::now() - s->t0[p],
            ).count() as u64
        }

        return s->cpu_ns[p].load()
    }

    static fn tail(const f: cxx::std::string, comps: usize) -> cxx::std::string {
        var pos: usize = f.size()
        for var i: usize = 0; i < comps && pos != cxx::std::string::npos; ++i {
            pos = if pos == 0 => cxx::std::string::npos
                  else => f.rfind(('/' as u8) as c_char, pos - 1)
        }

        return if pos == cxx::std::string::npos => f else => f.substr(pos + 1)
    }

    static fn compose(s: unsafe *Self::State) -> cxx::std::string {
        var out   = cxx::std::string()
        var first = true
        for var p: i32 = 0; p < Self::PhaseCount; ++p {
            if !s->active[p] {
                continue
            }

            // The stages stand for Codegen while they run.
            if p == Self::Codegen && s->active[Self::IRGen] {
                continue
            }

            if first {
                out += "["
            } else {
                out += "  ["
            }

            out += Self::name(p)
            out += " "
            out += cxx::std::to_string(s->done[p].load())
            out += "/"
            out += cxx::std::to_string(s->total[p].load())
            const r: usize = s->reused[p].load()
            if r != 0 {
                out += ", "
                out += cxx::std::to_string(r)
                out += " reused"
            }

            if p >= Self::IRGen {
                const t: u64          = Self::phase_ns(s, p) / 1000000000
                var   b: [c_char; 32]
                cxx::std::snprintf(
                    unsafe &b[0],
                    32,
                    ", %llu:%02llu",
                    (t / 60) as u64,
                    (t % 60) as u64,
                )

                out += unsafe (&b[0] as unsafe *const c_char)
            }

            out += "]"
            if first && !s->file.empty() {
                out += " "
                out += Self::tail(s->file, Self::PATH_COMPONENTS)
            }

            first = false
        }

        if first {
            return out
        }

        const secs: i64 = cxx::std::chrono::duration_cast<cxx::std::chrono::seconds>(
            cxx::std::chrono::steady_clock::now() - s->start,
        ).count() as i64
        var tm: [c_char; 32]
        cxx::std::snprintf(
            unsafe &tm[0],
            32,
            "  %lld:%02lld",
            secs / 60,
            secs % 60,
        )

        out += unsafe (&tm[0] as unsafe *const c_char)
        // Never wrap: a wrapped row cannot be erased by \r\x1b[2K. The cut
        // falls on a code point boundary, since half a UTF-8 sequence is not
        // text a terminal can show.
        var w: usize = ((if s->cols > 1 => s->cols else => Self::DEFAULT_COLS) - 1) as usize
        if out.size() > w {
            while w > 0 && ((out[w] as u8) & 0xC0) == 0x80 {
                --w
            }

            out.resize(w)
        }

        return out
    }

    static fn erase_locked(s: unsafe *Self::State) {
        if !s->drawn {
            return
        }

        cxx::std::fputs("\r\x1b[2K", kairo::std_err())
        cxx::std::fflush(kairo::std_err())
        s->drawn = false
    }

    /// Redraws every REDRAW_MS. The only thread that draws, so the line is
    /// written from one place.
    static fn render_loop(s: unsafe *Self::State) {
        var lk = kairo::std::UniqueLock<kairo::std::Mutex>(&s->mu)
        while !s->stop {
            if s->held == 0 {
                // The terminal can be resized while a phase runs.
                var cols: i32 = s->cols
                if Self::vt_ok(unsafe &cols) && cols > 0 {
                    s->cols = cols
                }

                var line = Self::compose(s)
                if line.empty() {
                    Self::erase_locked(s)
                } else {
                    var o = cxx::std::string("\r\x1b[2K")
                    o += line
                    cxx::std::fwrite(o.data(), 1, o.size(), kairo::std_err())
                    cxx::std::fflush(kairo::std_err())
                    s->drawn = true
                }
            }

            s->cv.wait_for(&lk, cxx::std::chrono::milliseconds(Self::REDRAW_MS))
        }
    }
}
