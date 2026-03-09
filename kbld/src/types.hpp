#pragma once

#include <windows.h>
#include <consoleapi2.h>
#include <winbase.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <format>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <mutex>
#include <optional>
#include <regex>
#include <semaphore>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <cstdio>

#ifdef _WIN32
#  define kbld_popen  _popen
#  define kbld_pclose _pclose
#else
#  define kbld_popen  popen
#  define kbld_pclose pclose
#endif

namespace kbld::fmt_detail {

template <typename... Args>
inline auto fmt(std::string_view f, Args &&...args) -> std::string {
    return std::vformat(f, std::make_format_args(args...));
}

inline void print_to(FILE *f, std::string_view s) { std::fwrite(s.data(), 1, s.size(), f); }

}  // namespace kbld::fmt_detail

namespace kbld {
using fmt_detail::fmt;

inline void puts_out(const std::string &s) { std::fwrite(s.data(), 1, s.size(), stdout); }
inline void puts_err(const std::string &s) { std::fwrite(s.data(), 1, s.size(), stderr); }
inline void putln(const std::string &s) {
    std::fwrite(s.data(), 1, s.size(), stdout);
    std::fputc('\n', stdout);
}
}  // namespace kbld

namespace fs = std::filesystem;

namespace kbld {

enum class BuildMode { Debug, Release };

inline auto to_string(BuildMode m) -> std::string {
    return m == BuildMode::Debug ? "debug" : "release";
}

enum class TargetType { Binary, Static, Shared };

inline auto parse_target_type(std::string_view s) -> TargetType {
    if (s == "static")
        return TargetType::Static;
    if (s == "shared")
        return TargetType::Shared;
    return TargetType::Binary;
}

struct ProjectConfig {
    std::string name;
    std::string version;
    std::string author;
    std::string license;
};

struct WorkspaceConfig {
    std::vector<std::string> skip_dirs;
};

struct BuildConfig {
    std::string compiler = "kairo";
    BuildMode   mode     = BuildMode::Release;
};

struct Target {
    std::string              name;
    std::string              entry;
    TargetType               type = TargetType::Binary;
    std::vector<std::string> includes;
    std::vector<std::string> links;
    std::vector<std::string> libs;
    std::vector<std::string> deps;
    std::vector<std::string> defines;
    std::vector<std::string> ld_flags;
    std::vector<std::string> cxx_sources;
    std::vector<std::string> cxx_passthrough;
    std::string              pre_build;
    std::string              post_build;
};

struct Config {
    ProjectConfig       project;
    WorkspaceConfig     workspace;
    BuildConfig         build;
    std::vector<Target> targets;
};

enum class Command {
    Build,
    Clean,
    Test,
    Deps,
    Index,
    Install,
    Line,
};

struct CLIOptions {
    Command                  command = Command::Build;
    std::vector<std::string> positional;     // target names, file paths, etc.
    std::optional<BuildMode> mode_override;  // --debug / --release
    bool                     verbose        = false;
    int                      jobs           = 0;  // 0 = auto
    bool                     dry_run        = false;
    bool                     emit_ir        = false;
    bool                     emit_ast       = false;
    bool                     keep_going     = false;
    bool                     perf           = false;  // test --perf
    bool                     compile_only   = false;  // test --compile-only
    std::string              install_prefix = "/usr/local";
    std::string              line_range;  // for `line` command
};

struct TargetState {
    std::int64_t                        entry_mtime = 0;
    std::map<std::string, std::int64_t> dep_mtimes;
    std::map<std::string, std::int64_t> cxx_source_mtimes;
    std::int64_t                        output_mtime = 0;
};

struct BuildState {
    std::map<std::string, TargetState> targets;
};

inline auto get_triple() -> std::string {
#if defined(__x86_64__) || defined(_M_X64)
    std::string arch = "x86_64";
#elif defined(__aarch64__) || defined(_M_ARM64)
    std::string arch = "aarch64";
#elif defined(__i386__) || defined(_M_IX86)
    std::string arch = "i386";
#else
    std::string arch = "unknown";
#endif

#if defined(_WIN32)
    std::string sys = "windows";
    std::string abi = "msvc";
#elif defined(__APPLE__)
    std::string sys = "darwin";
    std::string abi = "macho";
#elif defined(__linux__)
    std::string sys = "linux";
    std::string abi = "gnu";
#else
    std::string sys = "unknown";
    std::string abi = "unknown";
#endif

    return arch + "-" + sys + "-" + abi;
}

inline auto is_windows() -> bool {
#ifdef _WIN32
    return true;
#else
    return false;
#endif
}

inline auto file_mtime_ns(const fs::path &p) -> std::int64_t {
    std::error_code ec;
    auto            ftime = fs::last_write_time(p, ec);
    if (ec)
        return 0;
#if defined(_WIN32) && defined(_MSC_VER)
    // MSVC's file_clock does not expose to_sys(); convert manually.
    // Windows FILETIME epoch (1601-01-01) vs Unix epoch (1970-01-01)
    // = 11644473600 seconds difference.
    auto file_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                       ftime.time_since_epoch())
                       .count();
    constexpr std::int64_t kEpochDiffNs = 11644473600LL * 1'000'000'000LL;
    return file_ns - kEpochDiffNs;
#else
    auto sctp = std::chrono::file_clock::to_sys(ftime);
    return std::chrono::duration_cast<std::chrono::nanoseconds>(sctp.time_since_epoch()).count();
#endif
}

inline auto run_capture_stdout_only(const std::string &cmd, std::string &out) -> int {
    out.clear();
#ifdef _WIN32
    // redirect stderr to NUL on Windows
    std::string full = "cmd.exe /c \"" + cmd + " 2>NUL\"";
#else
    std::string full = cmd + " 2>/dev/null";
#endif
    FILE *fp = kbld_popen(full.c_str(), "r");
    if (!fp) return -1;
    char buf[4096];
    while (auto n = std::fread(buf, 1, sizeof(buf), fp))
        out.append(buf, n);
    int status = kbld_pclose(fp);
#ifndef _WIN32
    if (WIFEXITED(status)) return WEXITSTATUS(status);
#endif
    return status;
}

inline auto iso8601_now() -> std::string {
    auto    now = std::chrono::system_clock::now();
    auto    tt  = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
#ifdef _WIN32
    gmtime_s(&tm, &tt);
#else
    gmtime_r(&tt, &tm);
#endif
    char buf[64];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buf;
}

inline auto terminal_width() -> int {
#ifdef _WIN32
    return 80;
#else
    const char *cols = std::getenv("COLUMNS");
    if (cols) {
        int w = std::atoi(cols);
        if (w > 0)
            return w;
    }
    return 80;
#endif
}

inline auto run_command(const std::string &cmd) -> int { return std::system(cmd.c_str()); }

inline auto run_capture(const std::string &cmd, std::string &out) -> int {
    out.clear();
    std::string full = cmd + " 2>/dev/null";
    FILE       *fp   = kbld_popen(full.c_str(), "r");
    if (!fp)
        return -1;
    char buf[4096];
    while (auto n = std::fread(buf, 1, sizeof(buf), fp)) {
        out.append(buf, n);
    }
    int status = kbld_pclose(fp);
#ifndef _WIN32
    if (WIFEXITED(status))
        return WEXITSTATUS(status);
#endif
    return status;
}

inline auto run_capture_all(const std::string &cmd, std::string &out, std::string &err) -> int {
    out.clear();
    err.clear();

    auto        tmp  = fs::temp_directory_path() / "kbld_stderr.tmp";
    std::string full = cmd + " 2>" + tmp.string();

    FILE *fp = kbld_popen(full.c_str(), "r");
    if (!fp)
        return -1;
    char buf[4096];
    while (auto n = std::fread(buf, 1, sizeof(buf), fp)) {
        out.append(buf, n);
    }
    int status = kbld_pclose(fp);

    if (std::ifstream ifs(tmp); ifs) {
        std::ostringstream ss;
        ss << ifs.rdbuf();
        err = ss.str();
    }
    fs::remove(tmp);

#ifndef _WIN32
    if (WIFEXITED(status))
        return WEXITSTATUS(status);
#endif
    return status;
}

inline auto quick_hash(std::string_view sv) -> std::string {
    std::uint64_t h = 14695981039346656037ULL;
    for (unsigned char c : sv) {
        h ^= c;
        h *= 1099511628211ULL;
    }
    char buf[17];
    std::snprintf(buf, sizeof(buf), "%016llx", static_cast<unsigned long long>(h));
    return buf;
}

inline auto read_file(const fs::path &p) -> std::string {
    std::ifstream ifs(p, std::ios::binary);
    if (!ifs)
        return {};
    std::ostringstream ss;
    ss << ifs.rdbuf();
    return ss.str();
}

inline auto write_file(const fs::path &p, std::string_view content) -> bool {
    fs::create_directories(p.parent_path());
    std::ofstream ofs(p, std::ios::binary | std::ios::trunc);
    if (!ofs)
        return false;
    ofs.write(content.data(), static_cast<std::streamsize>(content.size()));
    return ofs.good();
}

namespace log {

    inline std::mutex g_log_mutex;

    inline void info(std::string_view msg) {
        std::lock_guard lk(g_log_mutex);
        auto            s = fmt("\033[1;32m[kbld]\033[0m {}\n", std::string(msg));
        fmt_detail::print_to(stderr, s);
    }

    inline void warn(std::string_view msg) {
        std::lock_guard lk(g_log_mutex);
        auto            s = fmt("\033[1;33m[kbld]\033[0m {}\n", std::string(msg));
        fmt_detail::print_to(stderr, s);
    }

    inline void error(std::string_view msg) {
        std::lock_guard lk(g_log_mutex);
        auto            s = fmt("\033[1;31m[kbld]\033[0m {}\n", std::string(msg));
        fmt_detail::print_to(stderr, s);
    }

    inline void verbose(std::string_view msg, bool enabled) {
        if (!enabled)
            return;
        std::lock_guard lk(g_log_mutex);
        auto            s = fmt("\033[1;36m[kbld]\033[0m {}\n", std::string(msg));
        fmt_detail::print_to(stderr, s);
    }

}  // namespace log

}  // namespace kbld

inline auto terminal_width() -> int {
#ifdef _WIN32
    CONSOLE_SCREEN_BUFFER_INFO csbi;
    if (GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &csbi))
        return csbi.srWindow.Right - csbi.srWindow.Left + 1;
#else
    struct winsize w;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0)
        return w.ws_col;
#endif
    return 80;
}

inline auto iso8601_now() -> std::string {
    auto now = std::chrono::system_clock::now();
    auto t   = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
#ifdef _WIN32
    gmtime_s(&tm, &t);
#else
    gmtime_r(&t, &tm);
#endif
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buf;
}