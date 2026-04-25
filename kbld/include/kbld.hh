#pragma once
// kbld_lib.hh — build script library for build.kro
// ffi "c++" import "kbld_lib.hh";
//
// build.kro emits a single JSON blob to stdout via Project::emit().
// kbld reads it after the script exits and deserializes into Config.
//
// Dependencies: nlohmann/json.hpp, include/core.hh

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>
#if defined(_WIN32)
#include <windows.h>
#define kbld_lib_popen _popen
#define kbld_lib_pclose _pclose
#else
#include <sys/wait.h>
#include <unistd.h>
#define kbld_lib_popen popen
#define kbld_lib_pclose pclose
#endif

#include "include/core.hh"
#include "nlohmann/json.hpp"

namespace fs = std::filesystem;
using json   = nlohmann::json;

// narrow string alias — everything that crosses the C boundary uses this
using _kstr = std::string;

// ─── narrow↔wide helpers ──────────────────────────────────────────────────────
// These live outside kairo:: so the detail namespace can use them freely.

inline auto _w2n(const kairo::string &s) -> _kstr { return kairo::std::string_to_cstring(s); }

inline auto _n2w(const _kstr &s) -> kairo::string { return kairo::std::cstring_to_string(s); }

inline auto _n2w(const char *s) -> kairo::string {
    if (!s)
        return kairo::string{};
    return kairo::string(s);  // basic<wchar_t>(const char*) constructor
}

// ─── fs::path from kairo string ──────────────────────────────────────────────

inline auto _kpath(const kairo::string &s) -> fs::path {
    return fs::path(s.raw_string());  // raw_string() is std::wstring
}

namespace kairo {

// ─────────────────────────────────────────────────────────────────────────────
// RunResult
// ─────────────────────────────────────────────────────────────────────────────

struct RunResult {
    int    exit_code = 0;
    string stdout_str;
    string stderr_str;
    bool   success = false;
};

// ─────────────────────────────────────────────────────────────────────────────
// Internal detail — narrow-only, all C boundary work happens here
// ─────────────────────────────────────────────────────────────────────────────

namespace _kbld_detail {

    // Run cmd (narrow), capture stdout into out (wide), stderr into err (wide).
    inline auto capture_all(_kstr cmd, string &out, string &err) -> int {
        out.clear();
        err.clear();

        auto tmp      = fs::temp_directory_path() / "kbld_lib_stderr.tmp";
        auto full_cmd = cmd + " 2>" + tmp.string();

        FILE *fp = kbld_lib_popen(full_cmd.c_str(), "r");
        if (!fp)
            return -1;

        // read stdout as narrow bytes, convert to wide
        _kstr narrow_out;
        char  buf[4096];
        while (auto n = libcxx::fread(buf, 1, sizeof(buf), fp)) {
            narrow_out.append(buf, n);
        }
        out = _n2w(narrow_out);

        int status = kbld_lib_pclose(fp);

        // read stderr file as narrow, convert to wide
        {
            libcxx::ifstream ifs(tmp);
            if (ifs) {
                libcxx::ostringstream ss;
                ss << ifs.rdbuf();
                err = _n2w(ss.str());
            }
        }
        fs::remove(tmp);

#ifndef _WIN32
        if (WIFEXITED(status))
            return WEXITSTATUS(status);
#endif
        return status;
    }

    inline auto getenv_str(const char *key) -> string {
        const char *v = libcxx::getenv(key);
        return v ? _n2w(v) : string{};
    }

    inline auto getenv_int(const char *key, int fallback = 1) -> int {
        const char *v = libcxx::getenv(key);
        if (!v)
            return fallback;
        try {
            return libcxx::stoi(_kstr(v));
        } catch (...) { return fallback; }
    }

    // Quote a single wide arg into a narrow shell-safe token.
    inline auto quote_arg(const string &a) -> _kstr {
        auto na = _w2n(a);
#ifdef _WIN32
        return "\"" + na + "\"";
#else
        _kstr out;
        out += '\'';
        for (char c : na) {
            if (c == '\'')
                out += "'\\''";
            else
                out += c;
        }
        out += '\'';
        return out;
#endif
    }

    inline auto argv_to_cmd(const vec<string> &args) -> _kstr {
        _kstr cmd;
        for (auto &a : args) {
            if (!cmd.empty())
                cmd += ' ';
            cmd += quote_arg(a);
        }
        return cmd;
    }

    inline auto resolve_path(const string &path) -> string {
        if (_kpath(path).is_absolute())
            return path;
        auto root = getenv_str("KBLD_ROOT");
        if (root.is_empty())
            return path;
        return string((fs::path(root.raw_string()) / _kpath(path)).wstring().c_str());
    }

}  // namespace _kbld_detail

// ─────────────────────────────────────────────────────────────────────────────
// Environment query
// ─────────────────────────────────────────────────────────────────────────────

inline auto target_name() -> string { return _kbld_detail::getenv_str("KBLD_TARGET"); }
inline auto build_mode() -> string { return _kbld_detail::getenv_str("KBLD_MODE"); }
inline auto triple() -> string { return _kbld_detail::getenv_str("KBLD_TRIPLE"); }
inline auto platform() -> string { return _kbld_detail::getenv_str("KBLD_PLATFORM"); }
inline auto arch() -> string { return _kbld_detail::getenv_str("KBLD_ARCH"); }
inline auto project_root() -> string { return _kbld_detail::getenv_str("KBLD_ROOT"); }
inline auto out_dir() -> string { return _kbld_detail::getenv_str("KBLD_OUT_DIR"); }
inline auto build_dir() -> string { return _kbld_detail::getenv_str("KBLD_BUILD_DIR"); }
inline auto compiler() -> string { return _kbld_detail::getenv_str("KBLD_COMPILER"); }
inline auto kbld_version() -> string { return _kbld_detail::getenv_str("KBLD_VERSION"); }
inline auto num_jobs() -> int { return _kbld_detail::getenv_int("KBLD_JOBS", 1); }
inline auto is_release() -> bool { return build_mode() == L"release"; }
inline auto is_debug() -> bool { return build_mode() == L"debug"; }

inline auto env(const string &key) -> libcxx::optional<string> {
    const char *v = libcxx::getenv(_w2n(key).c_str());
    if (!v)
        return libcxx::nullopt;
    return _n2w(v);
}

// ─────────────────────────────────────────────────────────────────────────────
// Logging — always stderr, never stdout
// ─────────────────────────────────────────────────────────────────────────────

namespace log {

    inline void info(const string &msg) {
        libcxx::fprintf(stderr, "\033[1;34m[build.kro]\033[0m %s\n", _w2n(msg).c_str());
    }
    inline void ok(const string &msg) {
        libcxx::fprintf(stderr, "\033[1;32m[build.kro]\033[0m %s\n", _w2n(msg).c_str());
    }
    inline void warn(const string &msg) {
        libcxx::fprintf(stderr, "\033[1;33m[build.kro]\033[0m %s\n", _w2n(msg).c_str());
    }
    inline void error(const string &msg) {
        libcxx::fprintf(stderr, "\033[1;31m[build.kro]\033[0m %s\n", _w2n(msg).c_str());
    }

}  // namespace log

// ─────────────────────────────────────────────────────────────────────────────
// Process execution
// ─────────────────────────────────────────────────────────────────────────────

inline auto run(const vec<string> &args) -> RunResult {
    RunResult r;
    auto      cmd = _kbld_detail::argv_to_cmd(args);
    r.exit_code   = _kbld_detail::capture_all(cmd, r.stdout_str, r.stderr_str);
    r.success     = (r.exit_code == 0);
    return r;
}

inline auto run_or_fail(const vec<string> &args) -> RunResult {
    auto r = run(args);
    if (!r.success) {
        if (!r.stderr_str.is_empty())
            libcxx::fprintf(stderr, "%s", _w2n(r.stderr_str).c_str());
        log::error(string(L"command failed (exit ") + _n2w(libcxx::to_string(r.exit_code)) +
                   string(L"): ") + _n2w(_kbld_detail::argv_to_cmd(args)));
        libcxx::exit(1);
    }
    return r;
}

inline auto run_in(const string &dir, const vec<string> &args) -> RunResult {
    auto      cmd = "cd " + _w2n(dir) + " && " + _kbld_detail::argv_to_cmd(args);
    RunResult r;
    r.exit_code = _kbld_detail::capture_all(cmd, r.stdout_str, r.stderr_str);
    r.success   = (r.exit_code == 0);
    return r;
}

inline auto run_env(const vec<string> &args, const libcxx::unordered_map<string, string> &extra_env)
    -> RunResult {
    _kstr prefix;
    for (auto &[k, v] : extra_env) {
#ifdef _WIN32
        prefix += "set " + _w2n(k) + "=" + _w2n(v) + " && ";
#else
        prefix += _w2n(k) + "=" + _w2n(v) + " ";
#endif
    }
    auto      cmd = prefix + _kbld_detail::argv_to_cmd(args);
    RunResult r;
    r.exit_code = _kbld_detail::capture_all(cmd, r.stdout_str, r.stderr_str);
    r.success   = (r.exit_code == 0);
    return r;
}

inline auto which(const string &name) -> libcxx::optional<string> {
#ifdef _WIN32
    auto cmd = "where " + _w2n(name) + " 2>NUL";
#else
    auto cmd = "command -v " + _w2n(name) + " 2>/dev/null";
#endif
    FILE *fp = kbld_lib_popen(cmd.c_str(), "r");
    if (!fp)
        return libcxx::nullopt;

    char buf[1024] = {};
    libcxx::fgets(buf, sizeof(buf), fp);
    kbld_lib_pclose(fp);

    _kstr result(buf);
    while (!result.empty() &&
           (result.back() == '\n' || result.back() == '\r' || result.back() == ' '))
        result.pop_back();

    if (result.empty())
        return libcxx::nullopt;
    return _n2w(result);
}

// ─────────────────────────────────────────────────────────────────────────────
// Filesystem
// ─────────────────────────────────────────────────────────────────────────────

inline auto path_exists(const string &path) -> bool { return fs::exists(_kpath(path)); }
inline auto is_file(const string &path) -> bool { return fs::is_regular_file(_kpath(path)); }
inline auto is_dir(const string &path) -> bool { return fs::is_directory(_kpath(path)); }
inline void mkdir(const string &path) { fs::create_directories(_kpath(path)); }
inline auto read_file(const string &path) -> string {
    libcxx::ifstream ifs(_kpath(path), libcxx::ios::binary);
    if (!ifs)
        return string{};
    libcxx::ostringstream ss;
    ss << ifs.rdbuf();
    return _n2w(ss.str());
}
inline void write_file(const string &path, const string &content) {
    auto p = _kpath(path);
    fs::create_directories(p.parent_path());
    libcxx::ofstream ofs(p, libcxx::ios::binary | libcxx::ios::trunc);
    auto             narrow = _w2n(content);
    ofs.write(narrow.data(), static_cast<libcxx::streamsize>(narrow.size()));
}
inline auto join_path(const vec<string> &parts) -> string {
    if (parts.empty())
        return string{};
    fs::path p = _kpath(parts[0]);
    for (libcxx::size_t i = 1; i < parts.size(); ++i)
        p /= _kpath(parts[i]);
    return string(p.wstring().c_str());
}
inline auto abs_path(const string &path) -> string {
    if (_kpath(path).is_absolute())
        return path;
    auto root = _kbld_detail::getenv_str("KBLD_ROOT");
    if (root.is_empty())
        return string(fs::absolute(_kpath(path)).wstring().c_str());
    return string(fs::absolute(fs::path(root.raw_string()) / _kpath(path)).wstring().c_str());
}
inline auto glob(const string &pattern) -> vec<string> {
    vec<string> results;
    auto        np = _w2n(pattern);

    auto star = np.find('*');
    if (star == _kstr::npos) {
        if (fs::exists(_kpath(pattern)))
            results.push_back(pattern);
        return results;
    }

    auto base_n = np.substr(0, star);
    auto rest_n = np.substr(star);

    while (!base_n.empty() && (base_n.back() == '/' || base_n.back() == '\\'))
        base_n.pop_back();

    _kstr ext;
    auto  dot = rest_n.rfind('.');
    if (dot != _kstr::npos)
        ext = rest_n.substr(dot);

    if (base_n.empty() || !fs::exists(base_n) || !fs::is_directory(base_n))
        return results;

    libcxx::error_code ec;
    for (auto &de : fs::recursive_directory_iterator(
             base_n, fs::directory_options::skip_permission_denied, ec)) {
        if (!de.is_regular_file())
            continue;
        if (!ext.empty() && de.path().extension().string() != ext)
            continue;
        results.push_back(string(de.path().wstring().c_str()));
    }
    libcxx::sort(results.begin(), results.end());
    return results;
}

// ─────────────────────────────────────────────────────────────────────────────
// Cache
// ─────────────────────────────────────────────────────────────────────────────

namespace _cache_detail {

    inline auto cache_path() -> fs::path {
        auto bd = _kbld_detail::getenv_str("KBLD_BUILD_DIR");
        if (bd.is_empty())
            bd = string(L"build");
        return fs::path(bd.raw_string()) / ".kbld" / "cache.json";
    }

    inline auto load() -> json {
        auto p = cache_path();
        if (!fs::exists(p))
            return json::object();
        libcxx::ifstream ifs(p);
        if (!ifs)
            return json::object();
        try {
            return json::parse(ifs);
        } catch (...) { return json::object(); }
    }

    inline void save(const json &doc) {
        auto p = cache_path();
        fs::create_directories(p.parent_path());
        libcxx::ofstream ofs(p, libcxx::ios::trunc);
        ofs << doc.dump(2);
    }

}  // namespace _cache_detail

inline auto cache_get(const string &key) -> libcxx::optional<string> {
    auto nk  = _w2n(key);
    auto doc = _cache_detail::load();
    if (!doc.contains(nk))
        return libcxx::nullopt;
    return _n2w(doc[nk].get<_kstr>());
}

inline void cache_set(const string &key, const string &val) {
    auto doc       = _cache_detail::load();
    doc[_w2n(key)] = _w2n(val);

    // record timestamp for cache_stale
    auto now_ns             = libcxx::chrono::duration_cast<libcxx::chrono::nanoseconds>(
                                  libcxx::chrono::system_clock::now().time_since_epoch())
                                  .count();
    doc[_w2n(key) + "__ts"] = libcxx::to_string(now_ns);

    _cache_detail::save(doc);
}

inline auto cache_has(const string &key) -> bool {
    return _cache_detail::load().contains(_w2n(key));
}

inline auto cache_stale(const string &key, const vec<string> &paths) -> bool {
    auto doc    = _cache_detail::load();
    auto ts_key = _w2n(key) + "__ts";
    if (!doc.contains(ts_key))
        return true;

    libcxx::int64_t stored_ts = 0;
    try {
        stored_ts = libcxx::stoll(doc[ts_key].get<_kstr>());
    } catch (...) { return true; }

    for (auto &p : paths) {
        libcxx::error_code ec;
        auto               ftime = fs::last_write_time(_kpath(p), ec);
        if (ec)
            continue;

#if defined(_WIN32) && defined(_MSC_VER)
        auto file_ns =
            libcxx::chrono::duration_cast<libcxx::chrono::nanoseconds>(ftime.time_since_epoch())
                .count();
        constexpr libcxx::int64_t kEpochDiff = 11644473600LL * 1'000'000'000LL;
        libcxx::int64_t           ns         = file_ns - kEpochDiff;
#else
        auto            sctp = libcxx::chrono::file_clock::to_sys(ftime);
        libcxx::int64_t ns =
            libcxx::chrono::duration_cast<libcxx::chrono::nanoseconds>(sctp.time_since_epoch())
                .count();
#endif
        if (ns > stored_ts)
            return true;
    }
    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Target — builder pattern, serializes to JSON via narrow strings
// ─────────────────────────────────────────────────────────────────────────────

class Target {
  public:
    Target() = default;
    explicit Target(const string &name) { _name = name; }

    auto name(const string &v) -> Target & {
        _name = v;
        return *this;
    }
    auto entry(const string &v) -> Target & {
        _entry = v;
        return *this;
    }
    auto kind(const string &v) -> Target & {
        _type = v;
        return *this;
    }
    auto include(const string &v) -> Target & {
        _includes.push_back(v);
        return *this;
    }
    auto link_dir(const string &v) -> Target & {
        _links.push_back(v);
        return *this;
    }
    auto lib(const string &v) -> Target & {
        _libs.push_back(v);
        return *this;
    }
    auto dep(const string &v) -> Target & {
        _deps.push_back(v);
        return *this;
    }
    auto define(const string &v) -> Target & {
        _defines.push_back(v);
        return *this;
    }
    auto ld_flag(const string &v) -> Target & {
        _ld_flags.push_back(v);
        return *this;
    }
    auto cxx_source(const string &v) -> Target & {
        _cxx_sources.push_back(v);
        return *this;
    }
    auto passthrough(const string &v) -> Target & {
        _cxx_passthrough.push_back(v);
        return *this;
    }
    auto pre_build(const string &v) -> Target & {
        _pre_build = v;
        return *this;
    }
    auto post_build(const string &v) -> Target & {
        _post_build = v;
        return *this;
    }

    // batch setters
    auto includes(const vec<string> &v) -> Target & {
        for (auto &x : v)
            _includes.push_back(x);
        return *this;
    }
    auto link_dirs(const vec<string> &v) -> Target & {
        for (auto &x : v)
            _links.push_back(x);
        return *this;
    }
    auto libs(const vec<string> &v) -> Target & {
        for (auto &x : v)
            _libs.push_back(x);
        return *this;
    }
    auto deps(const vec<string> &v) -> Target & {
        for (auto &x : v)
            _deps.push_back(x);
        return *this;
    }
    auto defines(const vec<string> &v) -> Target & {
        for (auto &x : v)
            _defines.push_back(x);
        return *this;
    }
    auto ld_flags(const vec<string> &v) -> Target & {
        for (auto &x : v)
            _ld_flags.push_back(x);
        return *this;
    }
    auto cxx_sources(const vec<string> &v) -> Target & {
        for (auto &x : v)
            _cxx_sources.push_back(x);
        return *this;
    }
    auto passthroughs(const vec<string> &v) -> Target & {
        for (auto &x : v)
            _cxx_passthrough.push_back(x);
        return *this;
    }

    // JSON serialization — all values narrowed for nlohmann
    auto to_json() const -> json {
        auto ws = [](const string &s) { return _w2n(s); };
        auto wa = [&](const vec<string> &v) {
            json arr = json::array();
            for (auto &s : v)
                arr.push_back(_w2n(s));
            return arr;
        };
        json j;
        j["name"]            = ws(_name);
        j["entry"]           = ws(_entry);
        j["kind"]            = ws(_type);
        j["includes"]        = wa(_includes);
        j["links"]           = wa(_links);
        j["libs"]            = wa(_libs);
        j["deps"]            = wa(_deps);
        j["defines"]         = wa(_defines);
        j["ld_flags"]        = wa(_ld_flags);
        j["cxx_sources"]     = wa(_cxx_sources);
        j["cxx_passthrough"] = wa(_cxx_passthrough);
        j["pre_build"]       = ws(_pre_build);
        j["post_build"]      = ws(_post_build);
        return j;
    }

    const string &get_name() const { return _name; }

  private:
    string      _name;
    string      _entry;
    string      _type = string(L"binary");
    vec<string> _includes;
    vec<string> _links;
    vec<string> _libs;
    vec<string> _deps;
    vec<string> _defines;
    vec<string> _ld_flags;
    vec<string> _cxx_sources;
    vec<string> _cxx_passthrough;
    string      _pre_build;
    string      _post_build;
};

// ─────────────────────────────────────────────────────────────────────────────
// Project — top-level config, emits JSON to stdout on emit()
// ─────────────────────────────────────────────────────────────────────────────

class Project {
  public:
    Project()
        : _emitted(libcxx::make_shared<bool>(false)) {}

    explicit Project(const string &name)
        : _emitted(libcxx::make_shared<bool>(false)) {
        _name = name;
    }

    Project(const Project &other)            = default;  // shared_ptr copies, shares the flag
    Project &operator=(const Project &other) = default;
    Project(Project &&other)                 = default;
    Project &operator=(Project &&other)      = default;

    ~Project() {
        // only emit if we're the last holder of the flag and it hasn't been emitted
        if (_emitted.use_count() == 1 && !*_emitted && !libcxx::uncaught_exceptions())
            emit();
    }

    auto name(const string &v) -> Project & {
        _name = v;
        return *this;
    }
    auto version(const string &v) -> Project & {
        _version = v;
        return *this;
    }
    auto author(const string &v) -> Project & {
        _author = v;
        return *this;
    }
    auto license(const string &v) -> Project & {
        _license = v;
        return *this;
    }
    auto compiler(const string &v) -> Project & {
        _compiler = v;
        return *this;
    }
    auto mode(const string &v) -> Project & {
        _mode = v;
        return *this;
    }

    auto skip_dir(const string &v) -> Project & {
        _skip_dirs.push_back(v);
        return *this;
    }
    auto skip_dirs(const vec<string> &v) -> Project & {
        for (auto &x : v)
            _skip_dirs.push_back(x);
        return *this;
    }
    auto target(const Target &t) -> Project & {
        _targets.push_back(t);
        return *this;
    }
    auto target(Target &&t) -> Project & {
        _targets.push_back(libcxx::move(t));
        return *this;
    }

    void emit() const {
        if (*_emitted)
            return;
        *_emitted = true;

        auto ws = [](const string &s) { return _w2n(s); };

        json doc;
        doc["project"]["name"]    = ws(_name);
        doc["project"]["version"] = ws(_version);
        doc["project"]["author"]  = ws(_author);
        doc["project"]["license"] = ws(_license);

        doc["build"]["compiler"] = ws(_compiler);
        doc["build"]["mode"]     = ws(_mode);

        json skip = json::array();
        for (auto &s : _skip_dirs)
            skip.push_back(_w2n(s));
        doc["workspace"]["skip_dirs"] = libcxx::move(skip);

        json targets = json::array();
        for (auto &t : _targets)
            targets.push_back(t.to_json());
        doc["targets"] = libcxx::move(targets);

        libcxx::puts(doc.dump().c_str());
        libcxx::fflush(stdout);
    }

  private:
    libcxx::shared_ptr<bool> _emitted;
    string                   _name;
    string                   _version = string(L"0.0.0");
    string                   _author;
    string                   _license;
    string                   _compiler = string(L"kairo");
    string                   _mode     = string(L"release");
    vec<string>              _skip_dirs;
    vec<Target>              _targets;
};

}  // namespace kairo

// ─────────────────────────────────────────────────────────────────────────────
// kbld driver side — used by kbld's C++ internals, never by build.kro
// ─────────────────────────────────────────────────────────────────────────────

namespace kbld::script {

struct ScriptEnvVars {
    _kstr target_name;
    _kstr mode;
    _kstr triple;
    _kstr root;
    _kstr out_dir;
    _kstr build_dir;
    _kstr jobs;
    _kstr compiler;
    _kstr version;
    _kstr platform;
    _kstr arch;
};

inline void apply_env(const ScriptEnvVars &e) {
#ifdef _WIN32
#define kbld_setenv(k, v) SetEnvironmentVariableA(k, v.c_str())
#else
#define kbld_setenv(k, v) setenv(k, v.c_str(), 1)
#endif
    kbld_setenv("KBLD_TARGET", e.target_name);
    kbld_setenv("KBLD_MODE", e.mode);
    kbld_setenv("KBLD_TRIPLE", e.triple);
    kbld_setenv("KBLD_ROOT", e.root);
    kbld_setenv("KBLD_OUT_DIR", e.out_dir);
    kbld_setenv("KBLD_BUILD_DIR", e.build_dir);
    kbld_setenv("KBLD_JOBS", e.jobs);
    kbld_setenv("KBLD_COMPILER", e.compiler);
    kbld_setenv("KBLD_VERSION", e.version);
    kbld_setenv("KBLD_PLATFORM", e.platform);
    kbld_setenv("KBLD_ARCH", e.arch);
#undef kbld_setenv
}

inline auto script_is_stale(const fs::path &src, const fs::path &bin) -> bool {
    if (!fs::exists(bin))
        return true;
    std::error_code ec;
    auto            src_t = fs::last_write_time(src, ec);
    if (ec)
        return true;
    auto bin_t = fs::last_write_time(bin, ec);
    if (ec)
        return true;
    return src_t > bin_t;
}

inline auto compile_script(const _kstr      &kairo,
                           const fs::path   &script_src,
                           const fs::path   &script_bin,
                           const vec<_kstr> &includes,
                           const fs::path   &kbld_bin,
                           bool              verbose) -> std::pair<int, _kstr> {
    fs::create_directories(script_bin.parent_path());
    auto lib_hh = kbld_bin.parent_path().parent_path() / "include" / "kbld.hh";

    _kstr cmd = kairo + " " + script_src.string() + " -o" + script_bin.string();
    for (auto &inc : includes)
        cmd += " -I" + inc;
    cmd += " --release";
    if (verbose)
        cmd += " --verbose";

    cmd += " -- -include " + lib_hh.string();

    // capture into wide then convert back for return
    kairo::string out_w, err_w;
    int           rc = kairo::_kbld_detail::capture_all(cmd, out_w, err_w);
    return {rc, _w2n(out_w) + _w2n(err_w)};
}

// Run the script binary, capturing only stdout (JSON blob).
// Script's stderr goes live to the terminal via popen without redirect.
inline auto run_script(const fs::path &bin, const ScriptEnvVars &env_vars)
    -> std::pair<int, _kstr> {
    apply_env(env_vars);

    FILE *fp = kbld_lib_popen(bin.string().c_str(), "r");
    if (!fp)
        return {-1, {}};

    _kstr out;
    char  buf[4096];
    while (auto n = std::fread(buf, 1, sizeof(buf), fp))
        out.append(buf, n);

    int status = kbld_lib_pclose(fp);
    int rc     = status;
#ifndef _WIN32
    if (WIFEXITED(status))
        rc = WEXITSTATUS(status);
#endif
    return {rc, out};
}

// Deserialize the JSON blob into kbld's Config/Target structs.
// Templated to avoid circular dependency with types.hpp.
template <typename T_Config, typename T_Target>
inline auto parse_script_output(const _kstr &raw_json, T_Config &cfg, _kstr &error_msg) -> bool {
    if (raw_json.empty()) {
        error_msg = "build.kro produced no output — did you call Project::emit()?";
        return false;
    }

    json doc;
    try {
        doc = json::parse(raw_json);
    } catch (const std::exception &e) {
        error_msg = _kstr("failed to parse build.kro JSON: ") + e.what();
        return false;
    }

    auto str_or = [&](const json &j, const char *key, const _kstr &def) -> _kstr {
        if (j.contains(key) && j[key].is_string())
            return j[key].get<_kstr>();
        return def;
    };
    auto str_arr = [&](const json &j, const char *key) -> vec<_kstr> {
        vec<_kstr> r;
        if (!j.contains(key) || !j[key].is_array())
            return r;
        for (auto &e : j[key])
            if (e.is_string())
                r.push_back(e.get<_kstr>());
        return r;
    };
    // kbld's Config fields are std::string-based (C++ side), so no conversion needed here.
    // The JSON is already narrow throughout.

    if (doc.contains("project") && doc["project"].is_object()) {
        auto &p             = doc["project"];
        cfg.project.name    = str_or(p, "name", "");
        cfg.project.version = str_or(p, "version", "0.0.0");
        cfg.project.author  = str_or(p, "author", "");
        cfg.project.license = str_or(p, "license", "");
    }

    if (doc.contains("build") && doc["build"].is_object()) {
        auto &b            = doc["build"];
        cfg.build.compiler = str_or(b, "compiler", "kairo");
        auto mode_str      = str_or(b, "mode", "release");
        cfg.build.mode     = (mode_str == "debug") ? decltype(cfg.build.mode)::Debug
                                                   : decltype(cfg.build.mode)::Release;
    }

    if (doc.contains("workspace") && doc["workspace"].is_object()) {
        auto raw = str_arr(doc["workspace"], "skip_dirs");
        cfg.workspace.skip_dirs.clear();
        for (auto &s : raw)
            cfg.workspace.skip_dirs.push_back(s);
    }

    if (!doc.contains("targets") || !doc["targets"].is_array()) {
        error_msg = "build.kro JSON has no 'targets' array";
        return false;
    }

    cfg.targets.clear();
    for (auto &jt : doc["targets"]) {
        if (!jt.is_object())
            continue;

        T_Target t;
        t.name       = str_or(jt, "name", "");
        t.entry      = str_or(jt, "entry", "");
        t.pre_build  = str_or(jt, "pre_build", "");
        t.post_build = str_or(jt, "post_build", "");

        auto fill = [&](vec<_kstr> &dst, const char *key) {
            auto v = str_arr(jt, key);
            dst.insert(dst.end(), v.begin(), v.end());
        };
        fill(t.includes, "includes");
        fill(t.links, "links");
        fill(t.libs, "libs");
        fill(t.deps, "deps");
        fill(t.defines, "defines");
        fill(t.ld_flags, "ld_flags");
        fill(t.cxx_sources, "cxx_sources");
        fill(t.cxx_passthrough, "cxx_passthrough");

        auto type_str = str_or(jt, "kind", "binary");
        if (type_str == "static")
            t.kind = decltype(t.kind)::Static;
        else if (type_str == "shared")
            t.kind = decltype(t.kind)::Shared;
        else
            t.kind = decltype(t.kind)::Binary;

        if (t.name.empty()) {
            error_msg = "target missing 'name'";
            return false;
        }
        if (t.entry.empty()) {
            error_msg = "target '" + t.name + "' missing 'entry'";
            return false;
        }

        cfg.targets.push_back(std::move(t));
    }

    if (cfg.targets.empty()) {
        error_msg = "build.kro emitted no targets";
        return false;
    }
    return true;
}

template <typename T_Config, typename T_Target>
inline auto run_build_script(const fs::path &script_src,
                             const fs::path &root,
                             const _kstr    &kairo,
                             const _kstr    &kbld_ver,
                             int             jobs,
                             bool            verbose,
                             T_Config       &cfg) -> int {
    auto build_dir  = root / "build";
    auto script_bin = build_dir / ".kbld" / "build_script";

    fs::path kbld_bin;
#if defined(__linux__)
    {
        char    buf[4096] = {};
        ssize_t n         = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
        if (n > 0)
            kbld_bin = fs::path(buf);
    }
#elif defined(__APPLE__)
    {
        char     buf[4096] = {};
        uint32_t sz        = sizeof(buf);
        if (_NSGetExecutablePath(buf, &sz) == 0)
            kbld_bin = fs::path(buf);
    }
#elif defined(_WIN32)
    {
        char buf[MAX_PATH] = {};
        if (GetModuleFileNameA(nullptr, buf, MAX_PATH))
            kbld_bin = fs::path(buf);
    }
#endif

    if (script_is_stale(script_src, script_bin)) {
        if (verbose)
            std::fprintf(
                stderr, "\033[1;36m[kbld]\033[0m compiling %s\n", script_src.string().c_str());
        auto [rc, output] = compile_script(kairo, script_src, script_bin, {}, kbld_bin, verbose);
        if (rc != 0) {
            std::fprintf(stderr, "\033[1;31m[kbld]\033[0m build.kro compilation failed\n");
            if (!output.empty())
                std::fprintf(stderr, "%s", output.c_str());
            return rc;
        }
    }

    ScriptEnvVars e;
    e.root      = fs::absolute(root).string();
    e.build_dir = fs::absolute(build_dir).string();
    e.out_dir   = (build_dir / "bin").string();
    e.jobs      = std::to_string(jobs > 0 ? jobs : 1);
    e.compiler  = kairo;
    e.version   = kbld_ver;
    e.mode      = "release";

#if defined(__x86_64__) || defined(_M_X64)
    e.arch = "x86_64";
#elif defined(__aarch64__) || defined(_M_ARM64)
    e.arch = "arm64";
#elif defined(__wasm__)
    e.arch = "wasm32";
#else
    e.arch = "unknown";
#endif

#if defined(_WIN32)
    e.platform = "windows";
    e.triple   = e.arch + "-windows-msvc";
#elif defined(__APPLE__)
    e.platform = "macos";
    e.triple   = e.arch + "-apple-macosx";
#else
    e.platform = "linux";
    e.triple   = e.arch + "-linux-gnu";
#endif

    auto [rc, raw_json] = run_script(script_bin, e);
    if (rc != 0) {
        std::fprintf(stderr, "\033[1;31m[kbld]\033[0m build.kro exited with code %d\n", rc);
        return rc;
    }

    _kstr error_msg;
    if (!parse_script_output<T_Config, T_Target>(raw_json, cfg, error_msg)) {
        std::fprintf(stderr, "\033[1;31m[kbld]\033[0m %s\n", error_msg.c_str());
        return 1;
    }
    return 0;
}

}  // namespace kbld::script