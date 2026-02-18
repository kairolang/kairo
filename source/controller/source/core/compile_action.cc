///--- The Kairo Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#include <filesystem>
#include <fstream>
#include <iostream>
#include <neo-panic/include/error.hh>
#include <neo-pprint/include/hxpprint.hh>
#include <numeric>
#include <random>
#include <string>
#include <utility>

#ifdef _WIN32
#include <Windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

#include "controller/include/config/Controller_config.def"
#include "controller/include/shared/eflags.hh"
#include "controller/include/shared/file_system.hh"
#include "controller/include/shared/logger.hh"
#include "controller/include/tooling/tooling.hh"

#ifndef DEBUG_LOG
#define DEBUG_LOG(...)                            \
    if (is_verbose) {                             \
        kairo::log<LogLevel::Debug>(__VA_ARGS__); \
    }
#endif

class FileLock {
  public:
    explicit FileLock(const std::filesystem::path &path)
        : filePath(path.generic_string()) {
#ifdef _WIN32
        hFile = CreateFileA(path.generic_string().c_str(),
                            GENERIC_READ | GENERIC_WRITE,
                            0,
                            nullptr,
                            OPEN_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL,
                            nullptr);
        if (hFile == INVALID_HANDLE_VALUE) {
            success = false;
            return;
        }

        OVERLAPPED ov = {0};
        if (!LockFileEx(hFile,
                        LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                        0,
                        MAXDWORD,
                        MAXDWORD,
                        &ov)) {
            CloseHandle(hFile);
            hFile   = INVALID_HANDLE_VALUE;
            success = false;
            return;
        }
#else
        fd = open(path.c_str(), O_RDWR | O_CREAT, 0666);
        if (fd < 0) {
            success = false;
            return;
        }

        struct flock fl{};
        fl.l_type   = F_WRLCK;
        fl.l_whence = SEEK_SET;
        fl.l_start  = 0;
        fl.l_len    = 0;

        if (fcntl(fd, F_SETLK, &fl) == -1) {
            close(fd);
            fd      = -1;
            success = false;
            return;
        }
#endif
        success = true;
    }

    ~FileLock() {
        if (!success) {
            return;
        }
#ifdef _WIN32
        OVERLAPPED ov = {0};
        UnlockFileEx(hFile, 0, MAXDWORD, MAXDWORD, &ov);
        CloseHandle(hFile);
#else
        struct flock fl{};
        fl.l_type   = F_UNLCK;
        fl.l_whence = SEEK_SET;
        fl.l_start  = 0;
        fl.l_len    = 0;
        fcntl(fd, F_SETLK, &fl);
        close(fd);
#endif
        // also delete the lock file
        std::error_code ec;
        std::filesystem::remove(filePath, ec);
    }

    bool is_locked() const { return success; }

  private:
    std::string filePath;
    bool        success = false;

#ifdef _WIN32
    HANDLE hFile = INVALID_HANDLE_VALUE;
#else
    int fd = -1;
#endif
};

void cleanup_old_files(const std::filesystem::path &dir) {
    using namespace std::chrono;

    auto now = std::filesystem::file_time_type::clock::now();
    std::vector<std::filesystem::directory_entry> files;

    // collect regular files
    for (auto &entry : std::filesystem::directory_iterator(dir)) {
        if (entry.is_regular_file()) {
            files.push_back(entry);
        }
    }

    // age-based cleanup
    for (auto &entry : files) {
        auto ftime = std::filesystem::last_write_time(entry);
        auto age   = duration_cast<hours>(now - ftime);

        if (age.count() >= 2) {
            std::error_code ec;
            std::filesystem::remove(entry, ec);
        }
    }

    // refresh file list after deletions
    files.clear();
    for (auto &entry : std::filesystem::directory_iterator(dir)) {
        if (entry.is_regular_file()) {
            files.push_back(entry);
        }
    }

    // enforce max 75 files
    if (files.size() > 75) {
        std::sort(files.begin(), files.end(),
            [](auto &a, auto &b) {
                return std::filesystem::last_write_time(a) <
                       std::filesystem::last_write_time(b);
            });

        std::size_t excess = files.size() - 75;
        for (std::size_t i = 0; i < excess; ++i) {
            std::error_code ec;
            std::filesystem::remove(files[i], ec);
        }
    }
}

CXXCompileAction
CXXCompileAction::init(CXIR &emitter, const Path &cc_out, flag::CompileFlags flags, Args cxx_args) {
    std::error_code            ec;
    std::optional<std::string> kairo_src = emitter.get_file_name();
    Path                       cwd       = __CONTROLLER_FS_N::get_cwd();
    Path                       exe       = __CONTROLLER_FS_N::get_exe().parent_path().parent_path();

    // make sure the output directory exists exe / cache / cxx
    if (!std::filesystem::exists(exe / "cache" / "cxx")) {
        std::filesystem::create_directories(exe / "cache" / "cxx/", ec);
        if (ec) {
            kairo::log<LogLevel::Error>("error creating cache at: ",
                                        (exe / "cache" / "cxx").generic_string(),
                                        " directory: ",
                                        ec.message());
            return {};
        }
    }

    if (!std::filesystem::exists(exe / "cache" / "cxx")) {
        kairo::log<LogLevel::Error>("error creating cache directory: ", ec.message());
        return {};
    }

    FileLock cleanup_lock(exe / "cache" / "cxx" / "cleanup.lock");

    if (cleanup_lock.is_locked()) {
        cleanup_old_files(exe / "cache" / "cxx");
    }

    Path cc_source = exe / "cache" / "cxx" / ("kairoCXIR" + generate_file_name(10) + ".cxx");

    bool is_verbose = flags.contains(EFlags(flag::types::CompileFlags::Verbose));

    // if (ec) {  /// use the current working directory
    //     temp_dir = cwd;
    // }

    if (flags.contains(EFlags(flag::types::CompileFlags::Verbose)) &&
        flags.contains(EFlags(flag::types::CompileFlags::Debug))) {
        cc_source = cwd / "IR.temp.debug.verbose.kairo-compiler.cxx";
    }


    struct {
        std::string compiler = "c++";
        
        static std::string does_tool_exist(const std::string& tool) {
            char* path = std::getenv("PATH");
            
            for (const auto& dir : std::filesystem::path(path ? path : "").string()
                                                     | std::views::split(':')) {

                auto full_path = std::filesystem::path(std::string(dir.begin(), dir.end())) / tool;
            
                if (std::filesystem::exists(full_path) &&
                    std::system((full_path.string() + " --version >/dev/null 2>&1").c_str()) == 0) {
                    /// return the full path to the tool
                    return full_path.string();
                }
            }
            
            return std::string{};
        }
    
        void find() {
            std::array<std::string, 6> compilers = {
                "clang++",
                "clang-cl",
                "cl",
                "g++",
                "GCC",
                "c++"
            };

            for (const auto &c : compilers) {
                if (does_tool_exist(c).empty()) {
                    continue;
                }

                this->compiler = c;
                return;
            }
        }
    } cxx_compiler = {};

    cxx_compiler.find();

    if (cxx_compiler.compiler.empty()) {
        kairo::log<LogLevel::Error>("no C++ compiler found, please install one");
        return {};
    }

    CXXCompileAction action = CXXCompileAction{
        /* working_dir */ cwd,
        /* cc_source   */ cc_source,
        /* cc_output   */ cc_out,
        /* kairo_src   */ kairo_src.has_value() ? Path(kairo_src.value()) : cc_out,
        /* cxx_args    */ std::move(cxx_args),
        /* flags       */ flags,
#if defined(__unix__) || defined(__APPLE__) || defined(__linux__) || defined(__FreeBSD__) ||      \
    defined(__NetBSD__) || defined(__OpenBSD__) || defined(__bsdi__) || defined(__DragonFly__) || \
    defined(__MACH__)
        /* cxx_compiler */ cxx_compiler.compiler,  // find c++ compiler using PATH
#else
        /* cxx_compiler */ "",  // find msvc using vswhere, if not found try `c++`
#endif
    };

    std::ofstream file(action.cc_source);

    if (!file) {
        kairo::log<LogLevel::Error>("error creating ", action.cc_source.generic_string(), " file");
        return action;
    }

    file << emitter.to_CXIR();
    file.close();

    if (flags.contains(EFlags(flag::types::CompileFlags::Verbose))) {
        DEBUG_LOG("CXXCompileAction initialized with:");
        DEBUG_LOG("working_dir: ", action.working_dir.generic_string());
        DEBUG_LOG("cc_source: ", action.cc_source.generic_string());
        DEBUG_LOG("cc_output: ", action.cc_output.generic_string());
        DEBUG_LOG("kairo_src: ", action.kairo_src.generic_string());
        DEBUG_LOG("cxx_compiler: ", action.cxx_compiler);
        DEBUG_LOG("cxx_args: ",
                  "[" +
                      std::accumulate(action.cxx_args.begin(),
                                      action.cxx_args.end(),
                                      std::string(),
                                      [](const std::string &a, const std::string &b) {
                                          return a.empty() ? b : a + ", " + b;
                                      }) +
                      "]");
        DEBUG_LOG("does cc_source exists? : ",
                  std::filesystem::exists(action.cc_source) ? "yes" : "no");
    }

    return action;
}

CXXCompileAction::~CXXCompileAction()
#if defined(__unix__) || defined(__APPLE__) || defined(__linux__) || defined(__FreeBSD__) ||      \
    defined(__NetBSD__) || defined(__OpenBSD__) || defined(__bsdi__) || defined(__DragonFly__) || \
    defined(__MACH__)
{
    cleanup();
}
#else
    = default;
#endif

void CXXCompileAction::cleanup() const {  // skip cleanup
#ifndef DEBUG_OUTPUT
    // if (std::filesystem::exists(cc_source)) {
    //     std::filesystem::remove(cc_source);
    // }
#endif
}

std::string CXXCompileAction::generate_file_name(size_t length) {
    const std::string chars = "QCDEGHINOPQRSAIUVYZabcefgjklnopqrsuvwyz012345789";

    std::random_device              rd;
    std::mt19937                    gen(rd());
    std::string                     name = "__";
    std::uniform_int_distribution<> dist(0, chars.size() - 1);

    name.reserve(length + name.size());

    std::generate_n(std::back_inserter(name), length, [&]() { return chars[dist(gen)]; });

    return name;
}