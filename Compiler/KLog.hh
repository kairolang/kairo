///--- The Kairo Project ----------------------------------------------------///
///                                                                          ///
///   Part of the Kairo Project, under the Attribution 4.0 International     ///
///   license (CC BY 4.0).  You are allowed to use, modify, redistribute,    ///
///   and create derivative works, even for commercial purposes, provided    ///
///   that you give appropriate credit, and indicate if changes were made.   ///
///                                                                          ///
///   For more information on the license terms and requirements, please     ///
///     visit: https://creativecommons.org/licenses/by/4.0/                  ///
///                                                                          ///
///   SPDX-License-Identifier: CC-BY-4.0                                     ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                       ///
///                                                                          ///
///------------------------------------------------------------ KAIRO -------///

#ifndef __KAIRO_TOOLCHAIN_CORE_KLOG_HH__
#define __KAIRO_TOOLCHAIN_CORE_KLOG_HH__

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <format>
#include <fstream>
#include <functional>
#include <include/core.hh>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "include/types/string/string.hh"

#if defined(__cpp_lib_source_location) || defined(__cpp_lib_source_location)
#include <source_location>
#define KLOG_HAS_SRCLOC 1
#else
#define KLOG_HAS_SRCLOC 0
#endif

namespace kairo {
class Logger {
  public:
    enum class Level : uint8_t {
        Trace,
        Debug,
        Info,
        Warn,
        Error,
        Fatal
    };

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
        string   message;
        uint64_t thread_id{};
        uint64_t timestamp_ns{};
        string   file;
        uint32_t line{};
        uint32_t col{};
    };

    static void init(Level min_level = Level::Info) {
        libcxx::lock_guard<libcxx::mutex> lock(init_mutex_());
        if (instance_() == nullptr) {
            instance_() = new Logger(min_level);
        }
    }

    static void set_level(Level level) { get()->min_level_ = level; }

    static Logger *get() { return instance_(); }

    static void shutdown() {
        libcxx::lock_guard<libcxx::mutex> lock(init_mutex_());
        if (instance_() != nullptr) {
            delete instance_();
            instance_() = nullptr;
        }
    }

    static void set_min_level(Level level) { get()->min_level_ = level; }

    static void set_dump_path(const string &path) { get()->dump_path_ = path; }

    static void enable_stage(Stage stage, bool enabled) {
        get()->stage_enabled_[static_cast<size_t>(stage)] = enabled;
    }

    void log(Level                         level,
             Stage                         stage,
             const string                 &message,
             const libcxx::source_location loc =
                 libcxx::source_location::current()) {
        if (static_cast<uint8_t>(level) < static_cast<uint8_t>(min_level_)) {
            return;
        }

        if (!stage_enabled_[static_cast<size_t>(stage)]) {
            return;
        }

        Entry e;
        e.level        = level;
        e.stage        = stage;
        e.message      = message;
        e.thread_id    = current_thread_id();
        e.timestamp_ns = elapsed_ns();
#ifndef NDEBUG
        e.file = libcxx::filesystem::path(loc.file_name())
                     .filename()
                     .generic_wstring();
        e.line = loc.line();
        e.col  = loc.column();
#endif

        libcxx::lock_guard<libcxx::mutex> lock(mutex_);
        entries_.push_back(libcxx::move(e));
    }

    static void trace(Stage                         s,
                      const string                 &msg,
                      const libcxx::source_location loc =
                          libcxx::source_location::current()) {
        auto *inst = get();
        if (inst == nullptr) {
            return;
        }

        inst->log(Level::Trace, s, msg, loc);
    }
    static void debug(Stage                         s,
                      const string                 &msg,
                      const libcxx::source_location loc =
                          libcxx::source_location::current()) {
        auto *inst = get();
        if (inst == nullptr) {
            return;
        }

        inst->log(Level::Debug, s, msg, loc);
    }
    static void info(Stage                         s,
                     const string                 &msg,
                     const libcxx::source_location loc =
                         libcxx::source_location::current()) {
        auto *inst = get();
        if (inst == nullptr) {
            return;
        }

        inst->log(Level::Info, s, msg, loc);
    }
    static void warn(Stage                         s,
                     const string                 &msg,
                     const libcxx::source_location loc =
                         libcxx::source_location::current()) {
        auto *inst = get();
        if (inst == nullptr) {
            return;
        }

        inst->log(Level::Warn, s, msg, loc);
    }
    static void error(Stage                         s,
                      const string                 &msg,
                      const libcxx::source_location loc =
                          libcxx::source_location::current()) {
        auto *inst = get();
        if (inst == nullptr) {
            return;
        }

        inst->log(Level::Error, s, msg, loc);
    }
    static void fatal(Stage                         s,
                      const string                 &msg,
                      const libcxx::source_location loc =
                          libcxx::source_location::current()) {
        auto *inst = get();
        if (inst == nullptr) {
            return;
        }

        inst->log(Level::Fatal, s, msg, loc);
    }

    static void dump_to_stderr() {
        libcxx::lock_guard<libcxx::mutex> lock(get()->mutex_);
        for (const auto &e : get()->entries_) {
            libcxx::fputws(format_entry(e).raw_string().c_str(), stderr);
        }
    }

    static void dump_to_file() {
        if (get()->dump_path_.empty()) {
            return;
        }
        libcxx::lock_guard<libcxx::mutex> lock(get()->mutex_);
        libcxx::wofstream out(libcxx::filesystem::path(get()->dump_path_.raw()),
                              libcxx::ios::trunc);
        if (!out.is_open()) {
            return;
        }
        for (const auto &e : get()->entries_) {
            out << format_entry(e).raw_string();
        }
    }

    static void dump() {
        dump_to_stderr();
        dump_to_file();
    }

    static void dump_stage(Stage stage) {
        libcxx::lock_guard<libcxx::mutex> lock(get()->mutex_);
        for (const auto &e : get()->entries_) {
            if (e.stage == stage) {
                libcxx::fputws(format_entry(e).raw_string().c_str(), stderr);
            }
        }
    }

    static void dump_level(Level min) {
        libcxx::lock_guard<libcxx::mutex> lock(get()->mutex_);
        for (const auto &e : get()->entries_) {
            if (static_cast<uint8_t>(e.level) >= static_cast<uint8_t>(min)) {
                libcxx::fputws(format_entry(e).raw_string().c_str(), stderr);
            }
        }
    }

    static void clear() {
        libcxx::lock_guard<libcxx::mutex> lock(get()->mutex_);
        get()->entries_.clear();
    }

    static size_t entry_count() {
        libcxx::lock_guard<libcxx::mutex> lock(get()->mutex_);
        return get()->entries_.size();
    }

    ~Logger() = default;

    Logger(const Logger &)            = delete;
    Logger &operator=(const Logger &) = delete;
    Logger(Logger &&)                 = delete;
    Logger &operator=(Logger &&)      = delete;

  private:
    explicit Logger(Level min_level)
        : min_level_(min_level)
        , start_(libcxx::chrono::steady_clock::now()) {
        stage_enabled_.fill(true);
    }

    static Logger *&instance_() {
        static Logger *inst = nullptr;
        return inst;
    }

    static libcxx::mutex &init_mutex_() {
        static libcxx::mutex m;
        return m;
    }

    [[nodiscard]] static string format_entry(const Entry &e) {
        auto        ts  = format_time(e.timestamp_ns);
        auto        tid = format_thread(e.thread_id);
        const auto *stg = stage_str(e.stage);
        const auto *lvl = level_str(e.level);

        string out = libcxx::format(L"[{}] [T:{}] [{}] [{}] {}",
                                    ts.raw_string(),
                                    tid.raw_string(),
                                    stg,
                                    lvl,
                                    e.message.raw_string());

#ifndef NDEBUG
        if (!e.file.empty()) {
            out += libcxx::format(
                L" ({}:{}:{})", e.file.raw_string(), e.line, e.col);
        }
#endif

        out += L'\n';
        return out;
    }

    static string format_time(uint64_t ns) {
        auto ms = ns / 1'000'000;
        auto us = (ns / 1'000) % 1'000;
        return libcxx::format(L"{:>6}.{:03}ms", ms, us);
    }

    static string format_thread(uint64_t tid) {
        return libcxx::format(L"0x{:04x}", tid & 0xFFFF);
    }

    static const wchar_t *stage_str(Stage s) {
        static constexpr const wchar_t *names[] = {
            L"Driver    ",
            L"Lexer     ",
            L"Preproc   ",
            L"Parser    ",
            L"Sema      ",
            L"AMT       ",
            L"Lowering  ",
            L"CodeGen   ",
            L"Linker    ",
            L"Optimizer ",
            L"LSP       ",
            L"ThreadPool",
        };
        auto i = static_cast<size_t>(s);
        return (i < libcxx::size(names)) ? names[i] : L"Unknown   ";
    }

    static const wchar_t *level_str(Level l) {
        static constexpr const wchar_t *names[] = {
            L"\033[94m"   L"TRACE" L"\033[0m",
            L"\033[36m"   L"DEBUG" L"\033[0m",
            L"\033[32m"   L"INFO " L"\033[0m",
            L"\033[33m"   L"WARN " L"\033[0m",
            L"\033[31m"   L"ERROR" L"\033[0m",
            L"\033[1;31m" L"FATAL" L"\033[0m",
        };
        auto i = static_cast<size_t>(l);
        return (i < libcxx::size(names)) ? names[i] : L"?????";
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

    vec<Entry>                                     entries_;
    libcxx::mutex                                  mutex_;
    Level                                          min_level_;
    libcxx::chrono::steady_clock::time_point       start_;
    array<bool, static_cast<size_t>(Stage::Count)> stage_enabled_{};
    string                                         dump_path_;
};
}  // namespace kairo

#endif  // __KAIRO_TOOLCHAIN_CORE_KLOG_HH__
