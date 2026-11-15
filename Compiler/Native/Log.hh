/// --- The Kairo Project ------------------------------- Native/Log.hh --- ///
///
///   Logger, the leveled, per-stage diagnostic log of the compiler itself.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_TOOLCHAIN_CORE_KLOG_HH__
#define __KAIRO_TOOLCHAIN_CORE_KLOG_HH__

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <format>
#include <functional>
#include "Prelude.hh"
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/Path.h>
#include <llvm/Support/raw_ostream.h>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <source_location>


namespace kairo {
class Logger {
  public:
    enum class Level : uint8_t { Trace, Debug, Info, Warn, Error, Fatal };

    enum class Stage : uint8_t {
        Driver,
        Lexer,
        Preprocessor,
        Parser,
        Sema,
        AMT,
        Lowering,
        CodeGen,
        Linker,
        Optimizer,
        LSP,
        ThreadPool,
        Count
    };

    struct Entry {
        Level    level;
        Stage    stage;
        // ::std::string, not the Kairo string: Native cannot name it, and
        // the entry never leaves this class as a string.
        ::std::string message;
        uint64_t      thread_id{};
        uint64_t      timestamp_ns{};
        ::std::string file;
        uint32_t line{};
        uint32_t col{};
    };

    static void init(Level min_level = Level::Info) {
        libcxx::lock_guard<libcxx::mutex> lock(init_mutex_());
        if (instance_().load(libcxx::memory_order_acquire) == nullptr) {
            instance_().store(new Logger(min_level), libcxx::memory_order_release);
        }
    }

    /// The configuration calls below do nothing before init() or after
    /// shutdown(), like the log calls.
    static void set_level(Level level) {
        if (Logger *l = get()) { l->min_level_.store(level, libcxx::memory_order_relaxed); }
    }

    static Logger *get() { return instance_().load(libcxx::memory_order_acquire); }

    /// Log calls after this are dropped and the buffered entries are freed.
    /// The Logger object itself is not: a pool worker may be inside log()
    /// when the driver shuts the log down, and it finishes on a live object.
    static void shutdown() {
        libcxx::lock_guard<libcxx::mutex> lock(init_mutex_());
        Logger *l = instance_().exchange(nullptr, libcxx::memory_order_acq_rel);
        if (l != nullptr) {
            libcxx::lock_guard<libcxx::mutex> entries(l->mutex_);
            libcxx::vector<Entry>().swap(l->entries_);
        }
    }

    /// Entries at or above this level are written to stderr AS THEY HAPPEN, in
    /// addition to being buffered for dump_to_file().
    ///
    /// The buffer-and-flush-at-teardown model alone loses everything when the
    /// process dies abnormally (ICE, signal, terminate) - which is exactly when
    /// the log is worth having - and shows nothing during a long compile. The
    /// live echo covers both. `min_level_` is still the master gate: an entry
    /// filtered out there is never recorded and so never streamed.
    ///
    /// Default is Error in a debug build, so an internal failure always
    /// reaches the terminal instead of sitting in a log file nobody was told
    /// about. A release build streams only Fatal: an Error entry there is a
    /// developer breadcrumb (the user-facing failure is a diagnostic), and
    /// -v (set_stream_level(Info)) still shows it.
    static void set_stream_level(Level level) {
        if (Logger *l = get()) { l->stream_level_.store(level, libcxx::memory_order_relaxed); }
    }

    template <class S>
    static void set_dump_path(const S &path) {
        if (Logger *l = get()) {
            libcxx::lock_guard<libcxx::mutex> lock(l->mutex_);
            l->dump_path_ = ::std::string(native::bytes(path));
        }
    }

    /// Every text entry point is a template on the message (native::bytes),
    /// so a Kairo string, an f-string and a literal all pass.
    template <class S>
    void log(Level                         level,
             Stage                         stage,
             const S                      &message,
             const libcxx::source_location loc =
                 libcxx::source_location::current()) {
        if (static_cast<uint8_t>(level) <
            static_cast<uint8_t>(min_level_.load(libcxx::memory_order_relaxed))) {
            return;
        }

        Entry e;
        e.level        = level;
        e.stage        = stage;
        e.message      = ::std::string(native::bytes(message));
        e.thread_id    = current_thread_id();
        e.timestamp_ns = elapsed_ns();
#ifndef NDEBUG
        auto fname = llvm::sys::path::filename(loc.file_name());
        e.file     = ::std::string(fname.data(), fname.size());
        e.line = loc.line();
        e.col  = loc.column();
#endif

        libcxx::lock_guard<libcxx::mutex> lock(mutex_);
        entries_.push_back(libcxx::move(e));

        // Live echo, under the same lock so concurrent stages cannot interleave
        // half-lines, and with any status line on stderr held off its row
        // (native::stderr_hold). Flushed immediately: the whole point is to
        // survive a crash that never reaches the teardown dump.
        if (static_cast<uint8_t>(level) >=
            static_cast<uint8_t>(stream_level_.load(libcxx::memory_order_relaxed))) {
            native::stderr_hold();
            write_err(format_entry(entries_.back(), stream_color()));
            libcxx::fflush(stderr);
            native::stderr_release();
        }
    }

    /// The six level entry points. Each drops the message when no Logger is
    /// published (before init(), after shutdown()).
    template <class S>
    static void trace(Stage s, const S &msg,
                    const libcxx::source_location loc = libcxx::source_location::current()) {
        log_at(Level::Trace, s, msg, loc);
    }

    template <class S>
    static void debug(Stage s, const S &msg,
                    const libcxx::source_location loc = libcxx::source_location::current()) {
        log_at(Level::Debug, s, msg, loc);
    }

    template <class S>
    static void info(Stage s, const S &msg,
                   const libcxx::source_location loc = libcxx::source_location::current()) {
        log_at(Level::Info, s, msg, loc);
    }

    template <class S>
    static void warn(Stage s, const S &msg,
                   const libcxx::source_location loc = libcxx::source_location::current()) {
        log_at(Level::Warn, s, msg, loc);
    }

    template <class S>
    static void error(Stage s, const S &msg,
                    const libcxx::source_location loc = libcxx::source_location::current()) {
        log_at(Level::Error, s, msg, loc);
    }

    template <class S>
    static void fatal(Stage s, const S &msg,
                    const libcxx::source_location loc = libcxx::source_location::current()) {
        log_at(Level::Fatal, s, msg, loc);
    }

    // UTF-8 bytes, written verbatim through C stdio (stderr, unbuffered): no
    // locale involved, and it orders with every other stdio writer.
    static void write_err(::std::string_view s) { native::write_bytes(stderr, s); }

    static void dump_to_file() {
        Logger *l = get();
        if (l == nullptr) { return; }
        libcxx::lock_guard<libcxx::mutex> lock(l->mutex_);
        if (l->dump_path_.empty()) {
            return;
        }
        // Nothing logged: create no file. The dump path sits beside the
        // installed binary, so an unconditional open litters bin/ with an
        // empty <exe>.log on every run (or fails in a read-only install). A
        // log left by an earlier run is removed, so the file on disk always
        // belongs to the last run.
        if (l->entries_.empty()) {
            llvm::sys::fs::remove(l->dump_path_);
            return;
        }
        // OF_None: binary, truncating. Streams entry by entry, so the dump
        // never holds the whole log as one string.
        libcxx::error_code   ec;
        llvm::raw_fd_ostream out(llvm::StringRef(l->dump_path_), ec, llvm::sys::fs::OF_None);
        if (ec) {
            return;
        }
        for (const auto &e : l->entries_) {
            auto line = format_entry(e, false);
            out.write(line.data(), line.size());
        }
        // A log that cannot be written is not an error of the run. The
        // stream's destructor ends the process when its error flag is still
        // set, so the file is closed and the flag cleared here.
        out.close();
        out.clear_error();
    }

    Logger(const Logger &)            = delete;
    Logger &operator=(const Logger &) = delete;
    Logger(Logger &&)                 = delete;
    Logger &operator=(Logger &&)      = delete;

  private:
    template <class S>
    static void log_at(Level level, Stage s, const S &msg, const libcxx::source_location &loc) {
        if (Logger *inst = get()) { inst->log(level, s, msg, loc); }
    }

    explicit Logger(Level min_level)
        : min_level_(min_level)
        , start_(libcxx::chrono::steady_clock::now()) {
    }

    static libcxx::atomic<Logger *> &instance_() {
        static libcxx::atomic<Logger *> inst{nullptr};
        return inst;
    }

    static libcxx::mutex &init_mutex_() {
        static libcxx::mutex m;
        return m;
    }

    /// Colour is decided once: honour NO_COLOR, and never emit escapes into a
    /// pipe or a file. The dump_to_file path passes false explicitly.
    static bool stream_color() {
        static const bool enabled = [] {
            if (libcxx::getenv("NO_COLOR") != nullptr) {
                return false;
            }
            return native::stderr_is_tty();
        }();
        return enabled;
    }

    [[nodiscard]] static ::std::string format_entry(const Entry &e,
                                             bool         use_color = true) {
        auto        ts  = format_time(e.timestamp_ns);
        auto        tid = format_thread(e.thread_id);
        const auto *stg = stage_str(e.stage);
        const auto *lvl = level_str(e.level, use_color);

        ::std::string out = libcxx::format("[{}] [T:{}] [{}] [{}] {}",
                                           ts,
                                           tid,
                                           stg,
                                           lvl,
                                           e.message);

#ifndef NDEBUG
        if (!e.file.empty()) {
            out += libcxx::format(
                " ({}:{}:{})", e.file, e.line, e.col);
        }
#endif

        out += '\n';
        return out;
    }

    static ::std::string format_time(uint64_t ns) {
        auto ms = ns / 1'000'000;
        auto us = (ns / 1'000) % 1'000;
        return libcxx::format("{:>6}.{:03}ms", ms, us);
    }

    static ::std::string format_thread(uint64_t tid) {
        return libcxx::format("0x{:04x}", tid & 0xFFFF);
    }

    static const char *stage_str(Stage s) {
        static constexpr const char *names[] = {
            "Driver    ",
            "Lexer     ",
            "Preproc   ",
            "Parser    ",
            "Sema      ",
            "AMT       ",
            "Lowering  ",
            "CodeGen   ",
            "Linker    ",
            "Optimizer ",
            "LSP       ",
            "ThreadPool",
        };
        auto i = static_cast<size_t>(s);
        return (i < libcxx::size(names)) ? names[i] : "Unknown   ";
    }

    static const char *level_str(Level l, bool use_color = true) {
        static constexpr const char *colored_names[] = {
            "\033[94m"   "TRACE" "\033[0m",
            "\033[36m"   "DEBUG" "\033[0m",
            "\033[32m"   "INFO " "\033[0m",
            "\033[33m"   "WARN " "\033[0m",
            "\033[31m"   "ERROR" "\033[0m",
            "\033[1;31m" "FATAL" "\033[0m",
        };
        
        static constexpr const char *plain_names[] = {
            "TRACE",
            "DEBUG",
            "INFO ",
            "WARN ",
            "ERROR",
            "FATAL",
        };

        const char *const *names = use_color ? colored_names : plain_names;
        auto                  i     = static_cast<size_t>(l);
        return (i < libcxx::size(colored_names)) ? names[i] : "?????";
    }

    uint64_t elapsed_ns() const {
        auto now = libcxx::chrono::steady_clock::now();
        return static_cast<uint64_t>(
            libcxx::chrono::duration_cast<libcxx::chrono::nanoseconds>(now -
                                                                       start_)
                .count());
    }

    static uint64_t current_thread_id() {
        return static_cast<uint64_t>(
            libcxx::hash<libcxx::thread::id>{}(libcxx::this_thread::get_id()));
    }

    libcxx::vector<Entry>                          entries_;
    libcxx::mutex                                  mutex_;
    // Set by the driver while pool workers log: read without the mutex.
    libcxx::atomic<Level>                          min_level_;
#ifndef NDEBUG
    libcxx::atomic<Level>                          stream_level_{Level::Error};
#else
    libcxx::atomic<Level>                          stream_level_{Level::Fatal};
#endif
    libcxx::chrono::steady_clock::time_point       start_;
    ::std::string                                  dump_path_;
};
}  // namespace kairo

#endif  // __KAIRO_TOOLCHAIN_CORE_KLOG_HH__
