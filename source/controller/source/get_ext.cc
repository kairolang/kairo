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
#include <iostream>
#include <stdexcept>
#include <vector>

#include "controller/include/shared/file_system.hh"

#if defined(_WIN32) || defined(WIN32) || defined(_WIN64) || defined(WIN64)
#include <windows.h>
#elif defined(__unix__) || defined(__linux__) || defined(__FreeBSD__) || defined(__NetBSD__) || \
    defined(__OpenBSD__) || defined(__bsdi__) || defined(__DragonFly__)
#include <unistd.h>
#elif defined(__APPLE__) || defined(__MACH__)
#include <mach-o/dyld.h>
#else
#error "unsupported platform"
#endif

__CONTROLLER_FS_BEGIN {
    fs_path get_exe() {
#if defined(_WIN32) || defined(WIN32) || defined(_WIN64) || defined(WIN64)
#include "controller/lib/shared/windows/__exe.inc"
#elif defined(__unix__) || defined(__linux__) || defined(__FreeBSD__) || defined(__NetBSD__) || \
    defined(__OpenBSD__) || defined(__bsdi__) || defined(__DragonFly__)
#include "controller/lib/shared/unix/__exe.inc"
#elif defined(__APPLE__) || defined(__MACH__)
#include "controller/lib/shared/mac/__exe.inc"
#else
        throw std::runtime_error("unsupported platform");
#endif
    }
}  // __CONTROLLER_FS_BEGIN