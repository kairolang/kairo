/// --- The Kairo Project -------------------------- Native/KProgress.hh --- ///
///
///   ninja-style build progress: per-phase atomic counters, and either one
///   pinned status line on a terminal or `@progress` event lines for a
///   program that reads the stream (build.py). Kairo-side API:
///   Driver/Progress.k. The format is documented in Spec/Driver.md.
///
///   WHY C++ AND NOT KAIRO: the Codegen worker loop and the Diagnostic
///   consumers both report here, and neither may import Driver/. A Native
///   header both can include keeps the layering; the thread, the atomics and
///   the terminal ioctls are what Native/ is for (see KTimeReport.hh).
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

#ifndef __KAIRO_NATIVE_KPROGRESS_HH__
#define __KAIRO_NATIVE_KPROGRESS_HH__

#include "KPrelude.hh"
#include "Win32.hh"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <string>
#include <thread>

#if defined(_WIN32)
#include <io.h>
#else
#include <sys/ioctl.h>
#include <unistd.h>
#endif

namespace kairo {

class ProgressMeter {
  public:
    enum Phase : int { Parse = 0, Sema = 1, Codegen = 2, PhaseCount = 3 };

    /// Resolves \p flag (auto|always|never|lines; "" is auto). False for any
    /// other spelling, with the meter left off. \p quiet_auto is ignored (kept
    /// for the caller's signature); `auto` means progress is on whenever
    /// stderr is a terminal, --verbose included.
    static bool configure(const char *flag, bool quiet_auto) {
        (void)quiet_auto;
        State &s = st();
        s.start = ::std::chrono::steady_clock::now();
        s.mode  = Off;
        ::std::string f = flag ? flag : "";
        if (f.empty() || f == "auto") {
            const char *term = ::std::getenv("TERM");
            if (!tty_err() || (term && ::std::strcmp(term, "dumb") == 0)) { return true; }
            if (vt_ok(&s.cols)) { s.mode = Pinned; }
            return true;
        }
        if (f == "never") { return true; }
        if (f == "always") {
            if (vt_ok(&s.cols)) { s.mode = Pinned; }
            return true;
        }
        if (f == "lines") {
            s.mode = Lines;
            return true;
        }
        return false;
    }

    /// A phase of \p total units starts. Counters reset: a driver running
    /// several inputs begins each phase once per input.
    static void begin(int p, size_t total) {
        State &s = st();
        if (s.mode == Off) { return; }
        ::std::lock_guard<::std::mutex> g(s.mu);
        s.done[p].store(0);
        s.reused[p].store(0);
        s.total[p].store(total);
        s.active[p] = true;
        s.file.clear();
        if (s.mode == Lines) {
            emit_line(s, p, 0, nullptr);
        } else if (!s.thread) {
            s.stop   = false;
            s.thread = new ::std::thread([&s] { render_loop(s); });
        }
    }

    /// \p n units of phase \p p finished; \p file is the one that did (may be
    /// null). Called from any thread.
    static void tick(int p, const char *file, size_t n = 1) {
        State &s = st();
        if (s.mode == Off) { return; }
        ::std::lock_guard<::std::mutex> g(s.mu);
        size_t d = (s.done[p] += n);
        if (file) { s.file = display(s, file); }
        if (s.mode == Lines) { emit_line(s, p, d, file ? s.file.c_str() : nullptr); }
    }

    /// \p n units of phase \p p were not done at all: the incremental cache
    /// already held their object. They count as done.
    static void reuse(int p, size_t n) {
        State &s = st();
        if (s.mode == Off || n == 0) { return; }
        ::std::lock_guard<::std::mutex> g(s.mu);
        s.reused[p] += n;
        size_t d = (s.done[p] += n);
        if (s.mode == Lines) { emit_line(s, p, d, nullptr); }
    }

    /// Phase \p p is over; its row leaves the pinned line.
    static void end(int p) {
        State &s = st();
        if (s.mode == Off) { return; }
        ::std::lock_guard<::std::mutex> g(s.mu);
        s.active[p] = false;
    }

    /// Erase the pinned line and keep it off until release(). Every write to
    /// stderr that can happen while a phase runs sits between the two. Nests.
    static void hold() {
        State &s = st();
        if (s.mode != Pinned) { return; }
        ::std::lock_guard<::std::mutex> g(s.mu);
        ++s.held;
        erase_locked(s);
    }
    static void release() {
        State &s = st();
        if (s.mode != Pinned) { return; }
        ::std::lock_guard<::std::mutex> g(s.mu);
        if (s.held > 0) { --s.held; }
    }

    /// The run is over (or is about to abort): erase the line, stop the thread.
    static void finish() {
        State &s = st();
        if (s.mode != Pinned) { return; }
        ::std::thread *t = nullptr;
        {
            ::std::lock_guard<::std::mutex> g(s.mu);
            s.stop = true;
            for (bool &a : s.active) { a = false; }
            erase_locked(s);
            t        = s.thread;
            s.thread = nullptr;
        }
        s.cv.notify_all();
        if (t) {
            t->join();
            delete t;
        }
    }

    /// Whether the meter writes anything (0 off, 1 pinned, 2 lines).
    static int mode() { return static_cast<int>(st().mode); }

  private:
    enum Mode : int { Off = 0, Pinned = 1, Lines = 2 };

    struct State {
        Mode                                     mode = Off;
        int                                      cols = 80;
        ::std::chrono::steady_clock::time_point  start{};
        ::std::mutex                             mu;
        ::std::condition_variable                cv;
        ::std::atomic<size_t>                    done[PhaseCount]{};
        ::std::atomic<size_t>                    total[PhaseCount]{};
        ::std::atomic<size_t>                    reused[PhaseCount]{};
        bool                                     active[PhaseCount]{};
        ::std::string                            file;
        ::std::string                            cwd;
        ::std::thread                           *thread = nullptr;
        bool                                     stop   = false;
        bool                                     drawn  = false;
        int                                      held   = 0;
    };

    // Leaked on purpose: a joinable thread member destroyed at exit would
    // terminate the process.
    static State &st() {
        static State *s = new State();
        return *s;
    }

    static const char *name(int p) {
        switch (p) {
        case Parse: return "parse";
        case Sema: return "sema";
        default: return "codegen";
        }
    }

    static bool tty_err() {
#if defined(_WIN32)
        return _isatty(_fileno(stderr)) != 0;
#else
        return ::isatty(2) != 0;
#endif
    }

    /// Whether stderr takes ANSI sequences, and how wide it is.
    static bool vt_ok(int *cols) {
#if defined(_WIN32)
        return kairo::win32::enable_vt_stderr(cols);
#else
        struct winsize w;
        if (::ioctl(2, TIOCGWINSZ, &w) == 0 && w.ws_col > 0) { *cols = w.ws_col; }
        return true;
#endif
    }

    /// The path relative to the working directory when it is under it, so a
    /// reader sees `Sema/Type/CallTyping.k` and not a checkout's prefix.
    static ::std::string display(State &s, const char *path) {
        if (s.cwd.empty()) {
            ::std::error_code ec;
            s.cwd = ::std::filesystem::current_path(ec).generic_string();
            if (s.cwd.empty() || s.cwd.back() != '/') { s.cwd += '/'; }
        }
        ::std::string p = path;
        for (char &c : p) { if (c == '\\') { c = '/'; } }
        if (p.compare(0, s.cwd.size(), s.cwd) == 0) { p.erase(0, s.cwd.size()); }
        return p;
    }

    /// One `@progress` event: fixed key order, `file=` last and unquoted (it
    /// runs to the end of the line). The prefix cannot begin a diagnostic.
    /// Caller holds mu, so lines come out in `done` order.
    static void emit_line(State &s, int p, size_t d, const char *file) {
        ::std::string l = "@progress phase=";
        l += name(p);
        l += " done=" + ::std::to_string(d);
        l += " total=" + ::std::to_string(s.total[p].load());
        if (p == Codegen) { l += " reused=" + ::std::to_string(s.reused[p].load()); }
        if (file && *file) { l += ::std::string(" file=") + file; }
        l += '\n';
        ::std::fwrite(l.data(), 1, l.size(), stderr);
        ::std::fflush(stderr);
    }

    static ::std::string tail(const ::std::string &f, size_t comps) {
        size_t pos = f.size();
        for (size_t i = 0; i < comps && pos != ::std::string::npos; ++i) {
            pos = pos == 0 ? ::std::string::npos : f.rfind('/', pos - 1);
        }
        return pos == ::std::string::npos ? f : f.substr(pos + 1);
    }

    static ::std::string compose(State &s) {
        ::std::string out;
        bool first = true;
        for (int p = 0; p < PhaseCount; ++p) {
            if (!s.active[p]) { continue; }
            out += (first ? "[" : "  [");
            out += name(p);
            out += " " + ::std::to_string(s.done[p].load()) + "/" + ::std::to_string(s.total[p].load());
            size_t r = s.reused[p].load();
            if (r) { out += ", " + ::std::to_string(r) + " reused"; }
            out += "]";
            if (first && !s.file.empty()) { out += " " + tail(s.file, 3); }
            first = false;
        }
        if (first) { return out; }
        auto secs = ::std::chrono::duration_cast<::std::chrono::seconds>(::std::chrono::steady_clock::now() - s.start).count();
        char tm[32];
        ::std::snprintf(tm, sizeof tm, "  %lld:%02lld", static_cast<long long>(secs / 60), static_cast<long long>(secs % 60));
        out += tm;
        // Never wrap: a wrapped row cannot be erased by \r\x1b[2K.
        size_t w = s.cols > 1 ? static_cast<size_t>(s.cols - 1) : 79;
        if (out.size() > w) { out.resize(w); }
        return out;
    }

    static void erase_locked(State &s) {
        if (!s.drawn) { return; }
        ::std::fputs("\r\x1b[2K", stderr);
        ::std::fflush(stderr);
        s.drawn = false;
    }

    /// Redraws about every 100 ms and never faster than 50 ms: the only
    /// thread that draws, so the line is written from one place.
    static void render_loop(State &s) {
        ::std::unique_lock<::std::mutex> lk(s.mu);
        while (!s.stop) {
            if (s.held == 0) {
                ::std::string line = compose(s);
                if (line.empty()) {
                    erase_locked(s);
                } else {
                    ::std::string o = "\r\x1b[2K" + line;
                    ::std::fwrite(o.data(), 1, o.size(), stderr);
                    ::std::fflush(stderr);
                    s.drawn = true;
                }
            }
            s.cv.wait_for(lk, ::std::chrono::milliseconds(100));
        }
    }
};

}  // namespace kairo

#endif
