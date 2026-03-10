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
///   SPDX-License-Identifier: Apache-2.0                                                        ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

#include "controller/include/shared/file_system.hh"
#include "neo-panic/include/error.hh"

__CONTROLLER_FS_BEGIN {
    std::unordered_map<std::string, std::string> FileCache::cache_;
    std::mutex                                   FileCache::mutex_;

    void FileCache::add_file(const std::string &key, const std::string &value) {
        std::lock_guard<std::mutex> lock(mutex_);
        cache_[key] = value;
    }

    std::optional<std::string> FileCache::get_file(const std::string &key) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto                        cache_it = cache_.find(key);
        if (cache_it != cache_.end()) {
            return cache_it->second;
        }
        return std::nullopt;
    }

    std::optional<std::string> get_line(const std::string &filename, u64 line) {
        std::string source = __CONTROLLER_FS_N::read_file(filename);

        u64 current_line = 1;
        u64 start        = 0;
        u64 end          = 0;

        for (u64 i = 0; i < source.size(); ++i) {
            if (source[i] == '\n') {
                ++current_line;
                if (current_line == line) {
                    start = i + 1;
                } else if (current_line == line + 1) {
                    end = i;
                    break;
                }
            }

            if (i == source.size() - 1) {
                end = source.size();
            }
        }

        if (line > current_line) {
            return std::nullopt;
        }

        return source.substr(start, end - start);
    }

    std::string _internal_read_file(const std::string &filename) {
        auto cached_file = FileCache::get_file(filename);
        if (cached_file.has_value()) {
            return cached_file.value();
        }

        std::ifstream file(filename, std::ios::binary | std::ios::ate);

        if (!file) {
            error::Panic(error::CompilerError{2.1001, {}, std::vector<string>{filename}});
            return "";
        }

        std::streamsize size = file.tellg();
        file.seekg(0, std::ios::beg);

        std::string source(size, '\0');
        if (!file.read(source.data(), size)) {
            error::Panic(error::CompilerError{2.1003, {}, std::vector<string>{filename}});
            return "";
        }

        FileCache::add_file(filename, source);

        return source;
    }

    fs_path normalize_path(std::string & filename) {
        std::optional<fs_path> path = __CONTROLLER_FS_N::resolve_path(filename);

        if (!path.has_value()) {
            error::Panic(error::CompilerError{2.1001, {}, std::vector<string>{filename}});
            std::exit(1);
        }

        return path.value();
    }

    fs_path normalize_path_no_check(std::string & filename) {
        std::optional<fs_path> path = __CONTROLLER_FS_N::resolve_path(filename, false);

        if (!path.has_value()) {
            error::Panic(error::CompilerError{2.1001, {}, std::vector<string>{filename}});
            std::exit(1);
        }

        return path.value();
    }

    std::string read_file(std::string & filename) {
        std::optional<fs_path> path = __CONTROLLER_FS_N::resolve_path(filename, true, false);
        if (!path.has_value()) {
            error::Panic(error::CompilerError{2.1001, {}, std::vector<string>{filename}});
            std::exit(1);
        }

        return _internal_read_file(path.value().string());
    }

    // TODO: make all readfiles after the first one be relative to the first one
    /// Example: readfile("file1.kro") -> /path/to/file1.kro
    ///          readfile("test/file2.kro") -> /path/to/test/file2.kro
    ///          readfile("../file3.kro") -> /path/to/file3.kro

    std::string read_file(const std::string &filename) {
        std::optional<fs_path> path = __CONTROLLER_FS_N::resolve_path(filename, true, false);
        if (!path.has_value()) {
            error::Panic(error::CompilerError{2.1001, {}, std::vector<string>{filename}});
            std::exit(1);
        }

        return _internal_read_file(path.value().string());
    }
}  // __CONTROLLER_FS_BEGIN