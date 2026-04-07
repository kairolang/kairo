/// kbld.cc — build tool for Kairo projects
/// compile: clang++ -std=c++23 -O2 -o kbld kbld.cc
///          (needs nlohmann/json.hpp and lib.hh on include path)

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <format>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <mutex>
#include <optional>
#include <semaphore>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#define kbld_popen _popen
#define kbld_pclose _pclose
#else
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#define kbld_popen popen
#define kbld_pclose pclose
#endif

#include "include/source/Casting.tpp"
#include "include/source/Finally.tpp"
#include "include/source/PanicFrame.tpp"
#include "include/source/PanicFrameContext.tpp"
#include "include/source/Questionable.tpp"
#include "include/source/Slice.tpp"
#include "include/source/String.tpp"
#include "include/source/i128.tpp"
#include "include/source/u128.tpp"
#include "kbld.hh"
#include "nlohmann/json.hpp"

namespace fs = std::filesystem;
using json   = nlohmann::json;

// ─────────────────────────────────────────────────────────────────────────────
// Narrow string helpers (kbld.cc is pure C++, no kairo strings here)
// ─────────────────────────────────────────────────────────────────────────────

template <typename... Args>
static auto fmt(std::string_view f, Args &&...args) -> std::string {
    return std::vformat(f, std::make_format_args(args...));
}

static void puts_out(const std::string &s) { std::fwrite(s.data(), 1, s.size(), stdout); }
static void puts_err(const std::string &s) { std::fwrite(s.data(), 1, s.size(), stderr); }
static void putln(const std::string &s) {
    std::fwrite(s.data(), 1, s.size(), stdout);
    std::fputc('\n', stdout);
}

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

enum class BuildMode { Debug, Release };
enum class TargetType { Binary, Static, Shared };
enum class Command { Build, Clean, Test, Deps, Index, Install };

static auto to_string(BuildMode m) -> std::string {
    return m == BuildMode::Debug ? "debug" : "release";
}

static auto parse_target_type(std::string_view s) -> TargetType {
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
    TargetType               kind = TargetType::Binary;
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

struct CLIOptions {
    Command                  command = Command::Build;
    std::vector<std::string> positional;
    std::optional<BuildMode> mode_override;
    bool                     verbose        = false;
    int                      jobs           = 0;
    bool                     dry_run        = false;
    bool                     emit_ir        = false;
    bool                     emit_ast       = false;
    bool                     keep_going     = false;
    bool                     perf           = false;
    bool                     compile_only   = false;
    std::string              install_prefix = "/usr/local";
};

// ─────────────────────────────────────────────────────────────────────────────
// Platform helpers
// ─────────────────────────────────────────────────────────────────────────────

static auto is_windows() -> bool {
#ifdef _WIN32
    return true;
#else
    return false;
#endif
}

static auto get_triple() -> std::string {
#if defined(__x86_64__) || defined(_M_X64)
    const char *arch = "x86_64";
#elif defined(__i386__) || defined(_M_IX86)
    const char *arch = "i686";
#elif defined(__aarch64__) || defined(_M_ARM64)
    const char *arch = "aarch64";
#elif defined(__arm__) || defined(_M_ARM)
#if defined(__ARM_ARCH_7__) || defined(__ARM_ARCH_7A__)
    const char *arch = "armv7";
#else
    const char *arch = "arm";
#endif
#elif defined(__riscv)
#if __riscv_xlen == 64
    const char *arch = "riscv64";
#else
    const char *arch = "riscv32";
#endif
#elif defined(__wasm64__)
    const char *arch = "wasm64";
#elif defined(__wasm32__) || defined(__wasm__)
    const char *arch = "wasm32";
#elif defined(__powerpc64__)
#if defined(__LITTLE_ENDIAN__)
    const char *arch = "powerpc64le";
#else
    const char *arch = "powerpc64";
#endif
#elif defined(__powerpc__)
    const char *arch = "powerpc";
#elif defined(__mips64)
    const char *arch = "mips64";
#elif defined(__mips__)
    const char *arch = "mips";
#elif defined(__s390x__)
    const char *arch = "s390x";
#elif defined(__loongarch64)
    const char *arch = "loongarch64";
#elif defined(__sparc_v9__) || defined(__sparcv9)
    const char *arch = "sparcv9";
#elif defined(__sparc__)
    const char *arch = "sparc";
#else
    const char *arch = "unknown";
#endif

#if defined(_WIN32)
    return std::string(arch) + "-pc-windows-msvc";
#elif defined(__APPLE__)
    return std::string(arch) + "-apple-macosx";
#elif defined(__ANDROID__)
    return std::string(arch) + "-linux-android";
#elif defined(__wasi__)
    return std::string(arch) + "-wasi";
#elif defined(__FreeBSD__)
    return std::string(arch) + "-freebsd";
#elif defined(__NetBSD__)
    return std::string(arch) + "-netbsd";
#elif defined(__OpenBSD__)
    return std::string(arch) + "-openbsd";
#elif defined(__Fuchsia__)
    return std::string(arch) + "-fuchsia";
#elif defined(__linux__)
#if defined(__arm__) && defined(__ARM_EABI__)
#if defined(__ARM_PCS_VFP)
    return std::string(arch) + "-linux-gnueabihf";
#else
    return std::string(arch) + "-linux-gnueabi";
#endif
#elif defined(__MUSL__)
    return std::string(arch) + "-linux-musl";
#else
    return std::string(arch) + "-linux-gnu";
#endif
#else
    return std::string(arch) + "-unknown-unknown";
#endif
}

static auto self_exe() -> fs::path {
#if defined(__linux__)
    char    buf[4096] = {};
    ssize_t n         = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    return n > 0 ? fs::path(buf) : fs::path{};
#elif defined(__APPLE__)
    char     buf[4096] = {};
    uint32_t sz        = sizeof(buf);
    return _NSGetExecutablePath(buf, &sz) == 0 ? fs::path(buf) : fs::path{};
#elif defined(_WIN32)
    char buf[MAX_PATH] = {};
    GetModuleFileNameA(nullptr, buf, MAX_PATH);
    return fs::path(buf);
#else
    return {};
#endif
}

static auto terminal_width() -> int {
#ifdef _WIN32
    return 80;
#else
    struct winsize w;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 && w.ws_col > 0)
        return w.ws_col;
    const char *cols = std::getenv("COLUMNS");
    if (cols) {
        int c = std::atoi(cols);
        if (c > 0)
            return c;
    }
    return 80;
#endif
}

// ─────────────────────────────────────────────────────────────────────────────
// Find sibling kairo binary
// kbld lives next to kairo — resolve own exe path, look there first.
// ─────────────────────────────────────────────────────────────────────────────

static auto find_kairo(const std::string &configured) -> std::string {
    // 1. Try sibling of kbld's own executable
#if defined(__linux__)
    {
        char    buf[4096] = {};
        ssize_t n         = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
        if (n > 0) {
            auto sibling = fs::path(buf).parent_path() / "kairo";
            if (fs::exists(sibling))
                return sibling.string();
        }
    }
#elif defined(__APPLE__)
    {
        char     buf[4096] = {};
        uint32_t sz        = sizeof(buf);
        if (_NSGetExecutablePath(buf, &sz) == 0) {
            auto sibling = fs::path(buf).parent_path() / "kairo";
            if (fs::exists(sibling))
                return sibling.string();
        }
    }
#elif defined(_WIN32)
    {
        char buf[MAX_PATH] = {};
        if (GetModuleFileNameA(nullptr, buf, MAX_PATH)) {
            auto sibling = fs::path(buf).parent_path() / "kairo.exe";
            if (fs::exists(sibling))
                return sibling.string();
        }
    }
#endif
    // 2. Fall back to whatever build.kro specified (hits PATH)
    return configured;
}

// ─────────────────────────────────────────────────────────────────────────────
// Process helpers
// ─────────────────────────────────────────────────────────────────────────────

static auto run_command(const std::string &cmd) -> int {
    int status = std::system(cmd.c_str());
#ifndef _WIN32
    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    return status;
#else
    return status;
#endif
}

static auto run_capture_all(const std::string &cmd, std::string &out, std::string &err) -> int {
    out.clear();
    err.clear();
    auto        tmp  = fs::temp_directory_path() / "kbld_stderr.tmp";
    std::string full = cmd + " 2>" + tmp.string();
    FILE       *fp   = kbld_popen(full.c_str(), "r");
    if (!fp)
        return -1;
    char buf[4096];
    while (auto n = std::fread(buf, 1, sizeof(buf), fp))
        out.append(buf, n);
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

static auto read_file(const fs::path &p) -> std::string {
    std::ifstream ifs(p, std::ios::binary);
    if (!ifs)
        return {};
    std::ostringstream ss;
    ss << ifs.rdbuf();
    return ss.str();
}

static auto write_file(const fs::path &p, std::string_view content) -> bool {
    fs::create_directories(p.parent_path());
    std::ofstream ofs(p, std::ios::binary | std::ios::trunc);
    if (!ofs)
        return false;
    ofs.write(content.data(), static_cast<std::streamsize>(content.size()));
    return ofs.good();
}

static auto iso8601_now() -> std::string {
    auto    now = std::chrono::system_clock::now();
    auto    t   = std::chrono::system_clock::to_time_t(now);
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

// ─────────────────────────────────────────────────────────────────────────────
// Logging
// ─────────────────────────────────────────────────────────────────────────────

namespace _I_log {
static std::mutex g_mtx;

static void info(std::string_view msg) {
    std::lock_guard lk(g_mtx);
    auto            s = fmt("\033[1;32m[kbld]\033[0m {}\n", std::string(msg));
    std::fwrite(s.data(), 1, s.size(), stderr);
}
static void warn(std::string_view msg) {
    std::lock_guard lk(g_mtx);
    auto            s = fmt("\033[1;33m[kbld]\033[0m {}\n", std::string(msg));
    std::fwrite(s.data(), 1, s.size(), stderr);
}
static void error(std::string_view msg) {
    std::lock_guard lk(g_mtx);
    auto            s = fmt("\033[1;31m[kbld]\033[0m {}\n", std::string(msg));
    std::fwrite(s.data(), 1, s.size(), stderr);
}
static void verbose(std::string_view msg, bool enabled) {
    if (!enabled)
        return;
    std::lock_guard lk(g_mtx);
    auto            s = fmt("\033[1;36m[kbld]\033[0m {}\n", std::string(msg));
    std::fwrite(s.data(), 1, s.size(), stderr);
}
}  // namespace _I_log

// ─────────────────────────────────────────────────────────────────────────────
// CLI parsing
// ─────────────────────────────────────────────────────────────────────────────

static auto parse_cli(int argc, char *argv[]) -> CLIOptions {
    CLIOptions opts;
    if (argc < 2)
        return opts;

    int              i     = 1;
    std::string_view first = argv[1];

    if (first == "build") {
        opts.command = Command::Build;
        ++i;
    } else if (first == "clean") {
        opts.command = Command::Clean;
        ++i;
    } else if (first == "test") {
        opts.command = Command::Test;
        ++i;
    } else if (first == "deps") {
        opts.command = Command::Deps;
        ++i;
    } else if (first == "index") {
        opts.command = Command::Index;
        ++i;
    } else if (first == "install") {
        opts.command = Command::Install;
        ++i;
    }
    // anything else: default Build, don't consume

    for (; i < argc; ++i) {
        std::string_view arg = argv[i];
        if (arg == "--debug")
            opts.mode_override = BuildMode::Debug;
        else if (arg == "--release")
            opts.mode_override = BuildMode::Release;
        else if (arg == "--verbose")
            opts.verbose = true;
        else if (arg == "--dry-run")
            opts.dry_run = true;
        else if (arg == "--emit-ir")
            opts.emit_ir = true;
        else if (arg == "--emit-ast")
            opts.emit_ast = true;
        else if (arg == "--keep-going")
            opts.keep_going = true;
        else if (arg == "--perf")
            opts.perf = true;
        else if (arg == "--compile-only")
            opts.compile_only = true;
        else if (arg == "--jobs" || arg == "-j") {
            if (++i >= argc)
                throw std::runtime_error("--jobs requires a value");
            opts.jobs = std::atoi(argv[i]);
            if (opts.jobs <= 0)
                throw std::runtime_error("--jobs must be positive");
        } else if (arg.starts_with("--jobs="))
            opts.jobs = std::atoi(std::string(arg.substr(7)).c_str());
        else if (arg.starts_with("-j"))
            opts.jobs = std::atoi(std::string(arg.substr(2)).c_str());
        else if (arg == "--help" || arg == "-h") {
            std::fputs("kbld — build tool for Kairo projects\n"
                       "\n"
                       "Usage: kbld [command] [options]\n"
                       "\n"
                       "Commands:\n"
                       "  build  [targets...]    Build all or specified targets (default)\n"
                       "  clean  [targets...]    Remove build artifacts\n"
                       "  test   <file.kro>      Compile and run a test file\n"
                       "  deps   <file.kro>      Print dependency tree for a file\n"
                       "  index                  Regenerate compile_commands.json only\n"
                       "  install [prefix]       Copy binaries to prefix/bin\n"
                       "\n"
                       "Options:\n"
                       "  --debug                Force debug mode\n"
                       "  --release              Force release mode\n"
                       "  --verbose              Verbose output\n"
                       "  --jobs <n>             Max parallel jobs\n"
                       "  --dry-run              Print commands, don't execute\n"
                       "  --emit-ir              Pass --emit-ir to kairo\n"
                       "  --emit-ast             Pass --emit-ast to kairo\n"
                       "  --keep-going           Don't stop on first failure\n"
                       "  --perf                 (test) compile in release mode\n"
                       "  --compile-only         (test) compile but don't run\n",
                       stdout);
            std::exit(0);
        } else if (!arg.starts_with("-"))
            opts.positional.emplace_back(arg);
        else
            _I_log::warn(fmt("unknown option: {}", std::string(arg)));
    }

    if (opts.command == Command::Install && !opts.positional.empty()) {
        opts.install_prefix = opts.positional[0];
        opts.positional.clear();
    }

    return opts;
}

// ─────────────────────────────────────────────────────────────────────────────
// build.kro → Config via kbld::script
// ─────────────────────────────────────────────────────────────────────────────

static auto load_config(const fs::path    &script_src,
                        const fs::path    &root,
                        const std::string &kairo_bin,
                        const CLIOptions  &opts) -> Config {
    Config      cfg;
    std::string err;

    int rc = kbld::script::run_build_script<Config, Target>(script_src,
                                                            root,
                                                            kairo_bin,
                                                            "0.2.0",  // kbld version string
                                                            opts.jobs,
                                                            opts.verbose,
                                                            cfg);

    if (rc != 0)
        throw std::runtime_error("build.kro failed");

    return cfg;
}

// ─────────────────────────────────────────────────────────────────────────────
// compile_commands.json
// ─────────────────────────────────────────────────────────────────────────────

static auto generate_compile_commands(const Config &cfg, const fs::path &root) -> bool {
    json entries = json::array();
    auto cwd     = fs::absolute(root).string();

    std::set<fs::path> entry_paths;
    for (auto &t : cfg.targets)
        entry_paths.insert(fs::absolute(t.entry));

    // build.kro is always excluded from normal kro scanning — gets its own entry
    auto build_kro_abs = fs::absolute(root / "build.kro");

    const auto &first = cfg.targets.front();

    static const std::set<std::string> cxx_exts = {
        ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp"};

    auto should_skip = [&](const fs::path &p) {
        auto rel = fs::relative(p, root);
        auto it  = rel.begin();
        if (it != rel.end() && *it == "build")
            return true;
        for (auto &skip : cfg.workspace.skip_dirs) {
            it = rel.begin();
            if (it != rel.end() && *it == skip)
                return true;
        }
        return false;
    };

    std::vector<fs::path> cxx_files, kro_non_entry;
    std::error_code       ec;
    for (auto &de : fs::recursive_directory_iterator(
             root, fs::directory_options::skip_permission_denied, ec)) {
        if (!de.is_regular_file())
            continue;
        if (should_skip(de.path()))
            continue;
        auto abs = fs::absolute(de.path());
        auto ext = de.path().extension().string();
        if (cxx_exts.contains(ext)) {
            cxx_files.push_back(abs);
        } else if (ext == ".kro" && !entry_paths.contains(abs) &&
                   abs != build_kro_abs) {  // exclude build.kro from non-entry scan
            kro_non_entry.push_back(abs);
        }
    }

    // C++ files — full clang++ invocation
    for (auto &f : cxx_files) {
        json args = json::array();
        if (is_windows()) {
            args.push_back("clang-cl.exe");
        } else {
            args.push_back("clang++");
            args.push_back("-lc++");
            args.push_back("-lc++abi");
            args.push_back("-stdlib=libc++");
        }
        args.push_back("-std=c++23");
        args.push_back("-O3");
        args.push_back("-w");
        for (auto &inc : first.includes)
            args.push_back("-I" + inc);
        for (auto &def : first.defines)
            args.push_back("-D" + def);
        for (auto &lf : first.cxx_passthrough)
            args.push_back(lf);
        args.push_back(f.string());
        json e;
        e["directory"] = cwd;
        e["arguments"] = std::move(args);
        e["file"]      = fs::relative(f, root).string();
        entries.push_back(std::move(e));
    }

    // Non-entry .kro files — includes only
    for (auto &f : kro_non_entry) {
        json args = json::array();
        for (auto &inc : first.includes)
            args.push_back("-I" + inc);

        args.push_back("--");
        for (auto &def : first.defines)
            args.push_back("-D" + def);
        for (auto &lf : first.ld_flags)
            args.push_back(lf);
        for (auto &src : first.cxx_sources)
            args.push_back(src);
        for (auto &pt : first.cxx_passthrough)
            args.push_back(pt);

        json e;
        e["directory"] = cwd;
        e["arguments"] = std::move(args);
        e["file"]      = f.string();
        entries.push_back(std::move(e));
    }

    // Target entry .kro files — each target's own includes
    for (auto &t : cfg.targets) {
        json args = json::array();
        for (auto &inc : t.includes)
            args.push_back("-I" + inc);

        // collect passthrough exactly as build_command does
        std::vector<std::string> passthrough;
        for (auto &def : t.defines)
            passthrough.push_back("-D" + def);
        for (auto &lf : t.ld_flags)
            passthrough.push_back(lf);
        for (auto &src : t.cxx_sources)
            passthrough.push_back(src);
        for (auto &pt : t.cxx_passthrough)
            passthrough.push_back(pt);

        if (!passthrough.empty()) {
            args.push_back("--");
            for (auto &pt : passthrough)
                args.push_back(pt);
        }

        json e;
        e["directory"] = cwd;
        e["arguments"] = std::move(args);
        e["file"]      = fs::absolute(t.entry).string();
        entries.push_back(std::move(e));
    }

    // build.kro — always gets its own entry with -include kbld_lib.hh
    // path is deterministic: <self_exe>/../include/kbld_lib.hh
    if (fs::exists(build_kro_abs)) {
        auto kbld_bin = self_exe();  // the static helper from earlier
        auto lib_hh   = kbld_bin.parent_path().parent_path() / "include" / "kbld.hh";

        json args = json::array();
        args.push_back("--");
        args.push_back("-include");
        args.push_back(lib_hh.string());
        for (auto &inc : first.includes)
            args.push_back("-I" + inc);

        json e;
        e["directory"] = cwd;
        e["arguments"] = std::move(args);
        e["file"]      = build_kro_abs.string();
        entries.push_back(std::move(e));
    }

    auto          out_path = root / "compile_commands.json";
    std::ofstream ofs(out_path, std::ios::trunc);
    if (!ofs) {
        _I_log::warn("failed to write compile_commands.json");
        return false;
    }
    ofs << entries.dump(2) << '\n';
    return ofs.good();
}

// ─────────────────────────────────────────────────────────────────────────────
// Binary metadata embedding
// ─────────────────────────────────────────────────────────────────────────────

static void
generate_metadata(const ProjectConfig &proj, const Target &target, const fs::path &gen_dir) {
    fs::create_directories(gen_dir);
    auto ts = iso8601_now();

    if (is_windows()) {
        auto rc_path = gen_dir / (target.name + ".rc");
        auto content = fmt("#include <winver.h>\n"
                           "VS_VERSION_INFO VERSIONINFO\n"
                           "FILEVERSION 1,0,0,0\n"
                           "PRODUCTVERSION 1,0,0,0\n"
                           "BEGIN\n"
                           "  BLOCK \"StringFileInfo\"\n"
                           "  BEGIN\n"
                           "    BLOCK \"040904E4\"\n"
                           "    BEGIN\n"
                           "      VALUE \"ProductName\",    \"{}\"\n"
                           "      VALUE \"ProductVersion\", \"{}\"\n"
                           "      VALUE \"CompanyName\",    \"{}\"\n"
                           "      VALUE \"LegalCopyright\", \"{}\"\n"
                           "      VALUE \"FileDescription\",\"{}\"\n"
                           "    END\n"
                           "  END\n"
                           "  BLOCK \"VarFileInfo\"\n"
                           "  BEGIN\n"
                           "    VALUE \"Translation\", 0x0409, 1252\n"
                           "  END\n"
                           "END\n",
                           proj.name,
                           proj.version,
                           proj.author,
                           proj.license,
                           target.name);
        write_file(rc_path, content);
        return;
    }

    auto cpp_path = gen_dir / (target.name + "_meta.cpp");
    auto meta     = fmt("name={}|version={}|author={}|license={}|built={}",
                        proj.name,
                        proj.version,
                        proj.author,
                        proj.license,
                        ts);
#if defined(__APPLE__)
    auto content = fmt("// auto-generated by kbld\n"
                       "__attribute__((section(\"__DATA,__build_meta\"), used))\n"
                       "static const char kBuildMeta[] = \"{}\";\n",
                       meta);
#else
    auto content = fmt("// auto-generated by kbld\n"
                       "__attribute__((section(\".build_meta\"), used))\n"
                       "static const char kBuildMeta[] = \"{}\";\n",
                       meta);
#endif
    write_file(cpp_path, content);
}

// ─────────────────────────────────────────────────────────────────────────────
// Build graph — topo sort + wave grouping
// ─────────────────────────────────────────────────────────────────────────────

static auto topo_sort(const std::vector<Target> &targets) -> std::vector<std::string> {

    std::unordered_map<std::string, std::vector<std::string>> adj;
    std::unordered_map<std::string, int>                      indegree;

    for (auto &t : targets) {
        if (!indegree.contains(t.name))
            indegree[t.name] = 0;
        for (auto &d : t.deps) {
            adj[d].push_back(t.name);
            indegree[t.name]++;
        }
    }

    std::vector<std::string> order;
    std::vector<std::string> queue;
    for (auto &[name, deg] : indegree)
        if (deg == 0)
            queue.push_back(name);

    while (!queue.empty()) {
        auto n = queue.back();
        queue.pop_back();
        order.push_back(n);
        for (auto &next : adj[n]) {
            if (--indegree[next] == 0)
                queue.push_back(next);
        }
    }

    if (order.size() != targets.size()) {
        // cycle — find and print it
        std::string cycle;
        for (auto &[name, deg] : indegree)
            if (deg > 0)
                cycle += name + " ";
        throw std::runtime_error("dependency cycle detected: " + cycle);
    }
    return order;
}

static auto build_waves(const std::vector<Target> &targets, const std::vector<std::string> &order)
    -> std::vector<std::vector<std::string>> {

    std::unordered_map<std::string, int>            depth;
    std::unordered_map<std::string, const Target *> by_name;
    for (auto &t : targets)
        by_name[t.name] = &t;

    for (auto &name : order) {
        int d = 0;
        for (auto &dep : by_name[name]->deps)
            d = std::max(d, depth[dep] + 1);
        depth[name] = d;
    }

    int max_depth = 0;
    for (auto &[_, d] : depth)
        max_depth = std::max(max_depth, d);

    std::vector<std::vector<std::string>> waves(max_depth + 1);
    for (auto &name : order)
        waves[depth[name]].push_back(name);

    return waves;
}

// ─────────────────────────────────────────────────────────────────────────────
// Build command construction
// ─────────────────────────────────────────────────────────────────────────────

static auto build_command(const Target      &target,
                          const Config      &cfg,
                          BuildMode          mode,
                          const fs::path    &output_dir,
                          const fs::path    &gen_dir,
                          const CLIOptions  &opts,
                          const std::string &kairo) -> std::string {
    std::string cmd = kairo;
    cmd += " " + target.entry;

    auto out_bin = output_dir / "bin" / target.name;
    cmd += " -o" + out_bin.string();

    for (auto &inc : target.includes)
        cmd += " -I" + inc;
    for (auto &link : target.links)
        cmd += " -L" + link;
    for (auto &lib : target.libs)
        cmd += " -l" + lib;

    cmd += (mode == BuildMode::Debug) ? " --debug" : " --release";
    if (opts.verbose)
        cmd += " --verbose";
    if (opts.emit_ir)
        cmd += " --emit-ir";
    if (opts.emit_ast)
        cmd += " --emit-ast";

    // collect passthrough items
    std::vector<std::string> passthrough;
    for (auto &def : target.defines)
        passthrough.push_back("-D" + def);
    for (auto &lf : target.ld_flags)
        passthrough.push_back(lf);
    for (auto &src : target.cxx_sources)
        passthrough.push_back(src);

    // auto-inject metadata
    auto meta_file = gen_dir / (target.name + "_meta.cpp");
    if (fs::exists(meta_file))
        passthrough.push_back(meta_file.string());

    // windows: inject .res if it was compiled
    if (is_windows()) {
        auto res_file = gen_dir / (target.name + ".res");
        if (fs::exists(res_file))
            passthrough.push_back(res_file.string());
    }

    for (auto &pt : target.cxx_passthrough)
        passthrough.push_back(pt);

    if (!passthrough.empty()) {
        cmd += " --";
        for (auto &pt : passthrough)
            cmd += " " + pt;
    }

    return cmd;
}

// ─────────────────────────────────────────────────────────────────────────────
// Build single target
// ─────────────────────────────────────────────────────────────────────────────

static auto build_target(const Target      &target,
                         const Config      &cfg,
                         BuildMode          mode,
                         const CLIOptions  &opts,
                         const std::string &kairo,
                         std::mutex        &log_mtx) -> int {
    auto triple     = get_triple();
    auto mode_str   = to_string(mode);
    auto output_dir = fs::path("build") / triple / mode_str;
    auto gen_dir    = fs::path("build") / ".gen";

    fs::create_directories(output_dir / "bin");
    fs::create_directories(gen_dir);

    if (!fs::exists(target.entry)) {
        _I_log::error(fmt("entry file '{}' not found for target '{}'", target.entry, target.name));
        return 1;
    }

    if (!target.pre_build.empty()) {
        _I_log::info(fmt("'{}' pre-build: {}", target.name, target.pre_build));
        if (!opts.dry_run) {
            int rc = run_command(target.pre_build);
            if (rc != 0) {
                _I_log::error(fmt("pre-build hook failed for '{}' (exit {})", target.name, rc));
                return rc;
            }
        }
    }

    generate_metadata(cfg.project, target, gen_dir);

#ifdef _WIN32
    // compile .rc → .res via rc.exe if present
    {
        auto rc_file  = gen_dir / (target.name + ".rc");
        auto res_file = gen_dir / (target.name + ".res");
        if (fs::exists(rc_file) && !opts.dry_run) {
            std::string rc_cmd =
                "rc.exe /nologo /fo\"" + res_file.string() + "\" \"" + rc_file.string() + "\"";
            std::string rc_out;
            std::string rc_err;
            int         rc = run_capture_all(rc_cmd, rc_out, rc_err);
            if (rc != 0)
                _I_log::warn(fmt("rc.exe failed for '{}', continuing", target.name));
        }
    }
#endif

    auto cmd = build_command(target, cfg, mode, output_dir, gen_dir, opts, kairo);

    _I_log::info(fmt("building '{}'", target.name));
    if (opts.verbose || opts.dry_run)
        _I_log::info(fmt("  {}", cmd));

    if (opts.dry_run)
        return 0;

    std::string out, err;
    int         rc = run_capture_all(cmd, out, err);

    // always print kairo's stdout — it has diagnostics
    if (!out.empty())
        puts_out(out);
    if (rc != 0) {
        _I_log::error(fmt("target '{}' failed (exit {})", target.name, rc));
        if (!err.empty())
            puts_err(err);
        return rc;
    }
    if (!err.empty() && opts.verbose)
        puts_err(err);

    if (!target.post_build.empty()) {
        _I_log::info(fmt("'{}' post-build: {}", target.name, target.post_build));
        int post_rc = run_command(target.post_build);
        if (post_rc != 0) {
            _I_log::error(fmt("post-build hook failed for '{}' (exit {})", target.name, post_rc));
            return post_rc;
        }
    }

    _I_log::info(fmt("'{}' built successfully", target.name));
    return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Commands
// ─────────────────────────────────────────────────────────────────────────────

static auto execute_build(const Config &cfg, const CLIOptions &opts, const std::string &kairo)
    -> int {
    auto mode = opts.mode_override.value_or(cfg.build.mode);

    _I_log::info("generating compile_commands.json");
    if (!generate_compile_commands(cfg, fs::current_path()))
        _I_log::warn("failed to generate compile_commands.json, continuing");

    // select targets
    std::vector<Target> selected;
    if (opts.positional.empty()) {
        selected = cfg.targets;
    } else {
        std::unordered_map<std::string, const Target *> by_name;
        for (auto &t : cfg.targets)
            by_name[t.name] = &t;

        // collect requested + their transitive deps
        std::unordered_set<std::string>          needed;
        std::function<void(const std::string &)> add_deps = [&](const std::string &n) {
            if (needed.contains(n))
                return;
            needed.insert(n);
            if (by_name.contains(n))
                for (auto &d : by_name[n]->deps)
                    add_deps(d);
        };

        for (auto &name : opts.positional) {
            if (!by_name.contains(name)) {
                _I_log::error(fmt("unknown target: '{}'", name));
                return 1;
            }
            add_deps(name);
        }

        for (auto &t : cfg.targets)
            if (needed.contains(t.name))
                selected.push_back(t);
    }

    auto order = topo_sort(selected);
    auto waves = build_waves(selected, order);

    std::unordered_map<std::string, const Target *> by_name;
    for (auto &t : selected)
        by_name[t.name] = &t;

    std::mutex        log_mtx;
    std::atomic<bool> any_failed{false};
    int               max_jobs =
        opts.jobs > 0 ? opts.jobs : static_cast<int>(std::thread::hardware_concurrency());
    if (max_jobs < 1)
        max_jobs = 1;

    for (auto &wave : waves) {
        if (any_failed.load() && !opts.keep_going)
            break;

        if (wave.size() == 1) {
            int rc = build_target(*by_name[wave[0]], cfg, mode, opts, kairo, log_mtx);
            if (rc != 0) {
                any_failed.store(true);
                if (!opts.keep_going)
                    return rc;
            }
        } else {
            std::counting_semaphore<> sem(max_jobs);
            std::vector<std::jthread> threads;
            std::atomic<int>          wave_rc{0};

            for (auto &name : wave) {
                if (any_failed.load() && !opts.keep_going)
                    break;
                sem.acquire();
                threads.emplace_back([&, name]() {
                    int rc = build_target(*by_name[name], cfg, mode, opts, kairo, log_mtx);
                    if (rc != 0) {
                        wave_rc.store(rc);
                        any_failed.store(true);
                    }
                    sem.release();
                });
            }
            threads.clear();  // join all

            if (wave_rc.load() != 0 && !opts.keep_going)
                return wave_rc.load();
        }
    }

    return any_failed.load() ? 1 : 0;
}

static auto execute_clean(const Config &cfg, const CLIOptions &opts) -> int {
    if (opts.positional.empty()) {
        _I_log::info("cleaning all build artifacts");
        std::error_code ec;
        fs::remove_all("build", ec);
        if (ec)
            _I_log::warn(fmt("failed to remove build/: {}", ec.message()));
        fs::remove("compile_commands.json", ec);
        return 0;
    }

    auto triple = get_triple();
    for (auto &name : opts.positional) {
        for (auto &mode_str : {"release", "debug"}) {
            auto bin = fs::path("build") / triple / mode_str / "bin" / name;
            if (fs::exists(bin)) {
                _I_log::info(fmt("removing {}", bin.string()));
                fs::remove(bin);
            }
        }
        for (auto &suffix : {"_meta.cpp", ".rc", ".res"}) {
            std::error_code ec;
            fs::remove(fs::path("build") / ".gen" / (name + suffix), ec);
        }
    }
    return 0;
}

static auto execute_index(const Config &cfg) -> int {
    _I_log::info("regenerating compile_commands.json");
    if (!generate_compile_commands(cfg, fs::current_path())) {
        _I_log::error("failed to generate compile_commands.json");
        return 1;
    }
    _I_log::info("compile_commands.json updated");
    return 0;
}

static auto execute_deps(const Config &cfg, const CLIOptions &opts, const std::string &kairo)
    -> int {
    if (opts.positional.empty()) {
        _I_log::error("usage: kbld deps <file.kro>");
        return 1;
    }

    auto file = opts.positional[0];
    if (!fs::exists(file)) {
        _I_log::error(fmt("file not found: {}", file));
        return 1;
    }

    const auto &first = cfg.targets.front();
    std::string cmd   = kairo + " " + file + " --deps";
    for (auto &inc : first.includes)
        cmd += " -I" + inc;

    std::string out, err;
    run_capture_all(cmd, out, err);

    // parse {"dependencies": [...]} from stdout
    auto pos = out.find("{\"dependencies\":");
    if (pos == std::string::npos) {
        putln(fmt("no dependencies found for {}", file));
        return 0;
    }

    std::vector<std::string> deps;
    try {
        auto doc = json::parse(out.substr(pos));
        for (auto &d : doc["dependencies"])
            deps.push_back(d.get<std::string>());
    } catch (...) {
        putln("failed to parse dependency output");
        return 1;
    }

    putln(file);
    for (std::size_t i = 0; i < deps.size(); ++i) {
        bool last = (i + 1 == deps.size());
        putln(fmt("  {} {}", last ? "└──" : "├──", deps[i]));
    }
    return 0;
}

static auto execute_install(const Config &cfg, const CLIOptions &opts) -> int {
    auto mode    = opts.mode_override.value_or(cfg.build.mode);
    auto triple  = get_triple();
    auto bin_dir = fs::path("build") / triple / to_string(mode) / "bin";
    auto dest    = fs::path(opts.install_prefix) / "bin";

    if (!fs::exists(bin_dir)) {
        _I_log::error(
            fmt("build directory '{}' not found. run kbld build first.", bin_dir.string()));
        return 1;
    }
    fs::create_directories(dest);

    int installed = 0;
    for (auto &t : cfg.targets) {
        if (t.kind != TargetType::Binary)
            continue;
        auto src = bin_dir / t.name;
        if (!fs::exists(src)) {
            _I_log::warn(fmt("binary '{}' not found, skipping", t.name));
            continue;
        }
        auto dst = dest / t.name;
        _I_log::info(fmt("installing {} -> {}", src.string(), dst.string()));
        std::error_code ec;
        fs::copy_file(src, dst, fs::copy_options::overwrite_existing, ec);
        if (ec) {
            _I_log::error(fmt("failed to install '{}': {}", t.name, ec.message()));
            return 1;
        }
#ifndef _WIN32
        fs::permissions(dst,
                        fs::perms::owner_exec | fs::perms::group_exec | fs::perms::others_exec,
                        fs::perm_options::add,
                        ec);
#endif
        ++installed;
    }
    _I_log::info(fmt("installed {} binaries to {}", installed, dest.string()));
    return 0;
}

static auto execute_test(const Config &cfg, const CLIOptions &opts, const std::string &kairo)
    -> int {
    if (opts.positional.empty()) {
        _I_log::error("usage: kbld test <file.kro> [--perf] [--compile-only]");
        return 1;
    }

    auto file = opts.positional[0];
    if (!fs::exists(file)) {
        _I_log::error(fmt("test file not found: {}", file));
        return 1;
    }

    auto source = read_file(file);

    // strip comments, look for fn Test() -> i32
    std::string stripped;
    stripped.reserve(source.size());
    for (std::size_t i = 0; i < source.size(); ++i) {
        if (i + 1 < source.size() && source[i] == '/' && source[i + 1] == '/') {
            while (i < source.size() && source[i] != '\n')
                ++i;
            stripped += '\n';
        } else if (i + 1 < source.size() && source[i] == '/' && source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.size() && !(source[i] == '*' && source[i + 1] == '/'))
                ++i;
            if (i + 1 < source.size())
                ++i;
        } else {
            stripped += source[i];
        }
    }

    if (stripped.find("fn Test()") == std::string::npos &&
        stripped.find("fn Test ()") == std::string::npos) {
        _I_log::error(fmt("{}: no 'fn Test() -> i32' found", file));
        return 1;
    }

    auto test_dir = fs::path("build") / ".shared" / "tests";
    fs::create_directories(test_dir);
    auto gen_dir = fs::path("build") / ".gen";
    fs::create_directories(gen_dir);

    auto filename  = fs::path(file).filename().string();
    auto test_file = test_dir / filename;
    auto test_bin  = gen_dir / "test_run";

    write_file(test_file, source + "\n\nfn main() -> i32 {\n    return Test();\n}\n");

    BuildMode   mode  = opts.perf ? BuildMode::Release : BuildMode::Debug;
    const auto &first = cfg.targets.front();

    std::string cmd = kairo + " " + test_file.string() + " -o" + test_bin.string();
    for (auto &inc : first.includes)
        cmd += " -I" + inc;
    cmd += (mode == BuildMode::Debug) ? " --debug" : " --release";
    if (opts.verbose)
        cmd += " --verbose";

    // mirror build_command passthrough
    std::vector<std::string> passthrough;
    for (auto &def : first.defines)
        passthrough.push_back("-D" + def);
    for (auto &lf : first.ld_flags)
        passthrough.push_back(lf);
    for (auto &src : first.cxx_sources)
        passthrough.push_back(src);
    for (auto &pt : first.cxx_passthrough)
        passthrough.push_back(pt);

    if (!passthrough.empty()) {
        cmd += " --";
        for (auto &pt : passthrough)
            cmd += " " + pt;
    }

    _I_log::info(fmt("compiling test: {}", filename));
    if (opts.verbose)
        _I_log::info(fmt("  {}", cmd));
    if (opts.dry_run)
        return 0;

    std::string out, err;
    int         rc = run_capture_all(cmd, out, err);
    if (!out.empty())
        puts_out(out);
    if (rc != 0) {
        _I_log::error(fmt("test compilation failed (exit {})", rc));
        if (!err.empty())
            puts_err(err);
        return rc;
    }

    if (opts.compile_only) {
        _I_log::info(fmt("test compiled: {}", test_bin.string()));
        return 0;
    }

    int         tw = terminal_width();
    std::string hr(tw, '-');
    putln(hr);
    int exit_code = run_command(test_bin.string());
    putln(hr);

    if (exit_code == 0)
        _I_log::info("test PASSED");
    else
        _I_log::error(fmt("test FAILED (exit {})", exit_code));

    return exit_code;
}

// ─────────────────────────────────────────────────────────────────────────────
// main
// ─────────────────────────────────────────────────────────────────────────────

int main(int argc, char *argv[]) {
    try {
        auto opts = parse_cli(argc, argv);

        // find build.kro — walk up from cwd
        fs::path script_src;
        fs::path root = fs::current_path();
        {
            auto dir = root;
            while (true) {
                if (fs::exists(dir / "build.kro")) {
                    script_src = dir / "build.kro";
                    root       = dir;
                    fs::current_path(dir);
                    break;
                }
                auto parent = dir.parent_path();
                if (parent == dir)
                    break;  // filesystem root, give up
                dir = parent;
            }
        }

        if (script_src.empty()) {
            _I_log::error("build.kro not found in current or parent directories");
            return 1;
        }

        auto cfg = load_config(script_src, root, "kairo", opts);

        // resolve actual kairo binary after we have cfg.build.compiler
        auto kairo = find_kairo(cfg.build.compiler);

        if (opts.mode_override.has_value())
            cfg.build.mode = *opts.mode_override;

        switch (opts.command) {
            case Command::Build:
                return execute_build(cfg, opts, kairo);
            case Command::Clean:
                return execute_clean(cfg, opts);
            case Command::Test:
                return execute_test(cfg, opts, kairo);
            case Command::Deps:
                return execute_deps(cfg, opts, kairo);
            case Command::Index:
                return execute_index(cfg);
            case Command::Install:
                return execute_install(cfg, opts);
        }
        return 0;

    } catch (const std::exception &e) {
        _I_log::error(e.what());
        return 1;
    }
}