/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

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