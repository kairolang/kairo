///--- The Helix Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Helix Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
///   Copyright (c) 2024 The Helix Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#ifndef __EXE_H__
#define __EXE_H__

/// uncomment only for lsp support otherwise there will be build errors.
#include "../../lib-helix/core/include/core.hh"

#if defined(_WIN32) || defined(WIN32) || defined(_WIN64) || defined(WIN64)
#   include <windows.h>
#elif defined(__unix__) || defined(__linux__) || defined(__FreeBSD__) || defined(__NetBSD__) || \
    defined(__OpenBSD__) || defined(__bsdi__) || defined(__DragonFly__)
#   include <unistd.h>
#elif defined(__APPLE__) || defined(__MACH__)
#   include <mach-o/dyld.h>
#else
#   error "unsupported platform"
#endif

namespace helix {
// This function retrieves the path of the currently running executable.
// It uses platform-specific methods to ensure compatibility across different systems.
// The implementation is platform-dependent and may vary based on the operating system.
inline libcxx::filesystem::path get_executable_path() {
#if defined(_WIN32) || defined(WIN32) || defined(_WIN64) || defined(WIN64)
    DWORD                bufferSize = 256;
    libcxx::vector<char> buffer(bufferSize);

    while (true) {
        DWORD result = GetModuleFileNameA(NULL, buffer.data(), bufferSize);
        if (result == 0) {
            throw libcxx::runtime_error("Failed to retrieve executable path");
        }
        if (result < bufferSize) {
            return libcxx::filesystem::path(buffer.data());
        }
        bufferSize *= 2;
        buffer.resize(bufferSize);
    }
#elif defined(__unix__) || defined(__linux__) || defined(__FreeBSD__) || defined(__NetBSD__) || \
    defined(__OpenBSD__) || defined(__bsdi__) || defined(__DragonFly__)
    size_t               bufferSize = 256;
    libcxx::vector<char> buffer(bufferSize);

    while (true) {
        ssize_t count = readlink("/proc/self/exe", buffer.data(), bufferSize);
        if (count == -1) {
            throw libcxx::runtime_error("Failed to retrieve executable path");
        }
        if (static_cast<size_t>(count) < bufferSize) {
            return libcxx::filesystem::path(libcxx::string(buffer.data(), count));
        }
        bufferSize *= 2;
        buffer.resize(bufferSize);
    }
#elif defined(__APPLE__) || defined(__MACH__)
    uint32_t             bufferSize = 256;
    libcxx::vector<char> buffer(bufferSize);

    while (true) {
        if (_NSGetExecutablePath(buffer.data(), &bufferSize) == 0) {
            return libcxx::filesystem::path(buffer.data());
        }

        buffer.resize(bufferSize);  // _NSGetExecutablePath updates bufferSize if it was too small
    }
#else
    throw std::runtime_error("unsupported platform");
#endif
}
}  // namespace helix

#endif  // __EXE_H__